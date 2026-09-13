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
| `GatewayProviderRouter` | Publish validated tool definitions, capabilities, and exact provider routes as one immutable snapshot |
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

Standalone tool commands own a temporary GatewayRuntime. List, inspection, and
execution share a scoped lifetime that awaits runtime shutdown on success or
failure before the CLI returns. This boundary closes owned MCP connections;
it does not acknowledge cleanup inside an independently crashed downstream
service or make an unknown write result safe to replay.

Product entry points construct runtimes through `GatewayRuntime.make`. It moves
synchronous discovery onto a blocking queue and retains each acquired workspace
access, registry and router as construction progresses. Failed or cancelled
construction joins the same cleanup that a completed runtime uses. Registry
ownership transfers to its router after successful catalog validation. Cleanup
runs in reverse acquisition order, retaining workspace access until its provider
cleanup finishes. Concurrent runtime or router shutdown callers await one shared
completion task. The synchronous initializer starts cleanup when it fails;
callers that need the completion boundary use the asynchronous factory.

App control-plane catalog queries, profile discovery, tunnel surface audits,
local tool execution and socket-session creation construct GatewayRuntime on a
blocking-operation queue. Downstream discovery therefore does not occupy the
control actor or Swift's cooperative executor. Before publishing a runtime or
derived catalog, the service checks cancellation and compares the current
manifest, registered workspaces, persisted profiles and plugin selection with
the inputs captured before discovery. A changed input rejects the pending
result and closes the constructed runtime; callers refresh before retrying.
Profile mutations also validate their inputs before starting discovery.
Bookmark refresh writes compare the stored registration with the record that
was resolved, inside the database transaction. A concurrent edit or removal wins
over a pending refresh. A successful refresh that changes discovery inputs can
require the caller to reconnect with the refreshed registration.

Temporary catalogs and tunnel audits await runtime shutdown on success and
failure. A socket session takes ownership after construction and closes its
runtime when the connection ends. Cancellation during synchronous initialization
is checked when the bounded discovery returns, then shutdown is awaited; it
does not immediately interrupt startup. Once a tool has been dispatched, its
result and audit remain governed by the tool-call lifecycle rather than being
discarded and automatically retried when configuration changes.

Cloudflare startup has one owned task per profile. Stop cancels and joins a
pending start before closing any published origin and process; concurrent stops
join the same task, and replacement starts are refused during either transition.
Startup rechecks the host configuration, workspace, grant and plugin inputs
around origin creation and process publication. Its downstream MCP client uses
the host's credential provider. Version probes use the bounded command runner on
the provider-probe queue, with the inherited launch environment captured
explicitly; truncated, timed-out or failed probes cannot authorize startup.

MCP connection diagnostics resolve a single registration and a registered workspace
through the App control plane. An ephemeral GatewayRuntime retains the selected
launch configuration and standard connection lifecycle, with an explicit read-only
diagnostic profile and no database authority. Discovery runs after host context
attachment; unrelated MCP, CLI and plugin contributions are excluded from the
probe. The result describes connection/catalog health rather than tool execution
or the caller's production permissions.

Manual MCP registrations are host-owned manifest entries. Their App editor
and owner-only `mcp` CLI share preview and activation operations, with an
expected manifest digest checked inside the store's serialized write transaction.
Plugin contributions retain package ownership and are changed through plugin
settings. Disabling a manual entry retains its configuration and grant references
but excludes its mapped tools, reexports and session capabilities from runtime
access. Removal requires the host's tool mappings and profile references to be
resolved first; it does not delete external dependencies.

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
The independent Codex adapter's App Server, Exec, and MCP lifecycles map the active
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

External-provider diagnostics carry a resolved launch directory and merged
environment through executable/interpreter inspection and version/contract
probes. Explicit configuration selects an installation; failure does not
silently probe a different installation. A successful probe describes that
operation, independently of MCP connection health or GUI permission readiness.
The package doctor remains a non-executing configuration/file inspection.

The default version/contract probe runner uses the shared CLI process lifecycle
with closed stdin, bounded output and process-group timeout cleanup. The inspected
environment is supplied as a complete child environment; lower layers do not
add host variables again. Normal Shell sessions retain their explicit environment
inheritance behavior. App provider refresh runs on a blocking-operation queue
outside the control-plane actor and publishes results only while its captured
configuration is current and the requesting task is not cancelled. Cancellation
discards publication; an already-running synchronous probe still has its bounded
execution and cleanup deadline.

