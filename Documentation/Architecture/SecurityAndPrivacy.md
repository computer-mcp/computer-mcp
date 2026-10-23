# Security And Privacy

Computer MCP executes local capabilities as the current logged-in macOS user.
Its primary security boundary is explicit local configuration and least
authority, not sandboxing an arbitrary remote shell.

Authorization has two levels: the host first decides whether a capability is
permitted at all; the user or caller then decides whether a permitted
higher-risk action is approved now. Changes preserve or strengthen registered
project boundaries, profile capability and caller binding, path and symlink
validation, explicit approval for mutation, registered tool dispatch, local-only
sensitive execution, request audit, credential and sensitive-text redaction,
fail-closed defaults, verified control of external processes, and bounded
input, output, persistence and lifecycle resources.

## Authority Boundaries

- Each profile explicitly defines permission mode, capabilities, projects,
  allowed callers and confirmation policy. Its name and transport do not
  determine its permission mode.
- `read-only` permits host-classified reads. `project-operations` permits
  granted typed operations, subject to their path and confirmation rules.
  `local-full-access` additionally permits separately enabled arbitrary
  execution; choosing this mode alone does not enable Shell or grant tools.
- `local-admin` is local-only and rejected for remote callers.
- All project operations resolve a stable registered id and normalized path.
- More than one project requires explicit selection.
- Unknown tools, providers, paths, and capabilities fail
  closed.
- Remote callers cannot approve host tickets or expand their own grants.

Arbitrary shell execution is equivalent to the current user's effective terminal
authority. The effective grant must permit `local-full-access` and Full Shell,
and the static TOML Shell policy must explicitly enable the facility. Both the
facility and client Full Access are off by default. Project bookmarks are
routing and audit context, not containment for an approved arbitrary command.

Downstream MCP annotations are presentation hints, not host authorization.
Registration assigns each exposed tool its actual server/tool identity;
neither a tool-name prefix nor downstream `_meta` can supply that identity.
Host risk classification and tool selection apply to configured aliases,
reexports, and generic calls. A generic invocation resolves its target's host
risk before policy, consent preflight, or operation-ticket handling. A
target requiring confirmation uses the same ticket through every calling path.

Profiles may receive an entire MCP registration through host-owned
`mcp_servers`, including remote profiles. Registration selection and profile
authorization are intersected at discovery and execution; an all-tools
selection follows future tools without copying a static capability list.
Exact alias and reexport grants refer to the same underlying tool. The explicit
generic `mcp.tools.call` capability grants host-selected tools across
registrations; generic discovery alone grants no tool authority. Catalog
counts and definitions are filtered before exposure. Permission-mode and
Full Shell boundaries still apply. App-managed grants are versioned in the
database and reread for calls and discovery; a change invalidates the affected
pending approvals without restarting unrelated Gateways or tunnels.

## Principals And Local Confirmation

Verified local peer credentials establish the local-user principal. Secure
Tunnel admission binds the registered bridge identity; authenticated HTTP
binds the validated credential. A connection id is tracing information, not
authority. Reconnection with the same credential retains the same principal;
clients sharing a credential share principal-level grants. Client-supplied labels
cannot establish a separate principal. Profile, project and caller checks still apply.

The App gateway and standalone HTTP gateway bind each admitted MCP session to a
host-created authorization object. The local owner can limit or end that session
without changing another connection's grant or stopping its runtime. A new
session starts with its profile's Observe or Restricted Control authority; a
configured Full Access profile alone does not approve the connected client.
New calls, discovery, selected
execution-owner calls and retained Host Services invocations reread the session's
current authority. A disconnected session loses this authority while its existing
execution resources remain owned until they drain. Serialized execution context,
connection labels and tool arguments cannot recreate the authorization object.
An HTTP session retains its scope across requests and event-stream reconnections.
Session DELETE, idle expiry and listener shutdown end that scope. A newly initialized
session receives a new scope while the same principal retains its execution runtime
until the listener stops.
App HTTP origins participate in the App's atomic configuration publication and
retained execution-owner routing. Runtime ownership is separate for each listener;
sharing a credential does not share session consent or shutdown ownership across
listeners. The App's local owner operations manage both socket and HTTP scopes.

The local control plane can explicitly approve Full Access for a selected
session. The default lifetime is This Session. Its effective grant includes
all enabled capabilities and projects and permits normal operations without
repeated confirmation. Verified caller admission, local-only actions, the static
Shell policy and macOS permissions remain enforced; the principal never becomes
`local-admin`. This decision does not change the persisted profile.

