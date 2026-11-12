package runtime

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"strings"
)

// Every runtime shares this toolchain: bash, git, an SSH client and the CA bundle.
//
//go:embed base-aarch64.json
var basePackages []byte

const sshVersion = "OpenSSH_10.3p1"

// withBase prepends the base toolchain to a language recipe and its verification.
func withBase(arch string, language Recipe, verify string) (Recipe, error) {
	if arch != "aarch64" {
		return Recipe{}, fmt.Errorf("runtimes are currently pinned for aarch64 only")
	}
	var inputs []Input
	if err := json.Unmarshal(basePackages, &inputs); err != nil {
		return Recipe{}, err
	}
	checks := []string{
		"bash --version >/dev/null",
		"git --version",
		fmt.Sprintf("test \"$(ssh -V 2>&1 | cut -d, -f1)\" = %s", sshVersion),
		"test -s /etc/ssl/cert.pem",
	}
	if verify != "" {
		checks = append(checks, verify)
	}
	recipe := language
	recipe.Inputs = append(inputs, language.Inputs...)
	recipe.VerificationCommand = []string{"sh", "-c", strings.Join(checks, " && ")}
	recipe.Environment = map[string]string{"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/work/home"}
	for k, v := range language.Environment {
		recipe.Environment[k] = v
	}
	recipe.Tools = map[string]string{"ssh": sshVersion}
	for k, v := range language.Tools {
		recipe.Tools[k] = v
	}
	if recipe.EgressHosts == nil {
		recipe.EgressHosts = []string{}
	}
	return recipe, nil
}