Codex MCP registration planning and explicit Tunnel client paths use the same
non-executing file/interpreter inspection. Automatic Tunnel discovery requires a
successful version probe before returning a launch path. Neither check installs
an interpreter or proves runtime protocol/authentication readiness.

Plugin dependency discovery and package diagnostics share a resolver. Host
bindings take precedence over PATH and declared macOS application locators.
Application lookup validates the bundle identifier and executable containment,
then passes the selected path to the ordinary file/interpreter inspection.
Diagnostics report the binding source. Discovery neither starts applications nor
establishes their signing identity, publisher provenance or runtime compatibility.

- CLI: registered executables use raw argv or a validated CLI Tree. Direct and
  package trees share ordered argv/stdin encoding and immutable catalog providers;
  execution reuses managed process sessions with per-call ownership and cancellation.
  Status, raw help/exec, tree exporters and projected calls use the registry's
  host environment with registration overrides. Relative executable paths and
  PATH entries resolve against the configured CLI workspace directory. Default
  raw command runners capture that host environment; tree execution receives
  the complete merged environment without adding ambient process values.
  Declared executable checks run inside each authorized call, before target argv,
  with bounded capture/time and executable/interpreter identity comparisons.
  Listings and static diagnostics do not execute file-backed compatibility checks.
  Publisher hints do not change the host Full Shell boundary. See
  [CLI Trees](../Reference/CLITrees.md) for the contract and refresh behavior.
- Shell/process: `swift-subprocess` sessions with stdin, cursor output,
  timeouts, cancellation, process-group cleanup, and byte limits.
- Downstream MCP: persistent official SDK clients over stdio or Streamable
  HTTP, including tools, resources, prompts, list-changed events, and
  cancellation. Each workspace registry owns an independently scoped client,
  connection pool, and tool-change stream. Authorization wrappers preserve the
  host policy when creating that scope. Stopping one registry closes its own
  sessions, not another workspace's sessions with the same registration IDs.
- Builtin/Skills: bounded typed operations inside resolved workspace or Skill
  roots.
- Computer Use: native macOS observation/action service with non-prompting TCC
  preflight, main-thread AX action dispatch, host-process self-target denial,
  and post-action verification.
- Codex: an independent standard MCP adapter package owns App Server, Exec,
  Codex MCP, domain persistence and `swift-codex`. Gateway registration and
  routing use the same downstream MCP plane as other providers.

Downstream MCP initialization and ready-session requests have independent
budgets. Expiry invalidates the connection and identifies the failed stage.
Cancellation is checked before queued work begins and after initialization;
an already issued action can still have an uncertain outcome. Tool calls are
not replayed automatically. Configuration values are described
in [Config](../Reference/Config.md).

Awaited downstream MCP calls carry cancellation through the provider and
authorization wrappers to their exact SDK request ID. Reexports, aliases and
the waiting form of `mcp.tools.call` share this path. Cancellation during shared
initialization prevents subsequent dispatch, while the initialization retains
its own startup budget. Once dispatched, cancellation is advisory. Delivery has
a 250 ms budget; failed or stalled delivery retires the affected connection and
joins the cancellation writer. Replacement and explicit shutdown wait for the
retained retirement cleanup. A successfully delivered cancellation leaves sibling
requests on that connection running. Independently started calls retain their
explicit request lifecycle and are managed through `mcp.requests.cancel`.

A ready session survives local argument rejection, an unknown cancellation
selector, an explicitly cancelled request, and downstream method-not-found,
invalid-parameter, server-defined, or URL-elicitation errors. The original error
still reaches the caller; other requests retain their session and ownership.
A tool's `isError` result likewise remains a result, including its structured
content. The upstream SDK conversion decodes the complete typed content array,
preserving text, images, audio, resource links, embedded text/binary resources,
supported annotations and metadata. Empty protocol content stays empty;
malformed or unsupported content fails the response instead of returning a
partial success. Ordinary JSON tool outputs are rendered as text when they do
not contain a protocol content array. Initialization failures always retire the
generation. Timeouts,
transport failures, malformed data, and ambiguous SDK failures also retain the
conservative retirement path. The pinned SDK uses `internalError` for local
disconnection as well as protocol errors, so that case does not establish a
reusable connection.

Gateway request IDs are reserved before the asynchronous SDK dispatch and remain
exclusive while their request is being established or awaited. Started requests
retain their own native request ID. Completion observers are keyed and checked
against that native identity, so an old cancelled request cannot remove the
state of a newer request that reuses its gateway ID. Shutdown joins all retained
observers, including cancelled requests whose completion is still pending.

