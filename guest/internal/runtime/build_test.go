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
	for _, requests := range [][]Request{nil, {{"node", "24"}}, {{"python", "3.13"}}, {{"node", "22"}, {"node", "22"}}} {
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
