package workspace

import (
	"bytes"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestPrivateHTTPSFetchSendsBearerAndLeavesNoToken(t *testing.T) {
	token := "dynocap-private-fetch-token-9f3c1e7a"
	repo := bareRepo(t)
	console := ""
	var gotAuth []string
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		gotAuth = append(gotAuth, auth)
		if auth != "Bearer "+token {
			w.Header().Set("WWW-Authenticate", "Bearer")
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		serveGitBackend(w, r, filepath.Dir(repo))
	}))
	defer srv.Close()
	ca := writeCertPEM(t, srv.Certificate())
	url := srv.URL + "/repo.git"

	dest := filepath.Join(t.TempDir(), "guest")
	wrongToken := "dynocap-wrong-bearer-token-0000aaaa"
	_, wrongConsole, err := fetchObserved(dest, url, "main", wrongToken, "", fetchOptions{caFile: ca})
	if err == nil {
		t.Fatal("wrong token cloned")
	}
	if _, statErr := os.Stat(dest); !os.IsNotExist(statErr) {
		t.Fatal("failed auth left a checkout")
	}
	if strings.Contains(wrongConsole, token) || strings.Contains(err.Error(), token) || strings.Contains(wrongConsole, wrongToken) || strings.Contains(err.Error(), wrongToken) {
		t.Fatal("failed auth kept a token in the console or error")
	}

	revision, console, err := fetchObserved(dest, url, "main", token, "", fetchOptions{caFile: ca})
	if err != nil {
		t.Fatal(err, console)
	}
	if !commitPattern.MatchString(revision) {
		t.Fatal(revision)
	}
	if len(gotAuth) == 0 || gotAuth[len(gotAuth)-1] != "Bearer "+token {
		t.Fatalf("fetch did not send the bearer token, saw %d requests", len(gotAuth))
	}
	assertTokenAbsent(t, dest, console, token)
	assertObjectsLack(t, dest, token)
	var published bytes.Buffer
	if err := Pack(dest, &published, true, Limit); err != nil {
		t.Fatal(err)
	}
	var history bytes.Buffer
	if err := PackGit(dest, &history, Limit); err != nil {
		t.Fatal(err)
	}
	journal := strings.Join(cloneArgs(url, dest, "main", false), "\n") + "\n" + console
	for _, label := range []struct {
		name string
		data []byte
	}{
		{"published result", published.Bytes()},
		{"history archive", history.Bytes()},
		{"journal", []byte(journal)},
	} {
		if bytes.Contains(label.data, []byte(token)) {
			t.Fatalf("token present in %s", label.name)
		}
	}
	config, err := os.ReadFile(filepath.Join(dest, ".git", "config"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(config, []byte(token)) || bytes.Contains(config, []byte("credential")) || !bytes.Contains(config, []byte("hooksPath = /dev/null")) || !bytes.Contains(config, []byte(url)) {
		t.Fatalf("config:\n%s", config)
	}
	if _, err := os.Stat(filepath.Join(dest, ".git", "hooks")); !os.IsNotExist(err) {
		t.Fatal("hooks directory remains")
	}
}

func assertObjectsLack(t *testing.T, root, token string) {
	t.Helper()
	// A hook exports GIT_DIR for this repository. Inspect the checkout, not that repo.
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir()}
	listCmd := exec.Command("git", "-C", root, "rev-list", "--objects", "--all")
	listCmd.Env = env
	list, err := listCmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	var ids strings.Builder
	for _, line := range strings.Split(string(list), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		ids.WriteString(fields[0])
		ids.WriteByte('\n')
	}
	batch := exec.Command("git", "-C", root, "cat-file", "--batch")
	batch.Env = env
	batch.Stdin = strings.NewReader(ids.String())
	out, err := batch.Output()
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(out, []byte(token)) {
		t.Fatal("token present in a git object")
	}
}

func assertTokenAbsent(t *testing.T, root, console, token string) {
	t.Helper()
	if strings.Contains(console, token) {
		t.Fatal("token present in console")
	}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !d.Type().IsRegular() {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if bytes.Contains(data, []byte(token)) {
			rel, _ := filepath.Rel(root, path)
			t.Fatalf("token present in guest tree %s", rel)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func bareRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	work := filepath.Join(root, "work")
	bare := filepath.Join(root, "repo.git")
	must(t, os.MkdirAll(work, 0755))
	gitCmd(t, work, "init", "-b", "main")
	must(t, os.WriteFile(filepath.Join(work, "README"), []byte("hello\n"), 0644))
	gitCmd(t, work, "add", "README")
	gitCmd(t, work, "commit", "-m", "initial")
	gitCmd(t, work, "clone", "--bare", work, bare)
	return bare
}

func writeCertPEM(t *testing.T, cert *x509.Certificate) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ca.pem")
	raw := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw})
	must(t, os.WriteFile(path, raw, 0600))
	return path
}

