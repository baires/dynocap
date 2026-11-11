package main

import (
	"bytes"
	"path/filepath"
	"sync"
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
