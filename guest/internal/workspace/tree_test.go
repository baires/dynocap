package workspace

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
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

func TestLocalHistoryReviewAppliesOnAFreshClone(t *testing.T) {
	source := t.TempDir()
	gitCmd(t, source, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(source, "old.txt"), []byte("kept\n"), 0644))
	must(t, os.WriteFile(filepath.Join(source, "mode.sh"), []byte("#!/bin/sh\ntrue\n"), 0644))
	must(t, os.WriteFile(filepath.Join(source, "data.bin"), []byte{0, 1, 2, 3, 255}, 0644))
	gitCmd(t, source, "add", "old.txt", "mode.sh", "data.bin")
	gitCmd(t, source, "commit", "-m", "initial")
	before := treeDigest(t, source)

	workspace := workspaceFromLocal(t, source)
	config, err := os.ReadFile(filepath.Join(workspace, ".git", "config"))
	if err != nil || !bytes.Contains(config, []byte("hooksPath = /dev/null")) || bytes.Contains(config, []byte("credential")) {
		t.Fatalf("config:\n%s", config)
	}
	if _, err := os.Stat(filepath.Join(workspace, ".git", "hooks")); !os.IsNotExist(err) {
		t.Fatal("hooks imported")
	}
	if _, err := os.Stat(filepath.Join(workspace, ".git", "objects", "info", "alternates")); !os.IsNotExist(err) {
		t.Fatal("alternates imported")
	}
	if _, err := os.Stat(filepath.Join(source, ".git", "hooks")); err != nil {
		t.Fatal(err)
	}

	must(t, os.Rename(filepath.Join(workspace, "old.txt"), filepath.Join(workspace, "new.txt")))
	must(t, os.Chmod(filepath.Join(workspace, "mode.sh"), 0755))
	edited := []byte{0, 1, 2, 9, 255}
	must(t, os.WriteFile(filepath.Join(workspace, "data.bin"), edited, 0644))
	if treeDigest(t, source) != before {
		t.Fatal("source checkout changed")
	}
	baseline := exportTree(t, source)
	exported := exportTree(t, workspace)
	out := t.TempDir()
	if err := Result(baseline, exported, out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(out, ".git")); !os.IsNotExist(err) {
		t.Fatal(".git in result")
	}
	raw, err := os.ReadFile(filepath.Join(out, "changes.json"))
	if err != nil {
		t.Fatal(err)
	}
	var changes []Change
	if err := json.Unmarshal(raw, &changes); err != nil {
		t.Fatal(err)
	}
	saw := map[string]bool{}
	for _, change := range changes {
		switch {
		case change.Kind == "renamed" && change.From == "old.txt" && change.Path == "new.txt":
			saw["rename"] = true
		case change.Kind == "modified" && change.Path == "mode.sh" && change.Mode == 0755:
			saw["mode"] = true
		case change.Kind == "modified" && change.Path == "data.bin":
			saw["binary"] = true
		default:
			t.Fatalf("unexpected change %+v", change)
		}
	}
	if len(saw) != 3 {
		t.Fatalf("changes: %s", raw)
	}
	got, err := os.ReadFile(filepath.Join(out, "files", "data.bin"))
	if err != nil || !bytes.Equal(got, edited) {
		t.Fatalf("binary file %q %v", got, err)
	}
	review, _ := os.ReadFile(filepath.Join(out, "review.txt"))
	if !bytes.Contains(review, []byte("renamed old.txt -> new.txt")) {
		t.Fatalf("review:\n%s", review)
	}
	patch := filepath.Join(out, "changes.patch")
	patchText, _ := os.ReadFile(patch)
	for _, want := range []string{"rename from old.txt", "rename to new.txt", "old mode 100644", "new mode 100755", "diff --git a/data.bin b/data.bin"} {
		if !bytes.Contains(patchText, []byte(want)) {
			t.Fatalf("missing %s\n%s", want, patchText)
		}
	}
	clone := filepath.Join(t.TempDir(), "clone")
	gitCmd(t, t.TempDir(), "clone", source, clone)
	apply := exec.Command("git", "apply", "--binary", patch)
	apply.Dir = clone
	apply.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
	if out, err := apply.CombinedOutput(); err != nil {
		t.Fatalf("git apply: %s\n%s", out, patchText)
	}
	if _, err := os.Stat(filepath.Join(clone, "old.txt")); !os.IsNotExist(err) {
		t.Fatal("rename left the old path")
	}
	renamed, err := os.ReadFile(filepath.Join(clone, "new.txt"))
	if err != nil || string(renamed) != "kept\n" {
		t.Fatal(err, renamed)
	}
	st, err := os.Stat(filepath.Join(clone, "mode.sh"))
	if err != nil || st.Mode().Perm() != 0755 {
		t.Fatalf("mode %v %v", st, err)
	}
	bin, err := os.ReadFile(filepath.Join(clone, "data.bin"))
	if err != nil || !bytes.Equal(bin, edited) {
		t.Fatalf("applied binary %q %v", bin, err)
	}
	if treeDigest(t, source) != before {
		t.Fatal("source checkout changed")
	}
}

