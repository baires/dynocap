package workspace

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

type Change struct {
	Path    string `json:"path"`
	Kind    string `json:"kind"`
	From    string `json:"from,omitempty"`
	Before  string `json:"beforeSha256,omitempty"`
	After   string `json:"afterSha256,omitempty"`
	Mode    uint32 `json:"mode"`
	Symlink string `json:"symlink,omitempty"`
}

func identity(root, n string) (string, os.FileMode, string, error) {
	p := filepath.Join(root, n)
	st, e := os.Lstat(p)
	if os.IsNotExist(e) {
		return "", 0, "", nil
	}
	if e != nil {
		return "", 0, "", e
	}
	if st.Mode()&os.ModeSymlink != 0 {
		link, e := os.Readlink(p)
		return "link:" + link, st.Mode(), link, e
	}
	sum, e := SHA(p)
	return sum, st.Mode(), "", e
}
func Result(before, after, out string) error {
	a, e := Names(before, false)
	if e != nil {
		return e
	}
	b, e := Names(after, false)
	if e != nil {
		return e
	}
	existing := map[string]bool{}
	for _, n := range a {
		existing[n] = true
	}
	var added []string
	for _, n := range b {
		if !existing[n] {
			added = append(added, n)
		}
	}
	ignored, e := ignoredNewFiles(before, added)
	if e != nil {
		return e
	}
	patch, renamedTo, e := reviewPatch(before, after, ignored)
	if e != nil {
		return e
	}
	replaced := map[string]bool{}
	for _, old := range renamedTo {
		replaced[old] = true
	}
	set := map[string]bool{}
	for _, n := range append(a, b...) {
		set[n] = true
	}
	var names []string
	for n := range set {
		names = append(names, n)
	}
	sort.Strings(names)
	if e = os.MkdirAll(filepath.Join(out, "files"), 0700); e != nil {
		return e
	}
	changes := []Change{}
	var review bytes.Buffer
	for _, n := range names {
		if ignored[n] || replaced[n] {
			continue
		}
		source := n
		from := ""
		if old, ok := renamedTo[n]; ok {
			source = old
			from = old
		}
		x, xm, _, e := identity(before, source)
		if e != nil {
			return e
		}
		y, ym, link, e := identity(after, n)
		if e != nil {
			return e
		}
		if from == "" && x == y && xm == ym {
			continue
		}
		kind := "modified"
		if from != "" {
			kind = "renamed"
		} else if x == "" {
			kind = "added"
		} else if y == "" {
			kind = "deleted"
		}
		changes = append(changes, Change{
			Path: n, Kind: kind, From: from, Before: x, After: y, Mode: uint32(ym.Perm()), Symlink: link,
		})
		if from != "" {
			fmt.Fprintf(&review, "renamed %s -> %s (mode %04o -> %04o)\n", from, n, xm.Perm(), ym.Perm())
		} else {
			fmt.Fprintf(&review, "%s %s (mode %04o -> %04o)\n", kind, n, xm.Perm(), ym.Perm())
		}
		if y != "" {
			dest := filepath.Join(out, "files", n)
			if e = os.MkdirAll(filepath.Dir(dest), 0700); e != nil {
				return e
			}
			if link != "" {
				if !safeLink(n, link) {
					return fmt.Errorf("unsafe result link")
				}
				e = os.Symlink(link, dest)
			} else {
				var data []byte
				data, e = os.ReadFile(filepath.Join(after, n))
				if e == nil {
					e = os.WriteFile(dest, data, ym.Perm())
				}
			}
			if e != nil {
				return e
			}
		}
		if xm&os.ModeSymlink != 0 || ym&os.ModeSymlink != 0 {
			fmt.Fprintf(&review, "symlink: %s -> %s\n\n", x, y)
			continue
		}
		old, _ := os.ReadFile(filepath.Join(before, source))
		next, _ := os.ReadFile(filepath.Join(after, n))
		if bytes.ContainsRune(old, 0) || bytes.ContainsRune(next, 0) || !utf8.Valid(old) || !utf8.Valid(next) {
			if from == "" || !bytes.Equal(old, next) {
				review.WriteString("Binary contents changed; see files/.\n\n")
			} else {
				review.WriteByte('\n')
			}
			continue
		}
		review.WriteString(unifiedDiff(n, old, next))
		review.WriteByte('\n')
		if review.Len() > int(Limit) {
			return fmt.Errorf("review exceeds limit")
		}
	}
	raw, e := json.MarshalIndent(changes, "", "  ")
	if e != nil {
		return e
	}
	if e = os.WriteFile(filepath.Join(out, "changes.json"), raw, 0600); e != nil {
		return e
	}
	if e = os.WriteFile(filepath.Join(out, "review.txt"), review.Bytes(), 0600); e != nil {
		return e
	}
	return os.WriteFile(filepath.Join(out, "changes.patch"), patch, 0600)
}