Each downstream connection is a single, non-reopenable generation. The pool
retains retiring generations and coalesces concurrent shutdown calls. A successor
waits for its predecessor's confirmed cleanup before initializing; a process
whose exit cannot be confirmed blocks replacement. The request timeout reports
the failed operation promptly, while explicit client shutdown also joins that
retirement. Neither transition retries an issued tool call.

HTTP registrations may select a Keychain bearer-token reference bound to their
exact endpoint. Only host configuration or plugin host settings own this
binding; package manifests do not. App-owned runtimes, workspace-scoped clients
and connection diagnostics use the same Keychain provider. Each HTTP exchange
resolves its current value off the UI thread with authentication prompts
disabled. Missing credentials fail before a request is sent. HTTP sessions are
ephemeral by default and reject redirects; neither authentication failures nor
redirects replay a POST. Credential management uses the local owner control
plane and leaves configuration, plugin ownership and grants unchanged.
The HTTP transport owns the authenticated, bounded best-effort session DELETE;
client facades delegate disconnect to that transport.
The transport correlates active HTTP response readers with typed MCP request
IDs. A cancellation notification closes and joins the matching POST or resumed
GET reader, preserving other requests and the session event stream. Disconnect
also joins outstanding response readers after cancellation or a transport error.

The upstream socket tracks each connection through authentication, session
creation and awaited runtime cleanup. The connection task owns session cleanup;
socket shutdown closes admission and channels, then joins those owners before
releasing its event loop. Concurrent socket shutdown calls wait for the same
completion. An idle registration-change reservation excludes retiring sessions
as well as clients still exchanging messages.

The upstream HTTP lifecycle serializes listener startup and shutdown. Stopping
closes admission, stops active and retiring sessions, joins session construction,
releases the event loop, and shuts down the shared registry. Concurrent stop and
listener-wait callers join that same cleanup. Listener restart is rejected while
cleanup is pending, and a waiter from a completed listener generation cannot
stop a subsequent listener.

The shared managed-line process primitive supplies protocol-independent stdio
ownership for downstream MCP adapters. It launches an owned
supervisor and child group, bounds protocol lines and receive queues, drains
stderr, and closes stdin before escalating through TERM and KILL. Shutdown
joins startup, readers and pipe writes; only the recorded owned group is
signalled. The supervisor also cleans up when its owner exits. This is process
ownership, not an OS sandbox, and does not claim containment of descendants
that deliberately leave the group.

For stdio, the scoped client's workspace directory is the base for an absent,
empty, `workspace`, or relative registration `cwd`. The transport resolves the
command and its interpreters in that directory using the scoped host
environment plus registration overrides. It retains the resolved lookup path,
including a selected symlink, for launch. This runtime context is not serialized
into plugin declarations or the source manifest. Explicit connection validation
uses the configuration directory and closes its client on success or failure.

