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
	// Newest linux-arm64-musl build that satisfies lint-staged's >=22.22.1 engine range. One pin, no fallback.
	const nodeVersion = "v22.23.4"
	const npmVersion = "10.9.9"
	const sshVersion = "OpenSSH_10.3p1"
	inputs = append(inputs, Input{
		URL:    "https://unofficial-builds.nodejs.org/download/release/" + nodeVersion + "/node-" + nodeVersion + "-linux-arm64-musl.tar.xz",
		SHA256: "ed505d3b41e7674fd20b864c544b6bcd177fd88cb00124a23d5ecd4874041b3a",
	})
	verify := fmt.Sprintf("test \"$(node --version)\" = %s && test \"$(npm --version)\" = %s && git --version && test \"$(ssh -V 2>&1 | cut -d, -f1)\" = %s && test -s /etc/ssl/cert.pem", nodeVersion, npmVersion, sshVersion)
	return Recipe{InstallArchive: installNodeArchive, VerificationCommand: []string{"sh", "-c", verify}, Requests: requests, Inputs: inputs, Environment: map[string]string{"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/work/home", "npm_config_cache": "/work/npm-cache"}, Tools: map[string]string{"node": nodeVersion, "npm": npmVersion, "ssh": sshVersion}}, nil
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
