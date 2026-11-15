# Boot time

Measured 9 Nov 2026 on an Apple Silicon Mac, macOS 27.0.1 (26A434). The number is wall-clock time for `dynocap run` to return, with the daemon already up and the kernel and initrd already in the page cache. `run` returns when the guest agent sends hello on vsock, which is when `exec` can start. Each sample is one sandbox, then `destroy`. Memory is 1024 MB and the guest has 1 vCPU unless a row says otherwise.

## Result

| Image                                                           | Median |    Min |    Max |              Runs |
| --------------------------------------------------------------- | -----: | -----: | -----: | ----------------: |
| Alpine 6.18.62 virt kernel, full minirootfs, 200 ms vsock retry | 374 ms | 370 ms | 397 ms | 4, after a warmup |
| Same kernel, 10 ms retry, pruned initrd                         | 290 ms | 282 ms | 304 ms |                 6 |
| Linux 6.12.46, virtio built in, pruned initrd, 10 ms retry      | 185 ms | 179 ms | 197 ms |                 8 |

On 9 November the 185 ms image was what `~/.dynocap/images/aarch64` booted. `./scripts/fetch-image.sh` writes the Alpine kernel back, and that path measured about 290 ms. It is the image again; the 13 November section below is the current measurement.

A single sample of daemon startup, before any sandbox, was 13 ms until the socket accepted a connection. The first `exec true` after `run` returned was about 10 ms.

Guest `/init` on the kernel's own clock:

| Image                  |   Unpacking initramfs | Freeing initrd | Run `/init` |
| ---------------------- | --------------------: | -------------: | ----------: |
| Alpine, 5.2 MB initrd  |                 37 ms | 107 ms (5080K) |      123 ms |
| Alpine, 1.9 MB initrd  |                 37 ms |  66 ms (1940K) |       77 ms |
| 6.12.46, 1.9 MB initrd | (console starts late) |              — |    33–41 ms |

Firecracker's specification says a microVM with 1 vCPU, 128 MiB, a tuned kernel, and the serial console disabled reaches `/sbin/init` within 125 ms of `InstanceStart`. That number does not include userspace past init, and it is not a Virtualization.framework measurement. On this Mac the 6.12.46 guest reaches `/init` in about 40 ms. The other ~140 ms is the host, before that guest clock is that far along. Apple's container runtime documents sub-second starts and, in the WWDC25 demo, a shell in a few hundred milliseconds. A third-party comparison on macOS 26 put Apple Container cold start near 0.8–0.9 s. Those are different workloads.

## Where the 374 ms went

Host timestamps from one Alpine boot, relative to `run`:

| Mark                                                                                |   Time |
| ----------------------------------------------------------------------------------- | -----: |
| CPU, memory, bootloader, NAT, console, vsock config, `validate`, `VZVirtualMachine` |   1 ms |
| `vm.start` completion                                                               | 128 ms |
| First vsock connect issued                                                          | 128 ms |
| That connect fails                                                                  | 149 ms |
| Hello, after the 200 ms retry                                                       | 363 ms |

`vm.start` is the only expensive host call. Skipping NAT, the entropy device, or the serial console, and toggling `quiet`, `nokaslr`, and `mitigations=off`, all stayed within a few milliseconds of 374 ms. 128 MB and 1024 MB were the same. A 64-byte initrd did not move the `vm.start` completion time (still ~132 ms), so initrd size is not that 128 ms.

The guest was ready during the 200 ms sleep. Connect retries on the Alpine image:

| Retry | Median `run` | Failed connects in the trace |
| ----: | -----------: | ---------------------------: |
|  0 ms |       316 ms |                           29 |
|  5 ms |       318 ms |                            8 |
| 10 ms |       325 ms |                            6 |
| 15 ms |       317 ms |                            5 |
| 20 ms |       327 ms |                            4 |
| 50 ms |       374 ms |                            3 |

10 ms is what the host uses now. Faster polling did not lower the median, and 0 ms spent the whole wait in failed connects.

On the pruned Alpine image, with the 10 ms retry, the console watcher placed the agent's "listening" line at 281 ms and `run`'s return at 290 ms. The connect is no longer the gap.

## Initrd

The old initrd was a full Alpine minirootfs. Gzip 5.2 MB, 11.3 MB uncompressed, 531 files. The largest files were `libcrypto` (4.5 MB), the static agent (2.1 MB), busybox (0.9 MB), and `libssl` (0.9 MB). The agent is a static Go binary. Busybox needs only musl.

