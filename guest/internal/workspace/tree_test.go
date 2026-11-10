package workspace

import (
	"archive/tar"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func archive(t *testing.T, headers ...*tar.Header) []byte {
	t.Helper()
	var b bytes.Buffer
	w := tar.NewWriter(&b)
	for _, h := range headers {
		if err := w.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if h.Size > 0 {
			w.Write(bytes.Repeat([]byte{'x'}, int(h.Size)))
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}
func TestRejectUnsafeTrees(t *testing.T) {
	for _, h := range []*tar.Header{
		{Name: "../escape", Typeflag: tar.TypeReg}, {Name: "/absolute", Typeflag: tar.TypeReg},
		{Name: "a", Typeflag: tar.TypeSymlink, Linkname: "../../escape"},
		{Name: "a", Typeflag: tar.TypeLink, Linkname: "target"}, {Name: "device", Typeflag: tar.TypeChar},
		{Name: "large", Typeflag: tar.TypeReg, Size: 17},
	} {
		t.Run(h.Name, func(t *testing.T) {
			if Unpack(t.TempDir(), bytes.NewReader(archive(t, h)), 16) == nil {
				t.Fatal("accepted unsafe tree")
			}
		})
	}
}
func TestRejectLinkParentsAndDuplicates(t *testing.T) {
	for _, headers := range [][]*tar.Header{
		{{Name: "link", Typeflag: tar.TypeSymlink, Linkname: "safe"}, {Name: "link/file", Typeflag: tar.TypeReg}},
		{{Name: "same", Typeflag: tar.TypeReg}, {Name: "same", Typeflag: tar.TypeReg}},
	} {
		if Unpack(t.TempDir(), bytes.NewReader(archive(t, headers...)), Limit) == nil {
			t.Fatal("accepted link parent or duplicate")
		}
	}
}
func TestRoundTripBinaryModesAndLinks(t *testing.T) {
	root := t.TempDir()
	payload := bytes.Repeat([]byte{0, 255, 3, 10}, 200000)
	if err := os.WriteFile(filepath.Join(root, "binary"), payload, 0755); err != nil {
		t.Fatal(err)
	}
	os.Symlink("binary", filepath.Join(root, "link"))
	var buf bytes.Buffer
	if err := Pack(root, &buf, false, Limit); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if err := Unpack(dest, &buf, Limit); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(dest, "binary"))
	if !bytes.Equal(got, payload) {
		t.Fatal("corrupt bytes")
	}
	st, _ := os.Stat(filepath.Join(dest, "binary"))
	if st.Mode().Perm() != 0755 {
		t.Fatal(st.Mode())
	}
	link, _ := os.Readlink(filepath.Join(dest, "link"))
	if link != "binary" {
		t.Fatal(link)
	}
}
func TestFilteredExportFollowsGitignore(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, ".gitignore"), []byte("node_modules/\ntarget/\n"), 0644)
	os.WriteFile(filepath.Join(root, ".git"), []byte("gitdir: /no/such/gitdir\n"), 0644)
	os.MkdirAll(filepath.Join(root, "node_modules/pkg"), 0755)
	os.WriteFile(filepath.Join(root, "node_modules/pkg/code"), []byte("ignored"), 0644)
	os.MkdirAll(filepath.Join(root, "target"), 0755)
	os.WriteFile(filepath.Join(root, "target/out"), []byte("out"), 0644)
	os.MkdirAll(filepath.Join(root, "dist"), 0755)
	os.WriteFile(filepath.Join(root, "dist/app"), []byte("app"), 0644)
	os.WriteFile(filepath.Join(root, "source"), []byte("data"), 0644)
	var b bytes.Buffer
	if err := PackFiltered(root, &b, Limit); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if err := Unpack(dest, &b, Limit); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dest, "node_modules")); !os.IsNotExist(err) {
		t.Fatal("gitignored node_modules exported")
	}
	if _, err := os.Stat(filepath.Join(dest, "target")); !os.IsNotExist(err) {
		t.Fatal("gitignored target exported")
	}
	data, err := os.ReadFile(filepath.Join(dest, "dist/app"))
	if err != nil || string(data) != "app" {
		t.Fatal("unignored dist was dropped")
	}
	if _, err := os.Stat(filepath.Join(dest, ".git")); !os.IsNotExist(err) {
		t.Fatal(".git exported")
	}
}
func TestResultTracksDeletionBinaryAndMode(t *testing.T) {
	before, after, out := t.TempDir(), t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(before, "deleted"), []byte("old"), 0644)
	os.WriteFile(filepath.Join(before, "mode"), []byte("same"), 0644)
	os.WriteFile(filepath.Join(after, "mode"), []byte("same"), 0755)
	os.WriteFile(filepath.Join(after, "binary"), []byte{0, 255}, 0644)
	if err := Result(before, after, out); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(filepath.Join(out, "changes.json"))
	for _, want := range []string{"deleted", "added", "modified"} {
		if !bytes.Contains(raw, []byte(want)) {
			t.Fatal(string(raw))
		}
	}
	data, _ := os.ReadFile(filepath.Join(out, "files/binary"))
	if !bytes.Equal(data, []byte{0, 255}) {
		t.Fatal(data)
	}
	review, _ := os.ReadFile(filepath.Join(out, "review.txt"))
	if bytes.Contains(review, []byte("-same")) || bytes.Contains(review, []byte("+same")) {
		t.Fatalf("unchanged text reprinted:\n%s", review)
	}
	if !bytes.Contains(review, []byte("Binary contents changed")) {
		t.Fatalf("review:\n%s", review)
	}
}

