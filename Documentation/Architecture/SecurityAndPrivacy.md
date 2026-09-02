# Security And Privacy

Computer MCP executes local capabilities as the current logged-in macOS user.
Its primary security boundary is explicit local configuration and least
authority, not sandboxing an arbitrary remote shell.

## Authority Boundaries

- `chatgpt-observe` is read-only and cannot use Codex, writes, CLI execution, or
  Shell.
- `chatgpt-operate` receives only locally configured capabilities and
  workspaces. Its local operator may explicitly enable Full Shell for the
  profile; the manifest policy and persisted profile grant must both opt in.
- `cloudflare-observe` and `cloudflare-operate` use separate caller grants and
  never inherit ChatGPT authority.
- `local-admin` is local-only and rejected for remote callers.
- All workspace operations resolve a stable registered id and normalized path.
- More than one workspace requires explicit selection.
- Unknown tools, providers, Codex RPC methods, paths, and capabilities fail
  closed.
- ChatGPT cannot request or wait for a permission expansion.

Full Shell is equivalent to the current user's effective terminal authority.
It is available only to `chatgpt-operate` and `local-admin`, remains off by
default, and can be enabled only through the local control plane. If enabled,
workspace bookmarks are routing and audit context, not containment.

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

## Codex

Codex App Server, Exec, and MCP use gateway-owned workspace, sandbox, approval,
session, and output policy. An unscoped `danger-full-access` value, raw remote
argv/config overrides, authentication mutation, marketplace mutation, and
remote-control pairing are rejected. The configured default sandbox remains
`workspace-write`; callers cannot replace it in a thread or turn request.

An authorized caller may request a separately persisted Codex execution
elevation. The request itself grants nothing. It is bound to the registered
workspace id and canonical root, profile, caller, connection, optional exact
thread, requested mode, duration/turn limits, and redacted reason. Approval and
denial require a local caller using the `local-admin` profile. The supported
modes are one next eligible turn, an exact thread with a TTL, and bounded time
with an optional turn limit. Pending requests expire after 15 minutes; approved
grants expire, can be revoked, and are invalidated by a matching workspace or
profile disable/removal, provider shutdown, or thread handoff.

An approved grant never hot-switches an active turn. The runtime claims it
atomically for an eligible future `thread/start` or `turn/start`, applies the
official `dangerFullAccess` sandbox to that start, and commits consumption only
after the upstream start succeeds. If a start cannot produce both a confirmed
response and durable consumption receipt, its claim is invalidated and its
exact owned runtime is stopped; ambiguous access never becomes reusable.
One-turn grants cannot be consumed twice, including across restart. Revocation
leaves an already active turn unchanged and restores the configured safe
sandbox for future starts.

Codex sandbox elevation is not Computer MCP capability elevation. It does not
add gateway tools, profile grants, registered workspaces, Full Shell, operation
tickets, TCC permissions, downstream MCP tools, or approval authority. In
particular, an elevated Codex turn cannot invoke a Computer MCP capability such
as `file.write` unless that capability was already granted independently.

Codex App Server approval is a two-level boundary. Gateway policy first
authorizes the capability for the bound caller, profile, and registered
workspace. A supported higher-risk request then enters the durable consent
broker for approve-once, an official protocol-bounded session approval, denial,
or timeout. Policy authorization never implies consent, and consent cannot
expand policy. Automatic approval is off by default and, when explicitly
enabled, applies only to the bounded low-risk workspace-write class.
For registered Computer MCP tools, the gateway authorizes the static tool
capability first and then derives consent risk from the reviewed invocation.
A built-in dry-run path whose implementation is known not to mutate state is
treated as read-only for consent, so repeated previews such as
`git.add` with `dry_run=true` do not create mutation approvals. The downgrade
does not apply to configured or downstream tools and does not widen the tool,
workspace, profile, caller, or path grant.

Approval records contain normalized redacted details, risk, workspace,
runtime, thread, turn, request correlation, deadline, decision, and terminal
reason. Credential-like fields and sensitive free text are redacted and
bounded before persistence. A restart marks an unresolved live request as
interrupted; the receipt remains auditable, but Computer MCP does not claim the
upstream request can be replayed.

Codex event buffers are count- and byte-bounded, and every retained event is
redacted before it becomes observable. Interactive requests and both App Server
and MCP approval views apply the same redactor. Credential-like or oversized
protocol request identifiers are represented by a SHA-256 digest instead of
being copied into runtime state, diagnostics, or persistence. JSONL protocol
lines are bounded in both directions.

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
- `operations.ticket_required`, `operations.ticket_invalid`, and
  `operations.ticket_expired_or_used` for two-phase operation enforcement;
- `mcp.tool_not_approved` for downstream catalog drift;
- `codex.app.override_denied`, `codex.app.danger_full_access_denied`, and
  `codex.app.workspace_override_denied` for rejected Codex App authority
  changes. `codex.app.danger_full_access_denied` continues to cover raw or
  mismatched overrides; an effective scoped grant is consumed internally and
  does not weaken this validation rule.

Malformed arguments and provider/runtime failures remain `failed`. Acceptance
tests must correlate the client-visible code, Gateway request ID, and exact
audit row rather than inferring a denial from message text alone.

## Persistence And Logging

GRDB stores workspaces, profiles, provider health, manifest revisions,
operation tickets, and redacted audit metadata. The Data Protection Keychain
stores transport keys and access token values.
App logs are JSONL, mode `0600`, rotated, bounded, and redact secret-like
fields.

The App does not intentionally persist full command output, file contents,
screenshots, or credentials. Tool results can still contain sensitive user
data while in transit and must be treated accordingly by the MCP client.

## Main Risks

- A registered CLI or downstream MCP provider can act with its own local
  credentials.
- Full Shell can read, modify, execute, and communicate as the user.
- Computer Use can operate visible UI after local TCC grants.
- A leaked remote bearer or overly broad caller/profile grant can expose the
  configured remote surface.
- Provider output may itself contain secrets despite audit redaction.

Minimize enabled capabilities, use `chatgpt-observe` first, keep Full Shell off
unless the target ChatGPT workspace is trusted for terminal-equivalent access,
review Tunnel tool snapshots after metadata changes, and remove sensitive data
from diagnostics before sharing it.
