# MicroVM

Local Linux sandboxes for agents. One daemon on a host owns them. Callers boot a sandbox, run commands inside it, and destroy it.

## The sandbox

**Sandbox**:
A named Linux guest with its own CPU, memory, and disk, owned by one daemon.
_Avoid_: VM, container, box, instance

**Phase**:
Where a sandbox is in its life: booting, running, stopping, stopped, or failed.
_Avoid_: status, state

**Disk**:
A sandbox's root filesystem.
_Avoid_: volume, drive, image

**Dev box**:
A sandbox whose disk outlives the running guest, and which sleeps while idle.
_Avoid_: persistent VM, sleeping container

**Snapshot**:
A saved guest that can become a running sandbox without a cold boot.
_Avoid_: checkpoint, image

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
_Avoid_: job, task, process

**TTL**:
A sandbox’s finite lifetime, counted from creation and including boot. Activity does not renew it.
_Avoid_: timeout, lease

**Workspace**:
The file tree a sandbox works on.
_Avoid_: home, repo, volume

**Fork**:
A copy-on-write clone of a workspace.
_Avoid_: snapshot, branch

**Preview**:
An address that reaches one port of a sandbox.
_Avoid_: tunnel, ingress

**Network mode**:
Whether a sandbox is offline, filtered to the install and public-clone allowlist, or unrestricted.

**Egress**:
Which outbound destinations a sandbox may open.
_Avoid_: firewall, NAT