// New files obey the imported .gitignore files. The temporary Git directory has
// no project history, configuration, or hooks.
func ignoredNewFiles(baseline string, names []string) (map[string]bool, error) {
	if len(names) == 0 {
		return map[string]bool{}, nil
	}
	session, err := openIgnoreSession(baseline)
	if err != nil {
		return nil, err
	}
	defer session.close()
	return session.ignored(names)
}

type ignoreSession struct {
	root    string
	scratch string
	env     []string
	git     string
}

func openIgnoreSession(root string) (*ignoreSession, error) {
	scratch, err := os.MkdirTemp("", "microvm-ignore-")
	if err != nil {
		return nil, err
	}
	bin, err := hostGit()
	if err != nil {
		os.RemoveAll(scratch)
		return nil, err
	}
	env := []string{
		"PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
		"HOME=" + scratch,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
	}
	init := exec.Command(bin, "-c", "core.hooksPath=/dev/null", "-c", "safe.directory=*", "init", "--quiet", scratch)
	init.Env = env
	if out, err := init.CombinedOutput(); err != nil {
		os.RemoveAll(scratch)
		return nil, fmt.Errorf("init ignore evaluator: %s: %w", out, err)
	}
	return &ignoreSession{root: root, scratch: scratch, env: env, git: bin}, nil
}

func (s *ignoreSession) close() { os.RemoveAll(s.scratch) }

func (s *ignoreSession) ignored(names []string) (map[string]bool, error) {
	ignored := map[string]bool{}
	if len(names) == 0 {
		return ignored, nil
	}
	gitDir := filepath.Join(s.scratch, ".git")
	cmd := exec.Command(
		s.git, "--git-dir="+gitDir, "--work-tree="+s.root,
		"-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "safe.directory=*",
		"check-ignore", "--no-index", "-z", "--stdin",
	)
	cmd.Env = append(append([]string{}, s.env...), "GIT_DIR="+gitDir)
	cmd.Dir = s.root
	cmd.Stdin = strings.NewReader(strings.Join(names, "\x00") + "\x00")
	out, err := cmd.Output()
	if err != nil {
		if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 1 {
			return nil, err
		}
	}
	for _, n := range strings.Split(string(out), "\x00") {
		if n != "" {
			ignored[n] = true
		}
	}
	return ignored, nil
}

type diffRow struct {
	op      byte
	text    string
	lastOld bool
	lastNew bool
}

