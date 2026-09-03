# CLI Reference

The signed `computer-mcp` CLI is embedded in `Computer MCP.app`. App-owned
commands connect to the owner-only control socket under Application Support and
operate the same manifest, database, bookmarks, Keychain records, providers,
transports, and audit stream as the App.

Install it from the App or from the bundled executable:

```sh
"/Applications/Computer MCP.app/Contents/Resources/computer-mcp" install cli
computer-mcp install cli --status
```

The installer creates `~/.local/bin/computer-mcp` without `sudo`. It will not
replace a regular file or an unrelated valid link. Add that directory to
`PATH` if Doctor reports it missing.

## Command surface

```text
computer-mcp app capabilities
computer-mcp app status
computer-mcp app start
computer-mcp app stop
computer-mcp app restart
computer-mcp app launch-at-login [--enabled] [--no-enabled]
computer-mcp doctor [--journey <journey>] [--json]
computer-mcp build-info
computer-mcp config path
computer-mcp config show
computer-mcp config defaults
computer-mcp config validate [--config <config>] [--connect]
computer-mcp config export [--output <output>]
computer-mcp config import --input <input> [--apply] [--expected-current-digest <expected-current-digest>]
computer-mcp config history [--limit <limit>]
computer-mcp config rollback <revision-id>
computer-mcp workspace list
computer-mcp workspace add <path> [--display-name <display-name>]
computer-mcp workspace remove <id>
computer-mcp workspace enable <id> --profile <profile> [--enabled] [--no-enabled]
computer-mcp workspace deduplicate [--apply] [--expected-plan-digest <expected-plan-digest>] [--allow-metadata-conflicts]
computer-mcp profile list
computer-mcp profile show <id>
computer-mcp profile activate <id>
computer-mcp profile grant <id> --workspace <workspace> [--enabled] [--no-enabled]
computer-mcp profile shell <id> [--enabled] [--no-enabled]
computer-mcp tunnel openai list
computer-mcp tunnel openai doctor <id>
computer-mcp tunnel openai start <id>
computer-mcp tunnel openai reconnect <id>
computer-mcp tunnel openai stop <id>
computer-mcp tunnel openai provision <id> [--force]
computer-mcp tunnel openai logs <id>
computer-mcp tunnel openai save <id> --tunnel-client-profile <tunnel-client-profile> --tunnel-id <tunnel-id> --gateway-profile <gateway-profile> [--tunnel-client-path <tunnel-client-path>] [--http-proxy <http-proxy>] [--api-key-stdin]
computer-mcp tunnel openai remove <id>
computer-mcp tunnel cloudflare list
computer-mcp tunnel cloudflare doctor <id>
computer-mcp tunnel cloudflare start <id>
computer-mcp tunnel cloudflare stop <id>
computer-mcp tunnel cloudflare logs <id>
computer-mcp tunnel cloudflare save <id> --tunnel-name <tunnel-name> --public-hostname <public-hostname> --gateway-profile <gateway-profile> [--local-port <local-port>] [--metrics-port <metrics-port>] [--cloudflared-path <cloudflared-path>] [--tunnel-token-stdin] [--regenerate-access-token]
computer-mcp tunnel cloudflare remove <id>
computer-mcp codex diagnose-thread <thread-id> --workspace-id <workspace-id> [--observed-error <observed-error>]
computer-mcp codex diagnostics --workspace-id <workspace-id> [--limit <limit>]
computer-mcp codex release-thread <thread-id> --workspace-id <workspace-id> [--interrupt-active-turn] [--force-owned-runtime]
computer-mcp codex recent-thread <thread-id> --workspace-id <workspace-id> [--before-cursor <before-cursor>] [--max-turns <max-turns>] [--max-messages <max-messages>] [--max-items <max-items>] [--max-bytes <max-bytes>] [--max-output-bytes <max-output-bytes>] [--max-elapsed-milliseconds <max-elapsed-milliseconds>]
computer-mcp codex elevation list --workspace-id <workspace-id> [--state <state>]
computer-mcp codex elevation read <grant-id> --workspace-id <workspace-id>
computer-mcp codex elevation approve <grant-id> --workspace-id <workspace-id>
computer-mcp codex elevation deny <grant-id> --workspace-id <workspace-id>
computer-mcp codex elevation revoke <grant-id> --workspace-id <workspace-id>
computer-mcp codex elevation effective --workspace-id <workspace-id> [--thread-id <thread-id>]
computer-mcp tools list [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools inspect <name> [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools call <name> [--arguments-json <arguments-json>] [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools inventory --config <config> [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp permissions status
computer-mcp audit list [--limit <limit>]
computer-mcp audit export --database <database> [--request-id <request-id>] [--limit <limit>]
computer-mcp providers list
computer-mcp providers doctor [<id>]
computer-mcp providers discover --config <config>
computer-mcp install cli [--status] [--replace-invalid-link]
computer-mcp uninstall cli
computer-mcp install codex [--config <config>] [--app] [--name <name>] [--codex-cli <codex-cli>] [--server-executable <server-executable>] [--dry-run]
computer-mcp serve stdio --config <config> [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>] [--database <database>]
computer-mcp serve http --config <config> [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>] [--database <database>] [--host <host>] [--port <port>] [--public-base-url <public-base-url>]
computer-mcp bridge [--socket <socket>] [--tunnel-credential-file <tunnel-credential-file>] [--tunnel-profile-id <tunnel-profile-id>] [--client-identity <client-identity>]
```

