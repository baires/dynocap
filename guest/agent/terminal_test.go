package main

import (
	"bytes"
	"net"
	"strings"
	"syscall"
	"testing"
	"time"

	"microvm.dev/guest/internal/protocol"
)

type terminalRun struct {
	t      *testing.T
	client net.Conn
	frames chan protocol.Message
	output bytes.Buffer
}

func startTerminal(t *testing.T, msg protocol.Message) *terminalRun {
	t.Helper()
	client, server := net.Pipe()
	go handleConn(server)
	hello, err := protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	if !protocol.AdvertisesTerminal(hello.Agent) {
		t.Fatalf("agent %q does not advertise terminals", hello.Agent)
	}
	msg.Type = protocol.TypeExecTTY
	if err := protocol.WriteFrame(client, msg); err != nil {
		t.Fatal(err)
	}
	run := &terminalRun{t: t, client: client, frames: make(chan protocol.Message, 64)}
	go func() {
		defer close(run.frames)
		for {
			frame, err := protocol.ReadFrame(client)
			if err != nil {
				return
			}
			run.frames <- frame
		}
	}()
	t.Cleanup(func() { client.Close() })
	return run
}

func (r *terminalRun) send(msg protocol.Message) {
	r.t.Helper()
	if err := protocol.WriteFrame(r.client, msg); err != nil {
		r.t.Fatal(err)
	}
}

// waitFor reads frames until the combined output contains text.
func (r *terminalRun) waitFor(text string) {
	r.t.Helper()
	deadline := time.After(5 * time.Second)
	for !strings.Contains(r.output.String(), text) {
		select {
		case frame, ok := <-r.frames:
			if !ok {
				r.t.Fatalf("connection closed before %q; output %q", text, r.output.String())
			}
			r.record(frame)
			if frame.Type == protocol.TypeExit && !strings.Contains(r.output.String(), text) {
				r.t.Fatalf("exited before %q; output %q", text, r.output.String())
			}
		case <-deadline:
			r.t.Fatalf("timed out waiting for %q; output %q", text, r.output.String())
		}
	}
}

func (r *terminalRun) exit() protocol.Message {
	r.t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case frame, ok := <-r.frames:
			if !ok {
				r.t.Fatalf("connection closed before exit; output %q", r.output.String())
			}
			r.record(frame)
			if frame.Type == protocol.TypeExit {
				return frame
			}
		case <-deadline:
			r.t.Fatalf("no exit; output %q", r.output.String())
		}
	}
}

func (r *terminalRun) record(frame protocol.Message) {
	switch frame.Type {
	case protocol.TypeStdout:
		r.output.Write(frame.Data)
	case protocol.TypeStderr:
		r.t.Fatalf("terminal exec produced a separate stderr frame %q", frame.Data)
	case protocol.TypeError:
		r.t.Fatalf("agent error %q", frame.Error)
	}
}

func TestTerminalExecHasControllingTerminalAndInitialSize(t *testing.T) {
	run := startTerminal(t, protocol.Message{ID: 41, Rows: 30, Cols: 100, Argv: []string{"python3", "-c", `
import os, sys
assert os.isatty(0) and os.isatty(1) and os.isatty(2)
assert os.getsid(0) == os.getpid(), "not a session leader"
assert os.tcgetpgrp(0) == os.getpgrp(), "not the foreground group"
size = os.get_terminal_size(0)
print("size", size.lines, size.columns, os.environ["TERM"])
print("err", file=sys.stderr)
`}})
	exit := run.exit()
	if exit.ExitCode != 0 || exit.ExitSignal != 0 {
		t.Fatalf("exit %+v output %q", exit, run.output.String())
	}
	// stdout and stderr share the terminal, and output post-processing adds CR.
	if run.output.String() != "size 30 100 xterm-256color\r\nerr\r\n" {
		t.Fatalf("output %q", run.output.String())
	}
}

func TestTerminalEnvOverrideWinsOverDefaultTerm(t *testing.T) {
	run := startTerminal(t, protocol.Message{ID: 42, Env: []string{"TERM=dumb"}, Argv: []string{"sh", "-c", `echo "$TERM"; stty size`}})
	if exit := run.exit(); exit.ExitCode != 0 {
		t.Fatalf("exit %+v", exit)
	}
	if run.output.String() != "dumb\r\n24 80\r\n" {
		t.Fatalf("unknown size should default to 24x80; output %q", run.output.String())
	}
}

// The session leader moves a child into its own foreground group, like a job
// control shell. Ctrl-C and a host signal must reach that child, not the leader.
const foregroundJob = `
import os, signal, sys, time
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
ready_r, ready_w = os.pipe()
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.setpgid(0, 0)
    os.write(ready_w, b"x")
    time.sleep(30)
    os._exit(0)
os.read(ready_r, 1)
os.tcsetpgrp(0, pid)
print("ready", flush=True)
_, status = os.waitpid(pid, 0)
os.tcsetpgrp(0, os.getpgrp())
print("child signal", os.WTERMSIG(status) if os.WIFSIGNALED(status) else 0, flush=True)
`