func TestPatchIgnoresProjectGitOnPath(t *testing.T) {
	before, after, out := t.TempDir(), t.TempDir(), t.TempDir()
	must(t, os.WriteFile(filepath.Join(before, "note.txt"), []byte("one\n"), 0644))
	must(t, os.WriteFile(filepath.Join(after, "note.txt"), []byte("two\n"), 0644))
	marker := filepath.Join(t.TempDir(), "fake-ran")
	script := "#!/bin/sh\necho ran >> " + shellQuote(marker) + "\nprintf 'fake-patch\\n'\n"
	must(t, os.WriteFile(filepath.Join(after, "git"), []byte(script), 0755))
	t.Setenv("PATH", after+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := Result(before, after, out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("project git executed")
	}
	patch, err := os.ReadFile(filepath.Join(out, "changes.patch"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(patch, []byte("diff --git a/note.txt b/note.txt")) || !bytes.Contains(patch, []byte("\n+two\n")) {
		t.Fatalf("patch:\n%s", patch)
	}
	if bytes.Equal(bytes.TrimSpace(patch), []byte("fake-patch")) {
		t.Fatalf("patch:\n%s", patch)
	}
}

func TestURLAndLocalImportsProduceTheSamePatch(t *testing.T) {
	source := t.TempDir()
	gitCmd(t, source, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(source, "README"), []byte("hello\n"), 0644))
	gitCmd(t, source, "add", "README")
	gitCmd(t, source, "commit", "-m", "initial")
	before := treeDigest(t, source)
	urlDest := filepath.Join(t.TempDir(), "url")
	revision, err := fetch(urlDest, "file://"+source, "", "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	local := workspaceFromLocal(t, source)
	localHead, err := os.ReadFile(filepath.Join(local, ".git", "refs", "heads", "main"))
	if err != nil || strings.TrimSpace(string(localHead)) != revision {
		t.Fatalf("local HEAD %s revision %s", localHead, revision)
	}
	edited := []byte("hello\nchanged\n")
	must(t, os.WriteFile(filepath.Join(urlDest, "README"), edited, 0644))
	must(t, os.WriteFile(filepath.Join(local, "README"), edited, 0644))
	if treeDigest(t, source) != before {
		t.Fatal("source checkout changed")
	}
	baseline := exportTree(t, source)
	urlOut, localOut := t.TempDir(), t.TempDir()
	if err := Result(baseline, exportTree(t, urlDest), urlOut); err != nil {
		t.Fatal(err)
	}
	if err := Result(baseline, exportTree(t, local), localOut); err != nil {
		t.Fatal(err)
	}
	urlPatch, _ := os.ReadFile(filepath.Join(urlOut, "changes.patch"))
	localPatch, _ := os.ReadFile(filepath.Join(localOut, "changes.patch"))
	if normalizePatch(urlPatch) != normalizePatch(localPatch) {
		t.Fatalf("url:\n%s\nlocal:\n%s", urlPatch, localPatch)
	}
	if !bytes.Contains(urlPatch, []byte("diff --git a/README b/README")) {
		t.Fatalf("patch:\n%s", urlPatch)
	}
}

func TestPlainDirectoryImportsNoHistory(t *testing.T) {
	root := t.TempDir()
	must(t, os.WriteFile(filepath.Join(root, "a.txt"), []byte("a\n"), 0644))
	dest := filepath.Join(t.TempDir(), "history")
	if err := ImportGit(root, dest); !errors.Is(err, ErrNoGit) {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dest, ".git")); !os.IsNotExist(err) {
		t.Fatal("invented history")
	}
}

func TestImportGitSanitizesWithoutTouchingSource(t *testing.T) {
	source := t.TempDir()
	gitCmd(t, source, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(source, "README"), []byte("hello\n"), 0644))
	gitCmd(t, source, "add", "README")
	gitCmd(t, source, "commit", "-m", "initial")
	token := "super-secret-token"
	gitCmd(t, source, "remote", "add", "origin", "https://"+token+"@github.com/org/repo.git")
	gitCmd(t, source, "config", "credential.helper", "store")
	gitDir := filepath.Join(source, ".git")
	must(t, os.MkdirAll(filepath.Join(gitDir, "objects", "info"), 0755))
	must(t, os.WriteFile(filepath.Join(gitDir, "objects", "info", "alternates"), []byte("/host/objects\n"), 0644))
	must(t, os.WriteFile(filepath.Join(gitDir, "hooks", "post-checkout"), []byte("#!/bin/sh\n"), 0755))
	must(t, os.WriteFile(filepath.Join(gitDir, "FETCH_HEAD"), []byte("https://"+token+"@github.com/org/repo.git\n"), 0644))
	before := treeDigest(t, source)
	dest := filepath.Join(t.TempDir(), "history")
	if err := ImportGit(source, dest); err != nil {
		t.Fatal(err)
	}
	if treeDigest(t, source) != before {
		t.Fatal("source checkout changed")
	}
	config, err := os.ReadFile(filepath.Join(dest, ".git", "config"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(config, []byte(token)) || bytes.Contains(config, []byte("credential")) || !bytes.Contains(config, []byte("https://github.com/org/repo.git")) || !bytes.Contains(config, []byte("hooksPath = /dev/null")) {
		t.Fatalf("config:\n%s", config)
	}
	for _, name := range []string{"hooks", "objects/info/alternates", "FETCH_HEAD"} {
		if _, err := os.Stat(filepath.Join(dest, ".git", name)); !os.IsNotExist(err) {
			t.Fatal(name)
		}
	}
	var packed bytes.Buffer
	if err := PackGit(dest, &packed, Limit); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(packed.Bytes(), []byte(token)) {
		t.Fatal("token in git archive")
	}
}

func TestLinkedWorktreeImportsHistory(t *testing.T) {
	main := t.TempDir()
	gitCmd(t, main, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(main, "README"), []byte("hello\n"), 0644))
	gitCmd(t, main, "add", "README")
	gitCmd(t, main, "commit", "-m", "initial")
	linked := filepath.Join(t.TempDir(), "linked")
	gitCmd(t, main, "worktree", "add", "--detach", linked, "HEAD")
	info, err := os.Lstat(filepath.Join(linked, ".git"))
	if err != nil || info.IsDir() {
		t.Fatal("fixture is not a linked worktree")
	}
	before := treeDigest(t, linked)
	head := gitOutputIn(t, linked, "rev-parse", "HEAD")
	dest := filepath.Join(t.TempDir(), "history")
	if err := ImportGit(linked, dest); err != nil {
		t.Fatal(err)
	}
	if treeDigest(t, linked) != before {
		t.Fatal("source worktree changed")
	}
	gitInfo, err := os.Lstat(filepath.Join(dest, ".git"))
	if err != nil || !gitInfo.IsDir() || gitInfo.Mode()&os.ModeSymlink != 0 {
		t.Fatal("imported history is not a git directory")
	}
	if got := gitOutputIn(t, dest, "rev-parse", "HEAD"); got != head {
		t.Fatalf("HEAD %s want %s", got, head)
	}
	config, err := os.ReadFile(filepath.Join(dest, ".git", "config"))
	if err != nil || !bytes.Contains(config, []byte("hooksPath = /dev/null")) || bytes.Contains(config, []byte("credential")) {
		t.Fatalf("config:\n%s", config)
	}
	for _, name := range []string{"hooks", "objects/info/alternates"} {
		if _, err := os.Stat(filepath.Join(dest, ".git", name)); !os.IsNotExist(err) {
			t.Fatal(name)
		}
	}
	baseline := exportTree(t, linked)
	edited := exportTree(t, linked)
	must(t, os.WriteFile(filepath.Join(edited, "README"), []byte("hello\nchanged\n"), 0644))
	out := t.TempDir()
	if err := Result(baseline, edited, out); err != nil {
		t.Fatal(err)
	}
	clone := filepath.Join(t.TempDir(), "clone")
	gitCmd(t, t.TempDir(), "clone", dest, clone)
	apply := exec.Command("git", "apply", "--binary", filepath.Join(out, "changes.patch"))
	apply.Dir = clone
	apply.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
	if output, err := apply.CombinedOutput(); err != nil {
		t.Fatalf("git apply: %s", output)
	}
	applied, err := os.ReadFile(filepath.Join(clone, "README"))
	if err != nil || string(applied) != "hello\nchanged\n" {
		t.Fatalf("applied %q %v", applied, err)
	}
	if treeDigest(t, linked) != before {
		t.Fatal("source worktree changed")
	}
}

func TestBogusGitFileIsNotCopied(t *testing.T) {
	root := t.TempDir()
	must(t, os.WriteFile(filepath.Join(root, "a.txt"), []byte("a\n"), 0644))
	must(t, os.WriteFile(filepath.Join(root, ".git"), []byte("gitdir: /elsewhere\n"), 0644))
	before := treeDigest(t, root)
	dest := filepath.Join(t.TempDir(), "history")
	err := ImportGit(root, dest)
	if err == nil || errors.Is(err, ErrNoGit) {
		t.Fatalf("expected git failure, got %v", err)
	}
	if treeDigest(t, root) != before {
		t.Fatal("source checkout changed")
	}
	if data, readErr := os.ReadFile(filepath.Join(dest, ".git")); readErr == nil && bytes.Contains(data, []byte("gitdir:")) {
		t.Fatal("copied gitfile")
	}
}

func TestLocalSubmoduleIsRejected(t *testing.T) {
	root := t.TempDir()
	gitCmd(t, root, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(root, "README"), []byte("hello\n"), 0644))
	gitCmd(t, root, "add", "README")
	gitCmd(t, root, "commit", "-m", "initial")
	rev := gitOutputIn(t, root, "rev-parse", "HEAD")
	must(t, os.Mkdir(filepath.Join(root, "vendor"), 0755))
	must(t, os.WriteFile(filepath.Join(root, "vendor", "inside"), []byte("sub\n"), 0644))
	gitCmd(t, root, "update-index", "--add", "--cacheinfo", "160000,"+rev+",vendor")
	_, err := Names(root, true)
	if err == nil || !strings.Contains(err.Error(), "submodule/directory entry unsupported: vendor") {
		t.Fatal(err)
	}
}

func TestGitfileDoesNotImportUnrelatedRepository(t *testing.T) {
	secret := t.TempDir()
	gitCmd(t, secret, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(secret, "secret.txt"), []byte("TOP-SECRET-HISTORY\n"), 0644))
	gitCmd(t, secret, "add", "secret.txt")
	gitCmd(t, secret, "commit", "-m", "secret")
	checkout := t.TempDir()
	must(t, os.WriteFile(filepath.Join(checkout, "README"), []byte("visible\n"), 0644))
	must(t, os.WriteFile(filepath.Join(checkout, ".git"), []byte("gitdir: "+filepath.Join(secret, ".git")+"\n"), 0644))
	beforeCheckout := treeDigest(t, checkout)
	beforeSecret := treeDigest(t, secret)
	dest := filepath.Join(t.TempDir(), "history")
	err := ImportGit(checkout, dest)
	if err == nil || errors.Is(err, ErrNoGit) {
		t.Fatalf("expected import failure, got %v", err)
	}
	if treeDigest(t, checkout) != beforeCheckout || treeDigest(t, secret) != beforeSecret {
		t.Fatal("source checkout changed")
	}
	if treeContains(t, dest, "TOP-SECRET-HISTORY") {
		t.Fatal("imported unrelated history")
	}
}