Always Allow this Client is a separate local choice. Client trust is bound to
verified principal, profile and caller, with an expected trust revision. The
consent audit and persistent trust update commit together before authority is
published. Trust cannot be inferred from a client label or a configured profile.
Only a new session with the same verified identity and unchanged profile can
restore active trust. An already connected Restricted session does not acquire
another session's approval. Selecting This Session replaces that client's
persistent trust; revocation removes it from existing and future sessions.

Consent binds the configured or persisted profile authorization and its source.
Derived Observe catalog or project additions alone do not change that authorization. Database grants are reread for admission; atomic configuration
publication updates the session baseline for current and retained invocations.
A changed profile invalidates consent and advances the session revision. A
TOML-only profile remains configuration-owned after approval. Disconnecting,
limiting or ending a session removes its current Full Access; a separate persistent
trust revocation controls whether future connections may restore it.

Operation tickets issued in a control session also bind that session's identity
and revision. Another session using the same credential cannot consume the ticket,
and restoring access after a change does not revive an older ticket. Generic host
callbacks require a common live control session among their originating invocations;
ambiguous sessions cannot borrow one another's permissions.

The default `risk-based` policy requires local confirmation for host-classified
destructive, external-write and arbitrary-execution operations. `all-writes`
also confirms project writes; `never` is an explicit local operator choice.
Classification cannot inspect all effects hidden inside an arbitrary script.
Project checks remain application-level validation, not an OS sandbox.

A ticket moves through `pending_approval`, `approved`, `denied` or `expired`;
an operation not requiring confirmation starts `prepared`. Approval is an
owner-only App/management CLI action. A model-supplied `confirm` field is not
approval. Commit binds the verified principal, exact arguments, project,
reviewed target state and authorization revision, then consumes the ticket
once. Approval does not grant a missing capability. Changing the grant
invalidates its pending tickets and prevents newly unauthorized calls;
stopping owned in-flight work is a separate action, not a side effect of
revocation or client disconnection.

## Transport And Secrets

The remote paths are:

```text
ChatGPT -> OpenAI Secure MCP Tunnel -> local stdio bridge -> private user socket
Remote MCP client -> Cloudflare named tunnel -> bearer-authenticated loopback HTTP
```

OpenAI and Cloudflare tokens and the Computer MCP Access Token are stored in
the macOS Data Protection Keychain. Every operation sets
`kSecUseDataProtectionKeychain`, the provisioned private access group
`<TeamID>.<BundleID>`, and an environment-specific service ending in
`.secrets`. New items use `AfterFirstUnlockThisDeviceOnly` so desired tunnels
can restore in the logged-in user context without an interactive biometric or
password policy. The production Development and Developer ID builds use the
same Team ID and Bundle ID and therefore share the same private access group.
This group-based Data Protection Keychain contract does not attach credentials
to an individual App binary, so routine builds with the stable signed identity
do not require an owner prompt. The opt-in development App uses a different
Bundle ID, group, service, and Application Support directory.

The App fails closed when its signed Team metadata, environment, Bundle ID,
embedded provisioning profile, or private Keychain entitlement do not agree.
Ad-hoc artifacts therefore validate packaging in CI but cannot open the live
App control plane or its secrets. Data Protection Keychain with the provisioned
private access group is the sole App secret store.

The App materializes the Cloudflare token only as a temporary `0600` file for
`cloudflared`. Consumer-owned Cloudflare Access service tokens are not stored
by Computer MCP. Downstream CLI credentials, provider tokens, and Codex login
state stay in their existing local stores. Secrets are not copied into TOML,
audit records, examples, exports, or App logs.

The private socket validates current-user ownership and peer credentials. The
App is the sole service owner and cleans up its socket and owned processes on
normal termination.

Cloudflare release mode uses authenticated loopback HTTP and a remotely-managed
named tunnel. Quick Tunnel and anonymous HTTP are development Validation Test Cases
only. Header-capable consumers use the Computer MCP Access Token; replacing it
through the owner control plane immediately updates the running listener.

OAuth is enabled per Cloudflare connection and defaults off. The gateway is both
the protected resource and authorization server on that connection's public HTTPS
origin. Its OAuth routes require the public Host; loopback Host requests cannot
use them. Public clients identify through HTTPS Client ID Metadata Documents
(CIMD), with exact hosts on the owner-managed allowlist (default `claude.ai` and
`claude.com`). The credential-free fetch is bounded to 64 KiB and eight seconds,
does not follow redirects, and pins a checked public numeric destination while
URLSession performs TLS validation. Private, loopback and special-use destination
addresses are refused. The document must bind its own URL and the exact redirect
URI; registered loopback redirect ports are ignored during matching.

