package main

import (
	"fmt"
	"io"
	"log"
	"microvm.dev/guest/internal/workspace"
	"net"
	"os"
	"sync"
	"syscall"

	"microvm.dev/guest/internal/protocol"
)

func main() {
	if len(os.Args) == 5 && os.Args[1] == "fetch" {
		revision, err := workspace.Fetch(os.Args[2], os.Args[3], os.Args[4], os.Getenv("MICROVM_GIT_TOKEN"), os.Getenv("MICROVM_SSH_KEY"))
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Fprint(os.Stdout, revision)
		return
	}
	if len(os.Args) == 3 && (os.Args[1] == "pack" || os.Args[1] == "unpack" || os.Args[1] == "cache-pack" || os.Args[1] == "cache-unpack" || os.Args[1] == "freeze" || os.Args[1] == "task-pack") {
		var err error
		switch os.Args[1] {
		case "freeze":
			err = workspace.Freeze(os.Args[2], "/work/imported-paths.json")
		case "task-pack":
			err = workspace.PackTask(os.Args[2], "/work/imported-paths.json", os.Stdout, workspace.Limit)
		case "pack":
			err = workspace.PackFiltered(os.Args[2], os.Stdout, workspace.Limit)
		case "cache-pack":
			err = workspace.Pack(os.Args[2], os.Stdout, false, 2<<30)
		case "cache-unpack":
			err = workspace.Unpack(os.Args[2], os.Stdin, 2<<30)
		default:
			err = workspace.Unpack(os.Args[2], os.Stdin, workspace.Limit)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	if err := osChdirRoot(); err != nil {
		log.Printf("chdir /: %v", err)
	}
	if err := serve(); err != nil {
		log.Fatal(err)
	}
}

type lockedConn struct {
	mu sync.Mutex
	c  net.Conn
}

func (l *lockedConn) write(m protocol.Message) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return protocol.WriteFrame(l.c, m)
}

func handleConn(c net.Conn) {
	defer c.Close()
	w := &lockedConn{c: c}
	hello := protocol.Message{Type: protocol.TypeHello, Version: protocol.Version, Agent: protocol.AgentHello}
	if err := w.write(hello); err != nil {
		log.Printf("hello: %v", err)
		return
	}
	var parked []protocol.Message
	for {
		parked = flushParkedStdin(parked)
		msg, err := protocol.ReadFrame(c)
		if err != nil {
			if err != io.EOF {
				log.Printf("read: %v", err)
			}
			return
		}
		switch msg.Type {
		case protocol.TypeStdin:
			if !deliverStdin(msg, false) {
				parked = append(parked, msg)
			}
		case protocol.TypeStdinEOF:
			leftover := parked
			parked = nil
			go deliverStdinEOF(msg.ID, leftover)
		case protocol.TypeSignal:
			if s := lookupSession(msg.ID); s != nil {
				s.signal(syscall.Signal(msg.Signal))
			}
		default:
			if !dispatchFrame(w, msg) {
				return
			}
		}
	}
}

// Stdin writes run outside this loop. A full guest pipe must not delay a
// signal or kill that is already the next frame.
func flushParkedStdin(parked []protocol.Message) []protocol.Message {
	for len(parked) > 0 && deliverStdin(parked[0], false) {
		parked = parked[1:]
	}
	return parked
}

func deliverStdin(msg protocol.Message, block bool) bool {
	s := lookupSession(msg.ID)
	if s == nil {
		return true
	}
	if block {
		s.writeStdin(msg.Data)
		return true
	}
	return s.tryWriteStdin(msg.Data)
}

func deliverStdinEOF(id uint32, leftover []protocol.Message) {
	s := lookupSession(id)
	if s == nil {
		return
	}
	for _, msg := range leftover {
		s.writeStdin(msg.Data)
	}
	s.closeStdin()
}

func dispatchFrame(w *lockedConn, msg protocol.Message) bool {
	switch msg.Type {
	case protocol.TypeExec:
		sess := registerSession(msg.ID)
		go func(req protocol.Message, s *session) {
			defer finishSession(req.ID)
			_ = s
			Execute(req, w.write)
		}(msg, sess)
	case protocol.TypeKill:
		if s := lookupSession(msg.ID); s != nil {
			s.kill()
		}
	case protocol.TypeShutdown:
		log.Printf("shutdown requested")
		powerOff()
		return false
	default:
		_ = w.write(protocol.Message{Type: protocol.TypeError, ID: msg.ID, Error: "unexpected message"})
	}
	return true
}