func TestNestedGitMetadataIsStripped(t *testing.T) {
	source := t.TempDir()
	gitCmd(t, source, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(source, "README"), []byte("hello\n"), 0644))
	gitCmd(t, source, "add", "README")
	gitCmd(t, source, "commit", "-m", "initial")
	gitDir := filepath.Join(source, ".git")
	module := filepath.Join(gitDir, "modules", "vendor")
	must(t, os.MkdirAll(filepath.Join(module, "hooks"), 0755))
	must(t, os.MkdirAll(filepath.Join(module, "objects", "info"), 0755))
	must(t, os.WriteFile(filepath.Join(module, "hooks", "post-checkout"), []byte("#!/bin/sh\necho nested-hook\n"), 0755))
	must(t, os.WriteFile(filepath.Join(module, "config"), []byte("[core]\n\trepositoryformatversion = 0\n[remote \"origin\"]\n\turl = https://example.invalid/repo.git\n[branch \"main\"]\n\tremote = origin\n\tmerge = refs/heads/main\n[credential]\n\thelper = store\n[credential \"https://example\"]\n\thelper = osxkeychain\n[credential] # keep\n\thelper = commented-helper\n[credential] ; keep\n\thelper = semicolon-helper\n"), 0644))
	must(t, os.WriteFile(filepath.Join(gitDir, "config.worktree"), []byte("[credential] # keep\n\thelper = worktree-helper\n"), 0644))
	must(t, os.MkdirAll(filepath.Join(gitDir, "objects", "info"), 0755))
	must(t, os.WriteFile(filepath.Join(gitDir, "objects", "info", "http-alternates"), []byte("https://example.invalid/objects\n"), 0644))
	must(t, os.WriteFile(filepath.Join(module, "objects", "info", "alternates"), []byte("/host/objects\n"), 0644))
	before := treeDigest(t, source)
	dest := filepath.Join(t.TempDir(), "history")
	if err := ImportGit(source, dest); err != nil {
		t.Fatal(err)
	}
	if treeDigest(t, source) != before {
		t.Fatal("source checkout changed")
	}
	destGit := filepath.Join(dest, ".git")
	for _, rel := range []string{
		"hooks",
		"modules/vendor/hooks",
		"modules/vendor/hooks/post-checkout",
		"objects/info/http-alternates",
		"modules/vendor/objects/info/alternates",
	} {
		if _, err := os.Lstat(filepath.Join(destGit, rel)); !os.IsNotExist(err) {
			t.Fatal(rel)
		}
	}
	nested, err := os.ReadFile(filepath.Join(destGit, "modules", "vendor", "config"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(bytes.ToLower(nested), []byte("helper")) {
		t.Fatalf("nested config:\n%s", nested)
	}
	if !bytes.Contains(nested, []byte("repositoryformatversion = 0")) || !bytes.Contains(nested, []byte("[credential] # keep")) || !bytes.Contains(nested, []byte("[remote \"origin\"]")) || !bytes.Contains(nested, []byte("[branch \"main\"]")) || !bytes.Contains(nested, []byte("[credential \"https://example\"]")) {
		t.Fatalf("nested config:\n%s", nested)
	}
	worktree, err := os.ReadFile(filepath.Join(destGit, "config.worktree"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(bytes.ToLower(worktree), []byte("helper")) || !bytes.Contains(worktree, []byte("[credential] # keep")) {
		t.Fatalf("config.worktree:\n%s", worktree)
	}
	var packed bytes.Buffer
	if err := PackGit(dest, &packed, Limit); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(packed.Bytes(), []byte("nested-hook")) || bytes.Contains(packed.Bytes(), []byte("osxkeychain")) || bytes.Contains(packed.Bytes(), []byte("commented-helper")) || bytes.Contains(packed.Bytes(), []byte("semicolon-helper")) || bytes.Contains(packed.Bytes(), []byte("worktree-helper")) || bytes.Contains(packed.Bytes(), []byte("http-alternates")) || bytes.Contains(packed.Bytes(), []byte("/host/objects")) {
		t.Fatal("unsafe metadata packed")
	}
}

func TestPackGitRejectsRemainingNestedMetadata(t *testing.T) {
	cases := []struct {
		name  string
		plant func(gitDir string)
	}{
		{
			name: "hooks",
			plant: func(gitDir string) {
				must(t, os.MkdirAll(filepath.Join(gitDir, "modules", "vendor", "hooks"), 0755))
				must(t, os.WriteFile(filepath.Join(gitDir, "modules", "vendor", "hooks", "post-checkout"), []byte("#!/bin/sh\n"), 0755))
			},
		},
		{
			name: "http-alternates",
			plant: func(gitDir string) {
				must(t, os.MkdirAll(filepath.Join(gitDir, "objects", "info"), 0755))
				must(t, os.WriteFile(filepath.Join(gitDir, "objects", "info", "http-alternates"), []byte("https://example.invalid/objects\n"), 0644))
			},
		},
		{
			name: "alternates",
			plant: func(gitDir string) {
				must(t, os.MkdirAll(filepath.Join(gitDir, "modules", "vendor", "objects", "info"), 0755))
				must(t, os.WriteFile(filepath.Join(gitDir, "modules", "vendor", "objects", "info", "alternates"), []byte("/host/objects\n"), 0644))
			},
		},
		{
			name: "credential.helper",
			plant: func(gitDir string) {
				must(t, os.MkdirAll(filepath.Join(gitDir, "modules", "vendor"), 0755))
				must(t, os.WriteFile(filepath.Join(gitDir, "modules", "vendor", "config"), []byte("[credential]\n\thelper = store\n"), 0644))
			},
		},
		{
			name: "commented-credential-header",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[credential] # keep\n\thelper = osxkeychain\n[credential] ; keep\n\thelper = store\n"), 0644))
			},
		},
		{
			name: "config.worktree",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config.worktree"), []byte("[credential] # keep\n\thelper = osxkeychain\n"), 0644))
			},
		},
		{
			name: "include",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[include] # keep\n\tpath = ../secret-config\n"), 0644))
			},
		},
		{
			name: "includeIf",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[includeIf \"gitdir:~/work\"] ; keep\n\tpath = ../secret-config\n"), 0644))
			},
		},
		{
			name: "include.path",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("include.path = ../secret-config\n"), 0644))
			},
		},
		{
			name: "extensions.worktreeConfig",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[extensions] # keep\n\tworktreeConfig = true\n"), 0644))
				must(t, os.WriteFile(filepath.Join(gitDir, "config.worktree"), []byte("[credential]\n\thelper = osxkeychain\n"), 0644))
			},
		},
		{
			name: "credential-header-extra",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[credential] extra\n[credential]\textra\n"), 0644))
			},
		},
		{
			name: "same-line-helper",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[credential] helper = store\n"), 0644))
			},
		},
		{
			name: "same-line-helper-tight",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[credential]helper=store\n"), 0644))
			},
		},
		{
			name: "same-line-helper-tab",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[credential]\thelper = store\n"), 0644))
			},
		},
		{
			name: "same-line-helper-quoted",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[credential] helper = \"store\"\n"), 0644))
			},
		},
		{
			name: "same-line-worktreeConfig",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[extensions] worktreeConfig\n"), 0644))
			},
		},
		{
			name: "bare-worktreeConfig",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[extensions]\n\tworktreeConfig\n"), 0644))
			},
		},
		{
			name: "unrecognized",
			plant: func(gitDir string) {
				must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[core]\n\tthis is not a key\n"), 0644))
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			gitDir := filepath.Join(root, ".git")
			must(t, os.MkdirAll(gitDir, 0755))
			must(t, os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte("ref: refs/heads/main\n"), 0644))
			tc.plant(gitDir)
			var packed bytes.Buffer
			if err := PackGit(root, &packed, Limit); err == nil {
				t.Fatal("packed unsafe history")
			}
		})
	}
}