func TestTerminalCtrlCReachesTheForegroundJob(t *testing.T) {
	run := startTerminal(t, protocol.Message{ID: 43, Argv: []string{"python3", "-c", foregroundJob}})
	run.waitFor("ready")
	run.send(protocol.Message{Type: protocol.TypeStdin, ID: 43, Data: []byte{0x03}})
	run.waitFor("child signal 2")
	if exit := run.exit(); exit.ExitCode != 0 || exit.ExitSignal != 0 {
		t.Fatalf("session leader should survive; exit %+v", exit)
	}
}

func TestTerminalSignalFrameTargetsTheForegroundJob(t *testing.T) {
	run := startTerminal(t, protocol.Message{ID: 44, Argv: []string{"python3", "-c", foregroundJob}})
	run.waitFor("ready")
	run.send(protocol.Message{Type: protocol.TypeSignal, ID: 44, Signal: int32(syscall.SIGINT)})
	run.waitFor("child signal 2")
	if exit := run.exit(); exit.ExitCode != 0 {
		t.Fatalf("exit %+v", exit)
	}
}

func TestTerminalCtrlCEndsAForegroundCommand(t *testing.T) {
	run := startTerminal(t, protocol.Message{ID: 45, Argv: []string{"sh", "-c", "echo ready; exec sleep 30"}})
	run.waitFor("ready")
	run.send(protocol.Message{Type: protocol.TypeStdin, ID: 45, Data: []byte{0x03}})
	if exit := run.exit(); exit.ExitCode != -1 || exit.ExitSignal != int32(syscall.SIGINT) {
		t.Fatalf("exit %+v", exit)
	}
}

func TestTerminalResizeDeliversWinch(t *testing.T) {
	run := startTerminal(t, protocol.Message{ID: 46, Rows: 24, Cols: 80, Argv: []string{"python3", "-c", `
import os, signal, sys
def winch(*_):
    size = os.get_terminal_size(0)
    print("winch", size.lines, size.columns, flush=True)
    sys.exit(0)
signal.signal(signal.SIGWINCH, winch)
print("ready", flush=True)
signal.pause()
`}})
	run.waitFor("ready")
	run.send(protocol.Message{Type: protocol.TypeResize, ID: 46, Rows: 40, Cols: 120})
	run.waitFor("winch 40 120")
	if exit := run.exit(); exit.ExitCode != 0 {
		t.Fatalf("exit %+v", exit)
	}
}

func TestTerminalInputEchoAndEOFKeepTheTerminalOpen(t *testing.T) {
	run := startTerminal(t, protocol.Message{ID: 47, Argv: []string{"sh", "-c", "read line; sleep 0.2; echo got $line"}})
	run.send(protocol.Message{Type: protocol.TypeStdin, ID: 47, Data: []byte("hi\r")})
	run.send(protocol.Message{Type: protocol.TypeStdinEOF, ID: 47})
	run.waitFor("got hi")
	if exit := run.exit(); exit.ExitCode != 0 {
		t.Fatalf("exit %+v", exit)
	}
	// The line discipline echoes input and maps CR to NL, as on a real terminal.
	if !strings.HasPrefix(run.output.String(), "hi\r\n") {
		t.Fatalf("output %q", run.output.String())
	}
}

func TestTerminalExitStatusAndTimeout(t *testing.T) {
	failed := startTerminal(t, protocol.Message{ID: 48, Argv: []string{"sh", "-c", "exit 5"}})
	if exit := failed.exit(); exit.ExitCode != 5 || exit.ExitSignal != 0 {
		t.Fatalf("exit %+v", exit)
	}
	slow := startTerminal(t, protocol.Message{ID: 49, TimeoutMS: 200, Argv: []string{"sleep", "30"}})
	if exit := slow.exit(); exit.ExitCode != exitTimeout || exit.ExitSignal != 0 {
		t.Fatalf("exit %+v", exit)
	}
	missing := startTerminal(t, protocol.Message{ID: 50, Argv: []string{"/nonexistent/terminal-command"}})
	if exit := missing.exit(); exit.ExitCode != exitNotFound {
		t.Fatalf("exit %+v", exit)
	}
}

func TestTerminalBackgroundHolderDoesNotDelayExit(t *testing.T) {
	started := time.Now()
	run := startTerminal(t, protocol.Message{ID: 51, Argv: []string{"sh", "-c", "trap '' HUP; sleep 5 & echo done"}})
	run.waitFor("done")
	if exit := run.exit(); exit.ExitCode != 0 {
		t.Fatalf("exit %+v", exit)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("exit waited %v for a background process holding the terminal", elapsed)
	}
}

func TestTerminalKillEndsTheSession(t *testing.T) {
	run := startTerminal(t, protocol.Message{ID: 52, Argv: []string{"sh", "-c", "echo ready; sleep 30"}})
	run.waitFor("ready")
	run.send(protocol.Message{Type: protocol.TypeKill, ID: 52})
	if exit := run.exit(); exit.ExitSignal != int32(syscall.SIGKILL) {
		t.Fatalf("exit %+v", exit)
	}
}
