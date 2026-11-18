package image

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// CacheBaseInputs collects the pinned image inputs in a release's content-addressed input directory.
func CacheBaseInputs(arch, dir string) error {
	pin, ok := Pins[arch]
	if !ok {
		return fmt.Errorf("unsupported arch %q (want aarch64 or x86_64)", arch)
	}
	if err := download(pin.MinirootURL, filepath.Join(dir, pin.MinirootSHA256), pin.MinirootSHA256); err != nil {
		return err
	}
	return download(pin.KernelURL, filepath.Join(dir, pin.KernelSHA256), pin.KernelSHA256)
}

// BundledInput returns an input from the install prefix only if it matches the compiled pin.
func BundledInput(repo, wantSHA string) (string, bool) {
	path := filepath.Join(repo, "alpine-inputs", wantSHA)
	data, err := os.ReadFile(path)
	return path, err == nil && sha256Sum(data) == wantSHA
}

func imageInput(repo, url, dest, wantSHA string) (string, error) {
	if path, ok := BundledInput(repo, wantSHA); ok {
		return path, nil
	}
	return dest, download(url, dest, wantSHA)
}

func download(url, dest, wantSHA string) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	if data, err := os.ReadFile(dest); err == nil {
		if sha256Sum(data) == wantSHA {
			return nil
		}
	}
	client := &http.Client{Timeout: 10 * time.Minute}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "dynocap-fetch/0.1")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	tmp := dest + ".partial"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(f, h), resp.Body); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	sum := hex.EncodeToString(h.Sum(nil))
	if sum != wantSHA {
		os.Remove(tmp)
		return fmt.Errorf("checksum mismatch for %s\n got %s\nwant %s", url, sum, wantSHA)
	}
	return os.Rename(tmp, dest)
}

func sha256Sum(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