func TestReviewIsAUnifiedDiff(t *testing.T) {
	before, after, out := t.TempDir(), t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(before, "f.txt"), []byte("keep\nremove me\nkeep\n"), 0644)
	os.WriteFile(filepath.Join(after, "f.txt"), []byte("keep\nkeep\n"), 0644)
	var farOld, farNew strings.Builder
	for i := 1; i <= 20; i++ {
		fmt.Fprintf(&farOld, "line %d\n", i)
		text := fmt.Sprintf("line %d\n", i)
		if i == 2 || i == 18 {
			text = fmt.Sprintf("LINE %d\n", i)
		}
		farNew.WriteString(text)
	}
	os.WriteFile(filepath.Join(before, "far.txt"), []byte(farOld.String()), 0644)
	os.WriteFile(filepath.Join(after, "far.txt"), []byte(farNew.String()), 0644)
	os.WriteFile(filepath.Join(after, "added.txt"), []byte("hello\n"), 0644)
	os.WriteFile(filepath.Join(before, "nl.txt"), []byte("old"), 0644)
	os.WriteFile(filepath.Join(after, "nl.txt"), []byte("new"), 0644)
	if err := Result(before, after, out); err != nil {
		t.Fatal(err)
	}
	review, err := os.ReadFile(filepath.Join(out, "review.txt"))
	if err != nil {
		t.Fatal(err)
	}
	want := "modified f.txt (mode 0644 -> 0644)\n--- a/f.txt\n+++ b/f.txt\n@@ -1,3 +1,2 @@\n keep\n-remove me\n keep\n\n"
	if !bytes.Contains(review, []byte(want)) {
		t.Fatalf("review:\n%s", review)
	}
	if bytes.Count(review, []byte("\n@@ ")) != 5 {
		t.Fatalf("hunks:\n%s", review)
	}
	if bytes.Contains(review, []byte("\n-line 1\n")) || bytes.Contains(review, []byte("\n+line 1\n")) {
		t.Fatalf("unchanged line reprinted:\n%s", review)
	}
	if !bytes.Contains(review, []byte("@@ -0,0 +1,1 @@\n+hello\n")) {
		t.Fatalf("addition:\n%s", review)
	}
	if !bytes.Contains(review, []byte("\\ No newline at end of file\n")) {
		t.Fatalf("newline marker:\n%s", review)
	}
}

