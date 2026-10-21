# ``ComputerMCPGateway``

Build a deterministic, profile-bound MCP gateway for macOS.

## Overview

`ComputerMCPGateway` is the internal gateway runtime used by `Computer MCP.app`
and the embedded `computer-mcp` CLI. It is not a supported external Swift SDK.
Other internal targets supply execution, administration, transport, and platform
services. Together they provide:

- MCP Swift SDK server and client integration;
- a private current-user Unix socket and stdio bridge;
- registered workspaces and static capability profiles;
- policy, single-use operation tickets, and redacted audit persistence;
- bounded Builtin, Skill, CLI, Shell, process, downstream MCP, and Computer Use
  execution planes;
- Codex execution through an independent standard MCP adapter plugin;
- independent App-managed OpenAI and Cloudflare transport profiles and Keychain
  credentials;
- standalone stdio and HTTP development modes.

The runtime does not plan, select tools, infer grants, or rewrite provider
semantics.

## App Boundary

`Computer MCP.app` owns the service lifecycle and hosts the gateway behind its
private socket. `computer-mcp bridge` is a transport adapter; it does not start
a second gateway. Workspace bookmarks and secrets are App-managed state and do
not belong in TOML.

Tunnel profiles expose explicit capabilities only. Generic CLI execution,
process spawning, and Full Shell remain off by default; only
`chatgpt-operate` can receive them through an explicit local opt-in.

### Gateway Runtime

- ``GatewayToolRegistry``
- ``MCPRuntimeAdapter``

### MCP and OpenAI Secure MCP Tunnel

`ComputerMCPTunnels` owns tunnel launch planning, supervision, transport values
and the `HTTPOriginLifecycle` contract. `ComputerMCPControlPlane` constructs the
Cloudflare HTTP origin and audits gateway profiles. `DownstreamMCPClient` belongs
to `ComputerMCPDownstream`; its gateway implementation is ``MCPProxyClient``.
`ChatGPTProfileAuditor` belongs to `ComputerMCPControlPlane`.

The following types belong to `ComputerMCPTunnels`:

- `OpenAITunnelLauncher`
- `OpenAITunnelInvocation`
- `OpenAITunnelPlan`
- `OpenAITunnelConfiguration`
- `OpenAITunnelSupervisor`
- `OpenAITunnelStatus`
- `OpenAITunnelDoctorReport`
- `OpenAITunnelLogPage`
- `ChatGPTProfileAudit`
- `ChatGPTProfileAuditError`
- `OpenAITunnelLauncherError`

### Reverse Codex Integration

`ComputerMCPControlPlane` owns the independent adapter's installation workflow:

- `CodexMCPInstaller`
- `CodexMCPInstallInvocation`
- `CodexMCPInstallerError`
