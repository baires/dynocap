---
name: dynocap
description: >
  Run work in a local DynoCap Linux sandbox on macOS. Use when the user wants a
  disposable guest, a copied project, a verified patch, or to run untrusted
  commands, tests, or installs away from the host checkout, or when the DynoCap
  CLI, @dynocap/sdk, or DynoCap MCP tools (dynocap_task_start,
  dynocap_task_exec, dynocap_diff, dynocap_task_finish) are available.
license: Apache-2.0
compatibility: >
  macOS 13 or newer with Virtualization.framework; project tasks need Apple
  Silicon. Needs the dynocap CLI on PATH or the DynoCap MCP server connected.
---

# DynoCap

DynoCap is a local Linux sandbox on a Mac. One daemon per user owns the guests. The CLI, the TypeScript SDK, and the MCP server all talk to that daemon. There is no host directory mount and no network device unless the user asks for one.

## When to use it

Use a task when the work is a project: tests, installs, refactors, or an agent edit that should come back as a patch. Use a raw sandbox (`dynocap run`) only for a command that does not need the project tree.

Do not use Docker, a host bind mount, or the user's checkout as the place untrusted commands run.

## Rules

- Apple Silicon and macOS 13 or newer for project tasks. The raw sandbox also documents Intel.
- Offline is the default. `filtered` is HTTPS to that runtime's registry only. `nat` is open outbound. Ask before either.
- The workspace is a copy. Never tell the user their checkout was edited. `finish` exports a patch. The user applies it.
- TTL starts at creation, includes boot, and activity does not extend it. Default is 30 minutes. Unexported work is discarded at expiry.
- `@dynocap/sdk` and `@dynocap/mcp` ship in this repository. They are not on the public npm registry. Do not invent an `npm install` for them.
- The Homebrew tap `dynocap/tap/dynocap` and `npx skills add dynocap/dynocap` are the intended install lines. If `dynocap` is not on `PATH`, say so and point at a source build (`./scripts/build-macos.sh`) instead of pretending the tap already resolved.

## CLI

```sh
dynocap doctor --fix ./project
dynocap clone ./project demo
dynocap exec demo -- npm test
dynocap diff demo
dynocap finish demo
```

`doctor --fix` prepares the guest image and the runtime the project already uses: `package.json` is `node:24`, `pyproject.toml` (or `uv.lock`, `requirements.txt`) is `python:3.14`, `go.mod` is `go:1.27`, otherwise `shell:1`. `clone` does not prepare a runtime by itself.

`clone` is offline unless you pass `--network filtered` or `--network nat`. After a filtered install is finished, a later clone with the same lockfile can install with no network device.

For each task:

1. Run `doctor --fix` on the project. Fix what it reports and run it again until it passes.
2. `clone`, then `exec` the work. A non-zero exit is the guest command failing. Read stderr before retrying.
3. `diff` and read the patch. If it is wrong, `exec` again in the same task and diff again.
4. `finish` before the TTL runs out. Give the user the patch path it prints.

Also: `dynocap shell NAME`, `dynocap ls`, `dynocap inspect NAME`, `dynocap logs NAME`. Discard a live guest with `dynocap rm NAME --force`. Delete a kept result with `dynocap rm NAME --purge`.

## MCP

If the DynoCap MCP tools are connected, prefer them over shelling out.

| Tool                                                              | Use                                                                           |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `dynocap_task_start`                                              | Copy a local project or clone a repository into a task.                       |
| `dynocap_task_exec`                                               | Run one command in `/workspace`. Read stdout, stderr, and the exit code.      |
| `dynocap_diff`                                                    | Read the verified patch before keeping anything.                              |
| `dynocap_task_finish`                                             | Export the patch and logs, then destroy the guest.                            |
| `dynocap_ls`                                                      | List tasks.                                                                   |
| `dynocap_rm`                                                      | Release a name. `force` discards a live guest. `purge` deletes a kept result. |
| `dynocap_run` / `dynocap_exec` / `dynocap_ps` / `dynocap_destroy` | A raw guest with no project workspace.                                        |

`network` defaults to `none`. The server refuses `filtered` unless `DYNOCAP_MCP_ALLOW_FILTERED=1`, and refuses `nat` unless `DYNOCAP_MCP_ALLOW_NAT=1`. Do not tell the user to set those unless they asked for network.

The server is local. After a build it is `node sdk/mcp/dist/bin.js`, or the `dynocap-mcp` bin from that package. It speaks MCP over stdio.

## SDK

Use this when writing a program, not when the MCP tools are already available.

```ts
import { Task } from "@dynocap/sdk";

const task = await Task.start({
  name: "demo",
  projectPath: "./project",
  network: "none",
  ttlSeconds: 1800,
});

const result = await task.exec("npm test");
const preview = await task.diff();
const finished = await task.finish();
```

`Task.start` talks to `~/.dynocap/daemon.sock` (mode `0600`). `result.exitCode` is the guest status. `finished.patchPath` is on the host. The guest is gone after `finish`.

Link the package from this repo (`file:./sdk/typescript`) until it is published. A raw guest, with no project copy, is the `Sandbox` class: `Sandbox.create`, `exec`, `destroy`.

## Words

Say sandbox, task, daemon, runtime, workspace, and result. A task is a sandbox with a copied project. A result is what `finish` keeps after the guest is destroyed. The TTL is not a timeout, and the workspace is not the host checkout.
