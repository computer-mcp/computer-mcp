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
list.

| Family | Shared operations | CLI entry points | UI |
| --- | --- | --- | --- |
| App | status, start, stop, restart, launch at login | `app …` | Home and Settings |
| Readiness | local, ChatGPT, and Cloudflare journey checks | `doctor` | Home and Diagnostics |
| Configuration | show, validate, export, digest-guarded import, history, rollback | `config …` | Diagnostics manifest editor and revision rollback |
| Workspaces | list, canonical add, remove, profile enable/disable, deduplication | `workspace …` | Workspaces |
| Profiles | list, show, activate, workspace grant/revoke, Full Shell | `profile …` | Profiles |
| Providers | recorded health and bounded Doctor refresh | `providers list|doctor` | Providers |
| Permissions | non-prompting TCC status | `permissions status` | Permissions; prompting remains an explicit local UI action |
| Audit | bounded redacted event list | `audit list` | Audit |
| Gateway tools | list, inspect, and policy-controlled local-admin call | `tools …` | CLI-only diagnostic escape hatch |
| OpenAI Tunnel | list, Doctor, start, reconnect, stop, provision, logs, save, remove | `tunnel openai …` | Tunnels |
| Cloudflare Tunnel | list, Doctor, start, stop, logs, save, remove | `tunnel cloudflare …` | Tunnels |

`workspace add` changes the authorization boundary and is therefore local-only.
A remote `workspace.list` description points callers to the local CLI and
explicitly rejects Computer Use as a fallback administration route.

OpenAI API keys and Cloudflare named-tunnel tokens are accepted by CLI save
commands only with `--api-key-stdin` or `--tunnel-token-stdin`. They never enter
argv, manifests, examples, capability output, or audit payloads. Generated
Cloudflare access tokens are returned once to the owner-only caller and stored
in Keychain.