Gateway-owned stdio sessions also receive immutable caller/profile, runtime,
workspace and transport provenance through a protected launch environment
entry. Direct and plugin registrations use the same injection path. Each call
must retain its connection's caller/profile/transport identity; its request ID
and selected granted workspace can vary. This metadata is neither a grant nor
an OS sandbox. See [MCP Protocol](../Reference/MCPProtocol.md#downstream-host-context)
for the wire contract and authorization boundary.

## Scoped Plugin Host Services

Callback-enabled owned stdio adapters receive a private standard MCP endpoint.
The host retains caller grants, workspace registrations, approval authority and
audit; the adapter owns domain state and vendor protocol execution.
`MCPHostInvocation` records the live outer call without exporting a credential.
Private services match that reference, current grants and, for destructive
removal, the executing operation ticket. Binding is lazy so plugin catalog
startup does not depend on a partially constructed Gateway runtime.

`MCPBoundHostServices` consumes existing approved elevation records, owns the
atomic derived-workspace registration ledger and projects bounded diagnostics.
It cannot issue local approval through the plugin connection. Failed owned
grant invalidation leaves retirement unconfirmed. The independent Codex adapter
implements its host interfaces through this endpoint while retaining separate
App Server, Exec and Codex MCP lifecycles. Imported embedded Codex configuration
requires the reviewed [configuration migration](../Reference/CodexMigration.md)
before runtime creation. The optional import record preserves the old format
for offline export; the adapter owns the resulting execution settings. Host
elevation reports connection-bound grant eligibility, while applied sandbox
state is reported by the adapter. Grants and historical database migration
records remain host-owned.

See [Scoped host services](../Reference/HostServices.md) for configuration,
wire surface, scope checks, bounds and recovery behavior.

## Tool Catalog Lifecycle

Each workspace router owns an immutable snapshot of tool definitions,
capabilities, and exact provider routes. Complete discovery and validation run
before an atomic replacement. Reexport naming is resolved from the explicit
host prefix choice, including an empty prefix that preserves native tool names.
Registration identity remains attached to the definition and capability rather
than inferred from its textual name. Host-management names are reserved in each
provider snapshot, so neither initialization nor a subsequent refresh can
replace them. Failed refreshes preserve the validated snapshot and record an error. Dispatch resolves the current route and rejects a capability
that changed after authorization. Shutdown cancels and drains refresh work before
releasing providers and downstream connections.

Downstream tool-list notifications invalidate the catalog. Each initialized
upstream SDK server independently compares its caller-visible tool definitions
before sending a list-change notification. Subscriptions are bounded invalidation
signals, not partial catalog deltas. HTTP holds one pending catalog invalidation
until the first GET event subscription exists, then flushes SSE events as they
arrive. See [MCP Protocol](../Reference/MCPProtocol.md) for refresh intervals,
manual refresh behavior, and client update requirements.

## Downstream process ownership

Stdio MCP launches acquire a private ownership receipt before spawning. Its
scope is the canonical workspace root and registration ID within the host's
recovery storage. A file-backed Gateway database uses a sibling
`<database filename>.mcp-processes` directory; clients without a file-backed
database use `computer-mcp-mcp-processes` in the process's platform temporary
directory. Recovery requires the same storage namespace. HTTP connections do
not own local processes and do not use these receipts.

The receipt records the host PID and process start time, not credentials,
arguments, plugin grants or executable authorization. The supervisor and its
watchdog inherit the locked file reference before the native command starts;
the native command does not inherit it. New sessions from live host owners
remain independent. If an owner has exited or its PID has been reused while
the process lock remains held, startup fails with `mcp.cleanup_pending`.
Releasing the orphaned lock permits the next startup to reconcile the receipt.
Confirmed shutdown removes its own receipt. An explicitly failed cleanup or
damaged receipt remains blocking and requires inspection; absence of a process
lock alone does not clear a recorded host-service cleanup failure.

The App-owned connection doctor shares the runtime's storage namespace without
obtaining its database or callback authority. It inspects receipts before
launching and after closing the probe. App and CLI recovery retire one reviewed
receipt with matching configuration and receipt digests under the same scope
lock. The receipt must be independently lockable and explicitly record confirmed
host-service cleanup. Missing confirmation and damaged records remain blocking;
recovery does not infer grant revocation from process exit. No replacement is
started automatically.

The stdio connection observes owned transport termination independently of the
SDK request loop. Once process and host-service cleanup finishes, it retires
that exact pooled generation and disconnects the SDK client so pending
initialization, catalog and tool requests complete with an error. Connection
retirement joins that observer as well as startup
and request tasks. An exited native process does not consume the remaining
startup budget, and a replacement still waits for confirmed ownership release.

Ownership files are private regular files, opened without following links and
checked for hard-link aliases. Short per-scope file transactions serialize
inspection and publication; they do not impose a single live MCP session per
registration. Receipt inspection never signals another process or replays a
tool call. Plugin installation ownership and downstream execution ownership
are separate: an installation recovery operation cannot clear process receipts.

## Codex App Server Ownership And Teardown

Codex App Server ownership follows the gateway connection rather than a
machine-wide singleton:

```text
gateway socket or HTTP session
  -> GatewayRuntime (caller + profile + transport generation)
    -> one provider router per registered workspace
      -> ordinary owned MCP connection to the Codex adapter
        -> adapter-owned lazy App Server runtime
          -> one current JSONL/stdio connection generation
            -> adapter-owned App Server process group
```

The adapter's domain runtime has a stable `runtime_id` for its lifetime. Each started connection
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
every workspace MCP connection. The adapter's shutdown cancels the notification and request
consumers, releases each subscribed thread with a bounded official
`thread/unsubscribe`, interrupts still-pending approval records, and closes the
App Server transport. The transport then:

1. closes stdin so App Server can observe EOF, persist state, release writer
   resources, and exit;
2. waits for the configured graceful interval;
3. sends `SIGTERM` to the exact owned App Server process group when required;
4. waits again, then sends `SIGKILL` only if the group is still alive;
5. waits for and records process reaping.

The adapter's private supervisor watches its owner PID and applies the same
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

The plugin's isolated validation harness owns cleanup; it is not a host runtime
service. Disposable real validation owns exact workspace, thread, runtime, process, and
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