func TestImportRejectsIncludeAndWorktreeConfig(t *testing.T) {
	cases := []struct {
		name string
		want string
		add  string
	}{
		{name: "include", want: "include", add: "[include] # keep\n\tpath = ../secret-config\n"},
		{name: "includeIf", want: "include", add: "[includeIf \"gitdir:~/work\"] ; keep\n\tpath = ../secret-config\n"},
		{name: "include.path", want: "include", add: "include.path = ../secret-config\n"},
		{name: "extensions.worktreeConfig", want: "extensions.worktreeConfig", add: "[extensions] # keep\n\tworktreeConfig = true\n"},
		{name: "bare-worktreeConfig", want: "extensions.worktreeConfig", add: "[extensions]\n\tworktreeConfig\n"},
		{name: "unrecognized", want: "unrecognized", add: "this is not a key\n"},
		{name: "same-line-helper", want: "unrecognized", add: "[credential] helper = store\n"},
		{name: "same-line-helper-tight", want: "unrecognized", add: "[credential]helper=store\n"},
		{name: "same-line-helper-tab", want: "unrecognized", add: "[credential]\thelper = store\n"},
		{name: "same-line-helper-quoted", want: "unrecognized", add: "[credential] helper = \"store\"\n"},
		{name: "same-line-worktreeConfig", want: "unrecognized", add: "[extensions] worktreeConfig\n"},
		{name: "credential-header-extra", want: "unrecognized", add: "[credential] extra\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			source := t.TempDir()
			gitCmd(t, source, "init", "-b", "main")
			must(t, os.WriteFile(filepath.Join(source, "README"), []byte("hello\n"), 0644))
			gitCmd(t, source, "add", "README")
			gitCmd(t, source, "commit", "-m", "initial")
			gitDir := filepath.Join(source, ".git")
			cfg, err := os.ReadFile(filepath.Join(gitDir, "config"))
			if err != nil {
				t.Fatal(err)
			}
			must(t, os.WriteFile(filepath.Join(gitDir, "config"), append(cfg, []byte(tc.add)...), 0644))
			must(t, os.WriteFile(filepath.Join(gitDir, "config.worktree"), []byte("[credential] # keep\n\thelper = osxkeychain\n"), 0644))
			must(t, os.WriteFile(filepath.Join(gitDir, "secret-config"), []byte("[credential]\n\thelper = osxkeychain\n"), 0644))
			before := treeDigest(t, source)
			err = ImportGit(source, filepath.Join(t.TempDir(), "history"))
			if err == nil || errors.Is(err, ErrNoGit) || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("got %v", err)
			}
			if treeDigest(t, source) != before {
				t.Fatal("source checkout changed")
			}
		})
	}
}

