package protocol

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type vectorFile struct {
	Frames []struct {
		Name string `json:"name"`
		Hex  string `json:"hex"`
	} `json:"frames"`
}

func loadVectors(t *testing.T) map[string][]byte {
	t.Helper()
	path := filepath.Join("..", "..", "..", "testdata", "protocol-vectors.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var file vectorFile
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	out := map[string][]byte{}
	for _, f := range file.Frames {
		b, err := hex.DecodeString(f.Hex)
		if err != nil {
			t.Fatal(err)
		}
		out[f.Name] = b
	}
	return out
}

func TestGoldenVectors(t *testing.T) {
	vectors := loadVectors(t)
	cases := []struct {
		name string
		msg  Message
	}{
		{"hello", Message{Type: TypeHello, Version: Version, Agent: AgentHello}},
		{"exec-uname", Message{Type: TypeExec, ID: 7, TimeoutMS: 5000, Argv: []string{"uname", "-a"}}},
		{"exec-shell", Message{Type: TypeExec, ID: 9, Argv: []string{"sh", "-c", "echo hello"}, Env: []string{"FOO=bar"}, Cwd: "/tmp"}},
		{"exec-tty", Message{Type: TypeExecTTY, ID: 7, TimeoutMS: 5000, Rows: 24, Cols: 80, Argv: []string{"sh"}, Env: []string{"TERM=xterm"}, Cwd: "/workspace"}},
		{"stdin-eof", Message{Type: TypeStdinEOF, ID: 7}},
		{"stdin-binary", Message{Type: TypeStdin, ID: 7, Data: []byte{0, 255, 10}}},
		{"kill", Message{Type: TypeKill, ID: 7}},
		{"signal-int", Message{Type: TypeSignal, ID: 7, Signal: 2}},
		{"resize", Message{Type: TypeResize, ID: 7, Rows: 40, Cols: 120}},
		{"shutdown", Message{Type: TypeShutdown}},
		{"started", Message{Type: TypeStarted, ID: 7}},
		{"stdout-hello", Message{Type: TypeStdout, ID: 7, Data: []byte("hello\n")}},
		{"stderr-warn", Message{Type: TypeStderr, ID: 7, Data: []byte("warn")}},
		{"exit-ok", Message{Type: TypeExit, ID: 7}},
		{"exit-signal", Message{Type: TypeExit, ID: 3, ExitCode: -1, ExitSignal: 9}},
		{"error-boom", Message{Type: TypeError, ID: 7, Error: "boom"}},
	}
	if len(cases) != len(vectors) {
		t.Fatalf("cases %d vectors %d", len(cases), len(vectors))
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			want, ok := vectors[tc.name]
			if !ok {
				t.Fatal("missing vector")
			}
			var buf bytes.Buffer
			if err := WriteFrame(&buf, tc.msg); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(buf.Bytes(), want) {
				t.Fatalf("encode\n got %x\nwant %x", buf.Bytes(), want)
			}
			got, err := ReadFrame(bytes.NewReader(want))
			if err != nil {
				t.Fatal(err)
			}
			if got.Type != tc.msg.Type || got.ID != tc.msg.ID || got.Agent != tc.msg.Agent || got.Cwd != tc.msg.Cwd || got.Error != tc.msg.Error {
				t.Fatalf("decode mismatch %+v vs %+v", got, tc.msg)
			}
			if !bytes.Equal(got.Data, tc.msg.Data) || got.ExitCode != tc.msg.ExitCode || got.ExitSignal != tc.msg.ExitSignal ||
				got.Rows != tc.msg.Rows || got.Cols != tc.msg.Cols || got.TimeoutMS != tc.msg.TimeoutMS {
				t.Fatalf("payload mismatch %+v", got)
			}
		})
	}
}

func TestRejects(t *testing.T) {
	if _, err := Encode(Message{Type: TypeExec}); err == nil {
		t.Fatal("expected empty argv error")
	}
	if _, err := Encode(Message{Type: TypeExec, Argv: []string{"ok"}, Env: []string{"NOEQUALS"}}); err == nil {
		t.Fatal("expected bad env")
	}
	if _, err := Decode([]byte{0x99}); err == nil {
		t.Fatal("expected unknown type")
	}
	// An EXEC_TTY body without the size is malformed, not a plain exec.
	if _, err := Decode([]byte{TypeExecTTY, 0, 0, 0, 7, 0, 0, 0, 0, 0, 1}); err == nil {
		t.Fatal("expected short exec-tty")
	}
	if !AdvertisesTerminal(AgentHello) || AdvertisesTerminal("dynocap-agent signal=1") || AdvertisesTerminal("dynocap-agent tty=10") {
		t.Fatal("terminal capability token is not exact")
	}
	// Length prefix claims more than the cap.
	var huge [4]byte
	huge[0] = 0x01
	if _, err := ReadFrame(bytes.NewReader(huge[:])); err == nil {
		t.Fatal("expected frame size error")
	}
}
