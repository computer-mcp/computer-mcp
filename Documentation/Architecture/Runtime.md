# Runtime

## App Control Plane

`Computer MCP.app` creates `AppControlPlaneService`, starts
`AppGatewayService`, and listens on a current-user Unix-domain socket. The
embedded `computer-mcp bridge` transparently pumps MCP messages between stdio
and that socket.

| Component | Responsibility |
| --- | --- |
| `AppControlPlaneOperations` | Shared lifecycle-aware App/CLI use cases, validation, restart/reconnect coordination, and rollback |
| `AppControlPlaneService` | Directories, database, manifest revisions, bookmarks, profiles, providers, Tunnel, Keychain, and launch at login |
| `AppGatewayService` | Own the private socket and one official SDK server per client connection |
| `GatewayRuntime` | Compose providers, apply policy, route calls, and audit outcomes |
| `GatewayProviderRouter` | Map exact tool name to one domain provider |
| `MCPRuntimeAdapter` | Construct official SDK MCP servers for App and standalone modes |
| `GatewayStdioSocketBridge` | Bridge MCP stdio to the Gateway Socket |
| `ControlSocketService` | Adapt owner-only CLI calls to shared App control operations without creating another control plane |
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

SwiftUI and the embedded CLI both call `AppControlPlaneOperations` for
mutations. Workspace, profile, manifest, provider, gateway, and Tunnel actions
therefore share validation, running-gateway restart, desired-Tunnel
reconnection, and rollback behavior. The CLI reaches that layer through the
owner-only control socket; it does not open App storage as a second service
owner.

App startup brings the App Control Plane, Control Socket, and Gateway Socket to
readiness before restoring desired remote transports in the background. Status
and list operations do not query Keychain; credentials are verified only for an
explicit `doctor`/`start` operation or background restoration of a transport
whose desired state is running. Background presence checks explicitly disable
authentication UI. The provisioned Data Protection Keychain access group does
not bind credentials to an individual App binary, so routine builds with the
stable signed identity do not stall local App/CLI management on an owner
prompt.
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
  preflight, main-thread AX action dispatch, host-process self-target denial,
  and post-action verification.
- Codex: separate App Server, Exec, and MCP runtimes using `swift-codex`.

## Codex App Server Ownership And Teardown

Codex App Server ownership follows the gateway connection rather than a
machine-wide singleton:

```text
gateway socket or HTTP session
  -> GatewayRuntime (caller + profile + transport generation)
    -> one provider router per registered workspace
      -> one lazy Codex App Server runtime per workspace
        -> one current JSONL/stdio connection generation
          -> one Computer MCP-owned App Server process group
```

The runtime has a stable `runtime_id` for its lifetime. Each started connection
has a separate generation id and records the registered workspace, caller,
profile, socket connection, Tunnel instance/profile, App Server PID,
supervisor PID, parent PID, process group, timestamps, exit status, signal, and
termination escalation. Concurrent first requests await the same startup; they
do not create parallel generations for one runtime. A timed-out connection is
retired and reaped before a read-only request may make one fresh retry.

Each runtime consumes App Server notifications and server requests for its
current connection. It tracks threads known to that workspace as loaded,
subscribed, active, idle, release-requested, released, externally claimable,
stopped, stale-receipt, or inconsistent when the available protocol evidence
supports that conclusion. Active turn, pending approval, and pending user-input
state are recorded separately. Reconnection creates a new connection
generation; it does not transfer authority over an earlier generation.

Closing an MCP connection shuts down its `GatewayRuntime`, which shuts down
every workspace provider. Codex shutdown cancels the notification and request
consumers, releases each subscribed thread with a bounded official
`thread/unsubscribe`, interrupts still-pending approval records, and closes the
App Server transport. The transport then:

1. closes stdin so App Server can observe EOF, persist state, release writer
   resources, and exit;
2. waits for the configured graceful interval;
3. sends `SIGTERM` to the exact owned App Server process group when required;
4. waits again, then sends `SIGKILL` only if the group is still alive;
5. waits for and records process reaping.

A private supervisor watches the Computer MCP owner PID and applies the same
bounded termination to the owned process group if the owner dies abruptly.
Signals are never selected by executable name or a machine-wide process scan;
Codex Desktop, IDE, CLI, and other user-owned App Servers are outside this
authority. Normal socket closure, abrupt disconnect, Tunnel replacement,
service stop, request timeout, and parent death therefore converge on the same
bounded cleanup contract.

The configured App Server request timeout is an end-to-end budget for a normal
call. It starts before connection startup and covers workspace validation, the
reviewed RPC, and at most one fresh-generation read-only retry. `app/list` has a
separate configured budget because Codex may emit a multi-megabyte directory
snapshot before its bounded page response; it uses one generation so a restart
cannot repeat that snapshot. A request timeout is a recoverable request result,
not a terminal runtime shutdown reason. Runtime lifecycle, connection state,
process state, current request state, last request failure, and terminal
shutdown reason are persisted independently. An actually stopped runtime has a
terminal reason; a live running runtime does not. Current request state is
derived from an active-request count, so one completed concurrent request cannot
report the runtime idle while another request is still running.

Connection retirement still has separately bounded EOF, TERM, and KILL
intervals. Concurrent close paths share one retirement operation, so neither
back-pressured stdin nor duplicate close requests multiply the deadline. A
fresh read-only retry may begin only after the timed-out connection generation
has been retired and reaped.

### Thread handoff and bounded supervision

`codex.app.thread.release` is a high-level transaction, not a synonym for one
successful `thread/unsubscribe` response. It serializes against thread/turn
starts, operates on every matching owned runtime, applies the requested active
turn policy, resolves or refuses pending interactive state, validates the
official loaded set after unsubscription, reaps runtimes that have no other
work, and performs a final ownership rescan. Only a final
`released_persisted` classification returns success.

Long-running supervision uses `codex.app.thread.recent`. It reads the newest
Codex state database in read-only mode, verifies the persisted thread's
canonical workspace and rollout root, scans only a bounded rollout tail, and
returns bounded metadata, Goal state, active/recent turns, messages, items, and
compact progress. Snapshot-bound cursors provide older pages without loading
the complete history. Page I/O, Goal scan I/O, record count, output bytes, and
elapsed scan budget are reported with the result; no Codex state is mutated.

### Validation cleanup

Disposable real validation owns exact workspace, thread, runtime, process, and
managed-worktree identities. Primary acceptance, turn finish,
unsubscribe/release, runtime stop, process reap, worktree cleanup, and final
diagnostics each have independent deadlines. A primary success remains a
success when cleanup times out, with a structured cleanup warning naming the
exact target and safe operator-reviewed action. Cleanup can stop only the receipted
Computer MCP runtime/PID and cannot select a process or worktree by name or path
heuristic.

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
