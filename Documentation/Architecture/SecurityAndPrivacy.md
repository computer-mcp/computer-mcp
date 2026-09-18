# Security And Privacy

Computer MCP executes local capabilities as the current logged-in macOS user.
Its primary security boundary is explicit local configuration and least
authority, not sandboxing an arbitrary remote shell.

## Authority Boundaries

- Each profile explicitly defines permission mode, capabilities, workspaces,
  allowed callers and confirmation policy. Its name and transport do not
  determine its permission mode.
- `read-only` permits host-classified reads. `workspace-operations` permits
  granted typed operations, subject to their path and confirmation rules.
  `local-full-access` additionally permits separately enabled arbitrary
  execution; choosing this mode alone does not enable Shell or grant tools.
- `local-admin` is local-only and rejected for remote callers.
- All workspace operations resolve a stable registered id and normalized path.
- More than one workspace requires explicit selection.
- Unknown tools, providers, Codex RPC methods, paths, and capabilities fail
  closed.
- Remote callers cannot approve host tickets or expand their own grants.

Full Shell is equivalent to the current user's effective terminal authority.
It requires `local-full-access`, the separate Full Shell grant, and the static
Shell policy. It remains off by default and is enabled through local
administration. If enabled,
workspace bookmarks are routing and audit context, not containment.

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
clients sharing a credential share authority and cannot be distinguished by
client-supplied labels. Profile, workspace and caller checks still apply.

The default `risk-based` policy requires local confirmation for host-classified
destructive, external-write and arbitrary-execution operations. `all-writes`
also confirms workspace writes; `never` is an explicit local operator choice.
Classification cannot inspect all effects hidden inside an arbitrary script.
Workspace checks remain application-level validation, not an OS sandbox.

A ticket moves through `pending_approval`, `approved`, `denied` or `expired`;
an operation not requiring confirmation starts `prepared`. Approval is an
owner-only App/management CLI action. A model-supplied `confirm` field is not
approval. Commit binds the verified principal, exact arguments, workspace,
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

Cloudflare release mode always requires the Computer MCP Access Token and a remotely-managed
named tunnel. Quick Tunnel and anonymous HTTP are development Validation Test Cases
only. Computer MCP does not implement an OAuth authorization server.

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

## Codex

The host authorizes access to the Codex plugin using the authenticated caller,
profile and registered workspace. The plugin and `swift-codex` preserve native
App Server and Exec semantics. Omitted execution settings inherit Codex
configuration; explicit supported settings retain their official meaning.
Provider, MCP, Skills, hooks and authentication remain Codex-owned.

Native Full Access may be the user's configured default or an explicit request.
It carries the operating-system permissions of the executing user. A workspace
is an initial directory and ownership reference, not containment for arbitrary
execution. The host does not silently lower an accepted native mode. A denied
host capability is rejected before invoking the plugin.

Native execution approval requests retain their official response shapes,
decision scopes and cancellation semantics. The adapter preserves correlation,
deadline and terminal state so a lost connection is not mistaken for approval
or replay authorization. Account management, marketplace management and remote
pairing are outside the coding surface.

Dynamic Codex requests for Computer MCP tools are independently subject to
host policy. Local control-plane confirmation applies to host operation
tickets; a native Codex approval does not resolve such a ticket or expand host
tool, workspace, profile, path or system permissions. Builtin dry-run paths
whose implementation is known not to mutate state have read-only consent risk.
Unverified downstream `dry_run` arguments do not lower risk.

Host approval previews and audit summaries redact credentials and bound their
size before persistence. Complete canonical inputs are bound to the operation
ticket, not copied into its human-facing preview. Protocol output and retained
events are bounded; consumers must distinguish native payloads from sanitized
diagnostic summaries. Unresolved native approvals after restart remain
auditable receipts, not reusable authority.

Runtime cleanup is receipt- and ownership-based. Computer MCP may unsubscribe
threads and signal only the exact process group created by the current owned
runtime generation. Stale-receipt cleanup is previewable before mutation and
does not grant control over Codex Desktop, IDE, CLI, or another gateway.
External writer ownership remains an inference unless a Computer MCP receipt
and live runtime prove it. A deliberate reclaim asks the official App Server to
resume the thread and returns a writer conflict without terminating an
unverified process.

Managed Git worktrees use the same verified-ownership rule. Provisioning is
bound to a registered source repository, active parent lease, reviewed branch
and start commit, derived Application Support path, and short-lived persisted
plan. Removal requires the Computer MCP ownership receipt, inactive child
lease, no live child runtime, exact common-repository match, clean status,
unchanged reviewed HEAD, explicit confirmation, and a gateway operation ticket.
The managed root and worktree must resolve as real, current-user-owned
directories under the canonical managed root; a receipted path replaced by a
symbolic link is rejected. Removal does not use force or delete the preserved
branch. Paths created by users or other tools have no qualifying receipt and
are never cleanup targets.

## Stable Denials And Audit Decisions

Security-policy refusals return stable bracketed codes and are stored with the
GRDB audit decision `denied`, not the generic execution decision `failed`.
Representative codes include:

- `policy.workspace_denied` for traversal, symlink escape, and cross-workspace
  access;
- `operations.approval_required`, `operations.ticket_invalid`, and
  `operations.ticket_expired_or_used` for operation approval and consumption;
- `mcp.tool_not_approved` for downstream catalog drift.

Malformed arguments and provider/runtime failures remain `failed`. Acceptance
tests must correlate the client-visible code, Gateway request ID, and exact
audit row rather than inferring a denial from message text alone.

## Persistence And Logging

GRDB stores workspaces, profiles, provider health, manifest revisions,
operation tickets, bounded MCP execution receipts and redacted audit metadata. The Data Protection Keychain
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