func splitLines(b []byte) []string {
	if len(b) == 0 {
		return nil
	}
	parts := strings.Split(string(b), "\n")
	if parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

func endsWithNewline(b []byte) bool {
	return len(b) == 0 || b[len(b)-1] == '\n'
}

func unifiedDiff(name string, oldb, newb []byte) string {
	rows := diffRows(splitLines(oldb), splitLines(newb))
	rows = showNewlineChange(rows, endsWithNewline(oldb), endsWithNewline(newb))
	body := formatHunks(rows, 3, endsWithNewline(oldb), endsWithNewline(newb))
	if body == "" {
		return ""
	}
	return fmt.Sprintf("--- a/%s\n+++ b/%s\n%s", name, name, body)
}

func showNewlineChange(rows []diffRow, oldNL, newNL bool) []diffRow {
	if oldNL == newNL || len(rows) == 0 {
		return rows
	}
	for _, row := range rows {
		if row.op != ' ' {
			return rows
		}
	}
	last := rows[len(rows)-1]
	rows[len(rows)-1] = diffRow{op: '-', text: last.text, lastOld: true}
	return append(rows, diffRow{op: '+', text: last.text, lastNew: true})
}

func diffRows(a, b []string) []diffRow {
	n, m := len(a), len(b)
	v := map[int]int{1: 0}
	var trace []map[int]int
	for d := 0; d <= n+m; d++ {
		snapshot := make(map[int]int, len(v))
		for k, x := range v {
			snapshot[k] = x
		}
		trace = append(trace, snapshot)
		for k := -d; k <= d; k += 2 {
			var x int
			if k == -d || (k != d && v[k-1] < v[k+1]) {
				x = v[k+1]
			} else {
				x = v[k-1] + 1
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[k] = x
			if x >= n && y >= m {
				return backtrack(trace, a, b)
			}
		}
	}
	return nil
}

func backtrack(trace []map[int]int, a, b []string) []diffRow {
	x, y := len(a), len(b)
	reversed := make([]diffRow, 0, x+y)
	for d := len(trace) - 1; d >= 0; d-- {
		frontier := trace[d]
		k := x - y
		var prevK int
		if k == -d || (k != d && frontier[k-1] < frontier[k+1]) {
			prevK = k + 1
		} else {
			prevK = k - 1
		}
		prevX := frontier[prevK]
		prevY := prevX - prevK
		for x > prevX && y > prevY {
			reversed = append(reversed, diffRow{op: ' ', text: a[x-1]})
			x--
			y--
		}
		if d > 0 {
			if x == prevX {
				reversed = append(reversed, diffRow{op: '+', text: b[y-1]})
				y--
			} else {
				reversed = append(reversed, diffRow{op: '-', text: a[x-1]})
				x--
			}
		}
	}
	rows := make([]diffRow, len(reversed))
	for i := range reversed {
		rows[i] = reversed[len(reversed)-1-i]
	}
	for i := len(rows) - 1; i >= 0; i-- {
		if rows[i].op != '+' {
			rows[i].lastOld = true
			break
		}
	}
	for i := len(rows) - 1; i >= 0; i-- {
		if rows[i].op != '-' {
			rows[i].lastNew = true
			break
		}
	}
	return rows
}

func formatHunks(rows []diffRow, context int, oldNL, newNL bool) string {
	var changed []int
	for i, row := range rows {
		if row.op != ' ' {
			changed = append(changed, i)
		}
	}
	if len(changed) == 0 {
		return ""
	}
	type span struct{ lo, hi int }
	var spans []span
	for _, i := range changed {
		lo, hi := i-context, i+context+1
		if lo < 0 {
			lo = 0
		}
		if hi > len(rows) {
			hi = len(rows)
		}
		if len(spans) > 0 && lo <= spans[len(spans)-1].hi {
			spans[len(spans)-1].hi = hi
			continue
		}
		spans = append(spans, span{lo, hi})
	}
	var b strings.Builder
	for _, sp := range spans {
		oldStart, newStart := 1, 1
		for i := 0; i < sp.lo; i++ {
			if rows[i].op != '+' {
				oldStart++
			}
			if rows[i].op != '-' {
				newStart++
			}
		}
		oldCount, newCount := 0, 0
		for i := sp.lo; i < sp.hi; i++ {
			if rows[i].op != '+' {
				oldCount++
			}
			if rows[i].op != '-' {
				newCount++
			}
		}
		if oldCount == 0 {
			oldStart = 0
		}
		if newCount == 0 {
			newStart = 0
		}
		fmt.Fprintf(&b, "@@ -%d,%d +%d,%d @@\n", oldStart, oldCount, newStart, newCount)
		for i := sp.lo; i < sp.hi; i++ {
			row := rows[i]
			fmt.Fprintf(&b, "%c%s\n", row.op, row.text)
			if (row.lastOld && !oldNL) || (row.lastNew && !newNL) {
				b.WriteString("\\ No newline at end of file\n")
			}
		}
	}
	return b.String()
}

// hostGit is the trusted host binary. A git executable on the writable
// workspace PATH is never selected.
func hostGit() (string, error) {
	for _, candidate := range []string{"/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"} {
		info, err := os.Stat(candidate)
		if err != nil || info.IsDir() || info.Mode()&0111 == 0 {
			continue
		}
		return candidate, nil
	}
	return "", fmt.Errorf("host git not found")
}

func gitEnv(home string) []string {
	return []string{
		"PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
		"HOME=" + home,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_TERMINAL_PROMPT=0",
		"GIT_AUTHOR_NAME=MicroVM",
		"GIT_AUTHOR_EMAIL=microvm@localhost",
		"GIT_AUTHOR_DATE=1970-01-01T00:00:00Z",
		"GIT_COMMITTER_NAME=MicroVM",
		"GIT_COMMITTER_EMAIL=microvm@localhost",
		"GIT_COMMITTER_DATE=1970-01-01T00:00:00Z",
	}
}

func runGit(bin, dir string, env, args []string) ([]byte, error) {
	cmd := exec.Command(bin, args...)
	cmd.Dir = dir
	cmd.Env = env
	out, err := cmd.Output()
	if err != nil {
		detail := ""
		if exit, ok := err.(*exec.ExitError); ok {
			detail = string(exit.Stderr)
		}
		return nil, fmt.Errorf("git %s: %s: %w", strings.Join(args, " "), detail, err)
	}
	return out, nil
}

func gitArgs(repo string, args ...string) []string {
	prefix := []string{"-C", repo, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=", "-c", "core.filemode=true", "-c", "commit.gpgsign=false"}
	return append(prefix, args...)
}

// reviewPatch diffs the saved baseline and the exported tree with host Git.
// Rename detection uses the exported paths. The writable workspace is not on PATH.
func reviewPatch(before, after string, ignored map[string]bool) ([]byte, map[string]string, error) {
	bin, err := hostGit()
	if err != nil {
		return nil, nil, err
	}
	root, err := os.MkdirTemp("", "microvm-review-")
	if err != nil {
		return nil, nil, err
	}
	defer os.RemoveAll(root)
	home := filepath.Join(root, "home")
	repo := filepath.Join(root, "repo")
	if err := os.MkdirAll(home, 0700); err != nil {
		return nil, nil, err
	}
	env := gitEnv(home)
	if _, err := runGit(bin, root, env, []string{"init", "-q", "-b", "main", repo}); err != nil {
		return nil, nil, err
	}
	if err := copyWorktree(before, repo); err != nil {
		return nil, nil, err
	}
	if _, err := runGit(bin, repo, env, gitArgs(repo, "add", "-A", "--force")); err != nil {
		return nil, nil, err
	}
	if _, err := runGit(bin, repo, env, gitArgs(repo, "commit", "--quiet", "--allow-empty", "-m", "baseline")); err != nil {
		return nil, nil, err
	}
	if err := clearWorktree(repo); err != nil {
		return nil, nil, err
	}
	if err := copyWorktreeExcept(after, repo, ignored); err != nil {
		return nil, nil, err
	}
	if _, err := runGit(bin, repo, env, gitArgs(repo, "add", "--all", "--force")); err != nil {
		return nil, nil, err
	}
	patch, err := runGit(bin, repo, env, gitArgs(repo, "diff", "--cached", "--binary", "--find-renames", "--no-color", "HEAD"))
	if err != nil {
		return nil, nil, err
	}
	if len(patch) > int(Limit) {
		return nil, nil, fmt.Errorf("review exceeds limit")
	}
	status, err := runGit(bin, repo, env, gitArgs(repo, "diff", "--cached", "--name-status", "--find-renames", "-z", "HEAD"))
	if err != nil {
		return nil, nil, err
	}
	return patch, parseRenames(status), nil
}

func parseRenames(status []byte) map[string]string {
	renames := map[string]string{}
	parts := strings.Split(string(status), "\x00")
	for i := 0; i < len(parts); {
		if parts[i] == "" {
			i++
			continue
		}
		kind := parts[i]
		i++
		if i >= len(parts) {
			break
		}
		if strings.HasPrefix(kind, "R") || strings.HasPrefix(kind, "C") {
			old := parts[i]
			i++
			if i >= len(parts) {
				break
			}
			next := parts[i]
			i++
			if strings.HasPrefix(kind, "R") && safeName(old) && safeName(next) {
				renames[next] = old
			}
			continue
		}
		i++
	}
	return renames
}

func copyWorktree(src, dst string) error { return copyWorktreeExcept(src, dst, nil) }

func copyWorktreeExcept(src, dst string, ignored map[string]bool) error {
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
		if ignored[filepath.ToSlash(rel)] {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if rel == ".git" || strings.HasPrefix(rel, ".git"+string(os.PathSeparator)) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.Mode()&os.ModeSymlink != 0 {
			link, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		}
		if d.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("unsupported file %s", filepath.ToSlash(rel))
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode().Perm())
	})
}

func clearWorktree(root string) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() == ".git" {
			continue
		}
		if err := os.RemoveAll(filepath.Join(root, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}
