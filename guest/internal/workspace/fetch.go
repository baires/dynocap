package workspace

import (
	"archive/tar"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Fetch clones a repository on the host. The token and SSH key stay in this
// process. The returned checkout has had credential material removed.
func Fetch(dest, rawURL, ref, token, sshKey string) (string, error) {
	return fetch(dest, rawURL, ref, token, sshKey, false)
}

func fetch(dest, rawURL, ref, token, sshKey string, allowFile bool) (string, error) {
	parsed, err := ParseRepositoryURL(rawURL)
	if err != nil {
		return "", err
	}
	if parsed.Kind == "file" && !allowFile {
		return "", fmt.Errorf("repository URL must be https or ssh")
	}
	if ref != "" {
		if err := ValidateRef(ref); err != nil {
			return "", err
		}
	}
	if token != "" && sshKey != "" {
		return "", fmt.Errorf("pass a token or an ssh key, not both")
	}
	if token != "" && parsed.Kind != "https" {
		return "", fmt.Errorf("an https token cannot fetch an ssh repository")
	}
	if sshKey != "" && parsed.Kind != "ssh" {
		return "", fmt.Errorf("an ssh key cannot fetch an https repository")
	}
	if sshKey != "" {
		info, err := os.Lstat(sshKey)
		if err != nil || !info.Mode().IsRegular() {
			return "", fmt.Errorf("ssh key is not a file")
		}
		if info.Mode().Perm()&0077 != 0 {
			return "", fmt.Errorf("ssh key must be readable only by its owner")
		}
	}
	scripts, err := os.MkdirTemp("", "microvm-fetch-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(scripts)
	extra := map[string]string{}
	if token != "" {
		askpass := filepath.Join(scripts, "askpass")
		if err := writeAskPass(askpass); err != nil {
			return "", err
		}
		extra["GIT_ASKPASS"] = askpass
		extra["SSH_ASKPASS"] = askpass
		extra["MICROVM_GIT_TOKEN"] = token
	}
	if sshKey != "" {
		wrapper := filepath.Join(scripts, "ssh")
		if err := writeSSHWrapper(wrapper); err != nil {
			return "", err
		}
		known := filepath.Join(scripts, "known_hosts")
		if err := os.WriteFile(known, nil, 0600); err != nil {
			return "", err
		}
		extra["GIT_SSH_COMMAND"] = wrapper
		extra["MICROVM_SSH_KEY"] = sshKey
		extra["MICROVM_KNOWN_HOSTS"] = known
	}
	env := cleanEnv(scripts, extra)
	if err := os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
		return "", err
	}
	bin, err := hostGit()
	if err != nil {
		return "", err
	}
	clone := exec.Command(bin, cloneArgs(parsed.URL, dest, ref, allowFile)...)
	clone.Env = env
	if out, err := clone.CombinedOutput(); err != nil {
		return "", fmt.Errorf("git clone failed: %s", redact(string(out), token, sshKey))
	}
	revision, err := gitOutput(dest, env, "rev-parse", "HEAD")
	if err != nil {
		return "", err
	}
	revision = strings.TrimSpace(revision)
	if !commitPattern.MatchString(revision) {
		return "", fmt.Errorf("git did not return a commit")
	}
	branch := ""
	if out, err := gitOutput(dest, env, "symbolic-ref", "--quiet", "HEAD"); err == nil {
		name := strings.TrimPrefix(strings.TrimSpace(out), "refs/heads/")
		if ValidateRef(name) == nil {
			branch = name
		}
	}
	detach := exec.Command(bin, append([]string{"-C", dest}, lockedConfig()...)...)
	detach.Args = append(detach.Args, "checkout", "--detach", revision)
	detach.Env = env
	if out, err := detach.CombinedOutput(); err != nil {
		return "", fmt.Errorf("git checkout failed: %s", redact(string(out), token, sshKey))
	}
	if err := Sanitize(dest, parsed.URL, branch, token); err != nil {
		return "", err
	}
	return revision, nil
}

type ParsedRepository struct {
	URL  string
	Kind string
}

func ParseRepositoryURL(raw string) (ParsedRepository, error) {
	if strings.ContainsAny(raw, " \t\r\n\\") || raw == "" {
		return ParsedRepository{}, fmt.Errorf("repository URL is invalid")
	}
	switch {
	case strings.HasPrefix(raw, "ext::") || strings.HasPrefix(raw, "file://") || strings.HasPrefix(raw, "http://"):
		kind := "rejected"
		if strings.HasPrefix(raw, "file://") {
			kind = "file"
		}
		if kind == "file" {
			return ParsedRepository{URL: raw, Kind: "file"}, nil
		}
		return ParsedRepository{}, fmt.Errorf("repository URL must be https or ssh")
	case strings.HasPrefix(raw, "https://"):
		if strings.Contains(raw, "@") {
			return ParsedRepository{}, fmt.Errorf("repository URL must not include credentials")
		}
		rest := strings.TrimPrefix(raw, "https://")
		host, path, ok := strings.Cut(rest, "/")
		if !ok || host == "" || path == "" || strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
			// host:port is acceptable; userinfo is already rejected by '@'.
		}
		if host == "" || path == "" {
			return ParsedRepository{}, fmt.Errorf("repository URL is invalid")
		}
		return ParsedRepository{URL: raw, Kind: "https"}, nil
	case strings.HasPrefix(raw, "ssh://"):
		if sshUserinfo(raw) {
			return ParsedRepository{}, fmt.Errorf("repository URL must not include credentials")
		}
		return ParsedRepository{URL: raw, Kind: "ssh"}, nil
	case strings.HasPrefix(raw, "git@"):
		rest := strings.TrimPrefix(raw, "git@")
		host, path, ok := strings.Cut(rest, ":")
		if !ok || host == "" || path == "" || strings.Contains(host, "@") {
			return ParsedRepository{}, fmt.Errorf("repository URL is invalid")
		}
		return ParsedRepository{URL: raw, Kind: "ssh"}, nil
	default:
		return ParsedRepository{}, fmt.Errorf("repository URL must be https or ssh")
	}
}

