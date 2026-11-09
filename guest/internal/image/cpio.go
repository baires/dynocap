package image

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// WriteCPIO writes a newc cpio archive (the format Linux initramfs uses)
// for the tree at root. Every entry is owned by uid 0 / gid 0 so the
// archive does not depend on the host user extracting the minirootfs.
func WriteCPIO(root string, w io.Writer) error {
	var rels []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if path == root {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rels = append(rels, rel)
		return nil
	})
	if err != nil {
		return err
	}
	sort.Strings(rels)

	cw := &countingWriter{w: w}
	var inode uint32 = 1
	for _, rel := range rels {
		full := filepath.Join(root, rel)
		fi, err := os.Lstat(full)
		if err != nil {
			return err
		}
		name := filepath.ToSlash(rel)
		if strings.HasPrefix(name, "/") || strings.Contains(name, "..") {
			return fmt.Errorf("refusing to archive %q", name)
		}
		mode, data, skip, err := entry(full, fi)
		if err != nil {
			return err
		}
		if skip {
			continue
		}
		if err := writeNewc(cw, name, mode, inode, data, fi); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		inode++
	}
	if err := writeNewc(cw, "TRAILER!!!", 0, inode, nil, nil); err != nil {
		return err
	}
	return nil
}

func entry(full string, fi os.FileInfo) (mode uint32, data []byte, skip bool, err error) {
	perm := uint32(fi.Mode().Perm())
	if fi.Mode()&os.ModeSetuid != 0 {
		perm |= 04000
	}
	if fi.Mode()&os.ModeSetgid != 0 {
		perm |= 02000
	}
	if fi.Mode()&os.ModeSticky != 0 {
		perm |= 01000
	}
	switch {
	case fi.Mode()&os.ModeSymlink != 0:
		target, err := os.Readlink(full)
		if err != nil {
			return 0, nil, false, err
		}
		return perm | 0120000, []byte(target), false, nil
	case fi.IsDir():
		return perm | 0040000, nil, false, nil
	case fi.Mode().IsRegular():
		b, err := os.ReadFile(full)
		if err != nil {
			return 0, nil, false, err
		}
		return perm | 0100000, b, false, nil
	default:
		return 0, nil, true, nil
	}
}

func writeNewc(w *countingWriter, name string, mode, inode uint32, data []byte, fi os.FileInfo) error {
	var mtime uint32
	if fi != nil && fi.ModTime().Unix() > 0 {
		mtime = uint32(fi.ModTime().Unix())
	}
	namesize := uint32(len(name) + 1)
	hdr := fmt.Sprintf("070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X",
		inode,
		mode,
		uint32(0), // uid
		uint32(0), // gid
		uint32(1), // nlink
		mtime,
		uint32(len(data)),
		uint32(0), // devmajor
		uint32(0), // devminor
		uint32(0), // rdevmajor
		uint32(0), // rdevminor
		namesize,
		uint32(0), // checksum
	)
	if len(hdr) != 110 {
		return fmt.Errorf("cpio header length %d", len(hdr))
	}
	if _, err := io.WriteString(w, hdr); err != nil {
		return err
	}
	if _, err := io.WriteString(w, name); err != nil {
		return err
	}
	if _, err := w.Write([]byte{0}); err != nil {
		return err
	}
	if err := w.pad(); err != nil {
		return err
	}
	if len(data) > 0 {
		if _, err := w.Write(data); err != nil {
			return err
		}
	}
	return w.pad()
}

type countingWriter struct {
	w io.Writer
	n int
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += n
	return n, err
}

func (c *countingWriter) pad() error {
	pad := (4 - (c.n % 4)) % 4
	if pad == 0 {
		return nil
	}
	_, err := c.Write(make([]byte, pad))
	return err
}
