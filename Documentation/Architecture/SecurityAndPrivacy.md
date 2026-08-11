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
same Team ID and Bundle ID, so they share the same private group without the
file-based Keychain's per-binary ACL prompts. The opt-in development App uses a
different Bundle ID, group, service, and Application Support directory.

The App fails closed when its signed Team metadata, environment, Bundle ID,
embedded provisioning profile, or private Keychain entitlement do not agree.
Ad-hoc artifacts therefore validate packaging in CI but cannot open the live
App control plane or its secrets. There is no product fallback to the legacy
file-based Keychain.

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
session, and output policy. `danger-full-access`, raw remote argv/config
overrides, authentication mutation, marketplace mutation, and remote-control
pairing are rejected.

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
  changes.

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