`pruneRoot` keeps busybox and its applet symlinks, the musl loader, the agent, the virtio modules, and the udhcpc script. The packed initrd is 1.9 MB gzip, 4.3 MB uncompressed. Unpacking is why `/init` moved from 123 ms to 77 ms. The kernel's initcall list on the Alpine kernel summed to 86 ms (575 calls). The long ones were the built-in X.509 list (20 ms), virtio-pci (10 ms), and a handful of 5–7 ms calls. None of those is a single lever left on that kernel.

## The 6.12.46 kernel

Built locally from linux 6.12.46 with `ARCH=arm64 LLVM=1`. Virtio-pci, virtio-net, virtio-console, virtio-vsock, `AF_PACKET`, and `RTC_DRV_PL031` plus `RTC_HCTOSYS` are built in. The `Image` is 6.7 MB. Alpine's virt `Image` is 35 MB and its drivers for vsock and net are modules.

On this kernel, a script whose interpreter is a symlink fails with `ENOEXEC` (`Failed to execute /init (error -8)`). `/bin/sh` is a symlink to busybox. The shebang is `#!/bin/busybox sh`, and `/bin/busybox` is a regular file. `date -u` inside the guest matched the host clock.

The initrd still lists the Alpine 6.18 modules. `insmod` fails because those objects do not match this kernel, then the agent starts. The devices are already built in. `fetch-image.sh` does not build this kernel. The source tree used for it is `/tmp/dynocap-kbuild`.

## 13 November 2026, same Mac

The image in `~/.dynocap/images/aarch64` is Alpine 6.18.62 again (35 MB kernel, 2.9 MB initrd). The 6.12.46 `Image` is still at `/tmp/dynocap-kbuild/linux-6.12.46/arch/arm64/boot/Image`, and its config has virtio-vsock, virtio-net, and virtio-console built in. It does not have `EXT4_FS` or `VIRTIO_BLK`, so it cannot mount a task workspace. It was not put back on the task path.

Raw `dynocap run` (daemon already up, 1 vCPU, 1024 MB, page cache warm), six runs after one warmup: median **299 ms**, min 291, max 306. The next `exec true` median was 11 ms. The guest clock reached `/init` at 86 ms and the agent logged listening at about 99 ms. That matches the earlier Alpine row, not the 185 ms kernel.

A prepared `shell:1` task is a different number, because clone also checks the runtime disk, builds a workspace image, and imports the tree. Before the changes below, a one-file directory on this Mac (three runs):

| Stage                                                         |  Median |
| ------------------------------------------------------------- | ------: |
| clone, wall clock                                             |  961 ms |
| snapshot, including a full SHA-256 of the 512 MB runtime disk |  461 ms |
| workspace `mke2fs` of an 8 GiB sparse disk, after snapshot    |  102 ms |
| boot, including `switch_root` onto the runtime                |  383 ms |
| `diff` of an unchanged tree                                   | 1233 ms |
| `finish`                                                      |  210 ms |

The runtime hash alone was 272 ms median over three reads (512 MB apparent, 59 MB allocated). `diff` spent that second in the guest starting Git to evaluate ignore rules for a tree that had no new files. Reviewing this repository's 387 files, with one `git hash-object` process per file, took **11.94 s** on the host for an identical tree. Importing that repository failed: a 2.9 MB stdin upload arrived with a different SHA-256 on six of six attempts (`archive/tar: invalid tar header`).

What changed, and the medians after:

| Change                                    | Plain directory, n=3 | This repo, 387 files, n=2 |
| ----------------------------------------- | -------------------: | ------------------------: |
| clone                                     |               491 ms |                    989 ms |
| snapshot                                  |                73 ms |                    589 ms |
| workspace disk (overlapped with snapshot) |               154 ms |                    132 ms |
| boot                                      |               321 ms |                    340 ms |
| upload                                    |                 3 ms |                     51 ms |
| start, guest ready                        |               481 ms |                    979 ms |
| diff                                      |               235 ms |                    882 ms |
| finish                                    |               182 ms |                    987 ms |

The runtime disk is hashed when its size, inode, or mtime differs from the last match. The workspace format runs while the tree is packed. Review hashes each tree with one `git hash-object --stdin-paths` instead of one process per file; the same 387-file identical review dropped from 11.94 s to 0.97 s. Git ignore in the guest starts only when a path is outside the imported set. Stdin frames that do not fit in the guest pipe used to let a later frame pass an older parked one, so a multi-megabyte upload was reordered. After that fix, the same 2.9 MB tar matched the host SHA-256 on four of four transfers, and clone of this repository completed.

Boot is the largest remaining piece of a small clone, about 320 ms, and it did not move. The open 140 ms inside `VZVirtualMachine.start` is still there. A further kernel build only pays off for tasks if ext4 and virtio-blk are built in; the 6.12.46 config is not that kernel.

