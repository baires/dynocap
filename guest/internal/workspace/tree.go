// Package workspace transports data trees. It never runs project code.
package workspace

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

const Limit int64 = 256 << 20

func safeName(name string) bool {
	return name != "" && name != "." && !path.IsAbs(name) && path.Clean(name) == name && name != ".." && !strings.HasPrefix(name, "../") && !strings.Contains(name, "\\") && !strings.ContainsRune(name, 0)
}
func safeLink(name, target string) bool {
	return !path.IsAbs(target) && safeName(path.Clean(path.Join(path.Dir(name), target)))
}
func parents(root, name string) error {
	dir := filepath.Dir(filepath.Join(root, filepath.FromSlash(name)))
	for dir != root {
		st, err := os.Lstat(dir)
		if err == nil && (!st.IsDir() || st.Mode()&os.ModeSymlink != 0) {
			return fmt.Errorf("unsafe parent %s", dir)
		}
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		dir = filepath.Dir(dir)
	}
	return nil
}

// Unpack accepts only fresh, bounded trees. Links cannot become extraction parents.
func Unpack(root string, r io.Reader, limit int64) error {
	if err := os.MkdirAll(root, 0755); err != nil {
		return err
	}
	root, _ = filepath.Abs(root)
	tracked := &tailReader{reader: io.LimitReader(r, limit+(16<<20))}
	tr := tar.NewReader(tracked)
	var total int64
	seen := map[string]bool{}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			if len(tracked.tail) != 1024 || !bytes.Equal(tracked.tail, make([]byte, 1024)) {
				return fmt.Errorf("incomplete archive trailer")
			}
			return nil
		}
		if err != nil {
			return err
		}
		name := strings.TrimSuffix(h.Name, "/")
		if !safeName(name) || seen[name] {
			return fmt.Errorf("invalid or duplicate archive path %q", h.Name)
		}
		seen[name] = true
		if len(seen) > 100000 || h.Size < 0 || h.Size > limit-total {
			return fmt.Errorf("workspace exceeds limit")
		}
		total += h.Size
		if err := parents(root, name); err != nil {
			return err
		}
		dest := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
			return err
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if st, err := os.Lstat(dest); err == nil && !st.IsDir() {
				return fmt.Errorf("directory collision")
			}
			if err := os.MkdirAll(dest, 0755); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			f, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, os.FileMode(h.Mode)&0777)
			if err != nil {
				return err
			}
			_, err = io.CopyN(f, tr, h.Size)
			closeErr := f.Close()
			if err != nil {
				return err
			}
			if closeErr != nil {
				return closeErr
			}
		case tar.TypeSymlink:
			if !safeLink(name, h.Linkname) {
				return fmt.Errorf("escaping symlink %q", name)
			}
			if err := os.Symlink(h.Linkname, dest); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unsupported archive entry %q", name)
		}
	}
}

func Names(root string, project bool) ([]string, error) {
	return names(root, project, project)
}
func names(root string, project, useGit bool) ([]string, error) {
	resolved, e := filepath.EvalSymlinks(root)
	if e != nil {
		return nil, e
	}
	root = resolved
	var names []string
	if useGit {
		if bin, err := hostGit(); err == nil {
			cmd := exec.Command(bin, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
			cmd.Env = []string{
				"PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
				"HOME=" + os.TempDir(),
				"GIT_CONFIG_NOSYSTEM=1",
				"GIT_CONFIG_GLOBAL=/dev/null",
				"GIT_TERMINAL_PROMPT=0",
			}
			if out, err := cmd.Output(); err == nil {
				for _, n := range strings.Split(string(out), "\x00") {
					if safeName(n) {
						if st, e := os.Lstat(filepath.Join(root, n)); e == nil {
							if st.IsDir() {
								return nil, fmt.Errorf("submodule/directory entry unsupported: %s", n)
							}
							names = append(names, n)
						}
					}
				}
				sort.Strings(names)
				return names, nil
			}
		}
	}
	if project {
		return filesRespectingIgnore(root, nil)
	}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == root {
			return nil
		}
		if d.Name() == ".git" {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		n, _ := filepath.Rel(root, p)
		n = filepath.ToSlash(n)
		if !d.IsDir() {
			names = append(names, n)
		}
		return nil
	})
	sort.Strings(names)
	return names, err
}

