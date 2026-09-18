# Gateway

## Purpose

Computer MCP is a policy-enforced execution gateway. Its current tool catalog
combines configured local capabilities, downstream MCP discovery and verified
CLI command-tree projections. Plugins package MCP, CLI and Skills contributions;
direct registrations and plugin contributions share the registry, routing,
authorization and lifecycle. The gateway does not plan, rank, select or
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

1. Resolve the exact tool name and host-owned provider identity.
2. Bind the verified principal, configured caller, profile and `workspace_id`.
3. Read the current grant revision and check mode, capability, caller, Full Shell, path/network
   policy, and TCC requirements.
4. Apply the confirmation policy and validate/consume an approved operation
   ticket when required. Only local administration resolves approval.
5. Dispatch to one provider.
6. Bound output and return structured content or a stable error.
7. Persist a redacted audit decision.

Unknown tools, workspaces and providers fail closed. Domain adapters validate
their own protocol methods inside the scope delegated by the host.

Profile permission updates apply to subsequent discovery and calls without
restarting unrelated transports. A profile change invalidates its outstanding
approvals. Existing sessions retain their verified principal and profile;
selecting the default profile affects new admissions. Disconnecting a client
does not stop owned execution. Revocation and explicit cancellation are
separate operations.

MCP requests with a caller-stable id reserve a durable receipt before dispatch.
Synchronous and asynchronous routes use the same identity and input digest.
Duplicate inputs observe the original execution; conflicting inputs fail.
Results are bounded and can be read without starting a provider. After loss of
an executing instance, an unresolved receipt reports an unknown outcome and
does not authorize replay. Cancellation delivery, execution outcome and
process cleanup are separate facts. This is a receipt layer, not a scheduler
or a promise that arbitrary downstream work survives a host restart.

## Workspace Model

The App registers folders with persistent security bookmarks and stable ids.
The symlink-resolved canonical root is the registration identity, so adding the
same directory through another path spelling returns the existing workspace.
Historical duplicate ids can be repaired through a reviewed, digest-bound
deduplication plan; aliases preserve prior audit and ownership references.
`workspace.list` and `workspace.describe` are always the discovery path. When
multiple workspaces are granted, a scoped call must include `workspace_id`;
there is no mutable global current directory.

Manifest `[[workspaces]]` entries support standalone development. App bookmarks
are persisted separately and are not copied into TOML.

## Source Types

| Source | Registration | Execution |
| --- | --- | --- |
| CLI | `[[cli.commands]]` or plugin contribution | Verified command-tree projection and deterministic argv; explicit raw CLI access |
| MCP | `[[mcp.servers]]` or plugin contribution | Persistent stdio or Streamable HTTP client session |
| Builtin | `[builtin].enabled` | Explicit typed local capability |
| Skills | `[skills]` or plugin contribution | Bounded reads inside registered Skill roots |
| Native AX fallback | profile capability | Generic UI observation/control with TCC preflight |
| Shell | `[policy]` plus local grant | Direct argv or shell script with complete process I/O |

CLI trees define projected tools and exact argument constraints. Raw
`cli.describe`, `cli.help` and `cli.exec` remain available under their own policy;
raw calls cannot bypass declared tree constraints. Missing structured coverage
is reported explicitly.

Downstream MCP registrations select all tools or a whitelist. Discovery,
pagination, schema updates and reconnects update the same validated catalog and
routes atomically. Upstream notifications reflect changes visible to each caller.
Tool annotations do not grant access or override host read-only boundaries.
Codex execution uses the independent MCP adapter plugin; native Computer Use
connects directly through its MCP declaration or a manual MCP registration.

## ChatGPT And Codex

ChatGPT Web is a remote MCP consumer and reaches the App through Secure MCP
Tunnel. Other reviewed consumers may use the Cloudflare named-tunnel endpoint.
Neither can use local Codex MCP configuration or directly reach localhost.

Codex has two distinct relationships:

- Computer MCP can invoke the independent Codex plugin, which owns the separate
  App Server and Exec provider lifecycles.
- Codex can use Computer MCP as an external MCP server through
  `computer-mcp install codex`.

These relationships share no implicit authority. Both are evaluated by the
same explicit gateway profile and workspace policy.
