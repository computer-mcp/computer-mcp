# MCP Protocol Reference

JSON integers in the signed 64-bit range retain their exact value through tool
arguments, results, metadata, schemas, request identifiers and execution
receipts. Integral values outside that range are rejected rather than rounded.
Use strings for identifiers that exceed this range. Fractional values use
binary floating-point precision.

## Transport

`computer-mcp serve` and the App's `computer-mcp bridge` use MCP stdio
transport. Each message is one UTF-8 JSON-RPC object followed by a newline:

```text
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"protocol-debugger","version":"1.0"}}}\n
```

For interactive debugging, do not use LSP-style `Content-Length` framing. This
gateway's stdio adapter expects one complete JSON-RPC object per line.

MCP protocol handling is provided by the official Swift MCP SDK. The examples
below document the wire shape for debugging; they are not a separate protocol
implementation in this repository.

## Downstream tool risk

A downstream tool can declare a minimum risk in
`_meta["io.github.computer-mcp/risk"]`: `read-only`, `workspace-write`,
`external-write`, `destructive` or `full-shell`. The host uses the higher of
this classification and its configured tool risk. Metadata cannot lower host
policy or grant a capability. Missing declarations retain configured behavior;
malformed or unknown declarations fail closed. Standard MCP annotations remain
hints, not permission grants.

Reexported tools, configured aliases and `mcp.tools.call` use the selected
workspace's current definition. The effective risk applies to discovery,
authorization, approval preparation and ticket commit. Execution rechecks the
declaration; a higher risk observed after admission is rejected with `mcp.risk_changed`
before dispatch. Retry through current host authorization and consent. Background
calls use the same checks before starting work.

## Downstream provider work

A provider may expose its live jobs and retained handles through ordinary MCP
resources. This is lifecycle evidence, not a capability grant, a task framework,
or permission to call private Host Services. A provider without this declaration
receives no work-invocation metadata and continues to use ordinary MCP.

