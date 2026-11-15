package workspace

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestCloneArgsLockHooksAndOmitCredentials(t *testing.T) {
	args := cloneArgs("https://github.com/org/repo.git", "/tmp/dest", "main", false)
	text := strings.Join(args, "\n")
	for _, want := range []string{"core.hooksPath=/dev/null", "credential.helper=", "protocol.file.allow=never", "protocol.ext.allow=never", "init.templateDir=", "--no-recurse-submodules", "--branch", "main"} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %s in %s", want, text)
		}
	}
	if strings.Contains(text, "secret-token") || strings.Contains(text, "@") {
		t.Fatal(text)
	}
}

func TestCleanEnvOmitsAgentAndAskpass(t *testing.T) {
	t.Setenv("SSH_AUTH_SOCK", "/tmp/agent.sock")
	t.Setenv("GIT_ASKPASS", "/tmp/user-askpass")
	t.Setenv("GIT_TEMPLATE_DIR", "/tmp/template")
	text := strings.Join(cleanEnv("/tmp/home", nil), "\n")
	for _, banned := range []string{"SSH_AUTH_SOCK", "GIT_ASKPASS", "GIT_TEMPLATE_DIR", "/tmp/agent.sock", "/tmp/user-askpass"} {
		if strings.Contains(text, banned) {
			t.Fatal(text)
		}
	}
	if !strings.Contains(text, "GIT_CONFIG_NOSYSTEM=1") || !strings.Contains(text, "GIT_CONFIG_GLOBAL=/dev/null") {
		t.Fatal(text)
	}
}

func TestAskPassAnswersPrompts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "askpass")
	if err := writeAskPass(path); err != nil {
		t.Fatal(err)
	}
	username := exec.Command(path, "Username for 'https://github.com'")
	username.Env = []string{"DYNOCAP_GIT_TOKEN=secret-token", "PATH=" + os.Getenv("PATH")}
	out, err := username.Output()
	if err != nil || string(out) != "git\n" {
		t.Fatalf("username %q %v", out, err)
	}
	password := exec.Command(path, "Password for 'https://github.com'")
	password.Env = username.Env
	out, err = password.Output()
	if err != nil || string(out) != "secret-token\n" {
		t.Fatalf("password %q %v", out, err)
	}
}

func TestSSHWrapperIsRestricted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ssh")
	if err := writeSSHWrapper(path); err != nil {
		t.Fatal(err)
	}
	text, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"-F /dev/null", "IdentitiesOnly=yes", "IdentityAgent=none", "ForwardAgent=no", "BatchMode=yes", "StrictHostKeyChecking=accept-new"} {
		if !bytes.Contains(text, []byte(want)) {
			t.Fatalf("missing %s", want)
		}
	}
}

func TestParseRepositoryURLRejectsCredentials(t *testing.T) {
	for _, raw := range []string{"http://github.com/org/repo.git", "ext::sh", "https://token@github.com/org/repo.git", "ssh://token@github.com/org/repo.git", "git@"} {
		if _, err := ParseRepositoryURL(raw); err == nil {
			t.Fatal(raw)
		}
	}
	if _, err := fetch(t.TempDir(), "file:///tmp/repo.git", "", "", "", false); err == nil {
		t.Fatal("accepted file URL")
	}
	parsed, err := ParseRepositoryURL("git@github.com:org/repo.git")
	if err != nil || parsed.Kind != "ssh" {
		t.Fatal(err, parsed)
	}
}

