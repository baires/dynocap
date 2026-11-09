package image

// AlpineVersion is the minirootfs release. The virt kernel package is the
// matching linux-virt build from the same stable branch. Both are fetched
// from dl-cdn.alpinelinux.org and checked against these SHA-256 pins.
const (
	AlpineVersion = "3.24.4"
	KernelPackage = "linux-virt-6.18.62-r0"
	AlpineBranch  = "v3.24"
)

// ArchPin is one guest architecture's kernel package and minirootfs.
type ArchPin struct {
	MinirootURL    string
	MinirootSHA256 string
	KernelURL      string
	KernelSHA256   string
	GoArch         string
}

// Pins is the only image this spike builds.
var Pins = map[string]ArchPin{
	"aarch64": {
		MinirootURL:    "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.4-aarch64.tar.gz",
		MinirootSHA256: "4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de",
		KernelURL:      "https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/linux-virt-6.18.62-r0.apk",
		KernelSHA256:   "3a9a0f16adaabee0e4e05e373682249e2a99ab000faebf6aaaf682ae575c661d",
		GoArch:         "arm64",
	},
	"x86_64": {
		MinirootURL:    "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-minirootfs-3.24.4-x86_64.tar.gz",
		MinirootSHA256: "cdaa38cb8de3537967ee5b6c9b6cd00cc962da2b018e6eea48696bb274923012",
		KernelURL:      "https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/linux-virt-6.18.62-r0.apk",
		KernelSHA256:   "e121b547d9b86194a641718b52ae1c3e605085c59f31525b1649a59b3d4db0c7",
		GoArch:         "amd64",
	},
}
