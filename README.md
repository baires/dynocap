# DynoCap

Local Linux sandboxes for AI agents on macOS. One CLI, `dynocap`, boots an isolated
Linux guest with Apple's Virtualization.framework, runs a command inside it,
and tears the sandbox down.

For project work, start with the **[Agent task workflow tutorial](docs/tutorials/agent-task-workflow.mdx)**:
clone a local directory or repository into a named task on a Node, Python, Go or
plain shell runtime, run commands,
review a verified diff, and retain results after teardown. It includes CLI,
TypeScript SDK, and MCP setup. Project tasks currently require Apple Silicon.

See the complete **[Documentation Portal](docs/index.mdx)** for tutorials,
how-to guides, reference schemas, and architectural explanations.

The tool is local-first: one user and one machine, with no hosted account,
cluster, or host filesystem share. A task's lifetime is finite. A machine you
sleep and resume later is not part of this release.

## Install

This release is Apple Silicon (`darwin-arm64`) only. Intel Macs are refused by
the installers. There is no Apple Developer ID signature: both installers
re-sign the CLI on your Mac with `codesign --sign -` and the bundled
virtualization entitlement, and they clear the download quarantine flag.
There is no Homebrew bottle, because pouring one would skip that re-sign.
Runtime preparation still needs `mke2fs` from `e2fsprogs`. The first runtime
preparation also needs Go 1.22 or newer. The release archive includes the guest
image and the pinned Alpine packages used to build runtimes. Runtime preparation
verifies these files and downloads language toolchains separately.

### Homebrew

```sh
brew install baires/tap/dynocap
```

