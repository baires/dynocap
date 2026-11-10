// Package runtime prepares immutable guest artifacts, independently of task execution.
package runtime

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"microvm.dev/guest/internal/image"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type Request struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}
type Input struct {
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
}
type Recipe struct {
	InstallArchive      func(string, string) error `json:"-"`
	VerificationCommand []string                   `json:"verificationCommand"`
	Requests            []Request                  `json:"runtimes"`
	Inputs              []Input                    `json:"inputs"`
	Environment         map[string]string          `json:"environment"`
	Tools               map[string]string          `json:"tools"`
}
type Manifest struct {
	BuildKey string `json:"buildKey"`
	Recipe
	Arch            string `json:"arch"`
	BaseImageDigest string `json:"baseImageDigest"`
	ArtifactDigest  string `json:"artifactDigest"`
	PreparedAt      int64  `json:"preparedAtUnix"`
	FormatVersion   int    `json:"formatVersion"`
}

//go:embed init.sh
var taskInit []byte

func Resolve(requests []Request, arch string) (Recipe, error) { return resolveNode(requests, arch) }
func hashFile(p string) (string, error) {
	f, e := os.Open(p)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	_, e = io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), e
}
func fetch(in Input, cache string) (string, error) {
	p := filepath.Join(cache, in.SHA256)
	if sum, _ := hashFile(p); sum == in.SHA256 {
		return p, nil
	}
	c := http.Client{Timeout: 5 * time.Minute}
	res, e := c.Get(in.URL)
	if e != nil {
		return "", e
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return "", fmt.Errorf("download %s: %s", in.URL, res.Status)
	}
	f, e := os.Create(p + ".partial")
	if e != nil {
		return "", e
	}
	defer os.Remove(p + ".partial")
	h := sha256.New()
	_, e = io.Copy(io.MultiWriter(f, h), res.Body)
	f.Close()
	if e != nil {
		return "", e
	}
	if hex.EncodeToString(h.Sum(nil)) != in.SHA256 {
		return "", fmt.Errorf("input hash mismatch: %s", in.URL)
	}
	return p, os.Rename(p+".partial", p)
}
func Mkfs(file, root string, size int64) error {
	f, e := os.Create(file)
	if e != nil {
		return e
	}
	e = f.Truncate(size)
	f.Close()
	if e != nil {
		return e
	}
	tool := os.Getenv("MICROVM_MKE2FS")
	if tool == "" {
		for _, p := range []string{"/opt/homebrew/opt/e2fsprogs/sbin/mke2fs", "/usr/local/opt/e2fsprogs/sbin/mke2fs", "/sbin/mke2fs"} {
			if _, e := os.Stat(p); e == nil {
				tool = p
				break
			}
		}
	}
	if tool == "" {
		return fmt.Errorf("mke2fs required: brew install e2fsprogs, or set MICROVM_MKE2FS")
	}
	args := []string{"-q", "-t", "ext4", "-F", "-E", "lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0"}
	if root != "" {
		args = append(args, "-d", root)
	}
	args = append(args, file)
	out, e := exec.Command(tool, args...).CombinedOutput()
	if e != nil {
		return fmt.Errorf("mke2fs: %s: %w", out, e)
	}
	return nil
}

