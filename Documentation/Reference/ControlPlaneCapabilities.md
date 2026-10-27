# Control Plane Capabilities

The embedded CLI and SwiftUI App are adapters over the same lifecycle-aware App
control operations. Read the exact installed inventory as JSON:

```sh
computer-mcp app capabilities
```

Each entry contains `id`, `cli_command`, `surface`, `read_only`, `destructive`,
`idempotent`, and `local_only`. The embedded CLI reads the catalog directly, so
it remains available when the App is stopped. The same catalog validates the
current-user control socket and is never part of a remote profile's MCP tool
list. Standalone HTTP hosts expose the six session/trust `clients` contracts and the
permission request, answer and authority-confirmation contracts on their explicit
private owner socket. They do not expose App lifecycle or configuration commands.

| Family | Shared operations | CLI entry points | UI |
| --- | --- | --- | --- |
| App | status, start, stop, restart, launch at login | `app …` | Home and Settings |
| Client access | list, explicit Full Access consent, limit/end connection access, saved trust list/revoke | `clients …` | Client access |
| OAuth client access | pending pairing requests, local approval/denial, grant list/revocation | `clients authorizations`, `clients authorize`, `clients deny`, `clients grants`, `clients revoke-grant` | Client access |
| Readiness | local, ChatGPT, and Cloudflare journey checks | `doctor` | Home and Diagnostics |
| Configuration | show, validate, export, digest-guarded import, history, rollback | `config …` | Diagnostics manifest editor and revision rollback |
| Projects | list, canonical add, remove, per-profile Read/Write/Deny/Ask, deduplication | `project …` | Projects |
| Profiles | list, show, activate, project grant/revoke, permissions, execution mode and network settings | `profile …` | Connection defaults and permission editing |
| Providers | recorded health and bounded Doctor refresh | `providers list|doctor` | Providers |
| Permissions | non-prompting TCC status; list and answer durable permission requests; review and confirm saved authority | `permissions status`, `permissions requests`, `permissions answer`, `permissions confirm-authority` | Privacy & Security, pending requests and captured authority review; TCC prompting remains an explicit local UI action |
| Audit | bounded redacted event list | `audit list` | Audit |
| Gateway tools | list, inspect, and policy-controlled local-admin call | `tools …` | CLI-only diagnostic escape hatch |
| OpenAI Tunnel | list, Doctor, start, reconnect, stop, provision, logs, save, remove | `tunnel openai …` | Tunnels |
| Cloudflare Tunnel | list, Doctor, start, stop, logs, save, remove | `tunnel cloudflare …` | Tunnels |

## Remote management

App-managed gateway connections expose typed management through their verified
session. The host applies the same permission evaluation, execution metadata and audit
as other tools. Full Access must already have explicit local consent; normal
project changes and verified official plugin changes need no additional prompt.
Standalone fixed-manifest gateways expose their configured execution tools and
optional local client-consent socket.

