package image

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// Options selects where an image is built.
type Options struct {
	Arch     string
	OutDir   string
	CacheDir string
	RepoRoot string
	Log      io.Writer
	RootDir  string
}

// Manifest is written next to the kernel and initrd.
type Manifest struct {
	Arch          string `json:"arch"`
	Alpine        string `json:"alpine"`
	KernelPackage string `json:"kernelPackage"`
	KernelRelease string `json:"kernelRelease"`
	KernelSHA256  string `json:"kernelSHA256"`
	InitrdSHA256  string `json:"initrdSHA256"`
	GuestPort     int    `json:"guestPort"`
	BuiltAtUnix   int64  `json:"builtAtUnix"`
}

// Build downloads the pinned Alpine virt kernel and minirootfs, compiles the
// static guest agent, and writes kernel + gzip cpio initrd into OutDir.
func Build(opts Options) (Manifest, error) {
	if opts.Log == nil {
		opts.Log = io.Discard
	}
	pin, ok := Pins[opts.Arch]
	if !ok {
		return Manifest{}, fmt.Errorf("unsupported arch %q (want aarch64 or x86_64)", opts.Arch)
	}
	if opts.OutDir == "" || opts.CacheDir == "" || opts.RepoRoot == "" {
		return Manifest{}, fmt.Errorf("out, cache, and repo are required")
	}
	if err := os.MkdirAll(opts.OutDir, 0o755); err != nil {
		return Manifest{}, err
	}
	fmt.Fprintf(opts.Log, "downloading Alpine %s minirootfs\n", AlpineVersion)
	rootfsTar := filepath.Join(opts.CacheDir, filepath.Base(pin.MinirootURL))
	if err := download(pin.MinirootURL, rootfsTar, pin.MinirootSHA256); err != nil {
		return Manifest{}, err
	}
	fmt.Fprintf(opts.Log, "downloading %s (%s)\n", KernelPackage, opts.Arch)
	apkPath := filepath.Join(opts.CacheDir, opts.Arch+"-"+filepath.Base(pin.KernelURL))
	if err := download(pin.KernelURL, apkPath, pin.KernelSHA256); err != nil {
		return Manifest{}, err
	}

	apkBytes, err := os.ReadFile(apkPath)
	if err != nil {
		return Manifest{}, err
	}
	members, err := splitGzip(apkBytes)
	if err != nil {
		return Manifest{}, fmt.Errorf("apk: %w", err)
	}
	if len(members) < 2 {
		return Manifest{}, fmt.Errorf("apk: expected signature, control, and data; got %d gzip members", len(members))
	}
	dataTar := members[len(members)-1]

	kernelRaw, configText, depText, release, err := readKernelParts(dataTar)
	if err != nil {
		return Manifest{}, err
	}
	kernel, err := PrepareKernel(opts.Arch, kernelRaw)
	if err != nil {
		return Manifest{}, err
	}
	plan, err := planModules(depText, configText)
	if err != nil {
		return Manifest{}, err
	}
	fmt.Fprintf(opts.Log, "kernel %s (%d bytes), %d modules\n", release, len(kernel), len(plan.Paths))

	agent, err := buildAgent(opts.RepoRoot, pin.GoArch, opts.Log)
	if err != nil {
		return Manifest{}, err
	}

	work, err := os.MkdirTemp("", "dynocap-rootfs-")
	if err != nil {
		return Manifest{}, err
	}
	defer os.RemoveAll(work)
	root := filepath.Join(work, "root")
	if err := os.MkdirAll(root, 0o755); err != nil {
		return Manifest{}, err
	}
	fmt.Fprintf(opts.Log, "extracting minirootfs\n")
	if err := extractTarFile(rootfsTar, root); err != nil {
		return Manifest{}, err
	}
	if err := installModules(dataTar, release, plan, root); err != nil {
		return Manifest{}, err
	}
	if err := installGuest(root, agent, plan, release); err != nil {
		return Manifest{}, err
	}

	if err := writeFileAtomic(filepath.Join(opts.OutDir, "kernel"), kernel, 0o644); err != nil {
		return Manifest{}, err
	}
	if opts.RootDir != "" {
		if out, err := exec.Command("cp", "-a", root, opts.RootDir).CombinedOutput(); err != nil {
			return Manifest{}, fmt.Errorf("copy runtime root: %s: %w", out, err)
		}
	}
	initrdPath := filepath.Join(opts.OutDir, "initrd")
	fmt.Fprintf(opts.Log, "packing initrd\n")
	if err := pruneRoot(root); err != nil {
		return Manifest{}, err
	}
	if err := writeInitrd(root, initrdPath); err != nil {
		return Manifest{}, err
	}
	kernelSum, err := fileSHA(filepath.Join(opts.OutDir, "kernel"))
	if err != nil {
		return Manifest{}, err
	}
	initrdSum, err := fileSHA(initrdPath)
	if err != nil {
		return Manifest{}, err
	}
	manifest := Manifest{
		Arch:          opts.Arch,
		Alpine:        AlpineVersion,
		KernelPackage: KernelPackage,
		KernelRelease: release,
		KernelSHA256:  kernelSum,
		InitrdSHA256:  initrdSum,
		GuestPort:     5252,
		BuiltAtUnix:   time.Now().Unix(),
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return Manifest{}, err
	}
	raw = append(raw, '\n')
	if err := writeFileAtomic(filepath.Join(opts.OutDir, "manifest.json"), raw, 0o644); err != nil {
		return Manifest{}, err
	}
	fmt.Fprintf(opts.Log, "image ready in %s\n", opts.OutDir)
	return manifest, nil
}

