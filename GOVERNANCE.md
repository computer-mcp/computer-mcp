# Governance

Computer MCP is maintained as a macOS App and embedded CLI built with SwiftPM.
It does not promise a general-purpose Swift library API.

Xudong Xu is the legal copyright-holder name. `@showxu` is the public GitHub
and product identity used for repository ownership and CODEOWNERS.

## Maintainer Responsibilities

- Keep the package buildable and testable with SwiftPM.
- Review changes that affect command execution, shell enablement, downstream MCP
  proxying, HTTP transport or bearer authentication, token handling,
  coding-provider execution, and Secure MCP Tunnel launch behavior carefully.
- Keep current architecture truth under `Documentation/Architecture/`.
- Keep reference behavior under `Documentation/Reference/`.
- Keep GitHub collaboration configuration in `.github/`.

## Decision Records

Accepted technical decisions live in `Documentation/Decisions/`. Architecture
documents must still state the current truth after a decision is accepted.

## Release and Versioning

The package exposes only the `ComputerMCPApp` and `computer-mcp` executable
products. Release versions are aligned between `ComputerMCPCLI`, the App
`Info.plist`, signed tags, DMG names, release notes, and checksums.

Release tags are immutable. A defect after `v1.0.0` is fixed in `v1.0.1`; the
existing tag and GitHub Release are never moved or overwritten.