func sshUserinfo(raw string) bool {
	rest := strings.TrimPrefix(raw, "ssh://")
	host, _, _ := strings.Cut(rest, "/")
	user, pass, ok := strings.Cut(host, "@")
	if !ok {
		return false
	}
	if strings.Contains(user, ":") || pass == "" {
		return true
	}
	return user != "git"
}

var refPattern = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)
var commitPattern = regexp.MustCompile(`^[0-9a-f]{40}$|^[0-9a-f]{64}$`)
var userinfoPattern = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^/\s@]+@`)

func ValidateRef(ref string) error {
	if ref == "" || strings.HasPrefix(ref, "-") || strings.HasPrefix(ref, "/") || strings.HasSuffix(ref, "/") || strings.Contains(ref, "..") || !refPattern.MatchString(ref) {
		return fmt.Errorf("ref must be a branch or tag name")
	}
	return nil
}

func cloneArgs(url, dest, ref string, allowFile bool) []string {
	fileAllow := "never"
	if allowFile {
		fileAllow = "always"
	}
	args := []string{
		"-c", "core.hooksPath=/dev/null",
		"-c", "core.fsmonitor=",
		"-c", "credential.helper=",
		"-c", "protocol.file.allow=" + fileAllow,
		"-c", "protocol.ext.allow=never",
		"-c", "init.templateDir=",
		"clone", "--no-recurse-submodules",
	}
	if ref != "" {
		args = append(args, "--branch", ref)
	}
	args = append(args, "--", url, dest)
	return args
}

func lockedConfig() []string {
	return []string{"-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=", "-c", "credential.helper="}
}

func cleanEnv(home string, extra map[string]string) []string {
	path := "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
	values := map[string]string{
		"PATH":                path,
		"HOME":                home,
		"GIT_CONFIG_NOSYSTEM": "1",
		"GIT_CONFIG_GLOBAL":   "/dev/null",
		"GIT_TERMINAL_PROMPT": "0",
	}
	for key, value := range extra {
		values[key] = value
	}
	env := make([]string, 0, len(values))
	for key, value := range values {
		env = append(env, key+"="+value)
	}
	return env
}

func writeAskPass(path string) error {
	script := "#!/bin/sh\ncase \"$1\" in\n*Username*) printf '%s\\n' git ;;\n*Password*) printf '%s\\n' \"$MICROVM_GIT_TOKEN\" ;;\n*) exit 1 ;;\nesac\n"
	return os.WriteFile(path, []byte(script), 0700)
}

func writeSSHWrapper(path string) error {
	script := "#!/bin/sh\nexec ssh -F /dev/null -i \"$MICROVM_SSH_KEY\" -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no -o BatchMode=yes -o UserKnownHostsFile=\"$MICROVM_KNOWN_HOSTS\" -o StrictHostKeyChecking=accept-new \"$@\"\n"
	return os.WriteFile(path, []byte(script), 0700)
}

func gitOutput(dir string, env []string, args ...string) (string, error) {
	bin, err := hostGit()
	if err != nil {
		return "", err
	}
	cmd := exec.Command(bin, append([]string{"-C", dir}, lockedConfig()...)...)
	cmd.Args = append(cmd.Args, args...)
	cmd.Env = env
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s failed", strings.Join(args, " "))
	}
	return string(out), nil
}

// Sanitize rewrites origin and drops host credential material before import.
func Sanitize(root, cleanURL, branch, token string) error {
	gitDir := filepath.Join(root, ".git")
	info, err := os.Lstat(gitDir)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("repository history is not a directory")
	}
	var config strings.Builder
	config.WriteString("[core]\n\thooksPath = /dev/null\n\tfsmonitor =\n")
	config.WriteString("[remote \"origin\"]\n")
	fmt.Fprintf(&config, "\turl = %s\n", cleanURL)
	config.WriteString("\tfetch = +refs/heads/*:refs/remotes/origin/*\n")
	if branch != "" {
		fmt.Fprintf(&config, "[branch \"%s\"]\n\tremote = origin\n\tmerge = refs/heads/%s\n", branch, branch)
	}
	if err := os.WriteFile(filepath.Join(gitDir, "config"), []byte(config.String()), 0644); err != nil {
		return err
	}
	if err := os.RemoveAll(filepath.Join(gitDir, "hooks")); err != nil {
		return err
	}
	_ = os.Remove(filepath.Join(gitDir, "objects", "info", "alternates"))
	return scrubMetadata(gitDir, token)
}

func scrubMetadata(gitDir, token string) error {
	return filepath.WalkDir(gitDir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(gitDir, p)
		rel = filepath.ToSlash(rel)
		if rel == "objects" || (strings.HasPrefix(rel, "objects/") && !strings.HasPrefix(rel, "objects/info")) {
			if d.IsDir() && rel != "objects/info" {
				if rel == "objects" {
					return nil
				}
				return filepath.SkipDir
			}
			if !strings.HasPrefix(rel, "objects/info") && !d.IsDir() {
				return nil
			}
		}
		if d.IsDir() {
			return nil
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if !containsCredential(data, token) {
			return nil
		}
		if essentialGitFile(rel) {
			return fmt.Errorf("credential material in %s", rel)
		}
		return os.Remove(p)
	})
}

func essentialGitFile(rel string) bool {
	return rel == "HEAD" || rel == "config" || rel == "packed-refs" || strings.HasPrefix(rel, "refs/")
}

func containsCredential(data []byte, token string) bool {
	if token != "" && bytes.Contains(data, []byte(token)) {
		return true
	}
	for _, match := range userinfoPattern.FindAll(data, -1) {
		if bytes.Contains(match, []byte("://git@")) {
			continue
		}
		return true
	}
	return false
}

func redact(text, token, keyPath string) string {
	for _, secret := range []string{token, keyPath} {
		if len(secret) >= 4 {
			text = strings.ReplaceAll(text, secret, "<redacted>")
		}
	}
	return text
}

// PackGit archives sanitized history. Object contents are project data.
// Credential files and hooks are refused.
func PackGit(root string, w io.Writer, limit int64) error {
	gitDir := filepath.Join(root, ".git")
	info, err := os.Lstat(gitDir)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("repository history is not a directory")
	}
	if _, err := os.Lstat(filepath.Join(gitDir, "objects", "info", "alternates")); err == nil {
		return fmt.Errorf("repository history has alternates")
	}
	var names []string
	err = filepath.WalkDir(gitDir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(gitDir, p)
		rel = filepath.ToSlash(rel)
		if rel == "." {
			return nil
		}
		if rel == "hooks" || strings.HasPrefix(rel, "hooks/") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		names = append(names, ".git/"+rel)
		return nil
	})
	if err != nil {
		return err
	}
	tw := tar.NewWriter(w)
	var total int64
	for _, name := range names {
		if strings.Contains(name, "/../") || strings.HasPrefix(name, "../") {
			return fmt.Errorf("unsafe git path %q", name)
		}
		path := filepath.Join(root, filepath.FromSlash(name))
		st, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if !st.Mode().IsRegular() {
			return fmt.Errorf("unsupported git file %s", name)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !strings.Contains(name, "/objects/") && containsCredential(data, "") {
			return fmt.Errorf("repository history contains credentials")
		}
		total += int64(len(data))
		if total > limit {
			return fmt.Errorf("repository history exceeds %d bytes", limit)
		}
		header, err := tar.FileInfoHeader(st, "")
		if err != nil {
			return err
		}
		header.Name = name
		header.Size = int64(len(data))
		header.Uid = 0
		header.Gid = 0
		header.Uname = ""
		header.Gname = ""
		if err := tw.WriteHeader(header); err != nil {
			return err
		}
		if _, err := tw.Write(data); err != nil {
			return err
		}
	}
	return tw.Close()
}

// ErrNoGit means the directory is a tree with no repository history.
var ErrNoGit = errors.New("directory has no git history")

// ImportGit copies sanitized history from a local checkout into dest.
// The source tree is only read. A directory without .git returns ErrNoGit.
// A gitfile is materialized with host Git into a normal repository, then sanitized.
func ImportGit(src, dest string) error {
	resolved, err := filepath.EvalSymlinks(src)
	if err != nil {
		return err
	}
	gitPath := filepath.Join(resolved, ".git")
	info, err := os.Lstat(gitPath)
	if err != nil {
		if os.IsNotExist(err) {
			return ErrNoGit
		}
		return err
	}
	// A gitfile or symlink names a directory outside this checkout. Do not copy
	// that pointer or the directory it names; clone through host Git instead.
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return importLinkedCheckout(resolved, dest)
	}
	if err := os.MkdirAll(dest, 0700); err != nil {
		return err
	}
	if err := copyGitTree(gitPath, filepath.Join(dest, ".git")); err != nil {
		return err
	}
	config, err := os.ReadFile(filepath.Join(dest, ".git", "config"))
	if err != nil {
		return err
	}
	url, token := cleanOrigin(originURL(config))
	return Sanitize(dest, url, headBranch(filepath.Join(dest, ".git")), token)
}

func copyGitTree(src, dst string) error {
	if err := os.MkdirAll(dst, 0755); err != nil {
		return err
	}
	return filepath.WalkDir(src, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == src {
			return nil
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.Mode()&os.ModeSymlink != 0 || (!info.IsDir() && !info.Mode().IsRegular()) {
			return fmt.Errorf("unsupported git file %s", filepath.ToSlash(rel))
		}
		if info.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode().Perm())
	})
}

func originURL(config []byte) string {
	inOrigin := false
	for _, line := range strings.Split(string(config), "\n") {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "[") {
			inOrigin = trim == `[remote "origin"]`
			continue
		}
		if !inOrigin {
			continue
		}
		key, val, ok := strings.Cut(trim, "=")
		if ok && strings.TrimSpace(key) == "url" {
			return strings.Trim(strings.TrimSpace(val), `"`)
		}
	}
	return ""
}