func readKernelParts(dataTar []byte) (kernel []byte, config, dep, release string, err error) {
	tr := tar.NewReader(bytes.NewReader(dataTar))
	var kernelB, configB, depB []byte
	var depName string
	for {
		hdr, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return nil, "", "", "", e
		}
		name := path.Clean(hdr.Name)
		switch {
		case name == "boot/vmlinuz-virt":
			kernelB, err = io.ReadAll(tr)
		case strings.HasPrefix(name, "boot/config-") && strings.HasSuffix(name, "-virt"):
			configB, err = io.ReadAll(tr)
		case strings.HasSuffix(name, "/modules.dep"):
			depB, err = io.ReadAll(tr)
			depName = name
		default:
			continue
		}
		if err != nil {
			return nil, "", "", "", err
		}
	}
	if kernelB == nil || configB == nil || depB == nil {
		return nil, "", "", "", fmt.Errorf("apk is missing vmlinuz, config, or modules.dep")
	}
	// lib/modules/<release>/modules.dep
	parts := strings.Split(depName, "/")
	if len(parts) < 3 {
		return nil, "", "", "", fmt.Errorf("unexpected modules.dep path %s", depName)
	}
	return kernelB, string(configB), string(depB), parts[len(parts)-2], nil
}

func installModules(dataTar []byte, release string, plan modulePlan, root string) error {
	want := map[string]string{}
	for _, rel := range plan.Paths {
		// dep paths are stored without .gz; the apk may contain .ko.gz.
		want[rel] = rel
		want[rel+".gz"] = rel
	}
	if len(want) == 0 {
		return nil
	}
	found := map[string]bool{}
	tr := tar.NewReader(bytes.NewReader(dataTar))
	prefix := path.Join("lib/modules", release) + "/"
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		name := path.Clean(hdr.Name)
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		rel := strings.TrimPrefix(name, prefix)
		stored, ok := want[rel]
		if !ok {
			continue
		}
		payload, err := io.ReadAll(tr)
		if err != nil {
			return err
		}
		if len(payload) >= 2 && payload[0] == 0x1f && payload[1] == 0x8b {
			payload, err = gunzip(payload)
			if err != nil {
				return fmt.Errorf("%s: %w", name, err)
			}
		}
		dest := filepath.Join(root, "lib", "modules", release, filepath.FromSlash(stored))
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(dest, payload, 0o644); err != nil {
			return err
		}
		found[stored] = true
	}
	for _, rel := range plan.Paths {
		if !found[rel] {
			return fmt.Errorf("module %s not in kernel package", rel)
		}
	}
	return nil
}

