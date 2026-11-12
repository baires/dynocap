package runtime

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExplicitResolution(t *testing.T) {
	for _, requests := range [][]Request{nil, {{"node", "20"}}, {{"python", "3.13"}}, {{"python", "3"}}, {{"node", "22"}, {"node", "22"}}} {
		if _, err := Resolve(requests, "aarch64"); err == nil {
			t.Fatalf("accepted %+v", requests)
		}
	}
	recipe, err := Resolve([]Request{{"node", "22"}}, "aarch64")
	if err != nil {
		t.Fatal(err)
	}
	if recipe.Tools["node"] != "v22.23.4" || recipe.Tools["npm"] != "10.9.9" || len(recipe.VerificationCommand) == 0 {
		t.Fatal(recipe)
	}
	if !strings.Contains(strings.Join(recipe.VerificationCommand, " "), "v22.23.4") || !strings.Contains(strings.Join(recipe.VerificationCommand, " "), "10.9.9") {
		t.Fatal(recipe.VerificationCommand)
	}
	nodePins := 0
	for _, in := range recipe.Inputs {
		if len(in.SHA256) != 64 {
			t.Fatalf("unpinned input %+v", in)
		}
		if strings.Contains(in.URL, "unofficial-builds.nodejs.org") {
			nodePins++
			if in.URL != "https://unofficial-builds.nodejs.org/download/release/v22.23.4/node-v22.23.4-linux-arm64-musl.tar.xz" || in.SHA256 != "ed505d3b41e7674fd20b864c544b6bcd177fd88cb00124a23d5ecd4874041b3a" {
				t.Fatalf("node pin %+v", in)
			}
		}
	}
	if nodePins != 1 {
		t.Fatalf("node tarball pins: %d", nodePins)
	}
}

func TestNode24Resolution(t *testing.T) {
	recipe, err := Resolve([]Request{{"node", "24"}}, "aarch64")
	if err != nil {
		t.Fatal(err)
	}
	verify := strings.Join(recipe.VerificationCommand, " ")
	if recipe.Tools["node"] != "v24.22.3" || recipe.Tools["npm"] != "11.19.1" || !strings.Contains(verify, "v24.22.3") || !strings.Contains(verify, "11.19.1") {
		t.Fatal(recipe.Tools, verify)
	}
	pinned := false
	for _, in := range recipe.Inputs {
		if in.URL == "https://unofficial-builds.nodejs.org/download/release/v24.22.3/node-v24.22.3-linux-arm64-musl.tar.xz" {
			pinned = in.SHA256 == "8f4a3003252ea38c48465ebffd61432f7e4f34e4574c4edd6d07fe4293ae00b0" && in.Install != nil
		}
	}
	if !pinned {
		t.Fatal("node 24 tarball is not pinned")
	}
	if selectionKey("aarch64", recipe.Requests) == selectionKey("aarch64", []Request{{"node", "22"}}) {
		t.Fatal("node 22 and 24 share a catalog entry")
	}
}

func TestShellHasNoLanguageCacheOrRegistry(t *testing.T) {
	recipe, err := Resolve([]Request{{"shell", "1"}}, "aarch64")
	if err != nil {
		t.Fatal(err)
	}
	if recipe.DependencyCache != nil || len(recipe.EgressHosts) != 0 || recipe.EgressHosts == nil {
		t.Fatalf("shell declares an ecosystem: %+v %+v", recipe.DependencyCache, recipe.EgressHosts)
	}
	if len(recipe.Tools) != 1 || recipe.Tools["ssh"] == "" {
		t.Fatalf("shell tools: %+v", recipe.Tools)
	}
	for _, in := range recipe.Inputs {
		if in.Install != nil || strings.Contains(in.URL, "nodejs") || strings.Contains(in.URL, "/libstdc++-") {
			t.Fatalf("shell includes a language input: %s", in.URL)
		}
	}
}

