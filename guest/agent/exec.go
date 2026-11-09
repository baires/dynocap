package main

import (
	"bytes"
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
)

// Execute runs one command and emits protocol messages on the shared writer.
// A zero timeout means no timer. On timeout the process group is killed and
// the exit code is 124.
func Execute(req protocol.Message, write func(protocol.Message) error) {
	if req.Type != protocol.TypeExec {
		_ = write(protocol.Message{Type: protocol.TypeError, ID: req.ID, Error: "not an exec"})
		return
	}
	cmd := exec.Command(req.Argv[0], req.Argv[1:]...)
	cmd.Env = mergeEnv(req.Env)
	if req.Cwd != "" {
		cmd.Dir = req.Cwd
	} else {
		cmd.Dir = "/"
	}
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
	if sess != nil {
		sess.attach(stdin)
	} else {
		_ = stdin.Close()
	}

	if err := cmd.Start(); err != nil {
		failStart(req.ID, err, write)
		return
	}
	if sess != nil {
		sess.setPID(cmd.Process.Pid)
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

func failStart(id uint32, err error, write func(protocol.Message) error) {
	code := int32(exitCannotRun)
	if os.IsNotExist(err) || isNotFound(err) {
		code = exitNotFound
	}
	msg := err.Error()
	_ = write(protocol.Message{Type: protocol.TypeStderr, ID: id, Data: []byte("microvm-agent: " + msg + "\n")})
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

func mergeEnv(overrides []string) []string {
	base := map[string]string{
		"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME": "/root",
		"TERM": "vt100",
		"LANG": "C.UTF-8",
	}
	order := []string{"PATH", "HOME", "TERM", "LANG"}
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
	mu     sync.Mutex
	stdin  io.WriteCloser
	buf    bytes.Buffer
	closed bool
	pid    int
	over   bool
}

func (s *session) attach(w io.WriteCloser) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stdin = w
	if s.buf.Len() > 0 {
		_, _ = w.Write(s.buf.Bytes())
		s.buf.Reset()
	}
	if s.closed {
		_ = w.Close()
	}
}

func (s *session) writeStdin(p []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.over || s.closed {
		return
	}
	if s.stdin == nil {
		_, _ = s.buf.Write(p)
		return
	}
	_, _ = s.stdin.Write(p)
}

func (s *session) closeStdin() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	if s.stdin != nil {
		_ = s.stdin.Close()
	}
}

func (s *session) setPID(pid int) {
	s.mu.Lock()
	s.pid = pid
	s.mu.Unlock()
}

func (s *session) kill() {
	s.mu.Lock()
	pid := s.pid
	s.mu.Unlock()
	killGroup(pid)
}

func (s *session) done() {
	s.mu.Lock()
	s.over = true
	if s.stdin != nil {
		_ = s.stdin.Close()
	}
	s.mu.Unlock()
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
