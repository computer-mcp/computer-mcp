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
computer-mcp doctor [--journey <journey>] [--json] [--control-socket <control-socket>]
computer-mcp build-info
computer-mcp config path
computer-mcp config show
computer-mcp config defaults
computer-mcp config validate [--config <config>] [--connect]
computer-mcp config export [--output <output>]
computer-mcp config migrate-codex --config <config> --adapter-config <adapter-config> --state-directory <state-directory> [--known-plugin-mcp-server <known-plugin-mcp-server> ...]
computer-mcp config import --input <input> [--apply] [--expected-current-digest <expected-current-digest>]
computer-mcp config history [--limit <limit>]
computer-mcp config rollback <revision-id>
computer-mcp workspace list
computer-mcp workspace add <path> [--display-name <display-name>]
computer-mcp workspace remove <id>
computer-mcp workspace enable <id> --profile <profile> [--enabled] [--no-enabled]
computer-mcp workspace deduplicate [--apply] [--expected-plan-digest <expected-plan-digest>] [--allow-metadata-conflicts]
computer-mcp profile list [--control-socket <control-socket>]
computer-mcp profile show <id> [--control-socket <control-socket>]
computer-mcp profile activate <id> [--control-socket <control-socket>]
computer-mcp profile grant <id> --workspace <workspace> [--enabled] [--no-enabled] [--control-socket <control-socket>]
computer-mcp profile shell <id> [--enabled] [--no-enabled] [--control-socket <control-socket>]
computer-mcp profile permissions <id> [--control-socket <control-socket>] [--mode <mode>] [--confirmation-policy <confirmation-policy>] [--arbitrary-execution] [--no-arbitrary-execution] [--capabilities <capabilities>] [--workspaces <workspaces>] [--mcp-servers <mcp-servers>] [--allowed-callers <allowed-callers>] [--expected-revision <expected-revision>]
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
computer-mcp tools list [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools inspect <name> [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools call <name> [--arguments-json <arguments-json>] [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools inventory --config <config> [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp permissions status [--control-socket <control-socket>]
computer-mcp permissions approvals list [--limit <limit>] [--control-socket <control-socket>]
computer-mcp permissions approvals approve <id> [--control-socket <control-socket>]
computer-mcp permissions approvals deny <id> [--control-socket <control-socket>]
computer-mcp audit list [--limit <limit>]
computer-mcp audit export --database <database> [--request-id <request-id>] [--limit <limit>]
computer-mcp providers list
computer-mcp providers doctor [<id>]
computer-mcp providers discover --config <config>
computer-mcp mcp list [--control-socket <control-socket>]
computer-mcp mcp show [--control-socket <control-socket>] <id>
computer-mcp mcp doctor <id> --workspace-id <workspace-id> [--control-socket <control-socket>]
computer-mcp mcp recover-process <id> --workspace-id <workspace-id> --receipt-id <receipt-id> --expected-receipt-digest <expected-receipt-digest> --expected-current-digest <expected-current-digest> [--control-socket <control-socket>]
computer-mcp mcp credential <subcommand>
computer-mcp mcp credential status <id> [--control-socket <control-socket>]
computer-mcp mcp credential set <id> --expected-binding-digest <expected-binding-digest> [--control-socket <control-socket>] [--stdin]
computer-mcp mcp credential remove <id> --expected-binding-digest <expected-binding-digest> [--control-socket <control-socket>]
computer-mcp mcp add --registration-file <registration-file> [--control-socket <control-socket>] [--apply] [--expected-current-digest <expected-current-digest>]
computer-mcp mcp configure --registration-file <registration-file> [--control-socket <control-socket>] [--apply] [--expected-current-digest <expected-current-digest>]
computer-mcp mcp enable <id> [--control-socket <control-socket>] [--apply] [--expected-current-digest <expected-current-digest>]
computer-mcp mcp disable <id> [--control-socket <control-socket>] [--apply] [--expected-current-digest <expected-current-digest>]
computer-mcp mcp remove <id> [--control-socket <control-socket>] [--apply] [--expected-current-digest <expected-current-digest>]
computer-mcp plugins list [--control-socket <control-socket>]
computer-mcp plugins show [--control-socket <control-socket>] <id>
computer-mcp plugins doctor [--control-socket <control-socket>] <id>
computer-mcp plugins register <path> [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins configure <id> --settings-file <settings-file> [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins enable <id> [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins disable <id> [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins select <id> [--installation-id <installation-id>] [--bundled] [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins remove <installation-id> [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins search [<query>] [--kind <kind>] [--page <page>] [--refresh] [--control-socket <control-socket>]
computer-mcp plugins artifacts <repository> --repository-id <repository-id> [--tag <tag>] [--page <page>] [--control-socket <control-socket>]
computer-mcp plugins install-release <selection-file> [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins install <archive> --id <id> --version <version> --sha256 <sha256> [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins uninstall <installation-id> [--control-socket <control-socket>] --expected-revision <expected-revision>
computer-mcp plugins recover [--control-socket <control-socket>] --expected-revision <expected-revision>
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

Use `--control-socket <path>` to check an isolated App control plane. Without
this option, `doctor` connects to the installed App's default control socket.

`--json` emits `schema_version: 1` with an ISO-8601 `generated_at`, journey,
status, checks, an optional redacted next action, and an optional redacted
verified request. If the App or owner-only Control Socket is unavailable, the
same parseable contract reports a blocked `app.control_socket` check. Internal
errors and credential values are not copied into the fallback result.

## Manual MCP registrations

HTTP bearer credentials use the same owner control plane for both manual and
plugin registrations. Configure the [endpoint and Keychain reference](Config.md#http-credentials)
first, then read `mcp credential status <id>`. It returns presence and the binding
digest, never the token. `set` requires that digest and `--stdin`; read the token
from a pipe or redirected secret source, not a command argument or interactive
terminal. Input is bounded to 16 KiB, with an optional trailing newline. `remove`
requires the same digest and deletes only the selected Keychain item.

Credential commands return JSON. A mutation failure exits nonzero; an unknown
outcome must be inspected before retrying. Tokens are excluded from output,
configuration and credential-operation audit digests. Subsequent HTTP exchanges
read the current token; changing it does not cancel an already issued request
or perform OAuth login, refresh or server-side revocation. The App exposes the
same operations through **Manage credential** in the MCP registrations list.

The App's Providers → Manage MCP panel and `mcp` commands use the same
App-owned manifest operations. `list` includes manual and resolved plugin
contributions; `show <id>` returns one entry and the current manifest digest.
Plugin-owned contributions are edited through plugin settings.

`mcp doctor <id> --workspace-id <id>` and the App's **Check connection** action
actively initialize the selected enabled registration in an explicitly selected
registered workspace, retrieve its catalog, and close the probe. They use the
resolved launch configuration and the standard MCP connection path, including
timeouts and scoped host callbacks. Other registrations are not started. Disabled
registrations are reported without launching; external dependencies are never
installed. Starting a third-party executable still runs that executable's startup
code; this check is not a process sandbox.

The JSON report records the configuration digest, observation time, status,
failure stage, executable/interpreter inspection, catalog receipt and negotiated
versions. Exit status is zero for a verified connection/catalog and one for a
failed or disabled check. Configuration/control errors use the usual CLI error
path. The report omits launch environment values and raw downstream errors.
It does not invoke downstream tools or change registration/profile grants.
Its ephemeral host callback scope is read-only and has no persistence authority.
Success does not prove tool execution, remote profile access, system permissions
or persistent host services. Recheck after configuration or environment changes.

For stdio registrations, `process_receipts` reports host-local process cleanup
state before connecting and after closing the probe. The check uses the same
database-adjacent ownership storage as the App runtime, while its host callback
scope retains no database authority. Inspection may initialize private empty
bookkeeping directories; it does not launch processes or retire failed records.
A blocking record produces the `cleanup` stage and prevents the probe launch.
Records identify their receipt, digest, owner PID, state, launch blocking and
whether recovery is currently safe. `running` is an independent live session;
`stopped` can be reconciled by the next launch. `cleanup_pending` means an
orphaned process lock is still held. `cleanup_failed` requires inspection;
`host_cleanup_unconfirmed` and `invalid` cannot be cleared through recovery.

After reviewing a record with `recoverable: true`, use **Recover released
record** in the App, or `mcp recover-process` with its ID and digest plus the
report's `current_digest`. The host rechecks both the configuration and the
exact receipt under its storage lock. Recovery requires all inherited process
locks released and recorded confirmation of host authorization cleanup. It
retires that receipt and returns `{"recovered":true}`; it does not launch a
replacement, change grants, signal a process or replay calls. Configuration
changes, damaged records and unconfirmed cleanup fail closed. Check again
before retrying; never remove these files merely because a PID is absent.

Normal HTTP shutdown makes one best-effort session termination request with a
two-second request timeout. A server may refuse termination or be unreachable;
connection health is not proof that the remote server deleted its session state.

`add` and `configure` read a JSON object of at most 1 MiB using the
[`mcp.servers` fields](Config.md). `configure` replaces the entire registration:
copy the `server` object from `show`, retain fields you want to preserve, and
edit that object. Unknown fields are rejected. For example:

```json
{
  "id": "design",
  "enabled": false,
  "transport": "streamable_http",
  "url": "https://mcp.example.com/mcp",
  "exposure": "reexport",
  "prefix": "design",
  "allowed_tools": ["get_screenshot"]
}
```

All five mutation commands preview by default. Review the proposed settings
and reconnect warning, then repeat the same command with `--apply` and
`--expected-current-digest <current_digest>` from that preview. A stale digest
rejects the change; obtain and review a fresh preview. Applying reconnects an
already running gateway and closes its clients' existing sessions. Clients
must reconnect and complete or cancel their pending request waits. A lost
response does not prove an operation failed: inspect its outcome before
retrying, especially for writes. Adding or enabling a registration does not grant
profile permissions, install dependencies, or prove connection health.

Disabling retains launch settings, selection and profile references while
excluding the registration from discovery and execution. Removal rejects
registrations still referenced by tool mappings or profile grants; disable
them or explicitly review those references first. External executables and
registration input files are retained.

Use `--control-socket <path>` on any `mcp` command to select an isolated
owner-only App instance. Without it, the command addresses the production App.
The CLI can be run from any working directory; a relative registration file
path is interpreted relative to the invoking directory.

## External provider diagnostics

`config validate --config <config> --connect` actively initializes downstream
MCP sessions and lists their tools. Relative launch directories are based on
the specified configuration directory. It closes its client after successful
validation and after a connection error. This is distinct from static manifest
validation and from the external-provider probes below. Disabled registrations
are reported as `state: "disabled", checked: false` without connecting them.

`providers list` reads the App's recorded provider health. `providers doctor`
runs version and diagnostic probes through the App-owned control plane and
records their results. `providers discover --config <config>` runs probes
locally against the specified manifest and emits a JSON report; it does not
contact the running App or change its provider records.

Configured MCP and CLI probes use the registration's working directory and
environment overrides. An absent, empty, or `workspace` directory selects the
configuration workspace; a relative directory is based there. Relative
executables and relative or empty PATH entries resolve in the selected launch
directory. Executable and shebang-interpreter checks precede execution.

When several registrations match a provider, discovery selects the first in
this order: enabled Codex configuration, enabled MCP registrations, then CLI
registrations, preserving registration order. An unavailable selected launch
is reported directly, not replaced by another installation. PATH and common
installation locations are searched when no registration matches. A symlink's
launch path is retained. Truncated probe output cannot establish success.

These commands execute external version/help/diagnostic code. They do not
open an MCP session, exercise GUI actions, install dependencies, or grant
permissions. Their results establish only the reported probe scope, not full
integration readiness. For non-executing package checks, use
`plugins doctor <id>`; see [Plugin Packages](PluginPackages.md).

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

## Host permission commands

`profile permissions` updates one profile's host authority. Modes are
`read-only`, `workspace-operations`, and `local-full-access`; they are independent
of the profile's name and connection channel. Unspecified options retain their
current values. `profile show` returns `authorization_revision`; pass it with
`--expected-revision` to reject an edit based on stale settings.

Every `profile` and `permissions` subcommand accepts `--control-socket <path>`
for an isolated owner-only App instance. Omitting it selects the production App.

Confirmation policies are `risk-based`, `all-writes`, and `never`. Risk-based
confirmation covers host-classified destructive actions, external writes, and
arbitrary execution. Changing confirmation policy does not grant a capability.
Codex keeps its native sandbox, Full Access, configuration, and approval model;
these controls govern Computer MCP-owned tools and access to registered tools.

Advanced lists are comma-separated replacements. An empty value clears the
list. A capability `*` grants tools, not workspaces; the separate workspace `*`
explicitly grants all registered and future workspaces. MCP registration grants
include that registration's host-selected tools. Caller kinds are `local-app`,
`local-cli`, `local-mcp`, `secure-tunnel`, and `cloudflare-tunnel`.

Arbitrary execution requires `local-full-access`, separate execution permission,
and a corresponding tool grant. Shell tools also require the manifest's
`policy.shell_enabled`. A working directory does not contain an unsandboxed
process or isolate it from the current macOS user's other resources.

Permission edits apply to new requests and invalidate pending confirmations.
They do not restart the gateway or tunnels, or stop existing work. Switching the
active profile selects the profile for subsequent admissions; established
connections retain their verified binding.

Use `permissions approvals list` to review exact host requests, their client,
profile, workspace, arguments summary, expiry, and state. Approve or deny an exact
ticket through the local App or management CLI. Approval permits the prepared
operation to be committed once; it does not execute the operation itself.
Changing arguments, target, authority, or using an expired ticket requires a new
request. These are host operation approvals; Codex native approvals remain in
the Codex adapter's native workflow.

## App-owned operation

`plugins list/show/register/configure/enable/disable/select/remove` manage local
development registrations and host-owned plugin settings through this same
control plane. Mutations require the `state.revision` returned by list/show.
They preflight configuration conflicts and do not interrupt connected Gateway
clients. See [Plugin Packages](PluginPackages.md#management-cli) for source
selection, exact settings fields, diagnostics, and isolated control sockets.

`plugins doctor <id>` checks the selected package, including disabled
contributions, through the same read-only use case as the App's **Check package**
action. JSON includes the configuration revision, checked time, dependencies,
per-check results, `scope` and `notChecked`. Exit 1 indicates a failed check or
control error; exit 0 can include explicitly unverified checks. It does not
enable contributions, execute probes, connect to servers, install dependencies,
prompt for permissions or change settings. File checks do not prove working
runtime health. See [Explicit Package Checks](PluginPackages.md#explicit-package-checks).

`plugins install <archive> --id <id> --version <version> --sha256 <digest>`
installs or updates a local package through the App's bounded worker.
`plugins uninstall <installation-id>` revokes one artifact and cleans only its
owned files; `plugins recover` retries pending owned-file cleanup. All three
require `--expected-revision`. Successful JSON may include cleanup `issues`;
runtime failures return structured errors and nonzero status. Previous versions
remain selectable for rollback. Neither archive installation nor digest checking
establishes official publisher provenance or installs external dependencies.

`plugins search [query] --kind mcp|cli|skills --page <number> --refresh`
reads public official GitHub plugin declarations through the same service as
the App. It returns JSON metadata, not an installation or a permission grant.
Follow `next_page` even when a filtered repository page has no matches. Runtime
failures return a JSON `error` object and a nonzero exit status; argument parsing
errors use the standard CLI usage diagnostics. See
[Official Search](PluginPackages.md#official-search) for provenance, caching,
network limits, and failure behavior.

`plugins artifacts <owner/repository> --repository-id <id> [--tag <tag>]`
lists installable release archives, defaulting to the latest stable release.
Use the repository name and numeric identity from search, and follow `next_page`
even on empty asset pages. Save one complete `artifacts` entry as a JSON file;
`plugins install-release <selection.json> --expected-revision <revision>`
revalidates that selection, downloads its bytes and installs it through the
same App-owned transaction. The selection file is bounded to 256 KiB. New
plugins remain disabled, and updates retain settings and older versions.
Runtime and selection-file failures return JSON errors with a nonzero exit
status. Metadata, downloads and archive checks have separate bounded deadlines;
connection loss does not prove rollback. Read list/show before retrying a write.

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

Standalone `tools list`, `tools inspect`, and `tools call` close their owned
Gateway connections before returning, including when an operation fails.
`tools call` prints the tool's JSON result and exits with status 1 when
`isError` is true, in both standalone and App-owned modes. An unknown tool
passed to `tools inspect` is a command validation error (exit status 64).
An unsuccessful call does not authorize an automatic retry of a write.

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
