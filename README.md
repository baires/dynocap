# microvm

A local Linux microVM runtime for AI agents on macOS. One CLI boots an
isolated Linux guest with Apple's Virtualization.framework, runs a command
inside it, and tears it down.

For project work, start with the **[Git-style workflow guide](docs/git-style-workflow.md)**:
clone a local directory or repository into a named Node 22 task, run commands,
review a verified diff, and retain results after teardown. It includes CLI,
TypeScript SDK, and MCP setup. Project tasks currently require Apple Silicon.

The tool is local-first: one user and one machine, with no hosted account,
cluster, or host filesystem share. Tasks have finite lifetimes; persistent
workspaces and resume are not implemented.

## Architecture

```
microvm CLI  --unix socket-->  microvm daemon (same binary)
                                    |
                                    |  VZLinuxBootLoader
                                    |  virtio-console  -> ~/.microvm/vms/<name>/console.log
                                    |  virtio-net      -> absent by default; NAT opt-in
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

The default guest has **no virtual network device**. Exec still works over
vsock. `--network nat` explicitly attaches `VZNATNetworkDeviceAttachment` for
unrestricted outbound access with DHCP. `--network filtered` attaches a virtio
NIC whose host forwarder allows HTTPS only to `registry.npmjs.org` and the
task's Git host. No host filesystem is mounted.

## Isolation promise

Each sandbox runs a separate Linux kernel with its configured CPU and memory.
By default it has no virtual NIC, no host filesystem mount, and a 30-minute
lifetime counted from creation, including boot. Loopback inside the guest
still works; vsock is the daemon-to-agent control channel.

`--network nat` is an explicit relaxation: the guest can reach destinations
allowed by the host network, potentially including host services, private
networks, link-local services, and cloud metadata endpoints. NAT does **not**
filter destinations or prevent data exfiltration. `--network filtered` is a
separate explicit mode. The host forwarder allows TCP port 443 only to
`registry.npmjs.org` and, for a repository URL, that URL's hostname, and
denies the host, private networks, link-local, CGNAT, multicast, and metadata
addresses. The runtime does not publish inbound ports. There is no general
allowlist language.

The host daemon and applications running as your user are trusted. The Unix
socket is the local control boundary, not a boundary between applications
running as the same user. Guest code may be privileged inside its own Linux
kernel; networking policy is enforced by host device configuration, not guest
firewall rules. This is not a claim that hypervisor vulnerabilities cannot exist.

TTL is host-clock-based lifecycle cleanup, not a precise real-time execution
deadline. A one-second sweep starts teardown at expiry; host sleep, clock
changes, scheduling, and teardown latency affect timing. Expired sandboxes
reject new execs and active commands receive an error. Failed teardown remains
visible as `stopping`, is logged, and is retried. Teardown uses the host
force-stop API on all supported macOS versions; it does not depend on the
guest accepting a shutdown request. Guest I/O is disconnected before force-stop
so unread output cannot obstruct shutdown. A socket write stalled for five
seconds disconnects the exec stream and cancels its command.

### Upgrading from unrestricted defaults

This release changes omitted networking to `none` and omitted/null TTL to
1800 seconds; explicit TTL must be an integer from 1 through 86400. There is
no unlimited lifetime or automatic renewal. Restart the daemon after upgrading:
stop its foreground process with Ctrl-C, or send SIGTERM to its PID from
`$MICROVM_HOME/daemon.json` (default `~/.microvm/daemon.json`), then let the next
CLI command start the rebuilt binary. Stopping the daemon stops its sandboxes.
There is no live migration or automatic restart of an existing daemon.

Updated CLI/SDK clients require isolation policy v1 before creating sandboxes
and reject older daemons with upgrade instructions. Missing networking in
historical records is reported as `unknown`, never as offline.

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
microvm run --name demo --cpus 2 --memory 1024 --ttl 3600 --network none --boot-timeout 60
# Opt in to unrestricted outbound networking:
microvm run --name online --network nat
microvm exec demo --timeout 30 --cwd /tmp --env FOO=bar -- uname -a
```

`microvm help run` and `microvm run --help` show the same command help. Top-level help
teaches the repository workflow; `microvm help advanced` lists raw sandboxes, task
commands, and the daemon. `--home`, `--verbose`, `--help`, and `--version` work
before or after the subcommand. Valued options accept `--flag value` and
`--flag=value`. Arguments after `exec`'s `--` are the guest command, unchanged,
even when they look like microvm flags. Invalid usage exits 2 and names the
offending argument. Help and invalid usage do not start the daemon.

`--memory` is megabytes. `--ttl` defaults to 1800 seconds and accepts 1–86400.
The limit includes boot time and exec never renews it. `ps` shows the effective
`NETWORK` and `TTL_SEC`; `unknown` identifies absent historical metadata.
`--timeout` kills the guest process group and the command exits 124. With an
empty `--env` list the agent still sets `PATH`, `HOME`, `TERM`, and `LANG`.

If boot fails, the error includes the tail of `console.log`.

## Cleanup

`microvm destroy demo` terminates active execs and calls
`VZVirtualMachine.stop` on the host. It deletes the sandbox directory only
after confirmed teardown. Failures remain visible as `stopping` and are retried.

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

To exercise real guests on a virtualization-capable Mac with an existing image:

```sh
./scripts/build-macos.sh
npm run typecheck
python3 scripts/test-isolation-macos.py
```

The smoke test uses a temporary home and its own daemon. It checks no NIC/routes
by default, outbound TCP denial, NAT DHCP and public HTTP reachability, real SDK
and MCP policy behavior, and TTL termination of active commands, including a
noisy command whose client stops reading output. It needs
internet for the explicit NAT test. Override the image directory with
`--images /path/to/images`; it never rewrites the source image or touches your
existing daemon. Unit tests also cover malformed policy requests, legacy daemon
rejection, expiry during boot/exec, late callbacks, and teardown failure/retry.

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

## Agent task loop

The Node 22 project/task/result path, runtime preparation, SDK/MCP usage and
retention limits are documented in [Task loop](docs/task-loop.md). Runtime tools
are read-only, workspaces are copied, and finalization exports results before
sandbox destruction.
