package image

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestImageInputUsesVerifiedBundle(t *testing.T) {
	repo := t.TempDir()
	data := []byte("pinned package")
	digest := sha256Sum(data)
	bundle := filepath.Join(repo, "alpine-inputs")
	if err := os.Mkdir(bundle, 0o755); err != nil {
		t.Fatal(err)
	}
	bundled := filepath.Join(bundle, digest)
	if err := os.WriteFile(bundled, data, 0o644); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer server.Close()

	cache := filepath.Join(t.TempDir(), "package.apk")
	path, err := imageInput(repo, server.URL, cache, digest)
	if err != nil || path != bundled {
		t.Fatalf("image input = %q, %v, want bundled %q", path, err, bundled)
	}
	if err := os.WriteFile(bundled, []byte("corrupt"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := imageInput(repo, server.URL, cache, digest); err == nil {
		t.Fatal("accepted a corrupt bundle even though the upstream package is gone")
	}
	if err := os.WriteFile(cache, data, 0o644); err != nil {
		t.Fatal(err)
	}
	path, err = imageInput(repo, server.URL, cache, digest)
	if err != nil || path != cache {
		t.Fatalf("image input = %q, %v, want cached %q", path, err, cache)
	}
}
