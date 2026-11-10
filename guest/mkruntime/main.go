package main

import (
	"encoding/json"
	"fmt"
	rt "microvm.dev/guest/internal/runtime"
	"os"
)

func main() {
	if len(os.Args) < 3 || (os.Args[1] != "workspace" && len(os.Args) < 4) {
		fmt.Fprintln(os.Stderr, "mkruntime REPO HOME ARCH | workspace PATH")
		os.Exit(2)
	}
	var err error
	if os.Args[1] == "workspace" {
		err = rt.Mkfs(os.Args[2], "", 8<<30)
	} else {
		var m rt.Manifest
		requests := []rt.Request{{Name: "node", Version: "22"}}
		if len(os.Args) > 4 {
			err = json.Unmarshal([]byte(os.Args[4]), &requests)
		}
		if err == nil {
			m, err = rt.Build(os.Args[1], os.Args[2], os.Args[3], requests)
		}
		if err == nil {
			err = json.NewEncoder(os.Stdout).Encode(m)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
