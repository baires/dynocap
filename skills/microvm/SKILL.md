---
name: microvm
description: >
  Run work in a local MicroVM Linux sandbox on macOS. Use when the user wants a
  disposable guest, a copied project, a verified patch, or when the MicroVM CLI,
  @microvm/sdk, or MicroVM MCP tools (microvm_task_start, microvm_task_exec,
  microvm_diff, microvm_task_finish) are available.
---

# MicroVM

MicroVM is a local Linux sandbox on a Mac. One daemon per user owns the guests. The CLI, the TypeScript SDK, and the MCP server all talk to that daemon. There is no host directory mount and no network device unless the user asks for one.

## When to use it

Use a task when the work is a project: tests, installs, refactors, or an agent edit that should come back as a patch. Use a raw sandbox (`microvm run`) only for a command that does not need the project tree.

Do not use Docker, a host bind mount, or the user's checkout as the place untrusted commands run.

## Rules

- Apple Silicon and macOS 13 or newer for project tasks. The raw sandbox also documents Intel.
- Offline is the default. `filtered` is HTTPS to that runtime's registry only. `nat` is open outbound. Ask before either.
- The workspace is a copy. Never tell the user their checkout was edited. `finish` exports a patch. The user applies it.
- TTL starts at creation, includes boot, and activity does not extend it. Default is 30 minutes. Unexported work is discarded at expiry.
- `@microvm/sdk` and `@microvm/mcp` ship in this repository. They are not on the public npm registry. Do not invent an `npm install` for them.
- The Homebrew tap `microvm/tap/microvm` and `npx skills add microvm/microvm` are the intended install lines. If `microvm` is not on `PATH`, say so and point at a source build (`./scripts/build-macos.sh`) instead of pretending the tap already resolved.

## CLI

```sh
microvm doctor --fix ./project
microvm clone ./project demo
microvm exec demo -- npm test
microvm diff demo
microvm finish demo
```

`doctor --fix` prepares the guest image and the runtime the project already uses: `package.json` is `node:24`, `pyproject.toml` (or `uv.lock`, `requirements.txt`) is `python:3.14`, `go.mod` is `go:1.27`, otherwise `shell:1`. `clone` does not prepare a runtime by itself.

`clone` is offline unless you pass `--network filtered` or `--network nat`. After a filtered install is finished, a later clone with the same lockfile can install with no network device.

Also: `microvm shell NAME`, `microvm ls`, `microvm inspect NAME`, `microvm logs NAME`. Discard a live guest with `microvm rm NAME --force`. Delete a kept result with `microvm rm NAME --purge`.

## MCP

If the MicroVM MCP tools are connected, prefer them over shelling out.

| Tool                                                              | Use                                                                           |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `microvm_task_start`                                              | Copy a local project or clone a repository into a task.                       |
| `microvm_task_exec`                                               | Run one command in `/workspace`. Read stdout, stderr, and the exit code.      |
| `microvm_diff`                                                    | Read the verified patch before keeping anything.                              |
| `microvm_task_finish`                                             | Export the patch and logs, then destroy the guest.                            |
| `microvm_ls`                                                      | List tasks.                                                                   |
| `microvm_rm`                                                      | Release a name. `force` discards a live guest. `purge` deletes a kept result. |
| `microvm_run` / `microvm_exec` / `microvm_ps` / `microvm_destroy` | A raw guest with no project workspace.                                        |

`network` defaults to `none`. The server refuses `filtered` unless `MICROVM_MCP_ALLOW_FILTERED=1`, and refuses `nat` unless `MICROVM_MCP_ALLOW_NAT=1`. Do not tell the user to set those unless they asked for network.

The server is local. After a build it is `node sdk/mcp/dist/bin.js`, or the `microvm-mcp` bin from that package. It speaks MCP over stdio.

## SDK

Use this when writing a program, not when the MCP tools are already available.

```ts
import { Task } from "@microvm/sdk";

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

`Task.start` talks to `~/.microvm/daemon.sock` (mode `0600`). `result.exitCode` is the guest status. `finished.patchPath` is on the host. The guest is gone after `finish`.

Link the package from this repo (`file:./sdk/typescript`) until it is published. A raw guest, with no project copy, is the `Sandbox` class: `Sandbox.create`, `exec`, `destroy`.

## Words

Say sandbox, task, daemon, runtime, workspace, and result. A task is a sandbox with a copied project. A result is what `finish` keeps after the guest is destroyed. The TTL is not a timeout, and the workspace is not the host checkout.
