package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"microvm.dev/guest/internal/protocol"
)

const (
	chunkSize     = 32 << 10
	exitTimeout   = 124
	exitNotFound  = 127
	exitCannotRun = 126

	// terminalDrain bounds how long EXIT waits for output after the command
	// exits, when a background process still holds the terminal open.
	terminalDrain = 250 * time.Millisecond
)

// Execute runs one command and emits protocol messages on the shared writer.
// A zero timeout means no timer. On timeout the process group is killed and
// the exit code is 124.
func Execute(req protocol.Message, write func(protocol.Message) error) {
	if req.Type == protocol.TypeExecTTY {
		executeTerminal(req, write)
		return
	}
	if req.Type != protocol.TypeExec {
		_ = write(protocol.Message{Type: protocol.TypeError, ID: req.ID, Error: "not an exec"})
		return
	}
	cmd := command(req, false)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		failStart(req.ID, err, write)
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		failStart(req.ID, err, write)
		return
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		failStart(req.ID, err, write)
		return
	}

	sess := lookupSession(req.ID)

	if err := cmd.Start(); err != nil {
		failStart(req.ID, err, write)
		return
	}
	if sess != nil {
		sess.setPID(cmd.Process.Pid)
		sess.attach(stdin)
	} else {
		_ = stdin.Close()
	}
	_ = write(protocol.Message{Type: protocol.TypeStarted, ID: req.ID})

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		stream(req.ID, protocol.TypeStdout, stdout, write)
	}()
	go func() {
		defer wg.Done()
		stream(req.ID, protocol.TypeStderr, stderr, write)
	}()

	waitDone := make(chan error, 1)
	go func() {
		wg.Wait()
		waitDone <- cmd.Wait()
	}()

	var timer <-chan time.Time
	if req.TimeoutMS > 0 {
		timer = time.After(time.Duration(req.TimeoutMS) * time.Millisecond)
	}

	var waitErr error
	timedOut := false
	select {
	case waitErr = <-waitDone:
	case <-timer:
		timedOut = true
		killGroup(cmd.Process.Pid)
		waitErr = <-waitDone
	}
	if sess != nil {
		sess.done()
	}

	if timedOut {
		_ = write(protocol.Message{Type: protocol.TypeExit, ID: req.ID, ExitCode: exitTimeout, ExitSignal: 0})
		return
	}
	code, sig := statusOf(waitErr)
	_ = write(protocol.Message{Type: protocol.TypeExit, ID: req.ID, ExitCode: code, ExitSignal: sig})
}

// executeTerminal runs the command as a session leader whose controlling
// terminal is a new PTY. Output is one combined STDOUT stream. Input bytes,
// including Ctrl-C, go through the terminal's line discipline, so the kernel
// signals the foreground process group. Stdin EOF does not close the terminal.
func executeTerminal(req protocol.Message, write func(protocol.Message) error) {
	ptmx, pts, err := openPTY()
	if err != nil {
		failStartOn(protocol.TypeStdout, req.ID, err, write)
		return
	}
	defer ptmx.Close()
	if err := setWindowSize(ptmx, req.Rows, req.Cols); err != nil {
		_ = pts.Close()
		failStartOn(protocol.TypeStdout, req.ID, err, write)
		return
	}
	cmd := command(req, true)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = pts, pts, pts
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}

	sess := lookupSession(req.ID)
	err = cmd.Start()
	_ = pts.Close()
	if err != nil {
		failStartOn(protocol.TypeStdout, req.ID, err, write)
		return
	}
	if sess != nil {
		sess.setPID(cmd.Process.Pid)
		sess.attachTerminal(ptmx)
	}
	_ = write(protocol.Message{Type: protocol.TypeStarted, ID: req.ID})

	output := make(chan struct{})
	go func() {
		defer close(output)
		stream(req.ID, protocol.TypeStdout, ptmx, write)
	}()
	waitDone := make(chan error, 1)
	go func() { waitDone <- cmd.Wait() }()

	var timer <-chan time.Time
	if req.TimeoutMS > 0 {
		timer = time.After(time.Duration(req.TimeoutMS) * time.Millisecond)
	}
	var waitErr error
	timedOut := false
	select {
	case waitErr = <-waitDone:
	case <-timer:
		timedOut = true
		killTerminal(cmd.Process.Pid, ptmx)
		waitErr = <-waitDone
	}
	_ = ptmx.SetReadDeadline(time.Now().Add(terminalDrain))
	<-output
	if sess != nil {
		sess.done()
	}
	if timedOut {
		_ = write(protocol.Message{Type: protocol.TypeExit, ID: req.ID, ExitCode: exitTimeout, ExitSignal: 0})
		return
	}
	code, sig := statusOf(waitErr)
	_ = write(protocol.Message{Type: protocol.TypeExit, ID: req.ID, ExitCode: code, ExitSignal: sig})
}

