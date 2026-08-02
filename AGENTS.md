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
- Keep Codex App Server, Exec, and MCP as separate provider lifecycles using
  `swift-codex`; do not restore a hand-written coding provider.
- Treat local tokens, CLI credentials, and downstream MCP authentication as
  user-owned secrets. Do not log, expose, or copy them into examples.
- Keep `shell.run` disabled by default unless the TOML policy explicitly enables
  it.
- Do not check in `.doccarchive` output. Generated DocC archives are build
  artifacts.
- Keep root `README.md` as the public manual. Put exhaustive CLI, protocol, tool,
  and troubleshooting details under `Documentation/Reference/`.

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