The browser displays client and redirect hosts and a six-character pairing code.
It can only poll a separate opaque status handle. Approval and denial require the
local App control plane or owner CLI. Pairing expires after ten minutes. Approval
creates a grant for the selected remote profile, default `cloudflare-observe`.
Its principal is `oauth:<grant ID>` and its caller is `cloudflare-tunnel`.
OAuth authenticates that identity; profile, project and per-session Full Access
consent still apply. Client secrets and Dynamic Client Registration are not part
of this authorization surface.

Authorization codes and tokens contain 256 random bits; GRDB stores their SHA-256
digests and bindings, never their plaintext. Codes expire after 60 seconds and
bind client ID, exact redirect URI, S256 PKCE and resource. Access tokens last one
hour and bind `https://<hostname>/mcp`. Refresh tokens rotate on every use and
expire after 30 idle days. Reuse of a rotated refresh token revokes its grant.
Owner grant revocation invalidates all of its tokens immediately. RFC 7009 access
token revocation invalidates that token; refresh token revocation invalidates the
grant. Grant revocation from Client access, the owner CLI, refresh-token revocation
or refresh-token reuse also ends the grant's active gateway sessions and open
streams. Audit records `oauth.grant_revoked` and completion as
`oauth.sessions_ended`, bound to the grant principal. OAuth credentials never enter
Keychain. In-flight OAuth admissions retain principal revocation state until they
drain, so revocation during idle cleanup or initialization cannot publish a new
session. The service keeps one lock-protected Access Token digest per Cloudflare
profile across listener startup and shutdown; rotation and rollback publish the
digest synchronously after the corresponding Keychain write. Saves and deletion
serialize each profile's credential mutation from the initial secret reads
through activation and rollback.

HTTP admission precedes body accumulation. With OAuth enabled, `/mcp`
authentication pauses channel reads until the credential is checked; failure
returns 401 with the resource metadata challenge and closes the connection.
Without enabled OAuth, synchronous Bearer authentication runs at the request
head. OAuth routes consume their address rate allowance at the head. Headers are
limited to 16 KiB, OAuth bodies to 16 KiB and authenticated MCP bodies to 8 MiB;
both declared lengths and arriving bytes are checked, with 413 and close on
overflow. A request must complete its body within 15 seconds of its head (also
15 seconds to supply an initial head), or receive 408 and close. Each listener
admits at most 32 connections awaiting authentication; excess connections receive
503 and close. Public OAuth connections retain this reservation until MCP
authentication or disconnect, with the same 15-second idle deadline.

Each tunnel admits at most 128 pending or approved pairings, including at most
three per tunnel-reported client address. Admission is reserved before CIMD
identification: at most one fetch per address and four per tunnel may run at
once. Capacity rejection returns 429 `temporarily_unavailable` without fetching;
failure and cancellation release the reservation.

The token endpoint returns 400 `invalid_request` for missing, empty or duplicate
parameters and unsupported content types, `unsupported_grant_type` for an unknown
grant type, `invalid_scope` for scopes other than `mcp`, and `invalid_grant` for
invalid, expired, reused or mismatched codes, refresh tokens or their bindings
(client, redirect, PKCE or resource). Unsupported client authentication returns
401 `invalid_client`, with a `WWW-Authenticate` challenge matching an attempted
Authorization scheme (`Basic` for Basic requests). After validating a registered
callback, authorization errors redirect with `unsupported_response_type` or
`invalid_scope`. Appended callback parameters use percent encoding with only RFC
3986 unreserved characters left literal, preserving the registered URI's existing query.

OAuth endpoints and failed Bearer requests use address token buckets, with grant
buckets for grant-bound operations. OAuth audit records requests, local decisions,
expiry, token issuance, refresh, token and grant revocation, and refresh reuse.
Failed Bearer audit is limited to one summary event per minute per listener.
No credential values enter these events. Cloudflare Verified requires an allowed
tool audit event from the current Access Token or a live OAuth grant, bound to
that credential's profile and the current tunnel start. OAuth protocol events
cannot establish Verified; replacement or revocation removes the affected
credential's verification evidence.

## Local Client Configuration

Local registration writes the generated server command and arguments only.
Codex and Claude Code changes go through their own CLIs with a configuration
location bound at preview. Codex is queried with `mcp get --json`; Claude Code's
user-scope file is read directly because its health-query commands start
servers. Claude Desktop's configuration is changed only while its App is
closed. No manifest contents, tokens or credential values are registered.