// buildKey includes recipes, base pins and guest sources; failed candidates never count as cache hits.
func buildKey(repo, arch string, recipe Recipe) (string, error) {
	raw, e := json.Marshal(struct {
		Recipe Recipe
		Arch   string
		Pin    image.ArchPin
	}{recipe, arch, image.Pins[arch]})
	if e != nil {
		return "", e
	}
	h := sha256.New()
	h.Write(raw)
	var files []string
	e = filepath.WalkDir(filepath.Join(repo, "guest"), func(p string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if d.IsDir() {
			return nil
		}
		ext := filepath.Ext(p)
		if strings.HasSuffix(p, "_test.go") {
			return nil
		}
		if ext == ".go" || ext == ".sh" || ext == ".json" || filepath.Base(p) == "go.mod" || filepath.Base(p) == "go.sum" {
			files = append(files, p)
		}
		return nil
	})
	if e != nil {
		return "", e
	}
	sort.Strings(files)
	for _, p := range files {
		rel, _ := filepath.Rel(repo, p)
		h.Write([]byte(rel))
		f, e := os.Open(p)
		if e != nil {
			return "", e
		}
		_, e = io.Copy(h, f)
		f.Close()
		if e != nil {
			return "", e
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func Build(repo, home, arch string, requests []Request) (Manifest, error) {
	recipe, e := Resolve(requests, arch)
	if e != nil {
		return Manifest{}, e
	}
	key, e := buildKey(repo, arch, recipe)
	if e != nil {
		return Manifest{}, e
	}
	catalogRaw, _ := os.ReadFile(filepath.Join(home, "runtime-catalog.json"))
	catalog := map[string]string{}
	_ = json.Unmarshal(catalogRaw, &catalog)
	selection := arch + "/"
	var names []string
	for _, request := range requests {
		names = append(names, request.Name+"@"+request.Version)
	}
	sort.Strings(names)
	selection += strings.Join(names, "+")
	existing := filepath.Join(home, "runtimes", catalog[selection])
	if raw, e := os.ReadFile(filepath.Join(existing, "runtime.json")); e == nil {
		var cached Manifest
		if json.Unmarshal(raw, &cached) == nil && cached.BuildKey == key {
			if sum, e := hashFile(filepath.Join(existing, "runtime.ext4")); e == nil && sum == cached.ArtifactDigest {
				return cached, nil
			}
		}
	}
	cache := filepath.Join(home, "cache")
	if e = os.MkdirAll(cache, 0700); e != nil {
		return Manifest{}, e
	}
	stage, e := os.MkdirTemp(cache, "runtime-build-")
	if e != nil {
		return Manifest{}, e
	}
	defer os.RemoveAll(stage)
	root := filepath.Join(stage, "root")
	boot := filepath.Join(stage, "boot")
	base, e := image.Build(image.Options{Arch: arch, OutDir: boot, CacheDir: cache, RepoRoot: repo, RootDir: root, Log: os.Stderr})
	if e != nil {
		return Manifest{}, e
	}
	for _, in := range recipe.Inputs {
		p, e := fetch(in, cache)
		if e != nil {
			return Manifest{}, e
		}
		if strings.HasSuffix(in.URL, ".apk") {
			e = image.InstallVerifiedAPK(p, root)
		} else {
			if recipe.InstallArchive == nil {
				return Manifest{}, fmt.Errorf("runtime has no archive installer")
			}
			e = recipe.InstallArchive(p, root)
		}
		if e != nil {
			return Manifest{}, e
		}
	}
	for _, d := range []string{"work", "workspace", "proc", "sys", "dev", "run", "tmp"} {
		if e = os.MkdirAll(filepath.Join(root, d), 0755); e != nil {
			return Manifest{}, e
		}
	}
	_ = os.Remove(filepath.Join(root, "workspace"))
	if e = os.Symlink("work/project", filepath.Join(root, "workspace")); e != nil {
		return Manifest{}, e
	}
	_ = os.Remove(filepath.Join(root, "etc/resolv.conf"))
	if e = os.Symlink("/run/resolv.conf", filepath.Join(root, "etc/resolv.conf")); e != nil {
		return Manifest{}, e
	}
	if e = os.MkdirAll(filepath.Join(root, "etc/udhcpc"), 0755); e != nil {
		return Manifest{}, e
	}
	if e = os.WriteFile(filepath.Join(root, "etc/udhcpc/udhcpc.conf"), []byte("RESOLV_CONF=/run/resolv.conf\n"), 0644); e != nil {
		return Manifest{}, e
	}
	envJSON, _ := json.Marshal(recipe.Environment)
	if e = os.WriteFile(filepath.Join(root, "etc/microvm-environment.json"), envJSON, 0644); e != nil {
		return Manifest{}, e
	}
	if e = os.WriteFile(filepath.Join(root, "sbin/microvm-task-init"), taskInit, 0755); e != nil {
		return Manifest{}, e
	}
	if e = Mkfs(filepath.Join(boot, "runtime.ext4"), root, 512<<20); e != nil {
		return Manifest{}, e
	}
	digest, e := hashFile(filepath.Join(boot, "runtime.ext4"))
	if e != nil {
		return Manifest{}, e
	}
	m := Manifest{BuildKey: key, Recipe: recipe, Arch: arch, BaseImageDigest: base.InitrdSHA256, ArtifactDigest: digest, PreparedAt: time.Now().Unix(), FormatVersion: 1}
	raw, _ := json.MarshalIndent(m, "", "  ")
	if e = os.WriteFile(filepath.Join(boot, "runtime.json"), raw, 0600); e != nil {
		return Manifest{}, e
	}
	// A candidate is verified by a read-only boot before daemon publication.
	dest := filepath.Join(home, "runtime-candidate")
	if _, e = os.Stat(dest); e == nil {
		return Manifest{}, fmt.Errorf("unverified runtime candidate already exists; remove it before rebuilding")
	}
	return m, os.Rename(boot, dest)
}