func workspaceFromLocal(t *testing.T, source string) string {
	t.Helper()
	ws := t.TempDir()
	var files bytes.Buffer
	if err := Pack(source, &files, true, Limit); err != nil {
		t.Fatal(err)
	}
	if err := Unpack(ws, bytes.NewReader(files.Bytes()), Limit); err != nil {
		t.Fatal(err)
	}
	history := t.TempDir()
	if err := ImportGit(source, history); err != nil {
		t.Fatal(err)
	}
	var gitTar bytes.Buffer
	if err := PackGit(history, &gitTar, Limit); err != nil {
		t.Fatal(err)
	}
	if err := Unpack(ws, bytes.NewReader(gitTar.Bytes()), Limit); err != nil {
		t.Fatal(err)
	}
	return ws
}

func exportTree(t *testing.T, root string) string {
	t.Helper()
	var packed bytes.Buffer
	if err := Pack(root, &packed, true, Limit); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if err := Unpack(dest, &packed, Limit); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dest, ".git")); !os.IsNotExist(err) {
		t.Fatal(".git exported")
	}
	return dest
}

func treeDigest(t *testing.T, root string) string {
	t.Helper()
	sum := sha256.New()
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		fmt.Fprintf(sum, "%s %o\n", filepath.ToSlash(rel), info.Mode())
		if info.Mode().IsRegular() {
			data, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			sum.Write(data)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			link, err := os.Readlink(p)
			if err != nil {
				return err
			}
			sum.Write([]byte(link))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(sum.Sum(nil))
}

func treeContains(t *testing.T, root, needle string) bool {
	t.Helper()
	if _, err := os.Stat(root); os.IsNotExist(err) {
		return false
	}
	found := false
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || found || d.IsDir() || !d.Type().IsRegular() {
			return err
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if bytes.Contains(data, []byte(needle)) {
			found = true
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return found
}

func gitOutputIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + t.TempDir(),
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=Test",
		"GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test",
		"GIT_COMMITTER_EMAIL=test@example.com",
	}
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %s: %v", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out))
}

func normalizePatch(patch []byte) string {
	var b strings.Builder
	for _, line := range strings.Split(string(patch), "\n") {
		if strings.HasPrefix(line, "Date:") || strings.HasPrefix(line, "author ") || strings.HasPrefix(line, "committer ") {
			continue
		}
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return b.String()
}
