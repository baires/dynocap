package image

import (
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// pruneRoot drops Alpine minirootfs files the guest never opens during boot.
// The kernel unpacks the whole initramfs before it runs /init, so unused
// libraries (libcrypto, apk, CA bundle) sit on the critical path.
func pruneRoot(root string) error {
	var drop []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if rel == "." || d.IsDir() {
			return nil
		}
		if keepGuestFile(root, rel, d) {
			return nil
		}
		drop = append(drop, p)
		return nil
	})
	if err != nil {
		return err
	}
	for _, p := range drop {
		if err := os.Remove(p); err != nil {
			return err
		}
	}
	var dirs []string
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p != root && d.IsDir() {
			dirs = append(dirs, p)
		}
		return nil
	})
	if err != nil {
		return err
	}
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return err
		}
		if len(entries) == 0 {
			if err := os.Remove(dir); err != nil {
				return err
			}
		}
	}
	return nil
}

func keepGuestFile(root, rel string, d fs.DirEntry) bool {
	switch rel {
	case "init", "bin/busybox", "etc/passwd", "etc/group",
		"etc/microvm-vsock-modules", "etc/microvm-storage-modules", "etc/microvm-net-modules",
		"usr/local/bin/microvm-agent", "usr/share/udhcpc/default.script":
		return true
	}
	if strings.HasPrefix(rel, "lib/modules/") || strings.HasPrefix(rel, "lib/ld-musl-") {
		return true
	}
	if d.Type()&os.ModeSymlink == 0 {
		return false
	}
	target, err := os.Readlink(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return false
	}
	base := path.Base(target)
	return base == "busybox" || strings.Contains(target, "ld-musl")
}
