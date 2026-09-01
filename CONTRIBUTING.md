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
