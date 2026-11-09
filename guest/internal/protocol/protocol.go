// Package protocol is the host/guest exec stream used over vsock.
//
// Frames are big-endian:
//
//	u32 length              // bytes after this field
//	u8  type
//	payload                 // length-1 bytes
//
// Version 1 types:
//
//	0x01 HELLO      guest -> host   u32 version, u16+utf8 agent
//	0x02 EXEC       host -> guest   u32 id, u32 timeout_ms, argv, env, cwd
//	0x03 STDIN      host -> guest   u32 id, u32+bytes
//	0x04 STDIN_EOF  host -> guest   u32 id
//	0x05 KILL       host -> guest   u32 id
//	0x06 SHUTDOWN   host -> guest   empty
//	0x10 STARTED    guest -> host   u32 id
//	0x11 STDOUT     guest -> host   u32 id, u32+bytes
//	0x12 STDERR     guest -> host   u32 id, u32+bytes
//	0x13 EXIT       guest -> host   u32 id, i32 code, i32 signal
//	0x14 ERROR      guest -> host   u32 id, u16+utf8 message
//
// argv, env, and cwd are repeated u16+utf8 strings. env entries are KEY=VAL.
// timeout_ms 0 means the guest applies no timer. EXIT code is -1 when the
// process dies on a signal; a timeout is reported as code 124 and signal 0.
package protocol

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"
)

const (
	Version uint32 = 1
	// Port is the guest vsock port the agent listens on. The host connects
	// with VZVirtioSocketDevice.connect(toPort:).
	Port uint32 = 5252

	maxFrame   = 1 << 20
	maxString  = 32 << 10
	maxArgs    = 256
	maxEnv     = 256
	maxPayload = 256 << 10
)

const (
	TypeHello    uint8 = 0x01
	TypeExec     uint8 = 0x02
	TypeStdin    uint8 = 0x03
	TypeStdinEOF uint8 = 0x04
	TypeKill     uint8 = 0x05
	TypeShutdown uint8 = 0x06
	TypeStarted  uint8 = 0x10
	TypeStdout   uint8 = 0x11
	TypeStderr   uint8 = 0x12
	TypeExit     uint8 = 0x13
	TypeError    uint8 = 0x14
)

var (
	ErrShort     = errors.New("short frame")
	ErrFrameSize = errors.New("frame exceeds limit")
	ErrType      = errors.New("unknown frame type")
	ErrUTF8      = errors.New("payload is not utf-8")
	ErrTrailing  = errors.New("trailing bytes")
	ErrTooMany   = errors.New("too many strings")
	ErrEmptyArgv = errors.New("argv is empty")
	ErrBadEnv    = errors.New("env entry must be KEY=VAL")
)

// Message is one decoded frame, not including the length prefix.
type Message struct {
	Type       uint8
	Version    uint32
	Agent      string
	ID         uint32
	TimeoutMS  uint32
	Argv       []string
	Env        []string
	Cwd        string
	Data       []byte
	ExitCode   int32
	ExitSignal int32
	Error      string
}

// ReadFrame reads one length-prefixed frame.
func ReadFrame(r io.Reader) (Message, error) {
	var lenb [4]byte
	if _, err := io.ReadFull(r, lenb[:]); err != nil {
		return Message{}, err
	}
	n := binary.BigEndian.Uint32(lenb[:])
	if n == 0 || n > maxFrame {
		return Message{}, ErrFrameSize
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return Message{}, err
	}
	return Decode(buf)
}

// WriteFrame writes one length-prefixed frame.
func WriteFrame(w io.Writer, m Message) error {
	payload, err := Encode(m)
	if err != nil {
		return err
	}
	var lenb [4]byte
	binary.BigEndian.PutUint32(lenb[:], uint32(len(payload)))
	if _, err := w.Write(lenb[:]); err != nil {
		return err
	}
	_, err = w.Write(payload)
	return err
}

