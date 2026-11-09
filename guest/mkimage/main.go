package main

import (
	"flag"
	"fmt"
	"os"
	"runtime"

	"microvm.dev/guest/internal/image"
)

func main() {
	arch := flag.String("arch", defaultArch(), "guest arch: aarch64 or x86_64")
	out := flag.String("out", "", "output directory for kernel, initrd, and manifest.json")
	cache := flag.String("cache", "", "directory for downloaded Alpine artifacts")
	repo := flag.String("repo", ".", "path to the microvm repository root")
	flag.Parse()
	if *out == "" || *cache == "" {
		fmt.Fprintln(os.Stderr, "usage: mkimage --arch aarch64|x86_64 --out DIR --cache DIR [--repo ROOT]")
		os.Exit(2)
	}
	manifest, err := image.Build(image.Options{
		Arch:     *arch,
		OutDir:   *out,
		CacheDir: *cache,
		RepoRoot: *repo,
		Log:      os.Stderr,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "mkimage: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("arch=%s release=%s kernel=%s initrd=%s\n", manifest.Arch, manifest.KernelRelease, manifest.KernelSHA256[:12], manifest.InitrdSHA256[:12])
}

func defaultArch() string {
	switch runtime.GOARCH {
	case "arm64":
		return "aarch64"
	case "amd64":
		return "x86_64"
	default:
		return ""
	}
}
