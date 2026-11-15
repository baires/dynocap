package workspace

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// This fixture runs the real OpenSSH client against a loopback SSH endpoint.
// It needs no login account, ssh-agent, sshd installation, or production key.
func TestPrivateSSHFetchAuthenticatesAndCleansCredentials(t *testing.T) {
	if _, err := exec.LookPath("ssh"); err != nil {
		t.Fatal("prepared runtime must contain the OpenSSH client")
	}
	repo := bareRepo(t)
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	block, err := ssh.MarshalPrivateKey(private, "dynocap-fixture")
	if err != nil {
		t.Fatal(err)
	}
	material := pem.EncodeToMemory(block)
	config := &ssh.ServerConfig{PublicKeyCallback: func(meta ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
		if meta.User() == "git" && bytes.Equal(key.Marshal(), signer.PublicKey().Marshal()) {
			return nil, nil
		}
		return nil, fmt.Errorf("test identity rejected")
	}}
	config.AddHostKey(signer)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			workers.Add(1)
			go func() { defer workers.Done(); serveSSHFixture(conn, config, repo) }()
		}
	}()
	defer func() { listener.Close(); <-stopped; workers.Wait() }()
	keyArg := func(key []byte) string {
		if runtime.GOOS == "linux" {
			return string(key)
		}
		p := filepath.Join(t.TempDir(), "key")
		if err := os.WriteFile(p, key, 0600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	url := "ssh://git@" + listener.Addr().String() + "/repo.git"
	dest := filepath.Join(t.TempDir(), "checkout")
	_, wrong, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	wrongPEM, err := ssh.MarshalPrivateKey(wrong, "wrong-test-key")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := fetchObserved(dest, url, "main", "", keyArg(pem.EncodeToMemory(wrongPEM)), fetchOptions{}); err == nil {
		t.Fatal("wrong key authenticated")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("failed SSH auth left a workspace")
	}
	revision, console, err := fetchObserved(dest, url, "main", "", keyArg(material), fetchOptions{})
	if err != nil {
		t.Fatalf("real SSH fetch: %v", err)
	}
	if !commitPattern.MatchString(revision) {
		t.Fatal(revision)
	}
	assertTokenAbsent(t, dest, console, string(material))
	assertObjectsLack(t, dest, string(material))
	configBytes, err := os.ReadFile(filepath.Join(dest, ".git/config"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(configBytes, []byte("DYNOCAP_SSH_KEY")) || bytes.Contains(configBytes, material) {
		t.Fatal("identity persisted in Git configuration")
	}
	if got, err := os.ReadFile(filepath.Join(dest, "README")); err != nil || string(got) != "hello\n" {
		t.Fatalf("checkout: %q %v", got, err)
	}
}

func serveSSHFixture(raw net.Conn, config *ssh.ServerConfig, repo string) {
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(15 * time.Second))
	conn, channels, requests, err := ssh.NewServerConn(raw, config)
	if err != nil {
		return
	}
	defer conn.Close()
	go ssh.DiscardRequests(requests)
	for incoming := range channels {
		if incoming.ChannelType() != "session" {
			incoming.Reject(ssh.UnknownChannelType, "sessions only")
			continue
		}
		channel, requests, err := incoming.Accept()
		if err != nil {
			return
		}
		for request := range requests {
			var command struct{ Command string }
			if request.Type != "exec" || ssh.Unmarshal(request.Payload, &command) != nil || !strings.HasPrefix(command.Command, "git-upload-pack ") {
				_ = request.Reply(false, nil)
				continue
			}
			_ = request.Reply(true, nil)
			bin, err := hostGit()
			code := uint32(1)
			if err == nil {
				process := exec.Command(bin, "upload-pack", repo)
				process.Env = []string{"PATH=" + os.Getenv("PATH"), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
				process.Stdout = channel
				process.Stderr = channel.Stderr()
				pipe, err := process.StdinPipe()
				if err == nil && process.Start() == nil {
					go func() { _, _ = io.Copy(pipe, channel); _ = pipe.Close() }()
					if process.Wait() == nil {
						code = 0
					}
				}
			}
			_, _ = channel.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{code}))
			channel.Close()
			break
		}
	}
}