func TestPythonUsesUVAndNeverDownloadsInterpreters(t *testing.T) {
	recipe, err := Resolve([]Request{{"python", "3.14"}}, "aarch64")
	if err != nil {
		t.Fatal(err)
	}
	if recipe.Tools["python"] != "3.14.10" || recipe.Tools["uv"] != "0.13.8" {
		t.Fatal(recipe.Tools)
	}
	if recipe.Environment["UV_PYTHON_DOWNLOADS"] != "never" || recipe.Environment["UV_CACHE_DIR"] != recipe.DependencyCache.Directory {
		t.Fatal(recipe.Environment)
	}
	if strings.Join(recipe.DependencyCache.Lockfiles, ",") != "uv.lock" || strings.Join(recipe.EgressHosts, ",") != "pypi.org,files.pythonhosted.org" {
		t.Fatalf("%+v %+v", recipe.DependencyCache, recipe.EgressHosts)
	}
	python, uv := false, false
	for _, in := range recipe.Inputs {
		python = python || strings.HasSuffix(in.URL, "/python3-3.14.10-r1.apk")
		uv = uv || (strings.HasSuffix(in.URL, "/0.13.8/uv-aarch64-unknown-linux-musl.tar.gz") && in.Install != nil)
	}
	if !python || !uv {
		t.Fatal("python or uv is not pinned")
	}
}

func TestGoUsesModulesWithALocalToolchain(t *testing.T) {
	recipe, err := Resolve([]Request{{"go", "1.27"}}, "aarch64")
	if err != nil {
		t.Fatal(err)
	}
	if recipe.Tools["go"] != "1.27.4" || recipe.Environment["GOTOOLCHAIN"] != "local" || recipe.DiskBytes < 1<<30 {
		t.Fatalf("%+v %+v %d", recipe.Tools, recipe.Environment, recipe.DiskBytes)
	}
	if !strings.HasPrefix(recipe.DependencyCache.Directory, recipe.Environment["GOMODCACHE"]+"/") || strings.Join(recipe.DependencyCache.Lockfiles, ",") != "go.sum" {
		t.Fatalf("%+v", recipe.DependencyCache)
	}
	if strings.Join(recipe.EgressHosts, ",") != "proxy.golang.org,sum.golang.org" {
		t.Fatal(recipe.EgressHosts)
	}
	pinned := false
	for _, in := range recipe.Inputs {
		pinned = pinned || (in.URL == "https://go.dev/dl/go1.27.4.linux-arm64.tar.gz" && in.Install != nil && len(in.SHA256) == 64)
	}
	if !pinned {
		t.Fatal("go toolchain is not pinned")
	}
}

