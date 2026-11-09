package image

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSplitGzipRoundTrip(t *testing.T) {
	a := gzipBytes(t, []byte("alpha-payload"))
	b := gzipBytes(t, []byte("beta-payload-longer"))
	members, err := splitGzip(append(a, b...))
	if err != nil {
		t.Fatal(err)
	}
	if len(members) != 2 || string(members[0]) != "alpha-payload" || string(members[1]) != "beta-payload-longer" {
		t.Fatalf("%q %q", members[0], members[1])
	}
}

func TestPrepareKernelARM64(t *testing.T) {
	img := make([]byte, 0x40)
	copy(img[0x38:], []byte("ARM\x64"))
	got, err := PrepareKernel("aarch64", img)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, img) {
		t.Fatal("identity unwrap failed")
	}
	gz := gzipBytes(t, img)
	got, err = PrepareKernel("aarch64", gz)
	if err != nil {
		t.Fatal(err)
	}
	if !isARM64Image(got) {
		t.Fatal("gzip unwrap lost magic")
	}

	payload := gzipBytes(t, img)
	zboot := make([]byte, 64+len(payload))
	copy(zboot[0:], []byte("MZ"))
	copy(zboot[4:], []byte("zimg"))
	binary.LittleEndian.PutUint32(zboot[8:], 64)
	binary.LittleEndian.PutUint32(zboot[12:], uint32(len(payload)))
	copy(zboot[24:], []byte("gzip"))
	copy(zboot[64:], payload)
	got, err = PrepareKernel("aarch64", zboot)
	if err != nil {
		t.Fatal(err)
	}
	if !isARM64Image(got) {
		t.Fatal("zboot unwrap lost magic")
	}
}

func TestPrepareKernelBZImage(t *testing.T) {
	bz := make([]byte, 0x210)
	copy(bz[0:], []byte("MZ"))
	copy(bz[0x202:], []byte("HdrS"))
	got, err := PrepareKernel("x86_64", bz)
	if err != nil {
		t.Fatal(err)
	}
	if !isBZImage(got) {
		t.Fatal("expected bzImage")
	}
	got, err = PrepareKernel("x86_64", gzipBytes(t, bz))
	if err != nil {
		t.Fatal(err)
	}
	if !isBZImage(got) {
		t.Fatal("gzip bzImage unwrap failed")
	}
	if _, err := PrepareKernel("aarch64", bz); err == nil {
		t.Fatal("aarch64 accepted a bzImage")
	}
}

func TestModulePlan(t *testing.T) {
	dep := `
kernel/drivers/net/virtio_net.ko.gz: kernel/drivers/net/net_failover.ko.gz kernel/net/core/failover.ko.gz
kernel/drivers/net/net_failover.ko.gz: kernel/net/core/failover.ko.gz
kernel/net/core/failover.ko.gz:
kernel/net/vmw_vsock/vsock.ko.gz:
kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko.gz: kernel/net/vmw_vsock/vsock.ko.gz
kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko.gz: kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko.gz kernel/net/vmw_vsock/vsock.ko.gz
`
	cfg := "CONFIG_VIRTIO_NET=m\nCONFIG_VIRTIO_VSOCKETS=m\n"
	plan, err := planModules(dep, cfg)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(plan.Paths, ",")
	want := strings.Join([]string{
		"kernel/net/core/failover.ko",
		"kernel/drivers/net/net_failover.ko",
		"kernel/drivers/net/virtio_net.ko",
		"kernel/net/vmw_vsock/vsock.ko",
		"kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko",
		"kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko",
	}, ",")
	if got != want {
		t.Fatalf("order\n got %s\nwant %s", got, want)
	}

	builtin := "CONFIG_VIRTIO_NET=y\nCONFIG_VIRTIO_VSOCKETS=y\n"
	plan, err = planModules("kernel/fs/ext4/ext4.ko.gz:\n", builtin)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Paths) != 0 {
		t.Fatalf("built-in kernel should load no modules, got %v", plan.Paths)
	}
}

