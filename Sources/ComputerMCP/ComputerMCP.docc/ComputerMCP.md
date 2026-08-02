# ``ComputerMCP``

Build a deterministic, profile-bound MCP gateway for macOS.

## Overview

`ComputerMCP` is the internal implementation module shared by `Computer
MCP.app` and the embedded `computer-mcp` CLI. It is not a supported external
Swift SDK. The module provides:

- official MCP SDK server and client integration;
- a private current-user Unix socket and stdio bridge;
- schema 1 TOML configuration;
- registered workspaces and static capability profiles;
- policy, single-use operation tickets, and redacted audit persistence;
- bounded Builtin, Skill, CLI, Shell, process, downstream MCP, and Computer Use
  execution planes;
- Codex App Server, Exec, and MCP integrations through `swift-codex`;
- independent App-managed OpenAI and Cloudflare transport profiles and Keychain
  credentials;
- built-in profile defaults;
- standalone stdio and HTTP development modes.

The runtime does not plan, select tools, infer grants, or rewrite provider
semantics.

## App Boundary

`Computer MCP.app` owns the service lifecycle and hosts the gateway behind its
private socket. `computer-mcp bridge` is a transport adapter; it does not start
a second gateway. Workspace bookmarks and secrets are App-managed state and do
not belong in TOML.

Tunnel profiles expose explicit typed capabilities only. Generic CLI execution,
process spawning, and Full Shell remain local to `local-admin`.

### Configuration And Policy

- ``GatewayConfiguration``
- ``ServerConfig``
- ``PolicyConfig``
- ``CLISectionConfig``
- ``CLICommandConfig``
- ``MCPSectionConfig``
- ``MCPServerConfig``
- ``ToolConfig``
- ``BuiltinConfig``
- ``ConfigurationError``

### Gateway Runtime

- ``GatewayToolRegistry``
- ``MCPRuntimeAdapter``
- ``MCPTool``
- ``MCPToolAnnotations``
- ``GatewayToolError``

### Execution

- ``CommandRunning``
- ``ProcessCommandRunner``
- ``CommandResult``
- ``ProcessManaging``
- ``ManagedProcessRegistry``
- ``ManagedProcessSnapshot``
- ``ManagedProcessCancelResult``

### MCP and OpenAI Secure MCP Tunnel

- ``DownstreamMCPClient``
- ``MCPProxyClient``
- ``OpenAITunnelLauncher``
- ``OpenAITunnelInvocation``
- ``OpenAITunnelPlan``
- ``OpenAITunnelConfiguration``
- ``OpenAITunnelSupervisor``
- ``OpenAITunnelStatus``
- ``OpenAITunnelDoctorReport``
- ``OpenAITunnelLogPage``
- ``ChatGPTProfileAuditor``
- ``ChatGPTProfileAudit``
- ``ChatGPTProfileAuditError``
- ``OpenAITunnelLauncherError``

### Reverse Codex Integration

- ``CodexMCPInstaller``
- ``CodexMCPInstallInvocation``
- ``CodexMCPInstallerError``

### Values And CLI

- ``JSONValue``
- ``ComputerMCPCLI``