That formula lives in [baires/homebrew-tap](https://github.com/baires/homebrew-tap).
On Homebrew 6, installing by this fully qualified name trusts the formula.
Trust covers loading the tap's Ruby. Run this when you want the short name
`dynocap` for a later install or upgrade:

```sh
brew trust --formula baires/tap/dynocap
```

The formula depends on macOS Ventura and `e2fsprogs`, and it refuses Intel.
`e2fsprogs` is keg-only; DynoCap looks up `mke2fs` under the Homebrew prefix.
A published release of this repository dispatches `dynocap-release` to the tap,
which rewrites `Formula/dynocap.rb` from the versioned archive and its
`.sha256` file. `packaging/homebrew/dynocap.rb` is the install method that
generator must keep. After install, run `dynocap doctor --fix` in your project.

### Curl

```sh
curl -fsSL https://dynocap.dev/install.sh | sh
```

The site serves `scripts/install.sh`. The script downloads
`dynocap-darwin-arm64.tar.gz` from the latest GitHub release, checks its
sha256, unpacks it to `~/.local/dynocap`, and symlinks `~/.local/bin/dynocap`.
The checksum catches a truncated download. When `gh` is installed and logged
in, the script also requires a build attestation from `baires/dynocap`. If
`mke2fs` is missing it tells you to run `brew install e2fsprogs`. Its last
step is `dynocap doctor --fix`.

### From source

```sh
./scripts/build-macos.sh
export PATH="$PWD/.build/release:$PATH"
```

`./scripts/build-macos.sh` is still the way to compile and ad-hoc sign from a
checkout. A source tree has no bundled guest image, so `dynocap doctor --fix`
builds one with Go. See [Build and run](#build-and-run) for a raw sandbox.

### Agent skill

[`skills/dynocap`](skills/dynocap/SKILL.md) is an [Agent Skills](https://agentskills.io)
skill that teaches a coding agent the task workflow, the network rules, and when
to prefer MCP. It works with the CLI alone; MCP is optional.

```sh
npx skills add baires/dynocap
```

Or copy the `skills/dynocap` folder into a skills directory your agent scans:
`.agents/skills/` in a project or `~/.agents/skills/` for every project (Claude
Code reads `.claude/skills/` and `~/.claude/skills/`). `npm run lint` checks
the skill against the specification with `scripts/validate-skills.mjs`.

## Release

Pull request titles are Conventional Commits. The bump is the title: `fix` is a patch, `feat` is a minor, and `type!:` is a breaking major. `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`, and `revert` do not change the version. When several pull requests land, the highest bump wins.

A push to `main` opens or updates `chore: release vX.Y.Z`, which writes that version into `DynoCapInfo.version`. Merging it does not publish. Create the GitHub release `vX.Y.Z` yourself after that commit is on `main`. The release workflow then packs the Apple Silicon archive, attests it, uploads it to the release you created, and updates the Homebrew formula.

## Quick start

After `dynocap` is on your PATH, the repository workflow below is the same one
`dynocap help` prints. `./project` is your project, with a `package-lock.json`
and `node_modules/` in `.gitignore`.

<!-- quick start: kept identical to `dynocap help` by CLIQuickStartTests -->

```sh
dynocap doctor --fix ./project                     # builds the guest image and the runtime ./project uses
dynocap clone ./project deps --network filtered    # explicit network: HTTPS to the runtime's registry only
dynocap exec deps --timeout 300 -- npm ci          # a node project; see RUNTIMES for the others
dynocap finish deps                                # exports the result and saves the package cache
dynocap clone ./project demo                       # offline by default: no network device
dynocap exec demo -- npm ci --offline              # installs from the saved package cache
dynocap exec demo -- npm test
dynocap shell demo
dynocap ls
dynocap inspect demo
dynocap logs demo
dynocap diff demo
dynocap finish demo                                # exports the patch, then destroys the sandbox
dynocap rm demo
dynocap rm deps
```

- `doctor --fix ./project` checks prerequisites and repairs what it can: it
  restarts a stale daemon, builds the guest image, and prepares the runtime
  `./project` uses, verifying every download. The project's files choose the
  runtime: `package.json` is `node:24`, `pyproject.toml` (or `uv.lock`,
  `requirements.txt`) is `python:3.14`, `go.mod` is `go:1.27`. `clone` picks the
  same one and says so; pass `--runtime` to either to choose another. Plain
  `doctor` only reports, and says what to run for each failure. `clone` never
  prepares a runtime for you.
- Sandboxes are offline unless you choose a network. `deps` uses
  `--network filtered` (HTTPS to the runtime's registry only: `registry.npmjs.org`
  for node) to install packages. Finishing it saves the package cache (npm, uv
  or Go modules), which later sandboxes with the same lockfile
  restore, so `demo` installs with no network device at all.
- Each sandbox has a finite TTL (30 minutes by default, `--ttl` up to 24 hours)
  that activity never renews. `shell` and `exec -t` warn before it ends. Expiry
  discards unexported edits.
- `finish` exports a verified patch and logs, destroys the sandbox, and prints
  a `git apply` command; it never modifies your checkout. Results are kept for
  seven days from creation.
- `rm` releases a finished sandbox. Discarding live work needs
  `rm NAME --force`; deleting a kept result needs `rm NAME --purge`.
- The quick start's `./project` has a `package.json`, so it runs on `node:24`.
  A project without `package.json`, `pyproject.toml` (or `uv.lock`,
  `requirements.txt`), or `go.mod`, and any repository URL, gets `shell:1`
  (bash, git and ssh only); the MCP server and SDK choose the same way. Pass
  `--runtime` for `node:22` or to override the choice. Each runtime has one
  package manager, and filtered egress reaches only that runtime's registry. See
  [Manage Dependencies and Caching](docs/how-to/manage-dependencies-and-caching.mdx)
  for each runtime's lockfile and offline install command.

Every command, its output, and its JSON support are in the
[command matrix](docs/reference/cli/commands.mdx). [The CLI reference](docs/reference/cli/overview.mdx)
collects error codes, deadlines, retention, destructive flags, terminal
transcripts, and interface changes. Raw sandboxes without a project
(`run`, `ps`, `destroy`) are described under [Build and run](#build-and-run).

## Architecture

```
dynocap CLI  --unix socket-->  dynocap daemon (same binary)
                                    |
                                    |  VZLinuxBootLoader
                                    |  virtio-console  -> ~/.dynocap/vms/<name>/console.log
                                    |  virtio-net      -> absent by default; NAT opt-in
                                    |  virtio-vsock    -> guest port 5252
                                    v
                               Linux guest (Alpine minirootfs initramfs)
                                    PID 1  /init
                                    dynocap-agent (static Go) listens on vsock
                                    exec streams stdout, stderr, and the exit code
```

The daemon is one per user. Each VM is a `VZVirtualMachine` on its own serial
queue inside that process. If the daemon exits, the kernel destroys the VMs
with it. The next `dynocap` command starts a new daemon, which marks those
records stopped so nothing is left looking alive. There is no host-side
`AF_VSOCK`; the file descriptor comes from `VZVirtioSocketDevice.connect`.

The guest wire protocol is version 1, big-endian, and shared by
`Sources/DynoCapCore/GuestProtocol.swift` and `guest/internal/protocol`.
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
cd dynocap
./scripts/build-macos.sh
./scripts/fetch-image.sh
.build/release/dynocap run --name demo --cpus 2 --memory 1024
.build/release/dynocap exec demo -- uname -a
echo hello | .build/release/dynocap exec demo -- cat
.build/release/dynocap exec demo -- sh -c 'echo hello'
.build/release/dynocap ps
.build/release/dynocap destroy demo --force
```

`build-macos.sh` runs `swift build -c release` and then:

```sh
codesign --sign - --entitlements entitlements/dynocap.entitlements --force .build/release/dynocap
```

Re-sign after every rebuild. An unsigned binary fails inside
`VZVirtualMachine.start` even when the rest of the code is fine.

Optional, so the commands above match a normal shell:

```sh
sudo install -m 755 .build/release/dynocap /usr/local/bin/dynocap
```

`run` returns when the guest agent answers on vsock, not when you destroy
the VM. `exec` prints the guest's stdout and stderr as they arrive and exits
with the guest status (128+signal if it was killed, 124 on timeout).
Piped stdin is streamed to the guest and closed at EOF. A terminal is not
read unless you pass `-i`. `--no-input` closes guest stdin immediately.
Project sandboxes start in `/workspace`; raw sandboxes start in `/`.

## Image

`scripts/fetch-image.sh` does not use Docker. It downloads two pinned Alpine
3.24 artifacts from `dl-cdn.alpinelinux.org`, checks SHA-256, and packs an
initramfs:

| Piece              | Source                                             |
| ------------------ | -------------------------------------------------- |
| Rootfs             | `alpine-minirootfs-3.24.4-{aarch64,x86_64}.tar.gz` |
| Kernel and modules | `linux-virt-6.18.64-r0.apk` (Alpine v3.24)         |

The virt kernel has virtio-pci and virtio-console built in. vsock and
virtio-net are modules (`CONFIG_VIRTIO_VSOCKETS=m`, `CONFIG_VIRTIO_NET=m`);
`/init` loads them with `insmod` before it starts the agent. On Apple Silicon,
Virtualization.framework needs an uncompressed ARM64 `Image`. Alpine ships an
EFI zboot wrapper, and the image builder extracts the gzip payload and checks
the `ARM\x64` magic. Intel Macs boot the bzImage as published.

The default guest has **no virtual network device**. Exec still works over
vsock. `--network nat` explicitly attaches `VZNATNetworkDeviceAttachment` for
unrestricted outbound access with DHCP. `--network filtered` attaches a virtio
NIC whose host forwarder allows HTTPS only to the task runtime's package
registry (`registry.npmjs.org` for a plain sandbox) and the task's Git host. No host filesystem is mounted.

## Isolation promise

Each sandbox runs a separate Linux kernel with its configured CPU and memory.
By default it has no virtual NIC, no host filesystem mount, and a 30-minute
lifetime counted from creation, including boot. Loopback inside the guest
still works; vsock is the daemon-to-agent control channel.

`--network nat` is an explicit relaxation: the guest can reach destinations
allowed by the host network, potentially including host services, private
networks, link-local services, and cloud metadata endpoints. NAT does **not**
filter destinations or prevent data exfiltration. `--network filtered` is a
separate explicit mode. The host forwarder allows TCP port 443 only to the
registry hosts the task runtime declares (`registry.npmjs.org` for node and plain
sandboxes, PyPI for python, the Go proxy and checksum database for go, none for
shell) and, for a repository URL, that URL's hostname, and
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
`$DYNOCAP_HOME/daemon.json` (default `~/.dynocap/daemon.json`), then let the next
CLI command start the rebuilt binary. Stopping the daemon stops its sandboxes.
There is no live migration or automatic restart of an existing daemon.

Updated CLI/SDK clients require isolation policy v1 before creating sandboxes
and reject older daemons with upgrade instructions. Missing networking in
historical records is reported as `unknown`, never as offline.

Cache and state:

```
~/.dynocap/daemon.sock
~/.dynocap/cache/                 downloaded apk and minirootfs
~/.dynocap/images/<arch>/kernel
~/.dynocap/images/<arch>/initrd   gzip newc cpio
~/.dynocap/images/<arch>/manifest.json
~/.dynocap/vms/<name>/state.json
~/.dynocap/vms/<name>/console.log
~/.dynocap/daemon.log
```

Override the root with `--home` or `DYNOCAP_HOME`.

## Flags

```
dynocap run --name demo --cpus 2 --memory 1024 --ttl 3600 --network none --boot-timeout 60
# Opt in to unrestricted outbound networking:
dynocap run --name online --network nat
dynocap exec demo --timeout 30 --cwd /tmp --env FOO=bar -- uname -a
dynocap shell demo
```

`shell` opens the guest's shell on a terminal, in `/workspace` for project
sandboxes, with no command deadline; leaving it keeps the sandbox running until
`finish`, `rm --force`, or its TTL. See [interactive shells guide](docs/how-to/interactive-shells-and-terminal.mdx).

`dynocap help run` and `dynocap run --help` show the same command help. Top-level help
teaches the repository workflow; `dynocap help advanced` lists raw sandboxes, task
commands, and the daemon. `--home`, `--verbose`, `--help`, and `--version` work
before or after the subcommand. Valued options accept `--flag value` and
`--flag=value`. Arguments after `exec`'s `--` are the guest command, unchanged,
even when they look like dynocap flags. Invalid usage exits 2 and names the
offending argument. Help and invalid usage do not start the daemon.

`--memory` is megabytes. `--ttl` defaults to 1800 seconds and accepts 1–86400.
The limit includes boot time and exec never renews it. `ps` lists raw sandboxes
with the same columns as `ls`, including the effective `NETWORK` and remaining
`TTL`; `unknown` identifies absent historical metadata. Every command's output and
`--json` support is in [CLI command reference](docs/reference/cli/commands.mdx).
`--timeout` kills the guest process group and the command exits 124. With an
empty `--env` list the agent still sets `PATH`, `HOME`, `TERM`, and `LANG`.

If boot fails, the error includes the tail of `console.log`.

## Cleanup

`dynocap destroy demo --force` (or `dynocap rm demo --force`) terminates active execs and calls
`VZVirtualMachine.stop` on the host. It deletes the sandbox directory only
after confirmed teardown. Failures remain visible as `stopping` and are retried.

A killed daemon takes its VMs with it. The next command starts a daemon with
a new token and rewrites stale `running` records to `stopped` with the message
`reaped leftover VM after daemon exit`. `run --name` replaces a stopped or
failed VM of that name. A second daemon refuses to start while the lock file
is held.

`dynocap daemon` runs in the foreground for debugging. The CLI otherwise
spawns it detached (`DYNOCAP_DETACH=1`) and waits until the socket answers.

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
python3 scripts/test-terminal-macos.py
python3 scripts/test-journey-macos.py
python3 scripts/validate-runtime-task.py --all
```

`test-terminal-macos.py` drives `exec -t` and `shell` from a host PTY: input,
resizing, Ctrl-C, TTL warnings and expiry, and host terminal restoration after
every exit path. `test-journey-macos.py` follows the [quick start](#quick-start)
with `testdata/journey-project`: doctor, preparation, a networked install, an
offline sandbox, exec, shell, logs, diff, finish, applying the patch, and
cleanup, checking that the source checkout is unchanged. Both prepare a node:24
runtime (seeded from `~/.dynocap/cache`) and need internet for verified inputs
and the npm registry. `validate-runtime-task.py` prepares each runtime, warms
its dependency seed under filtered egress, checks that only that runtime's
registry resolves, installs and tests offline from the seed, and clones a
repository URL under filtered egress.

The smoke test uses a temporary home and its own daemon. It checks no NIC/routes
by default, outbound TCP denial, NAT DHCP and public HTTP reachability, real SDK
and MCP policy behavior, and TTL termination of active commands, including a
noisy command whose client stops reading output. It needs
internet for the explicit NAT test. Override the image directory with
`--images /path/to/images`; it never rewrites the source image or touches your
existing daemon. Unit tests also cover malformed policy requests, legacy daemon
rejection, expiry during boot/exec, late callbacks, and teardown failure/retry.

## Boot time

`run` returns when the guest agent answers. On this Apple Silicon Mac, 13
November 2026, with the daemon already up, the image in the page cache, and a
runtime that had already been verified:

| Command                                            | Median | Runs |
| -------------------------------------------------- | -----: | ---: |
| `dynocap run`                                      | 299 ms |    6 |
| `dynocap clone` of a one-file directory, `shell:1` | 491 ms |    3 |
| `dynocap clone` of this repository (387 files)     | 989 ms |    2 |
| `dynocap diff` of that clone                       | 882 ms |    2 |
| `dynocap exec NAME -- true`                        |  12 ms |    3 |

The first clone after a runtime disk changes also reads that disk (about 270 ms
for the 512 MB `shell:1` runtime). That disk is not the boot image. Preparation, `npm ci`, and a cold Mac are not
in the table. The method, the earlier 185 ms kernel (it cannot mount a task
disk), and the before/after breakdown are in
[docs/research/boot-time.md](docs/research/boot-time.md).

The unit tests still do not boot a VM. If `run` times out, read
`~/.dynocap/vms/<name>/console.log` and `~/.dynocap/daemon.log`.

## Layout

```
Package.swift                 SwiftPM (CLI + portable core + macOS backend)
Sources/DynoCapCore           protocol, CLI, daemon, state
Sources/DynoCapVZ             Virtualization.framework
Sources/dynocap               main
guest/agent                   static Linux agent
guest/mkimage                 kernel/initrd builder
guest/internal/protocol       guest wire codec
guest/internal/image          pins, cpio, zboot unwrap
entitlements/dynocap.entitlements
scripts/build-macos.sh
scripts/fetch-image.sh
testdata/protocol-vectors.json
```

## License

Apache 2.0. See [LICENSE](LICENSE).

## Agent task loop

The Node 24 project/task/result path, runtime preparation, SDK/MCP usage and
retention limits are documented in the [Agent task workflow tutorial](docs/tutorials/agent-task-workflow.mdx). Runtime tools
are read-only, workspaces are copied, and finalization exports results before
sandbox destruction.
