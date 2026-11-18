package image

// AlpineVersion is the minirootfs release. The virt kernel package is the
// matching linux-virt build from the same stable branch. Both are fetched
// from dl-cdn.alpinelinux.org and checked against these SHA-256 pins.
const (
	AlpineVersion = "3.24.4"
	KernelPackage = "linux-virt-6.18.64-r0"
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
		KernelURL:      "https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/" + KernelPackage + ".apk",
		KernelSHA256:   "cf171f51ab44d637a7758dd5a2f6a4ecd7ddbea18d61b9e37a6d39357d2fb1d5",
		GoArch:         "arm64",
	},
	"x86_64": {
		MinirootURL:    "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-minirootfs-3.24.4-x86_64.tar.gz",
		MinirootSHA256: "cdaa38cb8de3537967ee5b6c9b6cd00cc962da2b018e6eea48696bb274923012",
		KernelURL:      "https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/" + KernelPackage + ".apk",
		KernelSHA256:   "cdcff66a46c4c512accff5c569efa2ae44e6006d97286c0dd44775ea1d54901b",
		GoArch:         "amd64",
	},
}