func command(req protocol.Message, terminal bool) *exec.Cmd {
	cmd := exec.Command(req.Argv[0], req.Argv[1:]...)
	cmd.Env = mergeEnv(req.Env, terminal)
	if req.Cwd != "" {
		cmd.Dir = req.Cwd
	} else {
		cmd.Dir = "/"
	}
	return cmd
}

// killTerminal also kills a job the session leader moved to another group.
func killTerminal(pid int, ptmx *os.File) {
	killGroup(pid)
	if pgrp := foregroundGroup(ptmx); pgrp > 0 {
		_ = syscall.Kill(-pgrp, syscall.SIGKILL)
	}
}

func failStart(id uint32, err error, write func(protocol.Message) error) {
	failStartOn(protocol.TypeStderr, id, err, write)
}

// failStartOn reports on the given stream; a terminal exec has only stdout.
func failStartOn(stream uint8, id uint32, err error, write func(protocol.Message) error) {
	code := int32(exitCannotRun)
	if os.IsNotExist(err) || isNotFound(err) {
		code = exitNotFound
	}
	msg := err.Error()
	_ = write(protocol.Message{Type: stream, ID: id, Data: []byte("microvm-agent: " + msg + "\n")})
	_ = write(protocol.Message{Type: protocol.TypeExit, ID: id, ExitCode: code})
}

func isNotFound(err error) bool {
	if ee, ok := err.(*exec.Error); ok {
		return ee.Err == exec.ErrNotFound
	}
	return false
}

func stream(id uint32, typ uint8, r io.Reader, write func(protocol.Message) error) {
	buf := make([]byte, chunkSize)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			chunk := append([]byte(nil), buf[:n]...)
			_ = write(protocol.Message{Type: typ, ID: id, Data: chunk})
		}
		if err != nil {
			return
		}
	}
}

func statusOf(err error) (int32, int32) {
	if err == nil {
		return 0, 0
	}
	ee, ok := err.(*exec.ExitError)
	if !ok {
		return exitCannotRun, 0
	}
	ws, ok := ee.Sys().(syscall.WaitStatus)
	if !ok {
		return int32(ee.ExitCode()), 0
	}
	if ws.Signaled() {
		return -1, int32(ws.Signal())
	}
	return int32(ws.ExitStatus()), 0
}

func killGroup(pid int) {
	if pid <= 0 {
		return
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
}

// mergeEnv builds the guest environment. A terminal exec defaults TERM to
// xterm-256color; --env TERM=... still wins.
func mergeEnv(overrides []string, terminal bool) []string {
	base := map[string]string{
		"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME": "/root",
		"TERM": "vt100",
		"LANG": "C.UTF-8",
	}
	if terminal {
		base["TERM"] = "xterm-256color"
	}
	order := []string{"PATH", "HOME", "TERM", "LANG"}
	var environment map[string]string
	if data, err := os.ReadFile("/etc/microvm-environment.json"); err == nil && json.Unmarshal(data, &environment) == nil {
		for key, value := range environment {
			if _, ok := base[key]; !ok {
				order = append(order, key)
			}
			base[key] = value
		}
	}
	for _, e := range overrides {
		key, val, _ := splitEnv(e)
		if _, ok := base[key]; !ok {
			order = append(order, key)
		}
		base[key] = val
	}
	out := make([]string, 0, len(order))
	for _, k := range order {
		out = append(out, k+"="+base[k])
	}
	return out
}

func splitEnv(e string) (string, string, bool) {
	for i := 0; i < len(e); i++ {
		if e[i] == '=' {
			if i == 0 {
				return "", "", false
			}
			return e[:i], e[i+1:], true
		}
	}
	return "", "", false
}

// session tracks stdin and the process group for one exec id.
type session struct {
	mu       sync.Mutex
	stdin    io.WriteCloser
	buf      bytes.Buffer
	closed   bool
	pid      int
	over     bool
	stdinCh  chan stdinChunk
	terminal *os.File
	rows     uint16
	cols     uint16
}

// terminalInput writes to the PTY's ptmx side. Close is a no-op: stdin EOF must
// not hang up the terminal while the command is still producing output.
type terminalInput struct{ *os.File }

func (terminalInput) Close() error { return nil }

func (s *session) attachTerminal(ptmx *os.File) {
	s.mu.Lock()
	s.terminal = ptmx
	rows, cols := s.rows, s.cols
	s.mu.Unlock()
	if rows > 0 && cols > 0 {
		_ = setWindowSize(ptmx, rows, cols)
	}
	s.attach(terminalInput{ptmx})
}

// resize applies a host window change. A resize before the terminal exists
// is kept and applied at attach.
func (s *session) resize(rows, cols uint16) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.over {
		return
	}
	if s.terminal == nil {
		s.rows, s.cols = rows, cols
		return
	}
	_ = setWindowSize(s.terminal, rows, cols)
}