These task numbers use a private `DYNOCAP_HOME` and a copy of the prepared `shell:1` disk with the rebuilt agent written into it. The copy is not `~/.dynocap`. A runtime prepared before this change still has the previous agent until it is prepared again.

## 15 November 2026, same Mac

Same Alpine 6.18.62 image. Numbers are medians of `clone --runtime shell:1` with the daemon up, one warmup discarded, results purged after each run. Baseline and changed binaries were run alternately against one private home. Host marks are timestamps of console bytes as they reached the daemon; guest marks are `/dev/kmsg` lines added to a scratch copy of the init scripts.

A raw `run` was 288 ms. `vm.start` completed at about 120 ms, `Run /init` arrived at about 256 ms, the agent's listening line at 265 ms and hello at 272 ms. Padding the kernel file from 36 MB to 72 MB moved `vm.start` by under 10 ms and `Run /init` not at all, so file size is not the pre-kernel gap. Hello came a median 4.9 ms (max 12.6 ms, n=45) after the listening line.

A task boot spent 53 ms between `Run /init` and listening, against 9 ms for a raw boot:

| Guest step                                                   | Before | After |
| ------------------------------------------------------------ | -----: | ----: |
| initramfs: virtio_blk, crc16, mbcache, jbd2, ext4 `insmod`   |  20–30 |  same |
| task init: mount the workspace (vdb), host `.full` sync      |    8.9 |   0.9 |
| task init: vsock `insmod` again, every call failing (EEXIST) |    4.3 |     — |

On the host, three things were serial or stalled:

- `mke2fs` of the 8 GiB workspace took 90–160 ms. Clone blocked on it for a median 39 ms (max 106 ms) after the snapshot. An APFS clone of a formatted copy took 0.2 ms.
- `Process.waitUntilExit` returned in 0.1 ms on most companion calls and in 65–67 ms on about one in four, after the child had closed its pipes.
- `pack` of a one-file directory without Git took 52 ms, 34 ms of it `git init` and `check-ignore` for a tree with no `.gitignore`. A Git repository took 19 ms.

For this repository (342 files, 78 commits), `import-git` was 428 ms of a 540 ms snapshot: copying `.git` 90–160 ms, `fsck --full` 130 ms, ref deletion, reflog expiry, `repack -a -d` and `prune` together 230 ms. Boot started only after it.

What changed:

- The workspace disk is cloned from a template formatted once per daemon start, and attached with `synchronizationMode: .none`. The file is deleted when the daemon restarts and results leave through the agent, so host flushes protected nothing.
- The task init no longer reloads vsock.
- Companion calls wait on the termination handler.
- Ignore rules are evaluated only below a directory holding a `.gitignore`. The scratch repository has no other rule source; packed tars were byte-identical before and after for a plain directory, a Git directory, and this repository.
- The sandbox boots while the host packs the tree and sanitizes history, and history import runs beside tree packing. A failed or cancelled snapshot waits for that boot, then cleanup destroys it. The cancellation message now names `import and boot`.

| Clone                                                |  Before |  After |
| ---------------------------------------------------- | ------: | -----: |
| one-file directory, wall clock                       |  530 ms | 349 ms |
| this repository, wall clock                          | 1006 ms | 538 ms |
| this repository, snapshot                            |  628 ms | 492 ms |
| this repository, boot not hidden behind the snapshot |  333 ms |   0 ms |

The imported tree of this repository matched the host's 342 file hashes, and its history kept 78 commits and the same HEAD. `test-journey-macos.py` and `test-isolation-macos.py` passed on the changed build. A runtime prepared before this change keeps the second vsock load until it is prepared again.

## What is still open

Snapshot restore and a warm pool are not measured. The ~140 ms before the guest clock moves is inside `VZVirtualMachine.start` and did not fall in proportion to kernel size. A kernel with vsock, virtio-blk and ext4 built in would remove the 20–30 ms of `insmod` on the task path; the 6.12.46 build measured 185 ms raw but had neither ext4 nor virtio-blk. For a repository, `import-git` is now the critical path; `fsck --connectivity-only` and cloning `.git` with `clonefile` are untested. `admit` reads every retained task directory to check the result quota, about 0.17 ms per retained task. Outbound DHCP was not timed as a lease; on the Alpine kernel `udhcpc` failed immediately with `socket(AF_PACKET): Address family not supported by protocol`, and that call is no longer on the way to the agent.

## Sources

- Firecracker specification, boot-time clause: <https://github.com/firecracker-dynocap/firecracker/blob/main/SPECIFICATION.md>
- Apple containerization, sub-second start and `vminitd`: <https://github.com/apple/containerization>
- WWDC25 session 346, shell in a few hundred milliseconds: <https://developer.apple.com/videos/play/wwdc2025/346/>