func TestOldNodeArtifactIsNotReused(t *testing.T) {
	recipe, err := Resolve([]Request{{"node", "22"}}, "aarch64")
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	body := []byte("stale runtime disk")
	sum := sha256.Sum256(body)
	digest := hex.EncodeToString(sum[:])
	dir := filepath.Join(home, "runtimes", digest)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "runtime.ext4"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"kernel", "initrd"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("boot image"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	selection := selectionKey("aarch64", recipe.Requests)
	staleKey := strings.Repeat("ab", 32)
	write := func(manifest Manifest) {
		t.Helper()
		raw, err := json.Marshal(manifest)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "runtime.json"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
		catalog, err := json.Marshal(map[string]string{selection: digest})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(home, "runtime-catalog.json"), catalog, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(Manifest{BuildKey: staleKey, ArtifactDigest: digest, Recipe: Recipe{Tools: map[string]string{"node": "v22.21.1", "npm": "10.9.4"}}})
	if _, ok := reusablePublished(home, selection, "current-key", recipe.Tools); ok {
		t.Fatal("reused stale node artifact")
	}
	if _, ok := reusablePublished(home, selection, staleKey, recipe.Tools); ok {
		t.Fatal("accepted stale node tools under their own build key")
	}
	write(Manifest{FormatVersion: 1, BuildKey: "current-key", ArtifactDigest: digest, Recipe: Recipe{Tools: recipe.Tools}})
	if _, ok := reusablePublished(home, selection, "current-key", recipe.Tools); ok {
		t.Fatal("reused format 1 artifact with no SSH contract")
	}
	write(Manifest{FormatVersion: ArtifactFormatVersion, BuildKey: "current-key", ArtifactDigest: digest, Recipe: Recipe{Tools: recipe.Tools}})
	got, ok := reusablePublished(home, selection, "current-key", recipe.Tools)
	if !ok || got.Tools["node"] != "v22.23.4" || got.Tools["npm"] != "10.9.9" {
		t.Fatalf("current artifact refused: %+v ok=%v", got.Tools, ok)
	}
	if err := os.Remove(filepath.Join(dir, "initrd")); err != nil {
		t.Fatal(err)
	}
	if _, ok := reusablePublished(home, selection, "current-key", recipe.Tools); ok {
		t.Fatal("reused runtime with a missing boot image instead of rebuilding it")
	}
}

func TestRuntimeIncludesVerifiedSSHClient(t *testing.T) {
	recipe, err := Resolve([]Request{{"node", "22"}}, "aarch64")
	if err != nil {
		t.Fatal(err)
	}
	if recipe.Tools["ssh"] != "OpenSSH_10.3p1" || !strings.Contains(strings.Join(recipe.VerificationCommand, " "), "ssh -V") {
		t.Fatal("SSH client not verified")
	}
	found := false
	for _, in := range recipe.Inputs {
		if strings.Contains(in.URL, "/openssh-client-default-") {
			found = true
			if len(in.SHA256) != 64 {
				t.Fatal("unverified SSH input")
			}
		}
	}
	if !found {
		t.Fatal("SSH client is not pinned")
	}
}

func TestUnsupportedSelectionListsCatalog(t *testing.T) {
	_, err := Resolve([]Request{{"cobol", "85"}}, "aarch64")
	if err == nil || !strings.Contains(err.Error(), "node:22") {
		t.Fatalf("error does not list supported runtimes: %v", err)
	}
}

// Every catalog entry carries the base toolchain and declares its ecosystem for the host.
func TestCatalogRecipesDeclareEcosystem(t *testing.T) {
	for _, selection := range Supported() {
		name, version, _ := strings.Cut(selection, ":")
		recipe, err := Resolve([]Request{{name, version}}, "aarch64")
		if err != nil {
			t.Fatalf("%s: %v", selection, err)
		}
		verify := strings.Join(recipe.VerificationCommand, " ")
		for _, check := range []string{"bash --version", "git --version", "ssh -V", "cert.pem"} {
			if !strings.Contains(verify, check) {
				t.Fatalf("%s does not verify %q", selection, check)
			}
		}
		for _, pkg := range []string{"/bash-", "/git-", "/openssh-client-default-", "/ca-certificates-bundle-"} {
			found := false
			for _, in := range recipe.Inputs {
				if len(in.SHA256) != 64 {
					t.Fatalf("%s: unpinned input %+v", selection, in)
				}
				found = found || strings.Contains(in.URL, pkg)
			}
			if !found {
				t.Fatalf("%s is missing base package %s", selection, pkg)
			}
		}
		if recipe.Environment["HOME"] != "/work/home" || recipe.Environment["PATH"] == "" || recipe.EgressHosts == nil {
			t.Fatalf("%s: incomplete recipe %+v", selection, recipe)
		}
		if spec := recipe.DependencyCache; spec != nil {
			if len(spec.Lockfiles) == 0 || !strings.HasPrefix(spec.Directory, "/work/") || spec.Registry == "" || len(recipe.EgressHosts) == 0 {
				t.Fatalf("%s: incomplete dependency cache %+v", selection, spec)
			}
		}
	}
	if _, err := Resolve([]Request{{"node", "22"}}, "x86_64"); err == nil {
		t.Fatal("resolved an unpinned architecture")
	}
}
