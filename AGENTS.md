# Agent Guide

Use this guide for agent work in this repository.

## Task Route

- For package work, inspect `Package.swift` before editing targets or products.
- For build, run, and test tasks, use SwiftPM commands from the repository root.
- For documentation work, keep the role boundaries in `Documentation/README.md`.
- For API documentation, keep DocC source with the target at
  `Sources/ComputerMCP/ComputerMCP.docc/`.
- For GitHub collaboration files, edit `.github/` or the root governance files,
  not repository architecture documents.

## Guardrails

- Keep the package buildable with `swift build` and tested with `swift test`.
- Do not introduce a dependency unless it removes real complexity and is
  documented in `Documentation/Architecture/Package.md`.
- Keep execution side effects behind gateway adapters such as CLI, Shell,
  process, MCP proxy, HTTP transport, Secure MCP Tunnel, Codex, Computer Use,
  and builtin runtimes.
- Codex App Server, Exec, and MCP are separate provider lifecycles implemented
  through `swift-codex`.
- Treat local tokens, CLI credentials, and downstream MCP authentication as
  user-owned secrets. Do not log, expose, or copy them into examples.
- Keep `shell.run` disabled by default unless the TOML policy explicitly enables
  it.
- Do not check in `.doccarchive` output. Generated DocC archives are build
  artifacts.
- Keep root `README.md` as the public manual. Put exhaustive CLI, protocol, tool,
  and troubleshooting details under `Documentation/Reference/`.

## Canonical Artifacts

- Treat conversation, review, plans, and intermediate attempts as editing
  input. Recompute the complete accepted result before finalizing.
- Active artifacts depend only on that result and their repository role, not
  on the editing path. Apply this to code, symbols, files, wrappers, branches,
  configuration, schemas, defaults, generated sources, scripts, templates,
  automation, comments, DocC, diagrams, tests, fixtures, snapshots, examples,
  and normative docs.
- If an intermediate result is `A + B` and the accepted result is `A`, express
  `A` directly. Remove `B` and its residual surface rather than retaining names
  such as `AOnly` or `AWithoutB`, or prose such as "B was removed."
- Normalize by semantic identity and artifact role, not by token. A rejected
  current capability does not invalidate a distinct historical fact,
  migration, ownership record, compatibility contract, safety boundary, or
  realistic regression fixture that uses the same term.
- Keep a negative constraint only when excluding `B` is independently required
  by a current compatibility, safety, ownership, or regression invariant.
- A disabled B flag, skipped B test, dead B branch, retained B fixture, or "do
  not add B" rule is residue when it exists only because B was attempted;
  disabled state alone is not an invariant.
- Keep change history only in commits, pull requests, changelogs, release
  records, migrations, archives, or accepted decision records with durable
  value. Do not create a history artifact merely to preserve a correction.
- Preserve role-owned facts unless separate evidence changes them; do not
  rewrite history or ownership merely to make a rejected term disappear.
- Leave an already-correct history, migration, provenance, ownership, or safety
  artifact unchanged when the task does not change its facts. Do not polish or
  restate it merely because it is relevant to the current edit.
- Comments document non-obvious current semantics such as invariants, units,
  ownership, lifecycle, side effects, failure behavior, and concurrency. They do
  not narrate the editing process.
- Before handoff, verify that a new agent with no editing conversation can
  derive the complete current behavior, boundaries, and operating guidance
  without mentally subtracting a rejected concept.

## Validation

Before finishing code changes, run:

```sh
swift-format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests
swift-format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
/usr/bin/swift build --build-system native
/usr/bin/swift test --build-system native
```

For user-facing CLI behavior, also run the relevant command directly, such as:

```sh
swift run computer-mcp --help
swift run computer-mcp serve http --help
swift run computer-mcp bridge --help
swift run computer-mcp config validate --config Examples/computer-mcp.toml
swift run computer-mcp tools list --config Examples/computer-mcp.toml
Scripts/build-app.sh
```