Use `--help` on any command for the authoritative options and exit behavior.
Structured inspection and mutation results are JSON; configuration display and
export are TOML.

## `doctor`

`doctor` reads the App-owned readiness engine. The default journey is `local`.
It exits 0 only when the selected journey is `ready` or `verified`; all other
states exit 1.

`--json` emits `schema_version: 1` with an ISO-8601 `generated_at`, journey,
status, checks, an optional redacted next action, and an optional redacted
verified request. If the App or owner-only Control Socket is unavailable, the
same parseable contract reports a blocked `app.control_socket` check. Internal
errors and credential values are not copied into the fallback result.

## Codex consumer registration

App mode registers the installed or embedded CLI bridge and does not use TOML:

```sh
computer-mcp install codex --app --dry-run
computer-mcp install codex --app
```

Standalone registration remains explicit:

```sh
computer-mcp install codex --config Examples/computer-mcp.toml --dry-run
```

`--app` and `--config` are mutually exclusive and exactly one is required. A
dry run prints the complete secret-free invocation without changing Codex.

## Codex ownership diagnosis

The App-owned diagnostic commands inspect Computer MCP evidence without a
machine-wide process scan:

```sh
computer-mcp codex diagnose-thread <thread-id> --workspace-id <workspace-id>
computer-mcp codex diagnostics --workspace-id <workspace-id>
computer-mcp codex release-thread <thread-id> --workspace-id <workspace-id>
```

`diagnose-thread` explains whether a live Computer MCP runtime has the thread
loaded, subscribed, or active; whether it is known but released; or whether an
external writer is only suspected. It returns exact safe follow-up tool calls,
including inspecting or releasing the owned runtime and deliberately
reclaiming an idle persisted thread. `--observed-error` may include the message
shown by another official client; it is redacted and bounded before appearing
in the result.

`diagnostics` returns a redacted workspace snapshot covering live and persisted
runtimes, process groups, thread and turn state, approvals, acceptance runs,
worktree leases, recent tool/Git audit linkage, cleanup previews, and actionable
findings. Neither command signals an external Codex process. Both require the
running App control plane and a registered workspace id.

`release-thread` performs the complete handoff transaction across every
matching Computer MCP-owned runtime. Graceful mode refuses active turns and
pending interactive requests. `--interrupt-active-turn` explicitly permits
the target turn to be interrupted. `--force-owned-runtime` may stop only exact
matching Computer MCP-owned runtimes when graceful unsubscription cannot
establish the postcondition. Success requires `final_classification` to be
`released_persisted`, `externally_claimable` to be true, and no Computer MCP
writer ownership to remain. The persisted Goal is unchanged and a repeat is
reported as already released.

## Scoped Codex execution elevation

Remote or ordinary callers request a grant through
`codex.app.elevation.request`; the CLI intentionally does not turn that request
into local approval. Review and resolve it from the local App/CLI control plane:

```sh
computer-mcp codex elevation list --workspace-id <workspace-id>
computer-mcp codex elevation read <grant-id> --workspace-id <workspace-id>
computer-mcp codex elevation approve <grant-id> --workspace-id <workspace-id>
computer-mcp codex elevation deny <grant-id> --workspace-id <workspace-id>
computer-mcp codex elevation revoke <grant-id> --workspace-id <workspace-id>
computer-mcp codex elevation effective --workspace-id <workspace-id> \
  [--thread-id <thread-id>]
```

Approve and deny require the local caller and `local-admin` profile. A grant is
bound to its original workspace, canonical root, profile, caller, connection,
and optional thread. Approval affects only an eligible future thread/turn
start; it never hot-switches an active turn. `effective` reports requested and
effective sandbox state without changing it. Revocation restores the configured
safe sandbox for future turns while leaving an already active turn unchanged.
List, read, and mutation results include a structured `local_approval_review`
with the workspace display name/root, exact binding and duration, network,
filesystem, `.git`, outside-workspace and macOS privacy effects, plus the exact
revoke tool arguments and CLI argv. Product surfaces may render that structure
in natural language; the field values, not one fixed sentence, are normative.

