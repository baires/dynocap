package runtime

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// The official static Go toolchain with Go modules. It never switches to another toolchain.
func goRecipe(goVersion, sha256 string) recipeFunc {
	return func(arch string) (Recipe, error) {
		verify := fmt.Sprintf("test \"$(go env GOVERSION)\" = go%s && test \"$(go env GOROOT)\" = /usr/local/go && echo package p | gofmt >/dev/null", goVersion)
		return withBase(arch, Recipe{
			Inputs: []Input{{
				URL:     "https://go.dev/dl/go" + goVersion + ".linux-arm64.tar.gz",
				SHA256:  sha256,
				Install: installGoArchive,
			}},
			Environment: map[string]string{
				"GOPATH":      "/work/go",
				"GOMODCACHE":  "/work/go/pkg/mod",
				"GOCACHE":     "/work/go-build",
				"GOTOOLCHAIN": "local",
				"GOFLAGS":     "-modcacherw",
				"CGO_ENABLED": "0",
			},
			Tools:       map[string]string{"go": goVersion},
			EgressHosts: []string{"proxy.golang.org", "sum.golang.org"},
			DependencyCache: &CacheSpec{
				Lockfiles: []string{"go.sum"},
				Directory: "/work/go/pkg/mod/cache/download",
				Registry:  "https://proxy.golang.org",
				IncompatibleEnvPrefixes: []string{
					"GOPROXY", "GOSUMDB", "GONOSUMDB", "GONOPROXY", "GOPRIVATE", "GOINSECURE", "GOFLAGS", "GOMODCACHE",
				},
				SeedCommands: [][]string{{"go", "mod", "download"}},
			},
			// The extracted toolchain is about 250 MiB.
			DiskBytes: 1 << 30,
		}, verify)
	}
}

func installGoArchive(archive, root string) error {
	dest := filepath.Join(root, "usr/local")
	if err := os.MkdirAll(filepath.Join(dest, "bin"), 0755); err != nil {
		return err
	}
	out, err := exec.Command("/usr/bin/tar", "-xzf", archive, "-C", dest).CombinedOutput()
	if err != nil {
		return fmt.Errorf("go extraction: %s: %w", out, err)
	}
	// GOROOT follows the resolved executable, so links keep PATH shared with every runtime.
	for _, tool := range []string{"go", "gofmt"} {
		link := filepath.Join(dest, "bin", tool)
		_ = os.Remove(link)
		if err := os.Symlink("../go/bin/"+tool, link); err != nil {
			return err
		}
	}
	return nil
}
