// Host companion. This executable has no daemon/socket or guest execution logic.
package main

import (
	"encoding/json"
	"fmt"
	"microvm.dev/guest/internal/workspace"
	"os"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "workspace pack|unpack|names ROOT")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "result":
		if len(os.Args) != 5 {
			err = fmt.Errorf("result BASELINE FINAL OUTPUT")
		} else {
			err = workspace.Result(os.Args[2], os.Args[3], os.Args[4])
		}
	case "pack":
		err = workspace.Pack(os.Args[2], os.Stdout, len(os.Args) > 3, workspace.Limit)
	case "unpack":
		err = workspace.Unpack(os.Args[2], os.Stdin, workspace.Limit)
	case "names":
		var n []string
		n, err = workspace.Names(os.Args[2], true)
		if err == nil {
			err = json.NewEncoder(os.Stdout).Encode(n)
		}
	default:
		err = fmt.Errorf("unknown operation")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
