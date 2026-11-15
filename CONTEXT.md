# DynoCap

Local Linux sandboxes for agents. One daemon on a host owns them. Callers boot a sandbox, run commands inside it, and destroy it.

## The sandbox

**Sandbox**:
A named Linux guest with its own CPU and memory, owned by one daemon.
_Avoid_: VM, container, box, instance

**Task**:
A sandbox working on one copied project. It has a workspace and a runtime, and finish can leave a result after the sandbox is gone.
_Avoid_: job, session, environment

**Phase**:
Where a sandbox is in its life: booting, running, stopping, stopped, or failed.
_Avoid_: status, state

**Dev box**:
A sandbox whose disk outlives the running guest, and which sleeps while idle.
_Avoid_: persistent VM, sleeping container

**Snapshot**:
A saved guest that can become a running sandbox without a cold boot.
_Avoid_: checkpoint, image, the import of a project

**Warm pool**:
Sandboxes already booted and waiting to be claimed.
_Avoid_: cache, fleet

**Daemon**:
The single process that owns the running sandboxes for one home.
_Avoid_: server, supervisor, runtime

**Home**:
The directory that holds a daemon's socket, images, and sandbox records.
_Avoid_: workspace, config, state dir

**Host**:
The computer whose daemon owns the sandboxes.
_Avoid_: node, server, box

**Runtime**:
A prepared, read-only language toolchain disk a task boots with, selected as NAME:VERSION, such as node:24 or shell:1. It declares its package registry and dependency cache.
_Avoid_: image, language, stack

**Dependency seed**:
The host copy of one runtime's package cache, keyed by the project's lockfile, restored into later tasks.
_Avoid_: npm cache, artifact, image

**Image**:
The kernel and initramfs a sandbox boots, one per host architecture.
_Avoid_: rootfs, template, snapshot

**Guest agent**:
The process inside a sandbox that accepts execs and returns their output and exit status.
_Avoid_: init, sidecar

**Reap**:
A sandbox marked stopped because the daemon that owned it is gone.
_Avoid_: garbage collection, cleanup

## Working inside a sandbox

**Exec**:
One command running inside a sandbox, with its own arguments, working directory, environment, and deadline.
_Avoid_: job, process

**TTL**:
A sandbox’s finite lifetime, counted from creation and including boot. Activity does not renew it. An exec deadline is a different clock.
_Avoid_: timeout, lease

**Workspace**:
The copied project tree a task works on. It is not the checkout on the host.
_Avoid_: home, repo, volume, mount

**Result**:
What finish keeps on the host after the sandbox is destroyed. Its clock starts when the task is created.
_Avoid_: snapshot, artifact, the sandbox itself

**Fork**:
A copy-on-write clone of a workspace.
_Avoid_: snapshot, branch

**Preview**:
An address that reaches one port of a sandbox.
_Avoid_: tunnel, ingress

**Network mode**:
Which NIC a sandbox gets: `none` (no NIC), `filtered` (HTTPS only to that runtime's registry, plus the Git host of a URL clone), or `nat` (unrestricted outbound).
_Avoid_: offline, unrestricted, and allowlist as names of the mode

**Egress**:
Which outbound destinations a filtered sandbox may open.
_Avoid_: firewall, calling that list NAT