The host's destructive `mcp.connections.close` operation requires an explicitly
selected live execution owner. It joins teardown of that original connection
and reports transport closure separately from managed-process exit and remaining
ownership. Remote or detached work retains its uncertainty; closing transport
does not discharge it. See [connection close](Tools.md#mcpconnectionsclose).

Advertise `resources` in initialization and put this declaration in one or more
tool definitions. Keep it available for the lifetime of the connection:

```json
{
  "_meta": {
    "io.github.computer-mcp/work": {
      "format_version": 1,
      "uri": "computer-mcp://runtime/work/v1"
    }
  }
}
```

The declaration names a resource on the downstream connection. The gateway
retains it internally but omits it from aliases and reexported tool definitions;
those definitions must not advertise the provider's URI as a gateway resource.
Other tool metadata, including the publisher's risk floor, remains available.

For each dispatched tool call, the host supplies a unique UUID in request
`_meta["io.github.computer-mcp/work-invocation"]`. This reference is generated
after host admission and belongs to that connection's workspace, registration,
principal and runtime scope. It cannot be replaced by a tool argument. It is
separate from the optional private Host Services invocation identity and grants
no callback access.

The provider's `resources/read` response for the declared URI contains exactly
one text content entry with that URI and MIME type `application/json`. Its text
is a complete snapshot:

```json
{
  "format_version": 1,
  "instance_id": "165c02b9-fb55-4d19-8f02-b8eb108bf1b7",
  "revision": 1,
  "resources": [
    {
      "kind": "session",
      "id": "provider-native-handle",
      "acquired_by": "09e2ae96-d486-45e1-9920-e54245210732",
      "state": "active"
    }
  ]
}
```

- `instance_id` is a UUID fixed for this provider connection instance. Reports
  must contain only resources acquired on that connection, including over HTTP.
- `revision` is a nonnegative signed 64-bit integer. Increase it whenever the
  snapshot changes. Equal revisions must describe equal resource sets; lower
  revisions and replacement instance IDs cannot discharge existing ownership.
- `kind` is a provider-defined identifier. `id` identifies the actual resource
  lifetime with a string or exact signed 64-bit integer. A reusable native handle
  may differ from this lifetime ID. Strings and integers remain distinct. The pair must be
  unique; strings are nonempty, at most 1,024 UTF-8 bytes, and contain no control
  characters.
- `acquired_by` is the host-supplied work-invocation UUID that acquired this
  resource. Keep that value while the resource exists. Unknown or expired
  references, foreign-connection references and changed creators are rejected.
- `state` is `active` or `uncertain`. Include work whose completion is unknown.
  Remove a resource only after its actual release or completion is established.

A row may additionally contain `handles`, a nonempty object of at most 16 named
native aliases. Names and values obey the same identifier bounds; values are
strings or exact signed integers. The name `id` is reserved for the row's primary
identity and cannot appear in `handles`. A known alias cannot change or disappear
while its resource lifetime remains present. A provider may add an alias when a
native reply establishes it. Reacquiring a reused native handle requires a new
resource lifetime and the correct acquisition reference.

The version-1 fields above are exact; other fields are rejected. Snapshots are
bounded to 512 KiB and 1,024 resources. A retained
thread, subscription, approval, interactive request, process or pending launch
can own work between tool calls. Record the acquisition before replying to its
tool call; a response must not leave unreported future background work. An
acquisition reference remains live while its invocation is unsettled or at least
one resource carries that binding. Derived work may inherit that still-live
binding, including a parent-to-child transfer in one snapshot. Once a completed
invocation has been covered by a valid snapshot and its final resource is gone,
the reference expires. Reacquisition then needs a current invocation reference.

The host reads after discovery and tool completion, coalesces resource update
notifications, and polls once per second while ownership or uncertainty remains.
There is at most one outstanding work read per connection. A stalled read marks
ownership uncertain without terminating the provider or issuing duplicate reads;
a late valid response can restore observation. A read started before an
invocation completed cannot discharge that invocation's observation barrier.
No tool is replayed by this process.

Malformed reports, lost transport and supervisor exit cannot prove detached work
completed. Only a valid complete snapshot on the owning instance releases absent
resources. Connection status includes `provider_work` counts and the last
accepted instance/revision; the bounded event stream records failed or timed-out
observations. A provider that does not advertise lifetime reporting retains an
uncertain owner after its first tool call. A reply alone cannot prove that such a
provider has no background work. `unreported_work` exposes this state; automatic
generation retirement preserves it. Verified exit of its managed local process
can release it, while closing a remote transport cannot.

### Continuation declarations

A tool that declares the work resource may also declare connection-local
`_meta["io.github.computer-mcp/continuation"]` metadata:

```json
{
  "format_version": 1,
  "selectors": [
    { "kind": "session", "handles": { "id": "/session" } }
  ]
}
```

Each selector names a resource kind and maps handle names to RFC 6901 JSON
Pointers in the tool arguments. `id` matches the primary resource ID; other names
match the row's optional native aliases. A selector matches only if all values
have the exact type and value on that resource. Missing fields make an optional
selector inapplicable. Supplied values must be bounded strings or exact integers;
malformed nested values do not silently become new work. Pointer escapes are
`~0` and `~1`; array indices use canonical nonnegative decimal notation.
An optional `nullable_handles` array can name a unique, nonempty subset of the
selector's handles whose explicit JSON null means no scope. For those handles,
null makes the selector inapplicable just like a missing field. Other supplied
handle values are still validated; this does not change the tool's input schema.

For a tool that dispatches several operations, an optional `when` field contains
`pointer` and `values`, for example
`{"pointer":"/operation","values":["read","cancel"]}`. The pointer must select
an exact string in the declared set before that selector applies. Missing or
unmatched operation names make it inapplicable; a supplied non-string is invalid.
The set contains 1–64 unique bounded strings and uses the same pointer bounds.
This distinguishes an operation creating a new handle from one continuing an
existing handle with the same argument shape.

There may be 1–16 selectors, each with 1–16 handles, within 16 KiB of encoded
metadata. Names and pointers are at most 1,024 UTF-8 bytes; pointers contain at
most 32 components. Unsupported fields/versions/pointers fail catalog validation.
A matching native alias is still a locator, never a permission grant or proof of
unique ownership across connections. Multiple matching lifetimes remain distinct.

The host validates and retains these declarations with the originating connection
and strips them from gateway aliases/reexports. The work ledger can match them
against accepted resource observations, including uncertain work. Observations
are scoped to the runtime, workspace and registration. Lost connections retain
their uncertain ownership evidence; a pending observation cannot prove a handle
is absent. Removed tool declarations remain available to locate retained owners.
A declaration for an existing tool cannot change while that connection retains
work or an unsettled observation. A connection retains at most 1,024 continuation
declarations. Catalog changes that exceed this budget fail atomically; a drained
connection can replace its declarations with the current catalog.

Host-selected continuation calls bind an exact connection, provider instance and
resource acquisition. Execution rechecks that binding and the original scalar
handle before dispatch. A reused native ID with a different acquisition cannot
satisfy an old selection. Missing owners fail without creating a replacement
connection; ordinary host policy and current permission checks still apply.
Ordinary MCP arguments and native handle values remain unchanged.

Clients can use the host's typed `runtime.owners.list` and `runtime.owners.call`
tools to select a retained instance explicitly. A locator binds the runtime,
workspace and a live host ownership lease, not just a reusable native handle.
The selected lease and original connection are rechecked before dispatch.
Current target authorization and operation approval remain mandatory; approval
tickets also bind the selected locator. See [Execution owners](Tools.md#execution-owners)
for paging, scope and call syntax. These host locators are not forwarded as
downstream arguments or accepted as authorization.

The local gateway listener keeps a stable dispatcher for each authenticated
connection. New work adopts the current configuration on a validated runtime;
continuations with a unique observed owner use their originating runtime within
the same principal, profile and caller scope. Duplicate owners, unsettled
observations on another connection, and unavailable owners fail before dispatch.
Private continuation bindings survive removal from the visible tool catalog
while their work remains owned. They do not restore a revoked permission.

Each new call also checks its registered workspace's current lifetime and root.
Removal, root rebinding or re-registration invalidates the old execution scope,
including under a wildcard workspace grant. Display metadata updates preserve
that scope. Existing work remains owned; a denied new call does not stop its
process. Owner directory queries use the current registration and omit retained
work whose original scope is no longer authorized.

Superseded runtimes retire only after their invocation and resource owners have
drained. Retirement reserves the runtime before asynchronous cleanup, preventing
new admission during shutdown. Pending construction and cleanup count toward the
128-runtime listener budget. Listener stop joins candidate construction and
invalidates its publication epoch, so a late candidate cannot enter a restarted
listener. Owner-side manifest and manual MCP management still use an explicit
listener restart. Plugin mutations and workspace add, remove and deduplication
prepare candidates for every admitted identity and profile while existing calls
continue. New identities wait at a bounded publication barrier. The host checks
the manifest and persisted inputs, commits the prepared configuration and
installs routing before notifying clients. A failed candidate or conflicting
input change leaves prior configuration and routing intact. Shutdown waits for
in-progress publication and its cleanup before completing.

When a continuation omits its workspace, cached ownership can identify its exact
original scope across registered workspaces. Multiple matching owners require an
explicit workspace or owner selection; the host does not dispatch by directory
order. The inferred scope still requires current authorization.

## Downstream Host Context

For stdio registrations created by `GatewayRuntime`, the host supplies
`COMPUTER_MCP_HOST_CONTEXT` as a UTF-8 JSON environment value, bounded to 16 KiB:

```json
{
  "formatVersion": 1,
  "runtimeID": "ed2868d1-5a81-4b59-a84a-8618c174a648",
  "caller": "secure-tunnel",
  "profileID": "chatgpt-observe",
  "workspace": { "id": "project", "rootPath": "/absolute/project" },
  "readOnly": true,
  "transportTrace": {
    "transport": "socket",
    "socketConnectionID": "connection-reference",
    "tunnelInstanceID": "tunnel-instance-reference",
    "tunnelProfileID": "tunnel-profile-reference"
  }
}
```

`runtimeID` identifies one gateway runtime lifetime, shared by its independently
scoped workspace sessions. It is not a downstream reconnect generation or a
request ID. The workspace path comes from host-resolved workspace access, not
the registration's optional launch `cwd`. Consumers must compare resolved path
identity and containment, including symlinks, rather than textual prefixes.
Transport trace and its connection/tunnel fields are optional provenance.

The host passes this value separately from inherited and registration-provided
environment dictionaries and injects it after their merge. Neither source can
override it. A standalone client or explicit connection validation without a
gateway runtime removes inherited/configured values of this reserved key.
Remote HTTP registrations do not receive this stdio environment contract.

The value contains no credential, capability grant or Full Shell approval.
`readOnly` conveys the host profile's independent mutation boundary; `false`
does not authorize a tool or grant unrestricted execution. The gateway checks
the current registration selection, risk, caller and workspace grant at each
call and retains audit ownership. Plugins cannot supply caller/transport
identity through tool arguments. A call cannot switch its gateway connection's
caller, profile or transport provenance while reusing that downstream session.

A local operator can supply any environment to a process launched outside the
gateway. Consequently this metadata is not authentication for callbacks into
the host, an OS sandbox, or permission for an adapter to access the host control
socket, credentials or approval database. Those authority boundaries remain
host-owned.

When explicitly enabled by the host, `COMPUTER_MCP_HOST_FD` separately identifies
an inherited connected Unix socket carrying standard MCP callbacks. The
optional `managedWorkspaceRoot` metadata field supplies the host-selected
managed directory. Neither value changes the northbound caller identity or
permits a plugin to connect to the administrator socket. See
[Scoped host services](HostServices.md) for authority, private tool discovery,
message bounds and cleanup requirements.

## Initialize

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": {
      "name": "protocol-debugger",
      "version": "1.0"
    }
  }
}
```

The initialize response advertises tools support, the configured server name
and title, and bounded server instructions for using the gateway tools.

## Tool Discovery

```json
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
```

The result contains the active profile's policy-filtered provider tools plus
any configured reexports. Tools include standard MCP operational annotations such
as `readOnlyHint`, `destructiveHint`, `idempotentHint`, and `openWorldHint`.
Local gateway and Codex tools also include a human-readable `title` and an
`outputSchema`. Downstream reexports preserve these fields when the provider
advertises them.
CLI/process and downstream MCP gateway tools are listed only when at least one
matching provider is configured.

Downstream discovery follows every `nextCursor` until the server omits it,
including empty intermediate pages. Cursors are opaque and scoped to that
discovery operation. A complete catalog is returned only after all pages
succeed and pass validation: names must be nonempty, NUL-free, and unique;
input schemas and any output schemas must be objects. Repeated cursors,
later-page errors, cancellation, and resource-limit failures reject the
discovery instead of returning partial tools.

A discovery is bounded by the configured server request timeout, 1,024 pages,
100,000 tools, and 32 MiB of re-encoded tool arrays plus UTF-8 cursor strings
across all pages. These catalog limits are additional to transport limits.
The server's exposure and tool authorization rules apply to tools on every
page.

The gateway advertises `tools.listChanged`. A downstream tool-list notification
triggers complete discovery and validation before definitions, capabilities,
and routing ownership are atomically replaced. Each initialized upstream
session has its own bounded change subscription. It receives
`notifications/tools/list_changed` when its visible tool definitions change;
reordering and changes outside its allowed surface do not generate a notice.
Names, descriptions, input/output schemas, annotations, and metadata participate
in the comparison. Caller authorization is checked again at dispatch.

Reexported catalogs are also refreshed every 30 seconds and on each upstream
`tools/list` request. A connection established by a downstream operation
invalidates the catalog; discovery itself does not recursively invalidate it.
A failed refresh retains the last validated snapshot. A manual `tools/list`
refresh failure is returned as an error, not reported as successful
synchronization. Active connections keep using their existing downstream
process; replacing an executable on disk requires reconnecting that registration.

Timeouts and connection errors retire the affected session without replaying
the tool call. Configuration replacement and reconnect wait for the preceding
owned process to exit; uncertain cleanup blocks a replacement. Closing the
client waits for both active and already-retiring sessions, including concurrent
startup. A stopped client cannot start another generation.
An inactive registration reports a retiring state while cleanup is pending and
a cleanup-failed state if its owned process has not confirmed exit, rather than
reporting it as an unused session.

On retirement, cancellation notifications have a bounded 250 ms delivery budget
before transport teardown. This confirms only the transport write, not that
the provider stopped the action. Stdio teardown closes input and allows 250 ms
for exit, then sends TERM to the owned group, allows another 250 ms, and escalates
to KILL with a 2-second exit budget. Startup ownership publication has a separate
5-second bound. Protocol lines are limited to 16 MiB and each inbound queue to
16 messages; overflow fails the session instead of silently dropping messages.
Read state before deciding whether an action with an uncertain outcome needs
another invocation.

For an awaited downstream tool call, an upstream `notifications/cancelled`
targets the native request belonging to that invocation, including calls through
reexported names, aliases and `mcp.tools.call` with `wait_for_result = true`.
Successful cancellation delivery does not close other requests on the session.
If delivery fails or exceeds 250 ms, the connection is retired. Delivery is not
proof that the vendor stopped its action. Calls admitted with
`wait_for_result = false` keep their independent request IDs and use
`mcp.requests.cancel` for explicit cancellation.

HTTP clients receive server-initiated notifications over their session's GET
SSE stream. A catalog invalidation before the first GET subscription is retained
as one pending notice and delivered when that subscription opens. Headers and
each event are flushed while the stream remains open,
and disconnecting cancels the stream reader. Clients must consume these
notifications and fetch the updated catalog. A client that does not support
live catalog updates needs to reconnect; server support does not imply that
every client refreshes automatically.

Tool results preserve the SDK-supported content types: text, image, audio,
resource links, and embedded text or binary resources. Their supported
annotations and metadata survive reexport alongside `structuredContent` and
`isError`; gateway execution metadata may also be attached. An empty content
array remains empty. Unsupported or malformed content produces an error rather
than silently dropping items or converting media to a text-only result.

App-owned manual registration changes restart a running gateway. Existing
socket sessions close, owned downstream processes are released, and clients
reconnect to obtain the replacement catalog. Clients must handle transport
termination and explicitly finish pending waits if their SDK does not do so.
A disconnected request has an unknown outcome unless independently verified;
neither the gateway nor the client should replay a write merely because its
response was lost.

Computer MCP's managed HTTP connections use the official SDK for JSON-RPC and
a host-owned HTTP transport for streaming. Each POST response and the standalone
GET event channel retain independent cursors. A truncated response with a cursor
is resumed through GET, never by repeating its POST. A truncated response with
no cursor reports an incomplete response; the caller must verify the action's
outcome before trying again. Session, negotiated protocol version, and configured
authorization headers accompany recovery requests. JSON bodies and individual
SSE events are bounded to 32 MiB; a full 32-message receive queue closes the
connection with an error rather than silently dropping messages.

Normal disconnect of a managed HTTP connection sends one best-effort DELETE
for its assigned session, retaining authentication and protocol headers. Concurrent
disconnect callers join the same cleanup. The request has a two-second timeout,
does not consume the response body and is not retried. Local closure proceeds when
the server refuses termination or cannot be reached; it does not establish that
remote state was deleted. A failed transport has already cancelled its local HTTP
session and does not promise remote termination.

Configured bearer credentials are resolved from the host Keychain for each POST,
GET/recovery and DELETE. A missing or inaccessible item fails that exchange
before network transmission; deletion cannot cancel already issued requests.
All HTTP redirects are rejected, and endpoint changes require a matching
host-owned binding. See [HTTP credentials](Config.md#http-credentials) for
configuration and the distinction from OAuth sign-in/refresh.

External clients must also keep stream cursors independent. The stock Swift MCP
SDK 0.12.1 HTTP transport shares a cursor between POST and GET and can miss
catalog notices by resuming a request stream instead of subscribing to the event
channel. Server notification support does not correct that client behavior.
Manual `tools/list` refreshes and validates the gateway catalog independently of
notification consumption. Stream ownership and GET recovery follow the
[MCP Streamable HTTP contract](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

The client-facing surface preserves canonical registry names such as
`cli.exec`. `tools/call`, tool descriptions, and machine-readable follow-up
references use the same identifiers without client-specific rewriting.

## Tool Call

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "cli.exec",
    "arguments": {
      "id": "git",
      "argv": ["status", "--short"]
    }
  }
}
```