## Bounded recent thread reads

Use `recent-thread` for supervision instead of a full historical
`thread/read`:

```sh
computer-mcp codex recent-thread <thread-id> --workspace-id <workspace-id> \
  --max-turns 10 --max-messages 50 --max-items 100 \
  --max-bytes 262144 --max-output-bytes 524288 \
  --max-elapsed-milliseconds 2000
```

The result includes a snapshot-bound `next_before_cursor`, `has_more`, Goal and
active-turn state, recent progress, and exact I/O/output/latency bounds. Pass
the cursor back with `--before-cursor` for an older bounded page. The command
opens Codex persistence read-only and never loads the full history by default.

## Workspace registration repair

`workspace add` resolves symlinks and is idempotent for an existing canonical
root. To repair older duplicates, first preview:

```sh
computer-mcp workspace deduplicate
```

Review canonical ids, aliases, profile changes, and metadata conflicts, then
apply the unchanged plan with its digest. `--allow-metadata-conflicts` is an
explicit choice to keep the oldest registration metadata. The operation never
deletes the workspace directory; retired ids remain aliases for historical
references.

## App-owned operation

`app`, `workspace`, `profile`, `tunnel`, and `tools` use the App control plane.
If the App is not running, the CLI fails with actionable startup guidance; it
does not silently create another database or gateway.

`config import` is two phase. The first invocation validates the candidate,
shows a secret-free diff, and returns the current digest. `--apply` requires
that digest so a concurrent App edit cannot be overwritten. Apply never starts
a stopped transport; when the gateway is already running it uses the same
restart-and-rollback operation as the App so the active runtime cannot drift
from the accepted manifest.

Workspace, profile, manifest, gateway, and Tunnel lifecycle writes all use the
same lifecycle-aware operations as the App. A local CLI call therefore performs
the same validation, restart, desired-Tunnel reconnection, and failure rollback
as the corresponding UI action.

The owner-only control CLI is deliberately not registered as a remotely
executable `cli.exec` provider. Doing so would let a remote caller inherit the
local-admin control-socket identity. Remote callers may inspect only workspaces
already granted to their profile; adding an authorization root remains a local
App or CLI operation. Computer Use rejects Accessibility actions aimed at the
Computer MCP host process rather than using its UI as an administration path.

OpenAI and Cloudflare commands are distinct namespaces and cannot select a
transport from ambient arguments. `doctor` is read-only and redacts secrets.
New OpenAI API keys and Cloudflare named-tunnel tokens are accepted only from
standard input through `--api-key-stdin` or `--tunnel-token-stdin`; the CLI has
no option that places either credential in argv. Updating a configuration
without either flag preserves its existing Keychain secret.

## `bridge`

`bridge` translates line-delimited MCP stdio to the App's private gateway
socket:

```sh
computer-mcp bridge
```

The App supplies private credential/profile options to its owned Secure MCP
Tunnel process. Local clients use the local-MCP identity. The command does not
load TOML or start a second control plane.

## Explicit standalone mode

Standalone development requires `--config`:

```sh
computer-mcp serve stdio --config Examples/computer-mcp.toml
COMPUTER_MCP_HTTP_ACCESS_TOKEN=<development-only-value> \
  computer-mcp serve http --config Examples/computer-mcp.toml

computer-mcp tools list --config Examples/computer-mcp.toml
computer-mcp tools inspect workspace.info --config Examples/computer-mcp.toml
```

Standalone mode uses in-process state and TOML paths. It does not use App
bookmarks, the App database, or App Keychain transport credentials. An explicit
`--database <path>` may preserve a disposable Gateway audit database for a
Validation Run; omitting it keeps the database in memory. Never point this
option at the App database or run standalone mode as a second service owner.

## Computer MCP Validation Suite

Validation tooling is intentionally absent from the root package. From the
repository root:

```sh
/usr/bin/swift run --package-path Tools/Validation \
  computer-mcp-validate test-case validate
/usr/bin/swift run --package-path Tools/Validation \
  computer-mcp-validate test-case list
/usr/bin/swift run --package-path Tools/Validation \
  computer-mcp-validate runbook generate --output validation-runbook.md
```

There is no pass-entry command. PASS is derived only from a verified Validation
Evidence Bundle with complete transport, request, audit, and independent result
correlations.
