# Gateway Direction

## Status

Accepted.

## Decision

`Computer MCP.app` owns a deterministic, policy-enforced MCP gateway and the
single App Control Plane. The embedded `computer-mcp` CLI administers that App
through the owner-only Control Socket or bridges MCP stdio to the Gateway
Socket. Standalone stdio and loopback HTTP modes remain explicit development
surfaces.

## Rationale

Remote consumers need independently attributable transports without duplicating
configuration, policy, secrets, or audit state. ChatGPT uses the OpenAI Secure
MCP Tunnel and the `secure-tunnel` caller. Standard remote MCP consumers use a
Remotely Managed Cloudflare Tunnel, a bearer-protected App-owned loopback
Streamable HTTP origin, and the `cloudflare-tunnel` caller. Both routes terminate
at the same Gateway Runtime while retaining separate profiles, credentials,
lifecycles, logs, and request provenance.

Capabilities remain behind explicit provider adapters: Builtin, Skills, CLI,
downstream MCP, Process, Codex App Server/Exec/MCP, Computer Use, and optional
Shell. The manifest and persisted profile grants decide which adapter operations
are visible and executable for each caller and workspace.

## Consequences

- Tokens and downstream credentials remain in Keychain or the owning consumer;
  they never enter the manifest.
- `shell.run`, generic CLI execution, and managed process spawning remain
  disabled for remote built-in profiles.
- Downstream MCP tools preserve their reviewed exposure and prefix boundaries.
- Codex App Server, Exec, and MCP remain separate provider lifecycles supplied
  by `swift-codex`.
- Computer Use performs non-prompting permission checks for remote calls and
  records policy and audit provenance like every other capability.
