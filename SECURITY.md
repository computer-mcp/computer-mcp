# Security Policy

## Supported Scope

Security reports should cover this repository's Swift package, MCP protocol
handling, App socket and lifecycle, profiles/workspaces, CLI/MCP proxying, HTTP
transport, Secure MCP Tunnel, Computer Use, Codex provider paths, persistence,
logging, and documentation that could lead users to unsafe operation.

## Reporting a Vulnerability

Do not disclose suspected vulnerabilities publicly before maintainers have had
a chance to review them. Use
[GitHub private vulnerability reporting](https://github.com/computer-mcp/computer-mcp/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Include:

- affected version or commit
- reproduction steps
- expected and actual behavior
- security impact
- any relevant logs or payloads with secrets removed

## Execution Boundaries

`computer-mcp` runs registered local sources on behalf of an MCP client:

- CLI commands and local or remote MCP servers registered directly or through
  plugin contributions, under the same host policy and workspace boundaries.
- Builtins explicitly enabled in TOML.
- Optional Full Shell only when both manifest and local profile enable it.
- Codex execution through the independent MCP adapter, with host-owned tool
  grants, approvals and scoped services. Adapter configuration owns vendor
  execution settings and domain state.
- Native Computer Use subject to vendor caller authentication and system
  permissions; generic AX fallback subject to local TCC grants.

Reports about command injection, source allowlist bypass, unexpected shell
execution, socket peer bypass, profile/workspace bypass, token leakage, path
containment bypass, unsafe Tunnel launch, Codex policy injection, audit leakage,
or unsafe downstream proxying are in scope.

## Secrets and Sensitive Data

Do not include real credentials, private keys, local tokens, personal data, or
private tool output in issues, pull requests, logs, or test fixtures.
