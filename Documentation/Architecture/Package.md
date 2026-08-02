# Package

Computer MCP is a SwiftPM macOS package that builds an internal gateway
implementation target, the `computer-mcp` CLI/bridge, and the native SwiftUI
App executable. Only the App and CLI are package products.

## Constraints

- Swift tools 6.2 and macOS 14 or newer.
- SwiftPM is the build and test entry point.
- Build, test, and release scripts consistently use SwiftPM's
  `--build-system native` implementation so one cache layout is produced.
- The release is a current-user App with Hardened Runtime and no App Sandbox.
- Generated `.doccarchive` output is not committed.

## Dependencies

| Package | Role |
| --- | --- |
| official MCP Swift SDK 0.12.1 | MCP server/client protocol and transports |
| ArgumentParser | CLI parsing |
| swift-toml and Yams | TOML config and Skill YAML frontmatter |
| SwiftNIO | HTTP and Unix-socket transport adapters |
| swift-subprocess | Process, Shell, and streaming lifecycle |
| GRDB | Transactional App metadata and redacted audit |
| swift-log | Runtime logging integration |
| `swift-codex` 0.1.1 (exact remote version) | Codex App Server, Exec, and MCP clients |

## Structure

| Path | Role |
| --- | --- |
| `Package.swift` | App/CLI products, internal targets, tests, and dependency graph |
| `Sources/ComputerMCP/` | Gateway core, transports, providers, policy, persistence, tunnel, and App Control Plane |
| `Sources/computer-mcp/` | Thin CLI and stdio bridge entry point |
| `Sources/ComputerMCPApp/` | SwiftUI control center and menu-bar lifecycle |
| `Resources/ComputerMCPApp/` | Bundle metadata and entitlements |
| `Tests/` | Swift Testing component, policy, transport, App, and provider tests |
| `Tools/Validation/` | Independent Test Case catalog, probes, fixtures, evidence correlation, and reports |
| `Sources/ComputerMCP/ComputerMCP.docc/` | Internal target documentation |
| `Examples/` | Standalone development and dogfood manifests |
| `Scripts/` | App build, DMG, notarization, and distribution verification workflows |

The release scripts assemble the SwiftPM App executable and embedded CLI into a
standard `.app`, sign both code objects, and package the bundle in a DMG.

`Tools/Validation` is not a root target and is not included in the App or DMG.
Real external consumers and tunnels are Validation Runs, never automated tests.

## Principles

- Keep executable targets thin; shared product behavior belongs in the internal
  `ComputerMCP` implementation target.
- Keep side effects behind provider and transport adapters.
- Delegate MCP framing and semantics to the official SDK.
- Use `swift-codex` instead of hand-writing Codex protocols.
- Keep App bookmarks, Keychain secrets, and runtime state out of TOML.
- Keep public behavior aligned across README, reference docs, DocC, and tests.

The root package resolves `swift-codex` from its public repository at exact
version `0.1.1`. `Scripts/verify-swift-codex-release-gate.sh` prevents a local
path, branch, revision, or different version from entering a release.
