# microvm

A local Linux microVM runtime for AI agents on macOS. One CLI boots an
isolated Linux guest with Apple's Virtualization.framework, runs a command
inside it, and tears it down.

This is a spike: one image, one user, one machine. No cluster, no registry,
no host filesystem share.

## Architecture

```
microvm CLI  --unix socket-->  microvm daemon (same binary)
                                    |
                                    |  VZLinuxBootLoader
                                    |  virtio-console  -> ~/.microvm/vms/<name>/console.log
                                    |  virtio-net NAT  -> outbound DHCP only
                                    |  virtio-vsock    -> guest port 5252
                                    v
                               Linux guest (Alpine minirootfs initramfs)
                                    PID 1  /init
                                    microvm-agent (static Go) listens on vsock
                                    exec streams stdout, stderr, and the exit code
```

The daemon is one per user. Each VM is a `VZVirtualMachine` on its own serial
queue inside that process. If the daemon exits, the kernel destroys the VMs
with it. The next `microvm` command starts a new daemon, which marks those
records stopped so nothing is left looking alive. There is no host-side
`AF_VSOCK`; the file descriptor comes from `VZVirtioSocketDevice.connect`.

The guest wire protocol is version 1, big-endian, and shared by
`Sources/MicroVMCore/GuestProtocol.swift` and `guest/internal/protocol`.
Golden frames live in `testdata/protocol-vectors.json`. No authentication:
the vsock exists only inside this VM, and the daemon socket is mode `0600`.

## Requirements

- macOS 13 or later, Apple Silicon or Intel
- Xcode 15 or later (Swift 5.9). The command-line tools are enough to compile
- Go 1.22 or later, to build the guest agent and the initramfs
- The entitlement `com.apple.security.virtualization`

Ad-hoc signing is enough for that entitlement. A paid Apple Developer account
is not required. Do not enable the App Sandbox; it fights the virtualization
entitlement.

Apple Silicon and Intel need different guest kernels. `scripts/fetch-image.sh`
selects the one that matches `uname -m`. The binary also records its arch at
compile time and will only boot that image.

## Build and run

```sh
git clone <this repo>
cd microvm
./scripts/build-macos.sh
./scripts/fetch-image.sh
.build/release/microvm run --name demo --cpus 2 --memory 1024
.build/release/microvm exec demo -- uname -a
.build/release/microvm exec demo -- sh -c 'echo hello'
.build/release/microvm ps
.build/release/microvm destroy demo
```

`build-macos.sh` runs `swift build -c release` and then:

```sh
codesign --sign - --entitlements entitlements/microvm.entitlements --force .build/release/microvm
```

Re-sign after every rebuild. An unsigned binary fails inside
`VZVirtualMachine.start` even when the rest of the code is fine.

Optional, so the commands above match a normal shell:

```sh
sudo install -m 755 .build/release/microvm /usr/local/bin/microvm
```

`run` returns when the guest agent answers on vsock, not when you destroy
the VM. `exec` prints the guest's stdout and stderr as they arrive and exits
with the guest status (128+signal if it was killed, 124 on timeout).

## Image

`scripts/fetch-image.sh` does not use Docker. It downloads two pinned Alpine
3.24 artifacts from `dl-cdn.alpinelinux.org`, checks SHA-256, and packs an
initramfs:

| Piece              | Source                                             |
| ------------------ | -------------------------------------------------- |
| Rootfs             | `alpine-minirootfs-3.24.4-{aarch64,x86_64}.tar.gz` |
| Kernel and modules | `linux-virt-6.18.62-r0.apk` (Alpine v3.24)         |

The virt kernel has virtio-pci and virtio-console built in. vsock and
virtio-net are modules (`CONFIG_VIRTIO_VSOCKETS=m`, `CONFIG_VIRTIO_NET=m`);
`/init` loads them with `insmod` before it starts the agent. On Apple Silicon,
Virtualization.framework needs an uncompressed ARM64 `Image`. Alpine ships an
EFI zboot wrapper, and the image builder extracts the gzip payload and checks
the `ARM\x64` magic. Intel Macs boot the bzImage as published.

The guest gets outbound NAT. Nothing is published inbound, and the host home
directory is not mounted. DHCP comes from `VZNATNetworkDeviceAttachment`.

Cache and state:

```
~/.microvm/daemon.sock
~/.microvm/cache/                 downloaded apk and minirootfs
~/.microvm/images/<arch>/kernel
~/.microvm/images/<arch>/initrd   gzip newc cpio
~/.microvm/images/<arch>/manifest.json
~/.microvm/vms/<name>/state.json
~/.microvm/vms/<name>/console.log
~/.microvm/daemon.log
```

Override the root with `--home` or `MICROVM_HOME`.

## Flags

```
microvm run --name demo --cpus 2 --memory 1024 --ttl 3600 --boot-timeout 60
microvm exec demo --timeout 30 --cwd /tmp --env FOO=bar -- uname -a
```

`--memory` is megabytes. `--ttl` destroys the VM after that many seconds.
`--timeout` kills the guest process group and the command exits 124. With an
empty `--env` list the agent still sets `PATH`, `HOME`, `TERM`, and `LANG`.

If boot fails, the error includes the tail of `console.log`.

## Cleanup

`microvm destroy demo` tells the agent to power the guest off
(`reboot(LINUX_REBOOT_CMD_POWER_OFF)`), then calls `VZVirtualMachine.stop` on
macOS 14+ (`requestStop` on macOS 13) and deletes the VM directory.

A killed daemon takes its VMs with it. The next command starts a daemon with
a new token and rewrites stale `running` records to `stopped` with the message
`reaped leftover VM after daemon exit`. `run --name` replaces a stopped or
failed VM of that name. A second daemon refuses to start while the lock file
is held.

`microvm daemon` runs in the foreground for debugging. The CLI otherwise
spawns it detached (`MICROVM_DETACH=1`) and waits until the socket answers.

## Tests

These run without a Mac. They do not pretend to boot a VM.

```sh
(cd guest && go test ./...)
swift test
```

Covered: the guest frame codec (against the shared vectors), exec exit codes
and timeouts in the agent, cpio/newc packing, EFI zboot and gzip kernel
unwrapping, module load order, CLI parsing, the VM phase machine, daemon
`run` / `exec` / `ps` / `destroy` over a unix socket, leftover-VM reaping, and
the exec timeout. On Linux the virtualization backend is the explicit
"requires macOS" error, and a test checks that path.

## Boot time

A measured cold start on this Mac is in [docs/boot-time.md](docs/boot-time.md).
`run` returns when the guest agent answers. The unit tests still do not boot
a VM. If `run` times out, read `~/.microvm/vms/<name>/console.log` and
`~/.microvm/daemon.log`.

## Layout

```
Package.swift                 SwiftPM (CLI + portable core + macOS backend)
Sources/MicroVMCore           protocol, CLI, daemon, state
Sources/MicroVMVZ             Virtualization.framework
Sources/microvm               main
guest/agent                   static Linux agent
guest/mkimage                 kernel/initrd builder
guest/internal/protocol       guest wire codec
guest/internal/image          pins, cpio, zboot unwrap
entitlements/microvm.entitlements
scripts/build-macos.sh
scripts/fetch-image.sh
testdata/protocol-vectors.json
```

## License

Apache 2.0. See [LICENSE](LICENSE).
