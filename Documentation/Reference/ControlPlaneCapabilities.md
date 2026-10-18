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
list. Standalone HTTP hosts expose the same six `clients` contracts on their
explicit private owner socket; they do not expose App lifecycle or configuration
commands.

| Family | Shared operations | CLI entry points | UI |
| --- | --- | --- | --- |
| App | status, start, stop, restart, launch at login | `app …` | Home and Settings |
| Client access | list, explicit Full Access consent, limit/end connection access, saved trust list/revoke | `clients …` | Client access |
| Readiness | local, ChatGPT, and Cloudflare journey checks | `doctor` | Home and Diagnostics |
| Configuration | show, validate, export, digest-guarded import, history, rollback | `config …` | Diagnostics manifest editor and revision rollback |
| Workspaces | list, canonical add, remove, profile enable/disable, deduplication | `workspace …` | Workspaces |
| Profiles | list, show, activate, workspace grant/revoke, permission mode, confirmation policy, advanced grants | `profile …` | Connection defaults and restricted permission selection |
| Providers | recorded health and bounded Doctor refresh | `providers list|doctor` | Providers |
| Permissions | non-prompting TCC status; list, approve, or deny exact host operation tickets | `permissions status`, `permissions approvals …` | Permissions and pending host approvals; TCC prompting remains an explicit local UI action |
| Audit | bounded redacted event list | `audit list` | Audit |
| Gateway tools | list, inspect, and policy-controlled local-admin call | `tools …` | CLI-only diagnostic escape hatch |
| OpenAI Tunnel | list, Doctor, start, reconnect, stop, provision, logs, save, remove | `tunnel openai …` | Tunnels |
| Cloudflare Tunnel | list, Doctor, start, stop, logs, save, remove | `tunnel cloudflare …` | Tunnels |

## Remote management

App-managed gateway connections expose typed management through their verified
session. The host applies the same capability policy, execution metadata and audit
as other tools. Full Access must already have explicit local consent; normal
workspace changes and verified official plugin changes need no additional prompt.
Standalone fixed-manifest gateways expose their configured execution tools and
optional local client-consent socket.

| Tools | Inputs and authority |
| --- | --- |
| `workspace.list`, `workspace.describe` | Inspect workspaces within the current grant; describe takes `workspace_id`. |
| `workspace.add` | Full Access; absolute `path`, optional `display_name`. |
| `workspace.repair` | Full Access; `id`, new `path`, reviewed `expected_root_path`, optional `display_name`. |
| `workspace.remove` | Full Access; `id`, reviewed `expected_root_path`. Removes the registration, preserving files and retained work. |
| `workspace.grant` | Full Access; `id`, `enabled`, `expected_profile_revision`. Changes only the connection's profile. A changed profile invalidates its prior Full consent. |
| `profile.show` | Inspect the connection's own session, profile and revisions. |
| `profile.limit` | `mode` (`observe` or `restricted`) and `expected_revision`; may only reduce this session's access. |
| `plugin.list`, `plugin.describe` | Inspect safe plugin summaries and exact store revision. Both accept `after_id` and `limit` (default 50, maximum 200); describe takes `id` and pages its installations. |
| `plugin.search` | Official static catalog; optional `query`, `kind` (`mcp`, `cli`, `skills`), `page` (starts at 1), `refresh`. |
| `plugin.artifacts` | `repository`, exact integer `repository_id`, optional `tag` and `page`. |
| `plugin.install`, `plugin.update` | Full Access; returned `artifact` and exact store `expected_revision`. Update also requires the existing plugin `id`. GitHub provenance and downloaded bytes are revalidated. |
| `plugin.configure` | Full Access; `id`, `settings` patch and `expected_revision`. Supports the existing plugin settings document fields; MCP authentication stays with the local credential owner. |
| `plugin.enable`, `plugin.disable` | Full Access; `id` and `expected_revision`. Activation requires bundled or verified official code. |
| `plugin.uninstall` | Full Access; `installation_id` and `expected_revision`. Active work retains its artifact lease. |

Tool discovery reflects the current session authority. Read operations and
`profile.limit` can be selected in the local Restricted permission editor;
configuration writes require Full Access even if a Restricted profile names them.
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
