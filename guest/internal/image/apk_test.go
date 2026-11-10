package image

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func apkMember(t *testing.T, name string, data []byte) []byte {
	t.Helper()
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tw := tar.NewWriter(gz)
	if e := tw.WriteHeader(&tar.Header{Name: name, Size: int64(len(data)), Mode: 0644}); e != nil {
		t.Fatal(e)
	}
	tw.Write(data)
	tw.Close()
	gz.Close()
	return b.Bytes()
}
func TestAPKSignatureAndDataHash(t *testing.T) {
	key, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	public, e := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if e != nil {
		t.Fatal(e)
	}
	data := apkMember(t, "usr/share/example", []byte("verified"))
	sum := sha256.Sum256(data)
	control := apkMember(t, ".PKGINFO", []byte(fmt.Sprintf("datahash = %s\n", hex.EncodeToString(sum[:]))))
	ch := sha1.Sum(control)
	signature, e := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA1, ch[:])
	if e != nil {
		t.Fatal(e)
	}
	sig := apkMember(t, ".SIGN.RSA.test.rsa.pub", signature)
	for _, test := range []struct {
		name  string
		alter func([]byte) []byte
		valid bool
	}{
		{"valid", func(b []byte) []byte { return b }, true},
		{"data tamper", func(b []byte) []byte {
			return append(b[:len(sig)+len(control)], apkMember(t, "usr/share/example", []byte("tampered"))...)
		}, false},
		{"control tamper", func(b []byte) []byte {
			return append(append(sig, apkMember(t, ".PKGINFO", []byte("datahash = bad\n"))...), data...)
		}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			os.MkdirAll(filepath.Join(root, "etc/apk/keys"), 0755)
			os.WriteFile(filepath.Join(root, "etc/apk/keys/test.rsa.pub"), pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: public}), 0644)
			raw := append(append(append([]byte{}, sig...), control...), data...)
			raw = test.alter(raw)
			file := filepath.Join(t.TempDir(), "package.apk")
			os.WriteFile(file, raw, 0644)
			err := InstallVerifiedAPK(file, root)
			if (err == nil) != test.valid {
				t.Fatalf("valid=%v err=%v", test.valid, err)
			}
			if !test.valid {
				if _, e := os.Stat(filepath.Join(root, "usr/share/example")); !os.IsNotExist(e) {
					t.Fatal("extracted unverified package")
				}
			}
		})
	}
}
