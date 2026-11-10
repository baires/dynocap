package workspace

import (
	"bytes"
	"encoding/json"
	"fmt"
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
		if ignored[n] {
			continue
		}
		x, xm, _, e := identity(before, n)
		if e != nil {
			return e
		}
		y, ym, link, e := identity(after, n)
		if e != nil {
			return e
		}
		if x == y && xm == ym {
			continue
		}
		kind := "modified"
		if x == "" {
			kind = "added"
		}
		if y == "" {
			kind = "deleted"
		}
		changes = append(changes, Change{n, kind, x, y, uint32(ym.Perm()), link})
		fmt.Fprintf(&review, "%s %s (mode %04o -> %04o)\n", kind, n, xm.Perm(), ym.Perm())
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
		old, _ := os.ReadFile(filepath.Join(before, n))
		next, _ := os.ReadFile(filepath.Join(after, n))
		if bytes.ContainsRune(old, 0) || bytes.ContainsRune(next, 0) || !utf8.Valid(old) || !utf8.Valid(next) {
			review.WriteString("Binary contents changed; see files/.\n\n")
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
	return os.WriteFile(filepath.Join(out, "review.txt"), review.Bytes(), 0600)
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
}

func openIgnoreSession(root string) (*ignoreSession, error) {
	scratch, err := os.MkdirTemp("", "microvm-ignore-")
	if err != nil {
		return nil, err
	}
	env := []string{
		"PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
		"HOME=" + scratch,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
	}
	init := exec.Command("git", "-c", "core.hooksPath=/dev/null", "-c", "safe.directory=*", "init", "--quiet", scratch)
	init.Env = env
	if out, err := init.CombinedOutput(); err != nil {
		os.RemoveAll(scratch)
		return nil, fmt.Errorf("init ignore evaluator: %s: %w", out, err)
	}
	return &ignoreSession{root: root, scratch: scratch, env: env}, nil
}

func (s *ignoreSession) close() { os.RemoveAll(s.scratch) }

func (s *ignoreSession) ignored(names []string) (map[string]bool, error) {
	ignored := map[string]bool{}
	if len(names) == 0 {
		return ignored, nil
	}
	gitDir := filepath.Join(s.scratch, ".git")
	cmd := exec.Command(
		"git", "--git-dir="+gitDir, "--work-tree="+s.root,
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
