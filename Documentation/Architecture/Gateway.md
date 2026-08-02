# Gateway

## Purpose

Computer MCP is a deterministic execution gateway. It publishes MCP tools and
routes each call to a statically registered Builtin, Skill, CLI, downstream MCP,
Computer Use, Shell, or Codex adapter. It does not plan, rank, select, or
semantically rewrite tools.

## App-owned Topology

```text
ChatGPT Web
  -> OpenAI Secure MCP Tunnel
  -> embedded computer-mcp bridge
  -> private Unix-domain socket

Remote MCP client
  -> Cloudflare remotely-managed named tunnel
  -> App loopback authenticated Streamable HTTP

Both -> Computer MCP.app -> AppGatewayService
     -> caller/profile policy + workspace resolution + audit
     -> domain provider
```

The App is the only service owner. OpenAI bridge connections and
Cloudflare HTTP requests create official MCP SDK sessions bound to distinct
remote callers and allowed profiles. The private sockets check peer
credentials and are accessible only to the current user; Cloudflare's origin
is loopback-only and requires the gateway bearer.

Standalone `serve` stdio and HTTP modes remain development and diagnostic
surfaces. They load a TOML manifest directly and do not share App-managed
bookmarks or Keychain state.

## Routing

`GatewayRuntime` composes `GatewayToolProvider` instances through
`GatewayProviderRouter`. Every `CapabilityDescriptor` declares its id, risk,
workspace scope, caller restrictions, and MCP metadata.

The execution sequence is:

1. Resolve the exact tool name.
2. Bind the configured caller, profile, and explicit `workspace_id`.
3. Check capability grant, caller eligibility, Full Shell state, path/network
   policy, and TCC requirements.
4. Require an operation ticket for configured destructive atomics.
5. Dispatch to one provider.
6. Bound output and return structured content or a stable error.
7. Persist a redacted audit decision.

Unknown tools, workspaces, providers, and Codex RPC methods fail closed.

## Workspace Model

The App registers folders with persistent security bookmarks and stable ids.
`workspace.list` and `workspace.describe` are always the discovery path. When
multiple workspaces are granted, a scoped call must include `workspace_id`;
there is no mutable global current directory.

Manifest `[[workspaces]]` entries support standalone development. App bookmarks
are persisted separately and are not copied into TOML.

## Source Types

| Source | Registration | Execution |
| --- | --- | --- |
| CLI | `[[cli.commands]]` | Raw help discovery and direct executable + argv |
| MCP | `[[mcp.servers]]` | Persistent stdio or Streamable HTTP client session |
| Builtin | `[builtin].enabled` | Explicit typed local capability |
| Skills | `[skills]` | Bounded reads inside registered Skill roots |
| Computer Use | profile capability | Native generic UI observation/control with TCC preflight |
| Codex | `[codex]` | App Server, Exec, and MCP runtimes |
| Shell | `[policy]` plus local grant | Direct argv or shell script with complete process I/O |

CLI commands are not expanded into a generated top-level catalog. MCP consumers
use `cli.describe`, `cli.help`, then `cli.exec`. Selected downstream MCP tools
may be pinned through `[[tools]]` or reviewed reexports.

## ChatGPT And Codex

ChatGPT Web is a remote MCP consumer and reaches the App through Secure MCP
Tunnel. Other reviewed consumers may use the Cloudflare named-tunnel endpoint.
Neither can use local Codex MCP configuration or directly reach localhost.

Codex has two distinct relationships:

- Computer MCP can use Codex through its App Server, Exec, and MCP provider
  paths.
- Codex can use Computer MCP as an external MCP server through
  `computer-mcp install codex`.

These relationships share no implicit authority. Both are evaluated by the
same explicit gateway profile and workspace policy.
