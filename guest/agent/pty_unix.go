//go:build linux || darwin

package main

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// finishPTY makes the ptmx side pollable so reads honor deadlines and Close.
func finishPTY(fd int, ptsPath string) (*os.File, *os.File, error) {
	if err := unix.SetNonblock(fd, true); err != nil {
		_ = unix.Close(fd)
		return nil, nil, err
	}
	ptmx := os.NewFile(uintptr(fd), "/dev/ptmx")
	pts, err := os.OpenFile(ptsPath, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		_ = ptmx.Close()
		return nil, nil, err
	}
	return ptmx, pts, nil
}

// setWindowSize applies a host terminal size. Zero means unknown, which is 24x80.
// The kernel sends SIGWINCH to the foreground process group when the size changes.
func setWindowSize(ptmx *os.File, rows, cols uint16) error {
	if rows == 0 || cols == 0 {
		rows, cols = 24, 80
	}
	return controlPTY(ptmx, func(fd int) error {
		return unix.IoctlSetWinsize(fd, unix.TIOCSWINSZ, &unix.Winsize{Row: rows, Col: cols})
	})
}

// foregroundGroup is the terminal's foreground process group, or 0.
func foregroundGroup(ptmx *os.File) int {
	pgrp := 0
	_ = controlPTY(ptmx, func(fd int) error {
		value, err := unix.IoctlGetInt(fd, unix.TIOCGPGRP)
		if err == nil && value > 0 {
			pgrp = value
		}
		return err
	})
	return pgrp
}

// controlPTY runs an ioctl without File.Fd, which would make the ptmx side blocking.
func controlPTY(ptmx *os.File, body func(fd int) error) error {
	raw, err := ptmx.SyscallConn()
	if err != nil {
		return err
	}
	var result error
	if err := raw.Control(func(fd uintptr) { result = body(int(fd)) }); err != nil {
		return err
	}
	return result
}
