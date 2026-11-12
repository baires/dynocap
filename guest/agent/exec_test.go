package main

import (
	"bytes"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"microvm.dev/guest/internal/protocol"
)

func collectExec(t *testing.T, msg protocol.Message) []protocol.Message {
	t.Helper()
	registerSession(msg.ID)
	defer finishSession(msg.ID)
	// Host sends stdin EOF immediately, matching the CLI.
	lookupSession(msg.ID).closeStdin()

	var mu sync.Mutex
	var got []protocol.Message
	done := make(chan struct{})
	Execute(msg, func(m protocol.Message) error {
		mu.Lock()
		got = append(got, m)
		finished := m.Type == protocol.TypeExit || m.Type == protocol.TypeError
		mu.Unlock()
		if finished {
			select {
			case <-done:
			default:
				close(done)
			}
		}
		return nil
	})
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("exec did not finish")
	}
	mu.Lock()
	defer mu.Unlock()
	return append([]protocol.Message(nil), got...)
}

func TestExecEcho(t *testing.T) {
	msgs := collectExec(t, protocol.Message{
		Type: protocol.TypeExec,
		ID:   1,
		Argv: []string{"sh", "-c", "echo hello"},
	})
	var stdout bytes.Buffer
	var exit *protocol.Message
	for i := range msgs {
		switch msgs[i].Type {
		case protocol.TypeStdout:
			stdout.Write(msgs[i].Data)
		case protocol.TypeExit:
			cp := msgs[i]
			exit = &cp
		}
	}
	if stdout.String() != "hello\n" {
		t.Fatalf("stdout %q", stdout.String())
	}
	if exit == nil || exit.ExitCode != 0 || exit.ExitSignal != 0 {
		t.Fatalf("exit %+v", exit)
	}
}

func TestExecExitCode(t *testing.T) {
	msgs := collectExec(t, protocol.Message{
		Type: protocol.TypeExec,
		ID:   2,
		Argv: []string{"sh", "-c", "echo err >&2; exit 3"},
	})
	var stderr bytes.Buffer
	code := int32(-99)
	for _, m := range msgs {
		if m.Type == protocol.TypeStderr {
			stderr.Write(m.Data)
		}
		if m.Type == protocol.TypeExit {
			code = m.ExitCode
		}
	}
	if stderr.String() != "err\n" {
		t.Fatalf("stderr %q", stderr.String())
	}
	if code != 3 {
		t.Fatalf("code %d", code)
	}
}

func TestExecNotFound(t *testing.T) {
	msgs := collectExec(t, protocol.Message{
		Type: protocol.TypeExec,
		ID:   3,
		Argv: []string{"/no/such/microvm-bin"},
	})
	code := int32(-1)
	for _, m := range msgs {
		if m.Type == protocol.TypeExit {
			code = m.ExitCode
		}
	}
	if code != exitNotFound {
		t.Fatalf("code %d msgs %+v", code, msgs)
	}
}

func TestExecTimeout(t *testing.T) {
	start := time.Now()
	msgs := collectExec(t, protocol.Message{
		Type:      protocol.TypeExec,
		ID:        4,
		TimeoutMS: 200,
		Argv:      []string{"sleep", "30"},
	})
	if time.Since(start) > 3*time.Second {
		t.Fatal("timeout did not fire")
	}
	code := int32(-1)
	for _, m := range msgs {
		if m.Type == protocol.TypeExit {
			code = m.ExitCode
		}
	}
	if code != exitTimeout {
		t.Fatalf("code %d", code)
	}
}

func TestExecCwd(t *testing.T) {
	msgs := collectExec(t, protocol.Message{
		Type: protocol.TypeExec,
		ID:   5,
		Cwd:  "/tmp",
		Argv: []string{"sh", "-c", "pwd"},
	})
	var stdout bytes.Buffer
	for _, m := range msgs {
		if m.Type == protocol.TypeStdout {
			stdout.Write(m.Data)
		}
	}
	got := stdout.String()
	want, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		t.Fatal(err)
	}
	if got != "/tmp\n" && got != want+"\n" {
		t.Fatalf("pwd %q", got)
	}
}

