// Host companion. This executable has no daemon/socket or guest execution logic.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"microvm.dev/guest/internal/workspace"
	"os"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "workspace pack|unpack|names|fetch|pack-git|import-git ROOT")
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
		// Every host unpack reads a guest or freshly packed tree into a new directory.
		err = workspace.UnpackFresh(os.Args[2], os.Stdin, workspace.Limit)
	case "names":
		var n []string
		n, err = workspace.Names(os.Args[2], true)
		if err == nil {
			err = json.NewEncoder(os.Stdout).Encode(n)
		}
	case "fetch":
		if len(os.Args) != 5 {
			err = fmt.Errorf("fetch DEST URL REF")
		} else {
			var revision string
			revision, err = workspace.Fetch(os.Args[2], os.Args[3], os.Args[4], os.Getenv("MICROVM_GIT_TOKEN"), os.Getenv("MICROVM_SSH_KEY"))
			if err == nil {
				fmt.Fprint(os.Stdout, revision)
			}
		}
	case "pack-git":
		err = workspace.PackGit(os.Args[2], os.Stdout, workspace.Limit)
	case "import-git":
		if len(os.Args) != 4 && len(os.Args) != 5 {
			err = fmt.Errorf("import-git SOURCE DEST [branches|head|none]")
		} else {
			history := workspace.HistoryBranches
			if len(os.Args) == 5 {
				history, err = workspace.ParseHistory(os.Args[4])
			}
			if err == nil {
				err = workspace.ImportGitHistory(os.Args[2], os.Args[3], history)
			}
			if errors.Is(err, workspace.ErrNoGit) {
				fmt.Fprint(os.Stdout, "none")
				err = nil
			} else if err == nil {
				fmt.Fprint(os.Stdout, "git")
			}
		}
	default:
		err = fmt.Errorf("unknown operation")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