// Encode returns the type byte plus payload (no length prefix).
func Encode(m Message) ([]byte, error) {
	switch m.Type {
	case TypeHello:
		if m.Version == 0 {
			return nil, errors.New("hello version is required")
		}
		body, err := encodeString(m.Agent)
		if err != nil {
			return nil, err
		}
		out := make([]byte, 0, 5+len(body))
		out = append(out, TypeHello)
		out = binary.BigEndian.AppendUint32(out, m.Version)
		out = append(out, body...)
		return out, nil
	case TypeExec:
		if len(m.Argv) == 0 || m.Argv[0] == "" {
			return nil, ErrEmptyArgv
		}
		if len(m.Argv) > maxArgs || len(m.Env) > maxEnv {
			return nil, ErrTooMany
		}
		for _, e := range m.Env {
			if !validEnv(e) {
				return nil, ErrBadEnv
			}
		}
		out := make([]byte, 0, 64)
		out = append(out, TypeExec)
		out = binary.BigEndian.AppendUint32(out, m.ID)
		out = binary.BigEndian.AppendUint32(out, m.TimeoutMS)
		var err error
		if out, err = appendStrings(out, m.Argv); err != nil {
			return nil, err
		}
		if out, err = appendStrings(out, m.Env); err != nil {
			return nil, err
		}
		cwd, err := encodeString(m.Cwd)
		if err != nil {
			return nil, err
		}
		out = append(out, cwd...)
		return out, nil
	case TypeStdin:
		if len(m.Data) > maxPayload {
			return nil, ErrFrameSize
		}
		out := make([]byte, 0, 9+len(m.Data))
		out = append(out, TypeStdin)
		out = binary.BigEndian.AppendUint32(out, m.ID)
		out = binary.BigEndian.AppendUint32(out, uint32(len(m.Data)))
		out = append(out, m.Data...)
		return out, nil
	case TypeStdinEOF:
		return idOnly(TypeStdinEOF, m.ID), nil
	case TypeKill:
		return idOnly(TypeKill, m.ID), nil
	case TypeShutdown:
		return []byte{TypeShutdown}, nil
	case TypeStarted:
		return idOnly(TypeStarted, m.ID), nil
	case TypeStdout, TypeStderr:
		if len(m.Data) > maxPayload {
			return nil, ErrFrameSize
		}
		out := make([]byte, 0, 9+len(m.Data))
		out = append(out, m.Type)
		out = binary.BigEndian.AppendUint32(out, m.ID)
		out = binary.BigEndian.AppendUint32(out, uint32(len(m.Data)))
		out = append(out, m.Data...)
		return out, nil
	case TypeExit:
		out := make([]byte, 0, 13)
		out = append(out, TypeExit)
		out = binary.BigEndian.AppendUint32(out, m.ID)
		out = binary.BigEndian.AppendUint32(out, uint32(m.ExitCode))
		out = binary.BigEndian.AppendUint32(out, uint32(m.ExitSignal))
		return out, nil
	case TypeError:
		body, err := encodeString(m.Error)
		if err != nil {
			return nil, err
		}
		out := make([]byte, 0, 5+len(body))
		out = append(out, TypeError)
		out = binary.BigEndian.AppendUint32(out, m.ID)
		out = append(out, body...)
		return out, nil
	default:
		return nil, ErrType
	}
}

