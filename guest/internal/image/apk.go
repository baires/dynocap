package image

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// InstallVerifiedAPK verifies the signed control member and its datahash before extraction.
// Trust keys originate in the SHA-256 pinned Alpine minirootfs.
func InstallVerifiedAPK(file, root string) error {
	raw, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	br := bytes.NewReader(raw)
	var compressed, plain [][]byte
	for br.Len() > 0 {
		start := len(raw) - br.Len()
		gz, e := gzip.NewReader(br)
		if e != nil {
			return e
		}
		gz.Multistream(false)
		b, e := io.ReadAll(gz)
		gz.Close()
		if e != nil {
			return e
		}
		end := len(raw) - br.Len()
		compressed = append(compressed, raw[start:end])
		plain = append(plain, b)
	}
	if len(plain) != 3 {
		return fmt.Errorf("expected signed v2 APK")
	}
	tr := tar.NewReader(bytes.NewReader(plain[0]))
	var sig []byte
	var key string
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return e
		}
		if strings.HasPrefix(h.Name, ".SIGN.RSA.") {
			key = strings.TrimPrefix(h.Name, ".SIGN.RSA.")
			sig, e = io.ReadAll(tr)
			if e != nil {
				return e
			}
		}
	}
	if filepath.Base(key) != key || key == "" {
		return fmt.Errorf("invalid APK signer")
	}
	pub, e := os.ReadFile(filepath.Join(root, "etc/apk/keys", key))
	if e != nil {
		return e
	}
	block, _ := pem.Decode(pub)
	if block == nil {
		return fmt.Errorf("bad APK key")
	}
	parsed, e := x509.ParsePKIXPublicKey(block.Bytes)
	if e != nil {
		return e
	}
	rsaKey, ok := parsed.(*rsa.PublicKey)
	if !ok {
		return fmt.Errorf("not RSA")
	}
	controlSHA := sha1.Sum(compressed[1])
	if e = rsa.VerifyPKCS1v15(rsaKey, crypto.SHA1, controlSHA[:], sig); e != nil {
		return fmt.Errorf("APK signature: %w", e)
	}
	var want string
	tr = tar.NewReader(bytes.NewReader(plain[1]))
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return e
		}
		if h.Name == ".PKGINFO" {
			b, e := io.ReadAll(tr)
			if e != nil {
				return e
			}
			for _, line := range strings.Split(string(b), "\n") {
				if strings.HasPrefix(line, "datahash = ") {
					want = strings.TrimPrefix(line, "datahash = ")
				}
			}
		}
	}
	sum := sha256.Sum256(compressed[2])
	if hex.EncodeToString(sum[:]) != want {
		return fmt.Errorf("APK data hash mismatch")
	}
	f, e := os.CreateTemp("", "dynocap-apk-*.tar")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if _, e = f.Write(plain[2]); e != nil {
		f.Close()
		return e
	}
	f.Close()
	return extractTarFile(f.Name(), root)
}
