# Contributing

This repository builds a macOS App and embedded CLI with SwiftPM. Keep changes
focused, buildable, and covered by tests when behavior changes.

## Development Setup

```sh
/usr/bin/swift build
/usr/bin/swift test
swift run computer-mcp --help
swift run computer-mcp serve http --help
Scripts/build-app.sh
```

Use macOS 14 or newer with Swift 6.2 or newer. Standalone development modes run
from SwiftPM; production lifecycle is owned by the App bundle.

Apply `.nativeIntegration` to test suites that launch native subprocesses or
exercise their ownership receipts. The trait admits four cases concurrently to
bound machine-wide process and I/O pressure; concurrency within each case and
existing suite serialization are preserved. Pure unit tests run independently.

## Contribution Expectations

- Keep the two executable products and internal implementation targets
  explicit in `Package.swift`; do not add a public library for test
  convenience.
- Add tests for config loading, gateway tool dispatch, CLI argv execution, MCP
  proxying, process lifecycle, and pure model behavior.
- Keep `cli.exec` input as an executable identifier plus `argv`; never convert
  it into shell string templating.
- Document source, profile, workspace, token, Tunnel, Codex, and provider
  behavior in both architecture and reference documentation.
- Keep root `README.md` concise and move exhaustive details to
  `Documentation/Reference/`.
- Do not check in generated `.doccarchive` files.

## Pull Requests

Before opening a pull request, run:

```sh
swift-format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests
swift-format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
/usr/bin/swift build
/usr/bin/swift test
swift run computer-mcp config validate --config Examples/computer-mcp.toml
```

If your change affects a CLI command, include the command output or a concise
summary in the pull request.

If your change affects a stable CLI, MCP, configuration, evidence, or release
contract, update the corresponding reference and DocC material.

## Repository closeout

Use the default branch for daily integration and a task branch or isolated
worktree for changes. Before cleanup, inspect local changes, worktree owners,
open pull requests and the accepted source revision. Preserve unrelated source,
credentials, runtime state and non-generated ignored files; never reset, clean
or stash another task's work to make a checkout appear clean.

After delivery, fast-forward only a clean integration checkout. Retire a task
branch only when its tip is in the accepted default branch or its exact head
matches a merged pull request whose merge is reachable there. Preserve unique
work with a documented reconciliation and independently verified recovery
bundle before retiring its directory. Remove owned worktrees through Git, or
through the managing application's archive operation for managed worktrees.

Build caches in the daily checkout may remain useful. Remove inactive duplicate
task caches, package staging and disposable test outputs after checking their
owner and running references. Preserve source inputs, immutable release
artifacts, necessary failure/acceptance evidence and required rollback state.
Keep local progress and recovery inventories under ignored `.agent/`; current
product behavior must remain understandable from committed documentation.

A merged source change, a validated package and a published release have
different identities. Record the exact source and artifact/check evidence at
handoff. Documentation or repository cleanup alone does not require a product
release; published tags and assets remain immutable. Active dependency-update
pull requests are reviewed maintenance work, not disposable cleanup residue.

For release-run outputs, use the preview and apply operations in
[Release](Documentation/Reference/Release.md#cleanup-and-recovery). The release
runner authenticates unchanged temporary output and retains candidate,
installation and delivery evidence. A refusal to clean changed or unrecognized
content is not permission to delete it manually.
