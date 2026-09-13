# MCP Protocol Reference

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