// A transfer payload must not fill the pipe before its child has been started.
func TestLargeStdinAfterStarted(t *testing.T) {
	const id = 9123
	s := registerSession(id)
	defer finishSession(id)
	done := make(chan struct{})
	var output bytes.Buffer
	go func() {
		defer close(done)
		Execute(protocol.Message{Type: protocol.TypeExec, ID: id, Argv: []string{"cat"}, TimeoutMS: 2000}, func(m protocol.Message) error {
			if m.Type == protocol.TypeStarted {
				go func() { s.writeStdin(bytes.Repeat([]byte{'a'}, 1<<20)); s.closeStdin() }()
			}
			if m.Type == protocol.TypeStdout {
				output.Write(m.Data)
			}
			return nil
		})
	}()
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		t.Fatal("stdin transfer blocked")
	}
	if output.Len() != 1<<20 {
		t.Fatalf("got %d bytes", output.Len())
	}
}

func TestStdinEOFIsDelivered(t *testing.T) {
	const id = 44
	s := registerSession(id)
	defer finishSession(id)
	done := make(chan struct{})
	var output bytes.Buffer
	var exitCode int32 = -1
	go func() {
		defer close(done)
		Execute(protocol.Message{Type: protocol.TypeExec, ID: id, Argv: []string{"cat"}}, func(m protocol.Message) error {
			if m.Type == protocol.TypeStarted {
				go func() {
					s.writeStdin([]byte("piped\n"))
					s.closeStdin()
				}()
			}
			if m.Type == protocol.TypeStdout {
				output.Write(m.Data)
			}
			if m.Type == protocol.TypeExit {
				exitCode = m.ExitCode
			}
			return nil
		})
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("cat did not see EOF")
	}
	if output.String() != "piped\n" || exitCode != 0 {
		t.Fatalf("stdout %q code %d", output.String(), exitCode)
	}
}

func TestSignalInterruptsForegroundSleep(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	go handleConn(server)
	if _, err := protocol.ReadFrame(client); err != nil {
		t.Fatal(err)
	}
	if err := protocol.WriteFrame(client, protocol.Message{
		Type: protocol.TypeExec, ID: 3, Argv: []string{"sleep", "30"},
	}); err != nil {
		t.Fatal(err)
	}
	started := false
	deadline := time.After(3 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("sleep was not signaled")
		default:
		}
		msg, err := protocol.ReadFrame(client)
		if err != nil {
			t.Fatal(err)
		}
		if msg.Type == protocol.TypeStarted && !started {
			started = true
			payload := bytes.Repeat([]byte{'x'}, 64<<10)
			for i := 0; i < 4; i++ {
				if err := protocol.WriteFrame(client, protocol.Message{Type: protocol.TypeStdin, ID: 3, Data: payload}); err != nil {
					t.Fatal(err)
				}
			}
			if err := protocol.WriteFrame(client, protocol.Message{
				Type: protocol.TypeSignal, ID: 3, Signal: int32(syscall.SIGINT),
			}); err != nil {
				t.Fatal(err)
			}
		}
		if msg.Type == protocol.TypeExit {
			if msg.ExitSignal != int32(syscall.SIGINT) || msg.ExitCode != -1 {
				t.Fatalf("exit code %d signal %d", msg.ExitCode, msg.ExitSignal)
			}
			return
		}
	}
}

