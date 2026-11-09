//go:build linux

package main

import (
	"log"
	"os"

	"github.com/mdlayher/vsock"
	"golang.org/x/sys/unix"
	"microvm.dev/guest/internal/protocol"
)

func osChdirRoot() error { return os.Chdir("/") }

func serve() error {
	ln, err := vsock.Listen(protocol.Port, nil)
	if err != nil {
		return err
	}
	log.Printf("microvm-agent listening on vsock port %d", protocol.Port)
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handleConn(conn)
	}
}

func powerOff() {
	unix.Sync()
	if err := unix.Reboot(unix.LINUX_REBOOT_CMD_POWER_OFF); err != nil {
		log.Printf("reboot: %v", err)
	}
}