func cleanOrigin(raw string) (string, string) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", ""
	}
	if parsed, err := ParseRepositoryURL(raw); err == nil && parsed.Kind != "file" {
		return parsed.URL, ""
	}
	if strings.HasPrefix(raw, "https://") {
		rest := strings.TrimPrefix(raw, "https://")
		userinfo, hostpath, ok := strings.Cut(rest, "@")
		if ok && hostpath != "" && !strings.Contains(hostpath, "@") {
			cleaned := "https://" + hostpath
			if _, err := ParseRepositoryURL(cleaned); err == nil {
				token := userinfo
				if _, pass, ok := strings.Cut(userinfo, ":"); ok {
					token = pass
				}
				return cleaned, token
			}
		}
	}
	return "", ""
}

func headBranch(gitDir string) string {
	data, err := os.ReadFile(filepath.Join(gitDir, "HEAD"))
	if err != nil {
		return ""
	}
	line := strings.TrimSpace(string(data))
	const prefix = "ref: refs/heads/"
	if !strings.HasPrefix(line, prefix) {
		return ""
	}
	branch := strings.TrimPrefix(line, prefix)
	if ValidateRef(branch) != nil {
		return ""
	}
	return branch
}

// importLinkedCheckout builds a normal repository for a linked worktree.
// Host Git resolves the worktree. The gitfile is never copied or parsed.
func importLinkedCheckout(src, dest string) error {
	bin, err := hostGit()
	if err != nil {
		return err
	}
	home, err := os.MkdirTemp("", "microvm-import-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(home)
	env := gitEnv(home)
	head, err := runGit(bin, home, env, linkedGitArgs("-C", src, "rev-parse", "HEAD"))
	if err != nil {
		return err
	}
	revision := strings.TrimSpace(string(head))
	if !commitPattern.MatchString(revision) {
		return fmt.Errorf("git did not return a commit")
	}
	branch := ""
	if out, err := runGit(bin, home, env, linkedGitArgs("-C", src, "symbolic-ref", "--quiet", "HEAD")); err == nil {
		name := strings.TrimPrefix(strings.TrimSpace(string(out)), "refs/heads/")
		if ValidateRef(name) == nil {
			branch = name
		}
	}
	remote := ""
	if out, err := runGit(bin, home, env, linkedGitArgs("-C", src, "config", "--get", "remote.origin.url")); err == nil {
		remote = strings.TrimSpace(string(out))
	}
	if _, err := runGit(bin, home, env, linkedGitArgs(
		"clone", "--no-local", "--no-checkout", "--no-recurse-submodules", "--", src, dest,
	)); err != nil {
		return err
	}
	if _, err := runGit(bin, dest, env, linkedGitArgs("-C", dest, "checkout", "--detach", revision)); err != nil {
		return err
	}
	url, token := cleanOrigin(remote)
	return Sanitize(dest, url, branch, token)
}

func linkedGitArgs(args ...string) []string {
	prefix := []string{
		"-c", "core.hooksPath=/dev/null",
		"-c", "core.fsmonitor=",
		"-c", "credential.helper=",
		"-c", "protocol.ext.allow=never",
		"-c", "init.templateDir=",
	}
	return append(prefix, args...)
}