func TestSanitizeRemovesCredentialMaterial(t *testing.T) {
	root := t.TempDir()
	gitDir := filepath.Join(root, ".git")
	token := "super-secret-token"
	must(t, os.MkdirAll(filepath.Join(gitDir, "objects", "info"), 0755))
	must(t, os.MkdirAll(filepath.Join(gitDir, "hooks"), 0755))
	must(t, os.MkdirAll(filepath.Join(gitDir, "refs", "heads"), 0755))
	must(t, os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte("ref: refs/heads/main\n"), 0644))
	must(t, os.WriteFile(filepath.Join(gitDir, "refs", "heads", "main"), []byte(strings.Repeat("a", 40)+"\n"), 0644))
	must(t, os.WriteFile(filepath.Join(gitDir, "config"), []byte("[remote \"origin\"]\n\turl = https://"+token+"@github.com/org/repo.git\n"), 0644))
	must(t, os.WriteFile(filepath.Join(gitDir, "objects", "info", "alternates"), []byte("/host/objects\n"), 0644))
	must(t, os.WriteFile(filepath.Join(gitDir, "hooks", "post-checkout"), []byte("#!/bin/sh\n"), 0755))
	must(t, os.WriteFile(filepath.Join(gitDir, "FETCH_HEAD"), []byte("https://"+token+"@github.com/org/repo.git\n"), 0644))
	if err := Sanitize(root, "https://github.com/org/repo.git", "main", token); err != nil {
		t.Fatal(err)
	}
	config, err := os.ReadFile(filepath.Join(gitDir, "config"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(config, []byte(token)) || !bytes.Contains(config, []byte("https://github.com/org/repo.git")) || !bytes.Contains(config, []byte("hooksPath = /dev/null")) {
		t.Fatalf("config:\n%s", config)
	}
	for _, name := range []string{"hooks", "objects/info/alternates", "FETCH_HEAD"} {
		if _, err := os.Stat(filepath.Join(gitDir, name)); !os.IsNotExist(err) {
			t.Fatal(name)
		}
	}
	var packed bytes.Buffer
	if err := PackGit(root, &packed, Limit); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(packed.Bytes(), []byte(token)) {
		t.Fatal("token in git archive")
	}
}

func TestSanitizeRejectsGitFile(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".git"), []byte("gitdir: /elsewhere\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if Sanitize(root, "https://github.com/org/repo.git", "", "") == nil {
		t.Fatal("accepted linked worktree")
	}
}

func TestFreezeAndPackSkipGitHistory(t *testing.T) {
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, ".git"), 0755))
	must(t, os.WriteFile(filepath.Join(root, ".git", "config"), []byte("secret-history\n"), 0644))
	must(t, os.WriteFile(filepath.Join(root, "README"), []byte("hello\n"), 0644))
	names, err := Names(root, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range names {
		if name == ".git" || strings.HasPrefix(name, ".git/") {
			t.Fatal(name)
		}
	}
	freeze := filepath.Join(t.TempDir(), "freeze.json")
	if err := Freeze(root, freeze); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(freeze)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(".git")) {
		t.Fatal(string(raw))
	}
	var packed bytes.Buffer
	if err := Pack(root, &packed, true, Limit); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(packed.Bytes(), []byte("secret-history")) {
		t.Fatal("project pack included git config")
	}
	if !bytes.Contains(packed.Bytes(), []byte("hello")) {
		t.Fatal("project pack dropped the project file")
	}
}

func TestFetchDoesNotRunTemplateHook(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "hook-ran")
	template := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(template, "hooks"), 0755))
	script := "#!/bin/sh\necho ran > " + shellQuote(marker) + "\n"
	must(t, os.WriteFile(filepath.Join(template, "hooks", "post-checkout"), []byte(script), 0755))
	source := filepath.Join(t.TempDir(), "source")
	must(t, os.MkdirAll(source, 0755))
	gitCmd(t, source, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(source, "README"), []byte("hello\n"), 0644))
	gitCmd(t, source, "add", "README")
	gitCmd(t, source, "commit", "-m", "initial")
	naive := filepath.Join(t.TempDir(), "naive")
	cmd := exec.Command("git", "clone", source, naive)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "GIT_TEMPLATE_DIR=" + template}
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("control clone: %s", out)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("control clone did not run the template hook")
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_TEMPLATE_DIR", template)
	dest := filepath.Join(t.TempDir(), "safe")
	revision, err := fetch(dest, "file://"+source, "", "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	if !commitPattern.MatchString(revision) {
		t.Fatal(revision)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("restricted fetch ran a template hook")
	}
	head, err := os.ReadFile(filepath.Join(dest, ".git", "HEAD"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(head, []byte(revision)) {
		t.Fatalf("HEAD %s revision %s", head, revision)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func gitCmd(t *testing.T, dir string, args ...string) {
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
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %s", strings.Join(args, " "), out)
	}
}

func shellQuote(path string) string {
	return "'" + strings.ReplaceAll(path, "'", "'\\''") + "'"
}

func TestSharedRefVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../testdata/repository-refs.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors []struct {
		Ref        string
		Valid      bool
		Normalized string
		Commit     bool
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	for _, v := range vectors {
		if (ValidateRef(v.Ref) == nil) != v.Valid {
			t.Errorf("validation %q", v.Ref)
		}
		if normalizeRef(v.Ref) != v.Normalized {
			t.Errorf("normalization %q", v.Ref)
		}
		if commitPattern.MatchString(normalizeRef(v.Ref)) != v.Commit {
			t.Errorf("commit %q", v.Ref)
		}
	}
}
