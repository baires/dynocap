package runtime

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// Alpine's CPython with uv as the only package manager. uv never downloads an interpreter.
//
//go:embed python-aarch64.json
var pythonPackages []byte

func pythonRecipe(pythonVersion, uvVersion, uvSHA256 string) recipeFunc {
	return func(arch string) (Recipe, error) {
		var inputs []Input
		if err := json.Unmarshal(pythonPackages, &inputs); err != nil {
			return Recipe{}, err
		}
		inputs = append(inputs, Input{
			URL:     "https://github.com/astral-sh/uv/releases/download/" + uvVersion + "/uv-aarch64-unknown-linux-musl.tar.gz",
			SHA256:  uvSHA256,
			Install: installUVArchive,
		})
		verify := fmt.Sprintf("test \"$(python3 --version)\" = \"Python %s\" && test \"$(python --version)\" = \"Python %s\" && test \"$(uv --version | cut -d' ' -f2)\" = %s", pythonVersion, pythonVersion, uvVersion)
		return withBase(arch, Recipe{
			Inputs: inputs,
			Environment: map[string]string{
				"UV_CACHE_DIR":        "/work/uv-cache",
				"UV_PYTHON":           "/usr/bin/python3",
				"UV_PYTHON_DOWNLOADS": "never",
				"UV_LINK_MODE":        "copy",
			},
			Tools:       map[string]string{"python": pythonVersion, "uv": uvVersion},
			EgressHosts: []string{"pypi.org", "files.pythonhosted.org"},
			DependencyCache: &CacheSpec{
				Lockfiles:                 []string{"uv.lock"},
				ConfigFiles:               []string{"uv.toml"},
				Directory:                 "/work/uv-cache",
				Registry:                  "https://pypi.org/simple",
				IncompatibleEnvPrefixes:   []string{"UV_INDEX", "UV_DEFAULT_INDEX", "UV_EXTRA_INDEX", "UV_CACHE_DIR", "UV_NO_CACHE", "PIP_"},
				IncompatibleArgSubstrings: []string{"index", "cache-dir", "no-cache"},
				SeedCommands:              [][]string{{"uv", "sync"}},
			},
		}, verify)
	}
}

func installUVArchive(archive, root string) error {
	dest := filepath.Join(root, "usr/local/bin")
	if err := os.MkdirAll(dest, 0755); err != nil {
		return err
	}
	out, err := exec.Command("/usr/bin/tar", "-xzf", archive, "--strip-components=1", "-C", dest).CombinedOutput()
	if err != nil {
		return fmt.Errorf("uv extraction: %s: %w", out, err)
	}
	// Projects and docs say python; Alpine only ships python3.
	link := filepath.Join(dest, "python")
	_ = os.Remove(link)
	return os.Symlink("/usr/bin/python3", link)
}
