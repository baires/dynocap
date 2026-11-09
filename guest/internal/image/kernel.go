package image

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"fmt"
	"io"
)

// arm64Magic is the ARM64 Image header magic at offset 0x38 ("ARM\x64").
var arm64Magic = []byte("ARM\x64")

// PrepareKernel returns a kernel image VZLinuxBootLoader can boot.
//
// Apple Silicon requires an uncompressed ARM64 Image. Alpine publishes the
// virt kernel as an EFI zboot (CONFIG_EFI_ZBOOT) PE wrapper around a gzip
// Image, so that wrapper is peeled off here. Intel Macs boot the x86_64
// bzImage directly.
func PrepareKernel(arch string, vmlinuz []byte) ([]byte, error) {
	switch arch {
	case "aarch64":
		img, err := unwrapARM64(vmlinuz, 0)
		if err != nil {
			return nil, err
		}
		if !isARM64Image(img) {
			return nil, fmt.Errorf("aarch64 kernel is not an uncompressed ARM64 Image")
		}
		return img, nil
	case "x86_64":
		img, err := unwrapBZImage(vmlinuz, 0)
		if err != nil {
			return nil, err
		}
		if !isBZImage(img) {
			return nil, fmt.Errorf("x86_64 kernel is not a bzImage (missing HdrS)")
		}
		return img, nil
	default:
		return nil, fmt.Errorf("unsupported guest arch %q", arch)
	}
}

func isARM64Image(b []byte) bool {
	return len(b) >= 0x3c && bytes.Equal(b[0x38:0x3c], arm64Magic)
}

func isBZImage(b []byte) bool {
	return len(b) >= 0x206 && bytes.Equal(b[0x202:0x206], []byte("HdrS"))
}

func unwrapARM64(b []byte, depth int) ([]byte, error) {
	if depth > 4 {
		return nil, fmt.Errorf("kernel compression nested too deeply")
	}
	if isARM64Image(b) {
		return b, nil
	}
	if len(b) >= 2 && b[0] == 0x1f && b[1] == 0x8b {
		raw, err := gunzip(b)
		if err != nil {
			return nil, err
		}
		return unwrapARM64(raw, depth+1)
	}
	if payload, comp, ok := efiZbootPayload(b); ok {
		raw, err := decompressPayload(comp, payload)
		if err != nil {
			return nil, err
		}
		return unwrapARM64(raw, depth+1)
	}
	return nil, fmt.Errorf("unrecognized aarch64 kernel (len %d)", len(b))
}

func unwrapBZImage(b []byte, depth int) ([]byte, error) {
	if isBZImage(b) {
		return b, nil
	}
	if depth < 2 && len(b) >= 2 && b[0] == 0x1f && b[1] == 0x8b {
		raw, err := gunzip(b)
		if err != nil {
			return nil, err
		}
		return unwrapBZImage(raw, depth+1)
	}
	return b, nil
}

// efiZbootPayload parses a Linux CONFIG_EFI_ZBOOT header.
//
//	0   "MZ"
//	4   "zimg"
//	8   u32le payload offset
//	12  u32le payload size
//	24  4-byte compression name ("gzip", "lz4 ", "zstd", "xz  ")
func efiZbootPayload(b []byte) (payload []byte, compression string, ok bool) {
	if len(b) < 28 || b[0] != 'M' || b[1] != 'Z' {
		return nil, "", false
	}
	if string(b[4:8]) != "zimg" {
		return nil, "", false
	}
	off := binary.LittleEndian.Uint32(b[8:12])
	size := binary.LittleEndian.Uint32(b[12:16])
	if uint64(off)+uint64(size) > uint64(len(b)) {
		return nil, "", false
	}
	comp := string(bytes.TrimRight(b[24:28], "\x00 "))
	return b[off : off+size], comp, true
}

func decompressPayload(comp string, payload []byte) ([]byte, error) {
	switch comp {
	case "gzip":
		return gunzip(payload)
	case "":
		return payload, nil
	default:
		return nil, fmt.Errorf("unsupported EFI zboot compression %q", comp)
	}
}

func gunzip(b []byte) ([]byte, error) {
	r, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(r)
}