type stdinChunk struct {
	data  []byte
	close bool
}

// attach hands input that arrived before the process started to the writer,
// in order. Bytes received before an early EOF are still delivered.
func (s *session) attach(w io.WriteCloser) {
	s.mu.Lock()
	s.stdin = w
	s.ensureWriterLocked()
	ch := s.stdinCh
	pending := append([]byte(nil), s.buf.Bytes()...)
	s.buf.Reset()
	closed := s.closed
	s.mu.Unlock()
	if len(pending) > 0 {
		ch <- stdinChunk{data: pending}
	}
	if closed {
		ch <- stdinChunk{close: true}
	}
}

func (s *session) writeStdin(p []byte) {
	if len(p) == 0 || s.tryWriteStdin(p) {
		return
	}
	s.mu.Lock()
	ch := s.stdinCh
	drop := s.over || s.closed || s.stdin == nil
	s.mu.Unlock()
	if drop || ch == nil {
		return
	}
	ch <- stdinChunk{data: append([]byte(nil), p...)}
}

// tryWriteStdin queues input without waiting for a full guest pipe.
func (s *session) tryWriteStdin(p []byte) bool {
	if len(p) == 0 {
		return true
	}
	chunk := append([]byte(nil), p...)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.over || s.closed {
		return true
	}
	if s.stdin == nil {
		_, _ = s.buf.Write(chunk)
		return true
	}
	s.ensureWriterLocked()
	select {
	case s.stdinCh <- stdinChunk{data: chunk}:
		return true
	default:
		return false
	}
}

func (s *session) ensureWriterLocked() {
	if s.stdinCh != nil {
		return
	}
	s.stdinCh = make(chan stdinChunk, 1)
	go s.writer()
}

func (s *session) writer() {
	for chunk := range s.stdinCh {
		s.mu.Lock()
		w := s.stdin
		over := s.over
		s.mu.Unlock()
		if over || w == nil {
			continue
		}
		if chunk.close {
			_ = w.Close()
			continue
		}
		_, _ = w.Write(chunk.data)
	}
}

func (s *session) closeStdin() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	if s.stdin == nil {
		s.mu.Unlock()
		return
	}
	s.ensureWriterLocked()
	ch := s.stdinCh
	s.mu.Unlock()
	ch <- stdinChunk{close: true}
}

func (s *session) setPID(pid int) {
	s.mu.Lock()
	s.pid = pid
	s.mu.Unlock()
}

func (s *session) kill() {
	s.mu.Lock()
	pid, terminal, over := s.pid, s.terminal, s.over
	s.mu.Unlock()
	if terminal != nil && !over {
		killTerminal(pid, terminal)
		return
	}
	s.signal(syscall.SIGKILL)
}

// signal targets the command's process group. On a terminal it targets the
// foreground process group, like a signal generated by the line discipline.
func (s *session) signal(sig syscall.Signal) {
	s.mu.Lock()
	pid, terminal, over := s.pid, s.terminal, s.over
	s.mu.Unlock()
	if pid <= 0 || sig <= 0 {
		return
	}
	if terminal != nil && !over {
		if pgrp := foregroundGroup(terminal); pgrp > 0 {
			_ = syscall.Kill(-pgrp, sig)
			return
		}
	}
	_ = syscall.Kill(-pid, sig)
}

func (s *session) done() {
	s.mu.Lock()
	s.over = true
	w := s.stdin
	s.mu.Unlock()
	if w != nil {
		_ = w.Close()
	}
}

type sessionTable struct {
	mu sync.Mutex
	m  map[uint32]*session
}

func (t *sessionTable) begin(id uint32) *session {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.m == nil {
		t.m = map[uint32]*session{}
	}
	s := &session{}
	t.m[id] = s
	return s
}

func (t *sessionTable) get(id uint32) *session {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.m[id]
}

func (t *sessionTable) end(id uint32) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.m, id)
}

var sessions sessionTable

func lookupSession(id uint32) *session {
	return sessions.get(id)
}

func registerSession(id uint32) *session {
	return sessions.begin(id)
}

func finishSession(id uint32) {
	sessions.end(id)
}