// filesRespectingIgnore lists project files. Ignore rules come from the tree.
// Matching uses a temporary Git directory, so project hooks and configuration
// never run. Paths in keep are included even when ignored, and their parent
// directories are still walked. Other ignored directories are not walked.
// Git starts only when a listed path is outside keep. A diff of an unchanged
// imported tree does not pay for git init.
func filesRespectingIgnore(root string, keep map[string]bool) ([]string, error) {
	ancestors := map[string]bool{}
	for n := range keep {
		for dir := path.Dir(n); dir != "." && dir != "/"; dir = path.Dir(dir) {
			ancestors[dir] = true
		}
	}
	var session *ignoreSession
	defer func() {
		if session != nil {
			session.close()
		}
	}()
	var names []string
	var walk func(string) error
	walk = func(rel string) error {
		dir := root
		if rel != "" {
			dir = filepath.Join(root, filepath.FromSlash(rel))
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			return err
		}
		type item struct {
			rel   string
			entry fs.DirEntry
		}
		items := make([]item, 0, len(entries))
		var unchecked []string
		for _, entry := range entries {
			if entry.Name() == ".git" {
				continue
			}
			child := entry.Name()
			if rel != "" {
				child = rel + "/" + entry.Name()
			}
			items = append(items, item{child, entry})
			if !keep[child] && !ancestors[child] {
				unchecked = append(unchecked, child)
			}
		}
		ignored := map[string]bool{}
		if len(unchecked) > 0 {
			if session == nil {
				session, err = openIgnoreSession(root)
				if err != nil {
					return err
				}
			}
			ignored, err = session.ignored(unchecked)
			if err != nil {
				return err
			}
		}
		for _, it := range items {
			if ignored[it.rel] && !keep[it.rel] && !ancestors[it.rel] {
				continue
			}
			info, err := it.entry.Info()
			if err != nil {
				return err
			}
			if info.Mode()&os.ModeSymlink != 0 || !it.entry.IsDir() {
				names = append(names, it.rel)
				continue
			}
			if err := walk(it.rel); err != nil {
				return err
			}
		}
		return nil
	}
	if err := walk(""); err != nil {
		return nil, err
	}
	sort.Strings(names)
	return names, nil
}
func PackFiltered(root string, w io.Writer, limit int64) error {
	return pack(root, w, true, false, limit)
}
func Pack(root string, w io.Writer, project bool, limit int64) error {
	return pack(root, w, project, project, limit)
}
func pack(root string, w io.Writer, project, useGit bool, limit int64) error {
	names, err := names(root, project, useGit)
	if err != nil {
		return err
	}
	return packNames(root, w, names, limit)
}
func packNames(root string, w io.Writer, names []string, limit int64) error {
	tw := tar.NewWriter(w)
	var total int64
	for _, n := range names {
		if !safeName(n) || strings.Contains("/"+n+"/", "/.git/") {
			return fmt.Errorf("unsafe workspace name %q", n)
		}
		p := filepath.Join(root, filepath.FromSlash(n))
		st, err := os.Lstat(p)
		if err != nil {
			return err
		}
		link := ""
		if st.Mode()&os.ModeSymlink != 0 {
			link, err = os.Readlink(p)
			if err != nil {
				return err
			}
			if !safeLink(n, link) {
				return fmt.Errorf("escaping symlink %q", n)
			}
		} else if !st.Mode().IsRegular() {
			return fmt.Errorf("unsupported file %s", n)
		}
		total += st.Size()
		if total > limit {
			return fmt.Errorf("workspace exceeds %d bytes", limit)
		}
		h, err := tar.FileInfoHeader(st, link)
		if err != nil {
			return err
		}
		h.Name = n
		h.Uid = 0
		h.Gid = 0
		h.Uname = ""
		h.Gname = ""
		if err = tw.WriteHeader(h); err != nil {
			return err
		}
		if st.Mode().IsRegular() {
			f, e := os.Open(p)
			if e != nil {
				return e
			}
			_, err = io.CopyN(tw, f, st.Size())
			f.Close()
			if err != nil {
				return err
			}
		}
	}
	return tw.Close()
}
func SHA(p string) (string, error) {
	f, e := os.Open(p)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	_, e = io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), e
}

// Freeze records the imported paths outside the writable project tree.
func Freeze(root, file string) error {
	n, e := Names(root, false)
	if e != nil {
		return e
	}
	raw, e := json.Marshal(n)
	if e != nil {
		return e
	}
	return os.WriteFile(file, raw, 0600)
}
func PackTask(root, file string, w io.Writer, limit int64) error {
	resolved, e := filepath.EvalSymlinks(root)
	if e != nil {
		return e
	}
	root = resolved
	raw, e := os.ReadFile(file)
	if e != nil {
		return e
	}
	var original []string
	if e = json.Unmarshal(raw, &original); e != nil {
		return e
	}
	keep := map[string]bool{}
	for _, n := range original {
		if !safeName(n) {
			return fmt.Errorf("invalid imported path")
		}
		keep[n] = true
	}
	selected, e := filesRespectingIgnore(root, keep)
	if e != nil {
		return e
	}
	return packNames(root, w, selected, limit)
}

type tailReader struct {
	reader io.Reader
	tail   []byte
}

func (r *tailReader) Read(p []byte) (int, error) {
	n, e := r.reader.Read(p)
	if n >= 1024 {
		r.tail = append(r.tail[:0], p[n-1024:n]...)
	} else if n > 0 {
		r.tail = append(r.tail, p[:n]...)
		if len(r.tail) > 1024 {
			r.tail = append([]byte{}, r.tail[len(r.tail)-1024:]...)
		}
	}
	return n, e
}