| Tools | Inputs and authority |
| --- | --- |
| `project.list`, `project.describe` | ID, display name and access status without Project permission; detailed metadata needs access. Describe takes `project_id`. |
| `project.add` | Full Access; absolute `path`, optional `display_name`. |
| `project.repair` | Full Access; `id`, new `path`, reviewed `expected_root_path`, optional `display_name`. |
| `project.remove` | Full Access; `id`, reviewed `expected_root_path`. Removes the registration, preserving files and retained work. |
| `project.grant` | Full Access; `id`, `access` (`read`, `write` or `deny`), `expected_profile_revision`. Changes only the connection's profile. A changed profile invalidates its prior Full access consent. |
| `profile.show` | Inspect the connection's own session, profile and revisions. |
| `profile.limit` | `limits` ([`ManagedPolicy` JSON](Config.md#managedpolicy-json)) and `expected_revision`; must narrow this session's effective ceiling. |
| `plugin.list`, `plugin.describe` | Inspect safe plugin summaries and exact store revision. Both accept `after_id` and `limit` (default 50, maximum 200); describe takes `id` and pages its installations. |
| `plugin.search` | Official static catalog; optional `query`, `kind` (`mcp`, `cli`, `skills`), `page` (starts at 1), `refresh`. |
| `plugin.artifacts` | `repository`, exact integer `repository_id`, optional `tag` and `page`. |
| `plugin.install`, `plugin.update` | Full Access; returned `artifact` and exact store `expected_revision`. Update also requires the existing plugin `id`. GitHub provenance and downloaded bytes are revalidated. |
| `plugin.configure` | Full Access; `id`, `settings` patch and `expected_revision`. Supports the existing plugin settings document fields; MCP authentication stays with the local credential owner. |
| `plugin.enable`, `plugin.disable` | Full Access; `id` and `expected_revision`. Activation requires bundled or verified official code. |
| `plugin.uninstall` | Full Access; `installation_id` and `expected_revision`. Active work retains its artifact lease. |

Tool listings include requirements and requestable tools within managed limits.
Full access consent changes execution mode without granting permissions.
Read summaries omit credential bindings and launch argument values. Input objects
reject unknown fields. Results use the normal gateway envelope and
`structuredContent.result`; errors use `structuredContent.error`.

Each asynchronous mutation captures its session and configuration before preparing
a candidate. Publication compares current state and checks consent again under
the session lock. Stale requests fail without rebasing or partially publishing.
Persistent client trust is checked again inside the same SQLite transaction as
the configuration write, including revocations from another owner connection.
Existing work retains its exact runtime; subsequent requests use the published
configuration. Unknown plugin sources, new credential scope, Full Access for
another principal, persistent client trust and macOS TCC remain local decisions.

OpenAI API keys and Cloudflare named-tunnel tokens are accepted by CLI save
commands only with `--api-key-stdin` or `--tunnel-token-stdin`. They never enter
argv, manifests, examples, capability output, or audit payloads. Generated
Cloudflare access tokens are returned once to the owner-only caller and stored
in Keychain.

## OAuth owner operations

These contracts use the App's current-user owner control socket or local App
control-plane API. They are absent from remote MCP catalogs and the standalone
HTTP owner socket. OAuth approval retains separate Full Access session consent.

| Operation | Arguments and result |
| --- | --- |
| `clients.authorizations` | Optional `tunnel_id`, `id`, `after_id`, `limit` (default 100, maximum 200). Returns `authorizations` with ID, tunnel ID, pairing code, client/redirect hosts and creation/expiry times; plus `next_after_id`. |
| `clients.authorize` | Required `pairing_code`; required `profile_id`; optional `tunnel_id`, `authorization_digest` (a SHA-256 hex string). When supplied, `authorization_digest` must match the chosen profile's current effective authorization digest or approval fails and the owner must review the profile again. Approves one unexpired pending request with a profile permitting `cloudflare-tunnel`; returns the grant. Ambiguous codes require `tunnel_id`. `profile.list` and `profile.show` include `authorization_digest`. |
| `clients.deny` | Required `pairing_code`, optional `tunnel_id`. Denies one pending request. |
| `clients.grants` | Same paging/filter fields as authorizations. Returns `grants`, including revoked records, and `next_after_id`. Grants carry client ID, redirect host, profile, resource, scope and creation/last-use/revocation times. |
| `clients.revoke_grant` | Required grant `id`. Immediately invalidates all grant tokens; repeated revocation is harmless. |

The local `authorizeOAuthClient` API also requires the owner to choose an
explicit profile. Its optional
`expectedAuthorizationDigest` binds approval to the reviewed
`OAuthApprovalProfile.authorizationDigest`, computed from the effective grant.
The App snapshot carries this digest with each remote profile, and the App
always supplies the digest of the profile it displayed.

`tunnel.cloudflare.save` accepts optional `oauth_enabled` and
`oauth_client_allowlist` (an array of exact lowercase hosts). New connections
default to disabled OAuth and `["claude.ai", "claude.com"]`; omission preserves
an existing connection. No client registry or client secret is created.

The optional `expected_tunnel_digest` (`expectedTunnelDigest` in the local save
API) binds a save to the tunnel configuration the caller opened. The digest is
lowercase SHA-256 hex over the saved `CloudflareTunnelTransportConfig` encoded as
compact JSON with sorted keys and unescaped slashes. It includes `id`,
`tunnel_name`, `public_hostname`, `gateway_profile`, `local_port`, `metrics_port`,
`cloudflared_path` when present, `oauth_enabled` and `oauth_client_allowlist` in
its saved order. Credential values and runtime status are excluded. The App
carries this digest in its tunnel summary and existing-tunnel editor draft.
Save compares it with the current tunnel while holding both the tunnel mutation
slot and configuration publication lock; a mismatch refuses the save with a
stale-configuration error and requires reopening the tunnel. New tunnels and
owner CLI saves omit the digest and retain their existing save behavior.

## Saved authority recovery

`permissions.requests` returns the permission `revision`, current `epoch`,
`suspended` state, `unconfirmed_profile_ids`, complete canonical `profiles`,
managed `sources`, and durable `requests`. Reading does not adopt saved authority.

`permissions.confirm_authority` requires an epoch UUID, an
`expected_permission_revision`, and the complete reviewed `profiles` array.
Every saved profile ID and authorization revision must match; an owner may
include reviewed permission edits in that snapshot. Missing, duplicate, unknown
or stale profiles fail before authority is adopted. The App review remains bound
to its captured snapshot while live request views refresh. The CLI requires
`--profiles-file` and never refreshes or retries a stale review.

The App socket and standalone HTTP private owner socket expose this operation.
The HTTP owner validates its active generation synchronously through commit.
These contracts remain absent from remote MCP catalogs.