func TestSignalReachesProcessGroupWhileStdinIsBlocked(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	go handleConn(server)
	hello, err := protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	if !protocol.AdvertisesSignal(hello.Agent) {
		t.Fatalf("agent %q does not advertise signals", hello.Agent)
	}
	if protocol.AdvertisesSignal("microvm-agent") || protocol.AdvertisesSignal("microvm-agent signal=10") {
		t.Fatal("old agent advertised signals")
	}
	err = protocol.WriteFrame(client, protocol.Message{
		Type: protocol.TypeExec,
		ID:   7,
		Argv: []string{"python3", "-c", `
import os, signal, time
# The child reports readiness only after it can die from SIGINT; Python
# otherwise ignores a KeyboardInterrupt raised inside its fork hooks.
ready_r, ready_w = os.pipe()
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.write(ready_w, b"x")
    time.sleep(30)
    os._exit(0)
signal.signal(signal.SIGINT, signal.SIG_IGN)
os.read(ready_r, 1)
print("ready", flush=True)
os.wait()
print("done", flush=True)
`},
	})
	if err != nil {
		t.Fatal(err)
	}
	stdout := make(chan []byte, 8)
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		for {
			msg, err := protocol.ReadFrame(client)
			if err != nil {
				return
			}
			if msg.Type == protocol.TypeStdout {
				stdout <- append([]byte(nil), msg.Data...)
			}
		}
	}()
	var got bytes.Buffer
	ready := false
	timeout := time.After(4 * time.Second)
	for !bytes.Contains(got.Bytes(), []byte("done\n")) {
		select {
		case chunk := <-stdout:
			got.Write(chunk)
			if !ready && bytes.Contains(got.Bytes(), []byte("ready\n")) {
				ready = true
				go func() {
					payload := bytes.Repeat([]byte{'x'}, 64<<10)
					for i := 0; i < 4; i++ {
						_ = protocol.WriteFrame(client, protocol.Message{Type: protocol.TypeStdin, ID: 7, Data: payload})
					}
					_ = protocol.WriteFrame(client, protocol.Message{
						Type: protocol.TypeSignal, ID: 7, Signal: int32(syscall.SIGINT),
					})
				}()
			}
		case <-timeout:
			t.Fatalf("ready %v stdout %q", ready, got.String())
		}
	}
	client.Close()
	<-readDone
}

// Input and EOF that both arrive before the process starts must not be dropped.
func TestStdinBeforeStartIsKeptAcrossEarlyEOF(t *testing.T) {
	s := registerSession(53)
	defer finishSession(53)
	if !s.tryWriteStdin([]byte("early\n")) {
		t.Fatal("pre-start stdin was refused")
	}
	s.closeStdin()
	var stdout bytes.Buffer
	var exit protocol.Message
	Execute(protocol.Message{Type: protocol.TypeExec, ID: 53, Argv: []string{"cat"}}, func(m protocol.Message) error {
		switch m.Type {
		case protocol.TypeStdout:
			stdout.Write(m.Data)
		case protocol.TypeExit:
			exit = m
		}
		return nil
	})
	if stdout.String() != "early\n" || exit.ExitCode != 0 {
		t.Fatalf("stdout %q exit %+v", stdout.String(), exit)
	}
}

// The guest init starts the agent as an asynchronous shell command, so the
// agent begins with SIGINT ignored. Guest commands must not inherit that. The
// check runs in a child test binary started the same way, with the signals ignored.
func TestCommandsDoNotInheritAnIgnoredInterrupt(t *testing.T) {
	cmd := exec.Command("sh", "-c", `trap "" INT HUP; exec "$0" -test.run='^TestHelperStartedWithInterruptIgnored$'`, os.Args[0])
	cmd.Env = append(os.Environ(), "MICROVM_AGENT_IGNORED_HELPER=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("helper failed: %v\n%s", err, out)
	}
	if !bytes.Contains(out, []byte("inherited: False False\n")) {
		t.Fatalf("guest command inherited ignored signals:\n%s", out)
	}
}

func TestHelperStartedWithInterruptIgnored(t *testing.T) {
	if os.Getenv("MICROVM_AGENT_IGNORED_HELPER") != "1" {
		t.Skip("helper for TestCommandsDoNotInheritAnIgnoredInterrupt")
	}
	resetInheritedSignals()
	msgs := collectExec(t, protocol.Message{Type: protocol.TypeExec, ID: 54, Argv: []string{"python3", "-c", `
import signal
print("inherited:", signal.getsignal(signal.SIGINT) is signal.SIG_IGN, signal.getsignal(signal.SIGHUP) is signal.SIG_IGN)
`}})
	for _, m := range msgs {
		if m.Type == protocol.TypeStdout {
			os.Stdout.Write(m.Data)
		}
	}
}