func serveGitBackend(w http.ResponseWriter, r *http.Request, project string) {
	execPath, err := exec.Command("git", "--exec-path").Output()
	if err != nil {
		http.Error(w, "git exec-path", http.StatusBadGateway)
		return
	}
	backend := filepath.Join(strings.TrimSpace(string(execPath)), "git-http-backend")
	cmd := exec.Command(backend)
	cmd.Env = []string{
		"GIT_PROJECT_ROOT=" + project,
		"GIT_HTTP_EXPORT_ALL=1",
		"PATH_INFO=" + r.URL.Path,
		"QUERY_STRING=" + r.URL.RawQuery,
		"REQUEST_METHOD=" + r.Method,
		"CONTENT_TYPE=" + r.Header.Get("Content-Type"),
		"REMOTE_ADDR=127.0.0.1",
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + project,
	}
	if r.ContentLength >= 0 {
		cmd.Env = append(cmd.Env, "CONTENT_LENGTH="+strconv.FormatInt(r.ContentLength, 10))
	}
	cmd.Stdin = r.Body
	out, err := cmd.Output()
	if err != nil {
		http.Error(w, "git backend failed", http.StatusBadGateway)
		return
	}
	writeCGI(w, out)
}

func writeCGI(w http.ResponseWriter, raw []byte) {
	sep := bytes.Index(raw, []byte("\r\n\r\n"))
	width := 4
	if sep < 0 {
		sep = bytes.Index(raw, []byte("\n\n"))
		width = 2
	}
	if sep < 0 {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(raw)
		return
	}
	status := http.StatusOK
	for _, line := range bytes.Split(raw[:sep], []byte("\n")) {
		line = bytes.TrimSuffix(line, []byte("\r"))
		key, value, ok := bytes.Cut(line, []byte(":"))
		if !ok {
			continue
		}
		name := string(key)
		text := strings.TrimSpace(string(value))
		if strings.EqualFold(name, "Status") {
			if n, ok := leadingInt(text); ok {
				status = n
			}
			continue
		}
		w.Header().Add(name, text)
	}
	w.WriteHeader(status)
	_, _ = w.Write(raw[sep+width:])
}

func leadingInt(text string) (int, bool) {
	n := 0
	i := 0
	for i < len(text) && text[i] >= '0' && text[i] <= '9' {
		n = n*10 + int(text[i]-'0')
		i++
	}
	return n, i > 0
}

func TestPublicAndCredentialedFetchShareRefSemantics(t *testing.T) {
	repo := bareRepo(t)
	gitCmd(t, repo, "branch", "feature/café", "main")
	gitCmd(t, repo, "tag", "release", "main")
	revision := gitOutputIn(t, repo, "rev-parse", "main")
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveGitBackend(w, r, filepath.Dir(repo))
	}))
	defer srv.Close()
	ca := writeCertPEM(t, srv.Certificate())
	for _, ref := range []string{"", "main", "feature/café", "release", strings.ToUpper(revision)} {
		for _, token := range []string{"", "fixture-token"} {
			dest := filepath.Join(t.TempDir(), "checkout")
			got, console, err := fetchObserved(dest, srv.URL+"/repo.git", ref, token, "", fetchOptions{caFile: ca})
			if err != nil {
				t.Fatalf("ref %q authenticated=%v: %v %s", ref, token != "", err, console)
			}
			if got != revision {
				t.Fatalf("revision %s != %s", got, revision)
			}
			head, err := os.ReadFile(filepath.Join(dest, ".git", "HEAD"))
			if err != nil || strings.TrimSpace(string(head)) != revision {
				t.Fatalf("not detached: %s %v", head, err)
			}
			if _, err := os.Stat(filepath.Join(dest, ".git", "hooks")); !os.IsNotExist(err) {
				t.Fatal("hooks remain")
			}
			assertTokenAbsent(t, dest, console, "fixture-token")
		}
	}
}