Local gateway and Codex tool results contain:

- `content`: a JSON text representation for clients that consume MCP content.
- `structuredContent.result`: the same JSON value in a schema-declared
  structure for machine-readable follow-up calls.
- `isError`: the standard MCP tool error flag.

Downstream MCP calls and reexports preserve provider content,
`structuredContent`, `_meta`, and error state through the official SDK.

In the App-owned runtime, the bridge forwards these messages to the private
current-user Unix socket. Each socket connection owns an official SDK MCP
server session; the bridge does not parse or reinterpret tool payloads.

## HTTP Transport

`computer-mcp serve http` exposes the same MCP server through the official MCP
Swift SDK HTTP server transport. The default endpoint is:

```text
http://127.0.0.1:8765/mcp
```

For ChatGPT Web and a private local gateway, use OpenAI Secure MCP Tunnel with
the stdio server. The HTTP transport is intended for loopback inspection,
temporary no-auth transport probes, and compatible clients that can provide the
configured fixed bearer token.

For a public HTTP probe, put an HTTPS forwarding service in front of the
endpoint and configure `[server.http].public_base_url` with that HTTPS origin.
The gateway does not serve OAuth discovery, authorization, registration, or
token endpoints. An authenticated public ChatGPT deployment must use an
established OAuth 2.1 identity provider in front of the MCP server; ChatGPT does
not accept the gateway's fixed bearer-token mode as app authentication.

Health check:

```sh
curl http://127.0.0.1:8765/health
```
