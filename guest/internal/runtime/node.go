package runtime

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// Node-specific pins and layout stay outside task/storage/daemon code.
//
//go:embed node22-aarch64.json
var nodePackages []byte

func resolveNode(requests []Request, arch string) (Recipe, error) {
	if len(requests) != 1 || requests[0].Name != "node" || requests[0].Version != "22" {
		return Recipe{}, fmt.Errorf("unsupported runtimes: supported selection is [{name:node,version:22}]")
	}
	if arch != "aarch64" {
		return Recipe{}, fmt.Errorf("Node 22 runtime is currently pinned for aarch64 only")
	}
	var inputs []Input
	if err := json.Unmarshal(nodePackages, &inputs); err != nil {
		return Recipe{}, err
	}
	inputs = append(inputs, Input{URL: "https://unofficial-builds.nodejs.org/download/release/v22.21.1/node-v22.21.1-linux-arm64-musl.tar.xz", SHA256: "ad3346dfd1dc9fdcadd54a22e4e9e5585abf9976f102fc3333cdfc6210658ec3"})
	return Recipe{InstallArchive: installNodeArchive, VerificationCommand: []string{"sh", "-c", "test \"$(node --version)\" = v22.21.1 && test \"$(npm --version)\" = 10.9.4 && git --version && test -s /etc/ssl/cert.pem"}, Requests: requests, Inputs: inputs, Environment: map[string]string{"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/work/home", "npm_config_cache": "/work/npm-cache"}, Tools: map[string]string{"node": "v22.21.1", "npm": "10.9.4"}}, nil
}
func installNodeArchive(archive, root string) error {
	dest := filepath.Join(root, "usr/local")
	if err := os.MkdirAll(dest, 0755); err != nil {
		return err
	}
	out, err := exec.Command("/usr/bin/tar", "-xJf", archive, "--strip-components=1", "-C", dest).CombinedOutput()
	if err != nil {
		return fmt.Errorf("node extraction: %s: %w", out, err)
	}
	// The unofficial musl build expects this libc soname.
	link := filepath.Join(root, "lib/libc.so")
	_ = os.Remove(link)
	return os.Symlink("ld-musl-aarch64.so.1", link)
}