func TestTaskExportKeepsImportedFilesAndUsesIgnoreRules(t *testing.T) {
	work := t.TempDir()
	root := filepath.Join(work, "project")
	os.MkdirAll(filepath.Join(root, "vendor/kept"), 0755)
	os.MkdirAll(filepath.Join(root, "target"), 0755)
	os.MkdirAll(filepath.Join(root, "dist"), 0755)
	os.MkdirAll(filepath.Join(root, "node_modules/pkg"), 0755)
	os.WriteFile(filepath.Join(root, ".gitignore"), []byte("vendor/\ntarget/\nnode_modules/\n"), 0644)
	os.WriteFile(filepath.Join(root, ".git"), []byte("gitdir: /no/such/gitdir\n"), 0644)
	hook := filepath.Join(root, ".githooks", "pre-commit")
	os.MkdirAll(filepath.Dir(hook), 0755)
	os.WriteFile(hook, []byte("#!/bin/sh\necho ran > hook-ran\nexit 1\n"), 0755)
	os.WriteFile(filepath.Join(root, "src.txt"), []byte("src"), 0644)
	os.WriteFile(filepath.Join(root, "vendor/kept/imported.txt"), []byte("imported"), 0644)
	os.WriteFile(filepath.Join(root, "vendor/other.txt"), []byte("other"), 0644)
	os.WriteFile(filepath.Join(root, "target/out"), []byte("out"), 0644)
	os.WriteFile(filepath.Join(root, "dist/app"), []byte("app"), 0644)
	os.WriteFile(filepath.Join(root, "node_modules/pkg/index.js"), []byte("dep"), 0644)
	os.WriteFile(filepath.Join(root, "notes.txt"), []byte("notes"), 0644)
	frozen := filepath.Join(work, "imported-paths.json")
	os.WriteFile(frozen, []byte("[\"src.txt\",\"vendor/kept/imported.txt\"]\n"), 0600)
	var b bytes.Buffer
	if err := PackTask(root, frozen, &b, Limit); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "hook-ran")); !os.IsNotExist(err) {
		t.Fatal("project hook ran")
	}
	dest := t.TempDir()
	if err := Unpack(dest, &b, Limit); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"src.txt", "vendor/kept/imported.txt", "dist/app", "notes.txt"} {
		if _, err := os.Stat(filepath.Join(dest, name)); err != nil {
			t.Fatalf("missing %s: %v", name, err)
		}
	}
	for _, name := range []string{"vendor/other.txt", "target/out", "node_modules/pkg/index.js", ".git"} {
		if _, err := os.Stat(filepath.Join(dest, name)); !os.IsNotExist(err) {
			t.Fatalf("exported %s", name)
		}
	}
}

func TestTaskExportResolvesSelectedRootSymlink(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "project")
	os.Mkdir(project, 0755)
	os.WriteFile(filepath.Join(project, "source"), []byte("before"), 0644)
	link := filepath.Join(root, "workspace")
	os.Symlink("project", link)
	frozen := filepath.Join(root, "selection.json")
	if err := Freeze(link, frozen); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(project, "source"), []byte("after"), 0755)
	os.WriteFile(filepath.Join(project, "binary"), []byte{0, 255}, 0644)
	var b bytes.Buffer
	if err := PackTask(link, frozen, &b, Limit); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if err := Unpack(dest, &b, Limit); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dest, "source"))
	if err != nil || string(data) != "after" {
		t.Fatalf("lost project: %q %v", data, err)
	}
	binary, err := os.ReadFile(filepath.Join(dest, "binary"))
	if err != nil || !bytes.Equal(binary, []byte{0, 255}) {
		t.Fatal("lost binary")
	}
	if err := os.Truncate(filepath.Join(project, "source"), Limit+1); err != nil {
		t.Fatal(err)
	}
	if err := PackTask(link, frozen, &bytes.Buffer{}, Limit); err == nil {
		t.Fatal("accepted oversized export")
	}
}

func TestRejectMissingArchiveTrailer(t *testing.T) {
	raw := archive(t, &tar.Header{Name: "file", Typeflag: tar.TypeReg, Size: 10})
	if err := Unpack(t.TempDir(), bytes.NewReader(raw[:1024]), Limit); err == nil {
		t.Fatal("accepted incomplete transfer")
	}
}