func installGuest(root string, agent []byte, plan modulePlan, release string) error {
	writeList := func(name string, rels []string) error {
		var lines []string
		for _, rel := range rels {
			lines = append(lines, path.Join("/lib/modules", release, rel))
		}
		body := strings.Join(lines, "\n")
		if body != "" {
			body += "\n"
		}
		return os.WriteFile(filepath.Join(root, "etc", name), []byte(body), 0o644)
	}
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		return err
	}
	vsock, net := plan.Vsock, plan.Net
	if vsock == nil && net == nil {
		vsock = plan.Paths
	}
	if err := writeList("dynocap-vsock-modules", vsock); err != nil {
		return err
	}
	if err := writeList("dynocap-storage-modules", plan.Storage); err != nil {
		return err
	}
	if err := writeList("dynocap-net-modules", net); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "init"), initScript, 0o755); err != nil {
		return err
	}
	binDir := filepath.Join(root, "usr", "local", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(binDir, "dynocap-agent"), agent, 0o755)
}

func extractTarFile(tarPath, dest string) error {
	f, err := os.Open(tarPath)
	if err != nil {
		return err
	}
	defer f.Close()
	var r io.Reader = f
	if strings.HasSuffix(tarPath, ".gz") || strings.HasSuffix(tarPath, ".tgz") {
		gz, err := gzip.NewReader(f)
		if err != nil {
			return err
		}
		defer gz.Close()
		r = gz
	}
	tr := tar.NewReader(r)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		name := path.Clean(hdr.Name)
		name = strings.TrimPrefix(name, "./")
		name = strings.TrimPrefix(name, "/")
		if name == "." || name == "" {
			continue
		}
		if strings.HasPrefix(name, "../") || strings.Contains(name, "/../") {
			return fmt.Errorf("tar path escapes root: %s", hdr.Name)
		}
		target := filepath.Join(dest, filepath.FromSlash(name))
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, os.FileMode(hdr.Mode)&0o777|0o755); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			payload, err := io.ReadAll(tr)
			if err != nil {
				return err
			}
			mode := os.FileMode(hdr.Mode) & 0o777
			if mode == 0 {
				mode = 0o644
			}
			if err := os.WriteFile(target, payload, mode); err != nil {
				return err
			}
		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			os.Remove(target)
			if err := os.Symlink(hdr.Linkname, target); err != nil {
				return err
			}
		case tar.TypeLink:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			linkName := path.Clean(strings.TrimPrefix(hdr.Linkname, "./"))
			src := filepath.Join(dest, filepath.FromSlash(linkName))
			os.Remove(target)
			if err := os.Link(src, target); err != nil {
				// Fall back to a copy so a hardlink still boots.
				b, rerr := os.ReadFile(src)
				if rerr != nil {
					return err
				}
				if werr := os.WriteFile(target, b, 0o755); werr != nil {
					return werr
				}
			}
		default:
			// Device nodes are created by devtmpfs at boot.
			continue
		}
	}
}

func writeInitrd(root, dest string) error {
	tmp := dest + ".partial"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	gz := gzip.NewWriter(f)
	gz.Name = "initrd.cpio"
	err = WriteCPIO(root, gz)
	closeErr := gz.Close()
	fileErr := f.Close()
	if err != nil {
		os.Remove(tmp)
		return err
	}
	if closeErr != nil {
		os.Remove(tmp)
		return closeErr
	}
	if fileErr != nil {
		os.Remove(tmp)
		return fileErr
	}
	return os.Rename(tmp, dest)
}

func buildAgent(repo, goarch string, log io.Writer) ([]byte, error) {
	dir, err := os.MkdirTemp("", "dynocap-agent-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	out := filepath.Join(dir, "dynocap-agent")
	cmd := exec.Command("go", "build", "-trimpath", "-ldflags=-s -w", "-o", out, "./agent")
	cmd.Dir = filepath.Join(repo, "guest")
	cmd.Env = append(os.Environ(),
		"CGO_ENABLED=0",
		"GOOS=linux",
		"GOARCH="+goarch,
	)
	var stderr bytes.Buffer
	cmd.Stdout = log
	cmd.Stderr = &stderr
	fmt.Fprintf(log, "building guest agent GOOS=linux GOARCH=%s\n", goarch)
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("build agent: %w\n%s", err, stderr.String())
	}
	return os.ReadFile(out)
}

func writeFileAtomic(dest string, data []byte, mode os.FileMode) error {
	tmp := dest + ".partial"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

func fileSHA(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return sha256Sum(b), nil
}
