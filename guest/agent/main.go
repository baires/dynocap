package main

import (
	"io"
	"log"
	"net"
	"sync"

	"microvm.dev/guest/internal/protocol"
)

func main() {
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
	hello := protocol.Message{Type: protocol.TypeHello, Version: protocol.Version, Agent: "microvm-agent"}
	if err := w.write(hello); err != nil {
		log.Printf("hello: %v", err)
		return
	}
	for {
		msg, err := protocol.ReadFrame(c)
		if err != nil {
			if err != io.EOF {
				log.Printf("read: %v", err)
			}
			return
		}
		switch msg.Type {
		case protocol.TypeExec:
			sess := registerSession(msg.ID)
			go func(req protocol.Message, s *session) {
				defer finishSession(req.ID)
				_ = s
				Execute(req, w.write)
			}(msg, sess)
		case protocol.TypeStdin:
			if s := lookupSession(msg.ID); s != nil {
				s.writeStdin(msg.Data)
			}
		case protocol.TypeStdinEOF:
			if s := lookupSession(msg.ID); s != nil {
				s.closeStdin()
			}
		case protocol.TypeKill:
			if s := lookupSession(msg.ID); s != nil {
				s.kill()
			}
		case protocol.TypeShutdown:
			log.Printf("shutdown requested")
			powerOff()
			return
		default:
			_ = w.write(protocol.Message{Type: protocol.TypeError, ID: msg.ID, Error: "unexpected message"})
		}
	}
}