The complete named entry is retained privately for comparison and Claude Code
recovery. Other fields in a JSON file are parsed to preserve the file and are
never retained in a plan. Displayable entries contain only type, command or URL
origin, argument count, and environment/header names. Argument values, URL
userinfo/path/query/fragment, environment/header values, client stdout/stderr
and `add-json` recovery payloads are never printed, logged or returned in errors.

An advisory writer lock serializes the App and CLI, and apply rechecks the
private plan's fingerprint. Other programs retain their client's own write
protections. Desktop rejects symlinks and nonregular files, compares bytes,
inode, mode and size immediately before rename, and uses exclusive rename to
create a missing file only inside an existing support directory. Temporary
files start at `0600` before content is written; replacement preserves the
existing mode and new files stay `0600`. Another program writing an existing
Desktop file after the final check can lose its update, so plans ask users to
close other configuration editors.

Client executables are selected from an explicit path or host search directories
and `~/.local/bin`. Their exact environment contains only basic user/locale/temp
variables, the bound client configuration variable and a constructed PATH.
Timeout kills the process group; recovery waits for confirmed exit. An uncertain
exit stops the sequence and is never reported as success. Unsupported Claude
Code entries cannot be replaced because they cannot be restored faithfully.

## TCC And Computer Use

Screen Recording and Accessibility permissions belong to the signed App.
Remote MCP calls never trigger a permission prompt. The App reports current
status; its local **Request Access** action invokes the public TCC request API,
opens the matching Privacy & Security page, anchors a noninteractive coach to
the System Settings window when its public window metadata is available, and
polls until the state changes. The coach omits its arrow when the window cannot
be located. Denied capabilities fail deterministically. ChatGPT's separate
**Lock Screen Operations** setting only
allows ChatGPT's own Computer Use principal to operate while the Mac is
locked; it does not grant or transfer TCC permissions to `Computer MCP.app`.
Application-specific automation remains in `apple-cli-mcp`.

Computer Use cannot perform Accessibility actions on the Computer MCP host
process. This prevents a remote caller from turning generic UI automation into
an implicit App administration channel and avoids re-entering AppKit menu
presentation from a non-main executor. App administration uses the local
SwiftUI adapter or owner-only `computer-mcp` control CLI.

## Plugin execution

The host authorizes plugin invocations through caller identity, profile and
registered project. Plugin runtime permissions and vendor configuration belong
to the plugin; see the [Codex plugin](https://github.com/computer-mcp/plugin-codex) for its execution model.

Callbacks into host tools require current host grants and operation approvals.
A plugin approval does not authorize a host operation. Verified builtin dry runs
can have read-only consent risk; unverified downstream `dry_run` arguments do not
lower risk. Host approval previews and audit summaries redact credentials and
bound their size. Canonical inputs remain bound to the exact operation ticket.

## Stable Denials And Audit Decisions

Security-policy refusals return stable bracketed codes and are stored with the
GRDB audit decision `denied`, not the generic execution decision `failed`.
Representative codes include:

- `policy.project_denied` for traversal, symlink escape, and cross-project
  access;
- `operations.approval_required`, `operations.ticket_invalid`, and
  `operations.ticket_expired_or_used` for operation approval and consumption;
- `mcp.tool_not_approved` for downstream catalog drift.

Malformed arguments and provider/runtime failures remain `failed`. Acceptance
tests must correlate the client-visible code, Gateway request ID, and exact
audit row rather than inferring a denial from message text alone.

## Persistence And Logging

GRDB stores projects, profiles, provider health, manifest revisions,
operation tickets, OAuth requests/grants and credential digests, bounded MCP execution receipts and redacted audit metadata. The Data Protection Keychain
stores transport keys and access token values.
App logs are JSONL, mode `0600`, rotated, bounded, and redact secret-like
fields.

Execution receipts retain bounded downstream results for reconnect queries;
these can contain sensitive command output, file contents or provider data.
Their local storage is private user data, not a redacted audit log. Output
expires after 24 hours and is subject to per-result and aggregate budgets;
deduplication metadata remains when output expires. See the
[request result contract](../Reference/Tools.md#mcprequestsread).

## Main Risks

- A registered CLI or downstream MCP provider can act with its own local
  credentials.
- Full Shell can read, modify, execute, and communicate as the user.
- Computer Use can operate visible UI after local TCC grants.
- A leaked remote bearer or overly broad caller/profile grant can expose the
  configured remote surface.
- Provider output may itself contain secrets despite audit redaction.

Minimize enabled capabilities, use read-only mode first, keep Full Shell off
unless the target ChatGPT workspace is trusted for terminal-equivalent access,
review Tunnel tool snapshots after metadata changes, and remove sensitive data
from diagnostics before sharing it.