// Decode parses a frame body that starts with the type byte.
func Decode(buf []byte) (Message, error) {
	if len(buf) == 0 {
		return Message{}, ErrShort
	}
	m := Message{Type: buf[0]}
	rest := buf[1:]
	var err error
	switch m.Type {
	case TypeHello:
		if len(rest) < 4 {
			return Message{}, ErrShort
		}
		m.Version = binary.BigEndian.Uint32(rest[:4])
		m.Agent, rest, err = takeString(rest[4:])
		if err != nil {
			return Message{}, err
		}
	case TypeExec:
		if len(rest) < 8 {
			return Message{}, ErrShort
		}
		m.ID = binary.BigEndian.Uint32(rest[:4])
		m.TimeoutMS = binary.BigEndian.Uint32(rest[4:8])
		m.Argv, rest, err = takeStrings(rest[8:], maxArgs)
		if err != nil {
			return Message{}, err
		}
		m.Env, rest, err = takeStrings(rest, maxEnv)
		if err != nil {
			return Message{}, err
		}
		m.Cwd, rest, err = takeString(rest)
		if err != nil {
			return Message{}, err
		}
		if len(m.Argv) == 0 || m.Argv[0] == "" {
			return Message{}, ErrEmptyArgv
		}
		for _, e := range m.Env {
			if !validEnv(e) {
				return Message{}, ErrBadEnv
			}
		}
	case TypeStdin, TypeStdout, TypeStderr:
		if len(rest) < 8 {
			return Message{}, ErrShort
		}
		m.ID = binary.BigEndian.Uint32(rest[:4])
		n := binary.BigEndian.Uint32(rest[4:8])
		if n > maxPayload || int(n) > len(rest)-8 {
			return Message{}, ErrFrameSize
		}
		m.Data = append([]byte(nil), rest[8:8+n]...)
		rest = rest[8+n:]
	case TypeStdinEOF, TypeKill, TypeStarted:
		if len(rest) < 4 {
			return Message{}, ErrShort
		}
		m.ID = binary.BigEndian.Uint32(rest[:4])
		rest = rest[4:]
	case TypeShutdown:
	case TypeExit:
		if len(rest) < 12 {
			return Message{}, ErrShort
		}
		m.ID = binary.BigEndian.Uint32(rest[:4])
		m.ExitCode = int32(binary.BigEndian.Uint32(rest[4:8]))
		m.ExitSignal = int32(binary.BigEndian.Uint32(rest[8:12]))
		rest = rest[12:]
	case TypeError:
		if len(rest) < 4 {
			return Message{}, ErrShort
		}
		m.ID = binary.BigEndian.Uint32(rest[:4])
		m.Error, rest, err = takeString(rest[4:])
		if err != nil {
			return Message{}, err
		}
	default:
		return Message{}, ErrType
	}
	if len(rest) != 0 {
		return Message{}, ErrTrailing
	}
	return m, nil
}

func idOnly(typ uint8, id uint32) []byte {
	out := make([]byte, 5)
	out[0] = typ
	binary.BigEndian.PutUint32(out[1:], id)
	return out
}

func encodeString(s string) ([]byte, error) {
	if len(s) > maxString {
		return nil, fmt.Errorf("string longer than %d bytes", maxString)
	}
	if !utf8.ValidString(s) {
		return nil, ErrUTF8
	}
	out := make([]byte, 2+len(s))
	binary.BigEndian.PutUint16(out[:2], uint16(len(s)))
	copy(out[2:], s)
	return out, nil
}

func appendStrings(out []byte, vals []string) ([]byte, error) {
	if len(vals) > 0xffff {
		return nil, ErrTooMany
	}
	var n [2]byte
	binary.BigEndian.PutUint16(n[:], uint16(len(vals)))
	out = append(out, n[:]...)
	for _, v := range vals {
		enc, err := encodeString(v)
		if err != nil {
			return nil, err
		}
		out = append(out, enc...)
	}
	return out, nil
}

func takeString(b []byte) (string, []byte, error) {
	if len(b) < 2 {
		return "", nil, ErrShort
	}
	n := int(binary.BigEndian.Uint16(b[:2]))
	if n > maxString || len(b) < 2+n {
		return "", nil, ErrFrameSize
	}
	s := b[2 : 2+n]
	if !utf8.Valid(s) {
		return "", nil, ErrUTF8
	}
	return string(s), b[2+n:], nil
}

func takeStrings(b []byte, limit int) ([]string, []byte, error) {
	if len(b) < 2 {
		return nil, nil, ErrShort
	}
	n := int(binary.BigEndian.Uint16(b[:2]))
	if n > limit {
		return nil, nil, ErrTooMany
	}
	rest := b[2:]
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		s, next, err := takeString(rest)
		if err != nil {
			return nil, nil, err
		}
		out = append(out, s)
		rest = next
	}
	return out, rest, nil
}

func validEnv(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] == '=' {
			return i > 0
		}
	}
	return false
}
