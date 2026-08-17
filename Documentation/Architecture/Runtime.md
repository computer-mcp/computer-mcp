# Runtime

## App Control Plane

`Computer MCP.app` creates `AppControlPlaneService`, starts
`AppGatewayService`, and listens on a current-user Unix-domain socket. The
embedded `computer-mcp bridge` transparently pumps MCP messages between stdio
and that socket.

| Component | Responsibility |
| --- | --- |
| `AppControlPlaneService` | Directories, database, manifest revisions, bookmarks, profiles, providers, Tunnel, Keychain, and launch at login |
| `AppGatewayService` | Own the private socket and one official SDK server per client connection |
| `GatewayRuntime` | Compose providers, apply policy, route calls, and audit outcomes |
| `GatewayProviderRouter` | Map exact tool name to one domain provider |
| `MCPRuntimeAdapter` | Construct official SDK MCP servers for App and standalone modes |
| `GatewayStdioSocketBridge` | Bridge MCP stdio to the Gateway Socket |
| `ControlSocketService` | Serve owner-only App/CLI administration without creating another control plane |
| `CloudflareTunnelManager` | Own loopback HTTP, named-tunnel token file, cloudflared, metrics, and cleanup |
| `AppFileLogger` | Bounded, rotated, redacted lifecycle JSONL |

Fresh installation is a valid fail-closed server with no workspace. It supports
MCP initialization and workspace onboarding tools without granting filesystem
access.

The control socket and gateway socket are distinct and mode `0600`. CLI
administration binds `local-cli`; MCP bridge clients bind `local-mcp` or an
authenticated transport caller. Static definitions live in the schema 1
manifest, grants/desired state in GRDB, bookmarks in App storage, and all
secrets in Keychain.

App startup brings the App Control Plane, Control Socket, and Gateway Socket to
readiness before restoring desired remote transports in the background. Status
and list operations do not query Keychain; credentials are verified only for an
explicit `doctor`/`start` operation or background restoration of a transport
whose desired state is running. Background presence checks explicitly disable
authentication UI. The provisioned Data Protection Keychain access group does
not use the older file-based Keychain's per-application ACL dialogs, so a
signature rebuild cannot stall local App/CLI management on an owner prompt.
Blocking Security framework operations run on a store-owned serial dispatch
queue and resume async callers through continuations; they never occupy
Swift's cooperative executor. Launch-at-login status is observed on a separate
blocking executor and cached, so a delayed Service Management XPC response
cannot hold the App Control Plane actor or its status UI.

OpenAI Tunnel definitions persist only transport identity and policy fields.
They may include a credential-free HTTP proxy URL; when absent, the runtime
resolves the active fixed macOS HTTPS/HTTP proxy at launch. Proxy credentials
remain outside the product configuration contract.
The Codex App Server, Exec, and MCP lifecycles independently map the active
fixed macOS HTTP, HTTPS, and SOCKS proxies into their child process
environments, while preserving an explicitly inherited proxy environment and
direct loopback access. This derived environment is never persisted or logged,
and Computer MCP does not evaluate proxy auto-configuration scripts.
At launch, the App injects the absolute path of its signed embedded CLI into
the Control Plane's runtime view; that derived bundle path is never written to
the manifest. Provisioning, Doctor, App actions, and CLI actions therefore use
the same current App binary even when the App is relocated. The Gateway creates
an owner-only bridge credential for the lifetime of its socket, and the Tunnel
profile references that exact current credential path. A spawned Tunnel must
remain alive through a bounded startup-stability window before its state may
become `running`; an immediate exit fails closed and enters the reconnect
backoff instead of producing a false healthy state.

## Execution Planes

- CLI: registered executable plus argv, with mechanical help passthrough.
- Shell/process: `swift-subprocess` sessions with stdin, cursor output,
  timeouts, cancellation, process-group cleanup, and byte limits.
- Downstream MCP: persistent official SDK clients over stdio or Streamable
  HTTP, including tools, resources, prompts, list-changed events, and
  cancellation.
- Builtin/Skills: bounded typed operations inside resolved workspace or Skill
  roots.
- Computer Use: native macOS observation/action service with non-prompting TCC
  preflight and post-action verification.
- Codex: separate App Server, Exec, and MCP runtimes using `swift-codex`.

## Policy And Results

Every call is bound to `ExecutionContext` containing caller, profile, and
optional workspace id. `GatewayPolicy` checks the provider's
`CapabilityDescriptor` before execution. Destructive configured atomics require
`operations.prepare` followed by a single-use, short-lived
`operations.commit` ticket.

MCP tools advertise a title, input schema, output schema, standard annotations,
and return the bounded JSON value as both compatible text and structured
content. Codex and process event streams use monotonic cursors so output limits
do not destroy resume semantics.

## Standalone Runtime

`computer-mcp serve` runs stdio directly from TOML.
`computer-mcp serve http` adds a SwiftNIO Streamable HTTP endpoint and optional
fixed bearer authentication for compatible clients. These are development
surfaces and do not replace the App-owned service.

Remote transports are separate App-owned lifecycles:

- OpenAI Secure MCP Tunnel owns a credentialed stdio bridge to the gateway
  socket and binds `secure-tunnel`.
- Cloudflare owns a loopback authenticated Streamable HTTP origin plus a
  remotely-managed named tunnel and binds `cloudflare-tunnel`.

They may run concurrently and have independent profile, health, log, restart,
and audit provenance.
