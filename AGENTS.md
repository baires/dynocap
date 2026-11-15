# Repository Guidelines

## Read the Relevant Docs

Use [docs/index.mdx](docs/index.mdx) to navigate the current documentation.
Read the relevant reference before changing a public contract:

- CLI behavior, errors, or JSON output: [CLI reference](docs/reference/cli/commands.mdx), [errors](docs/reference/cli/errors.mdx), and [schemas](docs/reference/cli/json-schemas.mdx).
- SDK or MCP behavior: [SDK API](docs/reference/sdk-api.mdx) and [MCP tools](docs/reference/mcp-tools.mdx).
- Host/guest protocol: [wire protocol](docs/reference/guest-wire-protocol.mdx).
- Runtime preparation, registry access, or dependency seeds: [dependency guide](docs/how-to/manage-dependencies-and-caching.mdx).
- Task finalization, retention, or Git import/export: [task lifecycle](docs/explanation/task-lifecycle-and-ttl.mdx) and [Git workspaces](docs/explanation/git-workspaces-and-patches.mdx).
- Isolation or networking: [security boundary](docs/explanation/security-and-isolation.mdx) and [egress guide](docs/how-to/network-isolation-and-egress.mdx).

Consult [CONTEXT.md](CONTEXT.md) for domain terminology before changing
architectural boundaries. Treat research as background; check current behavior
against the reference docs and implementation. Update the
relevant docs when behavior or contracts change.

## Project Structure & Boundaries

`Sources/dynocap` is the CLI entry point. `Sources/DynoCapCore` owns the CLI,
daemon, task lifecycle, runtime admission, dependency seeds, and protocols;
`Sources/DynoCapVZ` implements the macOS Virtualization.framework backend.
`guest/agent` runs guest commands; `guest/internal` holds protocol, image,
runtime, and workspace code. `guest/mkimage`, `guest/mkruntime`, and
`guest/workspace` provide the image builder and host companion tools.

`sdk/typescript` owns the daemon client; `sdk/mcp` calls that SDK rather than
implementing another socket client. Keep lifecycle, TTL, and deadline enforcement
in the daemon. Runtime recipes and pins in `guest/internal/runtime` declare
toolchains, registry hosts, and dependency-cache behavior through manifests;
keep package-manager knowledge there rather than in the daemon or egress code.

## Build, Test, and Development Commands

- Install tooling with `npm ci`, then `npm ci --prefix sdk/typescript` and `npm ci --prefix sdk/mcp` for the SDK packages.
- `./scripts/build-macos.sh`: build the release CLI and Go companions, then sign the CLI with the virtualization entitlement. Re-run after rebuilding before booting guests.
- `.build/release/dynocap doctor --fix`: build missing guest images, prepare the detected project runtime, and restart an outdated daemon. Pass `--runtime NAME:VERSION` to override detection. See [getting started](docs/tutorials/getting-started.mdx).
- Project workflow: `clone SOURCE NAME`, `exec NAME -- COMMAND`, `diff NAME`, then `finish NAME` to export results and destroy the sandbox. See the [task tutorial](docs/tutorials/agent-task-workflow.mdx); use the same release binary throughout.
- Raw sandbox workflow: `run --name demo`, `exec demo -- uname -a`, then `rm demo --force`.
- `npm run lint`: run SwiftLint and check Go formatting.
- `npm run typecheck`: compile both TypeScript packages.
- `npm test`: run Swift, Go, SDK, and MCP tests.

Real sandbox execution requires a virtualization-capable Mac with macOS 13+.
Building requires Swift 5.9+ and Go 1.22+; workspace/runtime disk preparation also
needs `mke2fs` from e2fsprogs. Use Node 22 to match CI tooling; host tooling versions
are separate from guest runtime selections.

## Coding Style & Naming Conventions

Follow `.editorconfig`: four spaces for Swift, tabs for Go, and two spaces for TypeScript, Markdown, JSON, and YAML. Use `gofmt`, SwiftLint, and Prettier; Prettier specifies double quotes and semicolons. Follow existing naming: `UpperCamelCase` types, `lowerCamelCase` Swift/TypeScript members, and idiomatic exported Go names. The pre-commit hook runs staged formatting, lint, typecheck, and tests.

## Testing Guidelines

Swift tests live in `Tests/DynoCapCoreTests`; Go tests live alongside guest code;
TypeScript tests live in each SDK package's `tests/` directory and use Node's test
runner. Add regression coverage for behavior changes. Protocol changes must keep
Swift, Go, and `testdata/protocol-vectors.json` aligned.

Unit tests do not boot real guests. For changes affecting sandbox behavior, build
the signed CLI, prepare the guest image, build the TypeScript packages, and run the
relevant real-guest checks:

- Virtualization, networking, TTL, or isolation: `python3 scripts/test-isolation-macos.py` (NAT needs internet).
- TTY, shell, signals, or terminal restoration: `python3 scripts/test-terminal-macos.py`.
- CLI task workflow, doctor, logs, diff, or finish: `python3 scripts/test-journey-macos.py`.
- Runtime recipes, manifest contracts, or dependency caching: `python3 scripts/validate-runtime-task.py --all`.

The terminal, journey, and runtime checks may download verified runtime inputs and
need registry access. See [README tests](README.md#tests) for setup and coverage.
Report checks that could not run and why.

## Commit & Pull Request Guidelines

Write concise, action-oriented commit subjects and keep commits focused. PRs
should describe behavior changes, link relevant issues, and report checks run,
including whether real sandbox tests ran.

## Invariants

Preserve offline-by-default networking, finite TTL measured from creation
(including boot, never renewed by activity), and isolation without host directory
sharing. Tasks attach a read-only runtime disk and a separate disposable workspace;
publish verified results before destroying the sandbox. Result retention starts at
task creation, not finish. Explain any change to these contracts explicitly.
