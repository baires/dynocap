//go:build !linux

package main

import "fmt"

func osChdirRoot() error { return nil }

func serve() error {
	return fmt.Errorf("dynocap-agent vsock listener is Linux-only")
}

func powerOff() {}