func TestCPIORoundTrip(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := []byte("#!/bin/sh\necho hi\n")
	if err := os.WriteFile(filepath.Join(root, "bin", "sh"), script, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("sh", filepath.Join(root, "bin", "busybox")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "init"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := WriteCPIO(root, &buf); err != nil {
		t.Fatal(err)
	}
	entries := readNewc(t, buf.Bytes())
	sh, ok := entries["bin/sh"]
	if !ok || !bytes.Equal(sh.data, script) {
		t.Fatalf("bin/sh missing or wrong: %+v", sh)
	}
	if sh.mode&0111 == 0 {
		t.Fatalf("bin/sh mode %#o", sh.mode)
	}
	link, ok := entries["bin/busybox"]
	if !ok || string(link.data) != "sh" || link.mode&0170000 != 0120000 {
		t.Fatalf("symlink %+v", link)
	}
	if _, ok := entries["init"]; !ok {
		t.Fatal("missing init")
	}
	if _, ok := entries["TRAILER!!!"]; !ok {
		t.Fatal("missing trailer")
	}
	if entries["bin/sh"].uid != 0 || entries["bin"].uid != 0 {
		t.Fatal("expected uid 0")
	}
}

type cpioEntry struct {
	mode uint32
	uid  uint32
	data []byte
}

func readNewc(t *testing.T, archive []byte) map[string]cpioEntry {
	t.Helper()
	out := map[string]cpioEntry{}
	i := 0
	for i+110 <= len(archive) {
		if string(archive[i:i+6]) != "070701" {
			t.Fatalf("magic at %d: %q", i, archive[i:i+6])
		}
		fields := make([]uint32, 13)
		for f := 0; f < 13; f++ {
			start := i + 6 + f*8
			var v uint32
			for _, c := range archive[start : start+8] {
				v <<= 4
				switch {
				case c >= '0' && c <= '9':
					v |= uint32(c - '0')
				case c >= 'A' && c <= 'F':
					v |= uint32(c-'A') + 10
				case c >= 'a' && c <= 'f':
					v |= uint32(c-'a') + 10
				default:
					t.Fatalf("bad hex")
				}
			}
			fields[f] = v
		}
		namesize := int(fields[11])
		filesize := int(fields[6])
		nameStart := i + 110
		nameEnd := nameStart + namesize
		if nameEnd > len(archive) || archive[nameEnd-1] != 0 {
			t.Fatal("bad name")
		}
		name := string(archive[nameStart : nameEnd-1])
		dataStart := (nameEnd + 3) &^ 3
		dataEnd := dataStart + filesize
		if dataEnd > len(archive) {
			t.Fatal("bad data")
		}
		out[name] = cpioEntry{mode: fields[1], uid: fields[2], data: append([]byte(nil), archive[dataStart:dataEnd]...)}
		i = (dataEnd + 3) &^ 3
		if name == "TRAILER!!!" {
			break
		}
	}
	return out
}

func gzipBytes(t *testing.T, payload []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestTarExtractAndModules(t *testing.T) {
	// Synthetic apk data tar: kernel bytes are irrelevant here; module install
	// is exercised through a tiny tar of one gzipped object.
	var body bytes.Buffer
	tw := tar.NewWriter(&body)
	payload := gzipBytes(t, []byte("not-a-real-ko"))
	hdr := &tar.Header{
		Name: "lib/modules/1.2.3-virt/kernel/net/vmw_vsock/vsock.ko.gz",
		Mode: 0o644,
		Size: int64(len(payload)),
	}
	if err := tw.WriteHeader(hdr); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	plan := modulePlan{Paths: []string{"kernel/net/vmw_vsock/vsock.ko"}}
	if err := installModules(body.Bytes(), "1.2.3-virt", plan, root); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(root, "lib/modules/1.2.3-virt/kernel/net/vmw_vsock/vsock.ko"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "not-a-real-ko" {
		t.Fatalf("module bytes %q", got)
	}
}
