# Repository Guidelines

## Project Structure & Module Organization

`Sources/microvm` contains the CLI entry point, `Sources/MicroVMCore` the portable daemon and protocols, and `Sources/MicroVMVZ` the macOS Virtualization.framework backend. `guest/agent` implements the Go guest agent; `guest/internal` contains protocol and image-building code. TypeScript packages live in `sdk/typescript` and `sdk/mcp`, with tests alongside each package. Swift tests live in `Tests/MicroVMCoreTests`; shared protocol fixtures are in `testdata/protocol-vectors.json`. Build and smoke-test scripts live in `scripts/`. Consult `CONTEXT.md` for domain terminology and `docs/adr/` when changing architectural boundaries.

## Build, Test, and Development Commands

- `npm ci`: install root tooling and configure Husky hooks; install each SDK package's dependencies separately when needed.
- `./scripts/build-macos.sh`: build the release CLI and sign it with the virtualization entitlement. Re-sign after rebuilding before booting guests.
- `./scripts/fetch-image.sh`: download verified Alpine artifacts and build the host architecture's guest image.
- `.build/release/microvm run --name demo`: start a local sandbox; use `exec demo -- uname -a` and `destroy demo` with the same binary.
- `npm run lint`: run SwiftLint and check Go formatting.
- `npm run typecheck`: compile both TypeScript packages.
- `npm test`: run Swift, Go, SDK, and MCP tests.

Real sandbox execution requires macOS 13+, Swift 5.9+, and Go 1.22+. CI uses Node 22; match CI for JavaScript tooling.

## Coding Style & Naming Conventions

Follow `.editorconfig`: four spaces for Swift, tabs for Go, and two spaces for TypeScript, Markdown, JSON, and YAML. Use `gofmt`, SwiftLint, and Prettier; Prettier specifies double quotes and semicolons. Follow existing naming: `UpperCamelCase` types, `lowerCamelCase` Swift/TypeScript members, and idiomatic exported Go names. The pre-commit hook runs staged formatting, lint, typecheck, and tests.

## Testing Guidelines

Use XCTest (`*Tests.swift`, `test...` methods), Go's testing package (`*_test.go`, `Test...` functions), and Node's test runner (`*.test.ts`). Add regression coverage for behavior changes; no numeric coverage threshold is configured. Protocol changes must keep Swift, Go, and shared golden vectors aligned. For virtualization or isolation changes, also run `python3 scripts/test-isolation-macos.py` after building the signed CLI, images, and TypeScript packages; its NAT check needs internet access.

## Commit & Pull Request Guidelines

History is short and mixes imperative subjects with `feat:` prefixes. Write concise, action-oriented subjects and keep commits focused. PRs should describe behavior changes, link relevant issues, and report checks run, including whether real sandbox tests ran. Preserve offline-by-default networking and finite TTL semantics; explain changes to either explicitly.
