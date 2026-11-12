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
//go:embed node-aarch64.json
var nodePackages []byte

// nodeRecipe pins one linux-arm64-musl build and the npm it bundles. One pin per version, no fallback.
func nodeRecipe(nodeVersion, npmVersion, sha256 string) recipeFunc {
	return func(arch string) (Recipe, error) {
		var inputs []Input
		if err := json.Unmarshal(nodePackages, &inputs); err != nil {
			return Recipe{}, err
		}
		inputs = append(inputs, Input{
			URL:     "https://unofficial-builds.nodejs.org/download/release/" + nodeVersion + "/node-" + nodeVersion + "-linux-arm64-musl.tar.xz",
			SHA256:  sha256,
			Install: installNodeArchive,
		})
		verify := fmt.Sprintf("test \"$(node --version)\" = %s && test \"$(npm --version)\" = %s", nodeVersion, npmVersion)
		return withBase(arch, Recipe{
			Inputs:      inputs,
			Environment: map[string]string{"npm_config_cache": "/work/npm-cache"},
			Tools:       map[string]string{"node": nodeVersion, "npm": npmVersion},
			EgressHosts: []string{"registry.npmjs.org"},
			DependencyCache: &CacheSpec{
				Lockfiles:                 []string{"package-lock.json"},
				ConfigFiles:               []string{".npmrc"},
				Directory:                 "/work/npm-cache/_cacache",
				Registry:                  "https://registry.npmjs.org/",
				VerifyCommand:             []string{"npm", "cache", "verify", "--cache", "/work/npm-cache"},
				IncompatibleEnvPrefixes:   []string{"npm_config_"},
				IncompatibleArgSubstrings: []string{"registry"},
			},
		}, verify)
	}
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
