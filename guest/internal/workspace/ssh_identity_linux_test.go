//go:build linux

package workspace

import (
	"os"
	"testing"
)

func TestExposeSSHKeyIsOwnerReadWriteOnly(t *testing.T) {
	path, cleanup, err := exposeSSHKey("-----BEGIN OPENSSH PRIVATE KEY-----\ntest-key\n-----END OPENSSH PRIVATE KEY-----\n")
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("identity mode %o, want 0600", info.Mode().Perm())
	}
}
