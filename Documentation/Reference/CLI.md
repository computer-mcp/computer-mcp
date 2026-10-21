# CLI Reference

The signed `computer-mcp` CLI is embedded in `Computer MCP.app`. App-owned
commands connect to the owner-only control socket under Application Support and
operate the same manifest, database, bookmarks, Keychain records, providers,
transports, and audit stream as the App. Each App-owned command accepts
`--control-socket <path>` to select a specific running App instance. An explicit
socket never falls back to another App. App management commands reject combining
`--config` and `--control-socket`. Standalone `serve http` can expose its own
client-access control socket explicitly, as described below.

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
computer-mcp app status [--control-socket <control-socket>]
computer-mcp app start [--control-socket <control-socket>]
computer-mcp app stop [--control-socket <control-socket>]
computer-mcp app restart [--control-socket <control-socket>]
computer-mcp app launch-at-login [--control-socket <control-socket>] [--enabled] [--no-enabled]
computer-mcp clients list [--control-socket <control-socket>] [--id <id>] [--after-id <after-id>] [--limit <limit>]
computer-mcp clients allow [--control-socket <control-socket>] <id> [--expected-revision <expected-revision>] [--full-access] [--always-allow-client] [--expected-trust-revision <expected-trust-revision>]
computer-mcp clients limit [--control-socket <control-socket>] <id> [--expected-revision <expected-revision>] --mode <mode>
computer-mcp clients end [--control-socket <control-socket>] <id> [--expected-revision <expected-revision>]
computer-mcp clients trusts [--control-socket <control-socket>] [--id <id>] [--after-id <after-id>] [--limit <limit>]
computer-mcp clients revoke [--control-socket <control-socket>] <id> [--expected-revision <expected-revision>]
computer-mcp clients authorizations [--control-socket <control-socket>] [--id <id>] [--after-id <after-id>] [--limit <limit>] [--tunnel-id <tunnel-id>]
computer-mcp clients authorize [--control-socket <control-socket>] <pairing-code> [--tunnel-id <tunnel-id>] [--profile <profile>] [--authorization-digest <authorization-digest>]
computer-mcp clients deny [--control-socket <control-socket>] <pairing-code> [--tunnel-id <tunnel-id>]
computer-mcp clients grants [--control-socket <control-socket>] [--id <id>] [--after-id <after-id>] [--limit <limit>] [--tunnel-id <tunnel-id>]
computer-mcp clients revoke-grant [--control-socket <control-socket>] <id>
computer-mcp doctor [--journey <journey>] [--json] [--control-socket <control-socket>]
computer-mcp build-info
computer-mcp config path [--control-socket <control-socket>]
computer-mcp config show [--control-socket <control-socket>]
computer-mcp config defaults
computer-mcp cli-tree validate <file> [--expected-version <expected-version>]
computer-mcp cli-tree check <file> [--expected-version <expected-version>] --executable <executable> [--working-directory <working-directory>]
computer-mcp config validate [--control-socket <control-socket>] [--config <config>] [--connect]
computer-mcp config export [--control-socket <control-socket>] [--output <output>]
computer-mcp config import [--control-socket <control-socket>] --input <input> [--apply] [--expected-current-digest <expected-current-digest>]
computer-mcp config history [--control-socket <control-socket>] [--limit <limit>]
computer-mcp config rollback [--control-socket <control-socket>] <revision-id>
computer-mcp workspace list [--control-socket <control-socket>]
computer-mcp workspace add [--control-socket <control-socket>] <path> [--display-name <display-name>]
computer-mcp workspace repair [--control-socket <control-socket>] <id> <path> [--display-name <display-name>]
computer-mcp workspace remove [--control-socket <control-socket>] <id>
computer-mcp workspace enable [--control-socket <control-socket>] <id> --profile <profile> [--enabled] [--no-enabled]
computer-mcp workspace deduplicate [--control-socket <control-socket>] [--apply] [--expected-plan-digest <expected-plan-digest>] [--allow-metadata-conflicts]
computer-mcp profile list [--control-socket <control-socket>]
computer-mcp profile show <id> [--control-socket <control-socket>]
computer-mcp profile activate <id> [--control-socket <control-socket>]
computer-mcp profile grant <id> --workspace <workspace> [--enabled] [--no-enabled] [--control-socket <control-socket>]
computer-mcp profile shell <id> [--enabled] [--no-enabled] [--control-socket <control-socket>]
computer-mcp profile permissions <id> [--control-socket <control-socket>] [--mode <mode>] [--confirmation-policy <confirmation-policy>] [--arbitrary-execution] [--no-arbitrary-execution] [--capabilities <capabilities>] [--workspaces <workspaces>] [--mcp-servers <mcp-servers>] [--allowed-callers <allowed-callers>] [--expected-revision <expected-revision>]
computer-mcp tunnel openai list [--control-socket <control-socket>]
computer-mcp tunnel openai doctor [--control-socket <control-socket>] <id>
computer-mcp tunnel openai start [--control-socket <control-socket>] <id>
computer-mcp tunnel openai reconnect [--control-socket <control-socket>] <id>
computer-mcp tunnel openai stop [--control-socket <control-socket>] <id>
computer-mcp tunnel openai provision [--control-socket <control-socket>] <id> [--force]
computer-mcp tunnel openai logs [--control-socket <control-socket>] <id>
computer-mcp tunnel openai save [--control-socket <control-socket>] <id> --tunnel-client-profile <tunnel-client-profile> --tunnel-id <tunnel-id> --gateway-profile <gateway-profile> [--tunnel-client-path <tunnel-client-path>] [--http-proxy <http-proxy>] [--api-key-stdin]
computer-mcp tunnel openai remove [--control-socket <control-socket>] <id>
computer-mcp tunnel cloudflare list [--control-socket <control-socket>]
computer-mcp tunnel cloudflare doctor [--control-socket <control-socket>] <id>
computer-mcp tunnel cloudflare start [--control-socket <control-socket>] <id>
computer-mcp tunnel cloudflare stop [--control-socket <control-socket>] <id>
computer-mcp tunnel cloudflare logs [--control-socket <control-socket>] <id>
computer-mcp tunnel cloudflare save [<options>] <id> --tunnel-name <tunnel-name> --public-hostname <public-hostname> --gateway-profile <gateway-profile>
computer-mcp tunnel cloudflare remove [--control-socket <control-socket>] <id>
computer-mcp tools list [--control-socket <control-socket>] [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools inspect <name> [--control-socket <control-socket>] [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools call <name> [--arguments-json <arguments-json>] [--control-socket <control-socket>] [--config <config>] [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp tools inventory --config <config> [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>]
computer-mcp permissions status [--control-socket <control-socket>]
computer-mcp permissions approvals list [--limit <limit>] [--control-socket <control-socket>]
computer-mcp permissions approvals approve <id> [--control-socket <control-socket>]
computer-mcp permissions approvals deny <id> [--control-socket <control-socket>]
computer-mcp audit list [--control-socket <control-socket>] [--limit <limit>]
computer-mcp audit export --database <database> [--request-id <request-id>] [--limit <limit>]
computer-mcp state import <file> [--database <database>]
computer-mcp providers list [--control-socket <control-socket>]
computer-mcp providers doctor [--control-socket <control-socket>] [<id>]
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
computer-mcp install codex [--name <name>] [--client-cli <client-cli>] [--dry-run] [--expect <expect>] [--config <config>] [--app] [--socket <socket>] [--server-executable <server-executable>]
computer-mcp install claude-code [--name <name>] [--client-cli <client-cli>] [--dry-run] [--expect <expect>] [--config <config>] [--app] [--socket <socket>] [--server-executable <server-executable>]
computer-mcp install claude-desktop [--name <name>] [--client-cli <client-cli>] [--dry-run] [--expect <expect>] [--config <config>] [--app] [--socket <socket>] [--server-executable <server-executable>]
computer-mcp uninstall codex [--name <name>] [--client-cli <client-cli>] [--dry-run] [--expect <expect>]
computer-mcp uninstall claude-code [--name <name>] [--client-cli <client-cli>] [--dry-run] [--expect <expect>]
computer-mcp uninstall claude-desktop [--name <name>] [--client-cli <client-cli>] [--dry-run] [--expect <expect>]
computer-mcp serve stdio --config <config> [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>] [--database <database>]
computer-mcp serve http --config <config> [--caller <caller>] [--profile <profile>] [--workspace-id <workspace-id>] [--database <database>] [--host <host>] [--port <port>] [--public-base-url <public-base-url>] [--control-socket <control-socket>]
computer-mcp bridge [--socket <socket>] [--tunnel-credential-file <tunnel-credential-file>] [--tunnel-profile-id <tunnel-profile-id>] [--client-identity <client-identity>]
```

Use `--help` on any command for the authoritative options and exit behavior.

## Client access

OAuth pairing and grants use the local App control socket:

```sh
computer-mcp clients authorizations
computer-mcp clients authorize <pairing-code> --profile cloudflare-observe
computer-mcp clients deny <pairing-code>
computer-mcp clients grants
computer-mcp clients revoke-grant <grant-id>
```

`authorizations` and `grants` page their named result arrays with `--id`,
`--after-id`, `--limit` (default 100, maximum 200) and optional `--tunnel-id`.
Pending rows include pairing code, client host, redirect host and expiry.
`authorize` and `deny` accept `--tunnel-id` to resolve ambiguous codes. Approval
defaults to `cloudflare-observe` only while its effective mode is read-only.
Otherwise approval requires an explicit `--profile`. The selected profile must
allow `cloudflare-tunnel`. Pairing lasts ten minutes and decisions are single-use.
Pass `--authorization-digest <digest>` to bind approval to the chosen
profile's reviewed `authorization_digest` from `profile show` (also returned by
`profile list`). The digest covers effective authorization from the active
manifest and persisted permission overrides. If its mode or
permissions have changed, approval fails; review the current profile before
trying again. The argument is optional for CLI approvals.
Grant revocation immediately invalidates its tokens. OAuth approval retains
the existing separate Full Access session consent requirement.

Enable OAuth per connection with `tunnel cloudflare save … --oauth-enabled`;
use `--no-oauth-enabled` to disable it. Repeat `--oauth-client-host <host>` to
replace its exact CIMD host allowlist. Omission preserves current settings on
save; new connections default off with hosts `claude.ai` and `claude.com`.
See [Cloudflare OAuth setup](CloudflareRunbook.md#oauth-client-pairing).

`clients list` returns `sessions` sorted by ID and a `next_after_id` cursor.
Each row includes the connection's exact `revision` and matching
`trust_revision`. `clients trusts` returns saved `trusts` with their revisions,
including revoked entries. Both accept `--id`, `--after-id` and `--limit`
(default 100, maximum 200). These are live pages, not a retained snapshot.

```sh
computer-mcp clients list
computer-mcp clients allow <connection-id> --full-access
computer-mcp clients limit <connection-id> --mode observe
computer-mcp clients end <connection-id>
computer-mcp clients trusts
computer-mcp clients revoke <trust-id>
```

`allow --full-access` is explicit consent to arbitrary execution as the current
macOS user, including access to that user's files, processes, network and
credentials. A workspace provides context, not a sandbox; macOS privacy
permissions still apply. The default is **This Session**. Add
`--always-allow-client` deliberately to save approval for future connections
with the same authenticated principal, caller and unchanged profile. Changing
the profile or revoking its saved trust invalidates that approval.

`limit --mode observe|restricted` sets the selected connection's access ceiling;
its profile remains an upper bound for Restricted Access. `end` stops new
requests on that connection. These commands do not cancel already started work.
`revoke` changes saved approval and affects connections relying on that approval.

Mutations read the selected record once, capture its revisions and submit one
write. Automation can supply `--expected-revision` and, for `allow`,
`--expected-trust-revision` to use previously reviewed values. Stale values fail
without retry or silently adopting new authority. Successful operations return
JSON; control failures return an `error` object with `code` and `message` and
exit nonzero. Argument parsing failures use standard CLI diagnostics. After an
unknown transport outcome, inspect access before deciding whether to try again.

For an independently started HTTP gateway, select a private absolute Unix socket:

```sh
computer-mcp serve http --config /absolute/computer-mcp.toml --database /absolute/state.sqlite --control-socket /absolute/private/control.sock
computer-mcp clients list --control-socket /absolute/private/control.sock
computer-mcp clients allow <connection-id> --full-access --control-socket /absolute/private/control.sock
```

The standalone manifest must already set `policy.shell_enabled = true` before
Full Access can be approved. Approval does not rewrite that manifest. Persistent
approval also requires `--database` and an authenticated HTTP principal; anonymous
or memory-only hosts can use This Session. The existing HTTP authentication,
loopback, origin and request-size guards apply. The socket uses current-user peer
validation and accepts only local-CLI identity. Its commands are absent from the
remote MCP catalog. Its listener and accepted connections close with the owning
HTTP runtime, and a control request from an old startup generation cannot affect
a later one. It has no authority over the production App.
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

All five mutation commands preview by default. Review the proposed settings,
then repeat the same command with `--apply` and
`--expected-current-digest <current_digest>` from that preview. A stale digest
rejects the change; obtain and review a fresh preview. Applying prepares the new
runtime configuration before publication and keeps existing client connections.
The same connection can list and invoke the new tools; existing work retains its
original owner. A failed candidate leaves the prior configuration active. A lost
response does not prove failure: inspect the current configuration before retrying.
Adding or enabling a registration does not grant profile permissions or install
dependencies. Candidate discovery does not prove authenticated tool execution.

Disabling retains launch settings, selection and profile references while
excluding the registration from new discovery and invocation. Existing work can
continue on its original owner while its current permissions remain valid. Removal rejects
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
this order: enabled MCP registrations, then CLI
registrations, preserving registration order. An unavailable selected launch
is reported directly, not replaced by another installation. PATH and common
installation locations are searched when no registration matches. A symlink's
launch path is retained. Truncated probe output cannot establish success.

These commands execute external version/help/diagnostic code. They do not
open an MCP session, exercise GUI actions, install dependencies, or grant
permissions. Their results establish only the reported probe scope, not full
integration readiness. For non-executing package checks, use
`plugins doctor <id>`; see [Plugin Packages](PluginPackages.md).

## Local client registration

`install` and `uninstall` support `codex`, `claude-code` and `claude-desktop`.
Registration installs only the generated stdio command under `computer-mcp`,
or the name selected with `--name`. It grants no gateway permissions.

App mode registers the running CLI's absolute path and the App Gateway Socket:

```sh
computer-mcp install codex --app --dry-run
computer-mcp install claude-code --app --dry-run
computer-mcp install claude-desktop --app --dry-run
computer-mcp install codex --app
```

Use the embedded CLI at
`/Applications/Computer MCP.app/Contents/Resources/computer-mcp`, or its installed
symlink. `--server-executable` selects a different executable. `--socket` with
`--app` selects a particular App instance; the default is the production App's
Gateway Socket. The App's Home connects, updates and removes each client with
its own embedded CLI and socket; it retains the reviewed plan and applies that
exact plan.

Standalone mode validates the manifest before planning and registers
`serve stdio --config <absolute-path>`:

```sh
computer-mcp install claude-code --config Examples/computer-mcp.toml --dry-run
```

Exactly one of `--app` and `--config` is required for install. `--client-cli`
selects the Codex or Claude Code executable explicitly; Claude Desktop rejects
it. Otherwise discovery uses the host's executable directories followed by
`~/.local/bin`, independently of inherited `PATH`. `--server-executable` is
available only for install. Removal needs neither a manifest nor an existing
server executable:

```sh
computer-mcp uninstall codex --dry-run
computer-mcp uninstall claude-code --name computer-mcp --dry-run
computer-mcp uninstall claude-desktop --dry-run
```

The states are `unavailable`, `not_registered`, `registered`, `different` and
`unreadable`. Registered means exact command and argument string equality;
a symlink or an old App path is different. Only positively observed absence
means not registered. Unavailable or unreadable clients cannot be changed.
An already registered install, or removal of an absent entry, is a no-op.

`--dry-run` prints the displayable schema-1 plan as snake_case JSON:

```json
{
  "schema_version": 1,
  "client": "claude-code",
  "operation": "register",
  "server_name": "computer-mcp",
  "location": {
    "configuration_file": "/home/alex/.claude.json",
    "configuration_variable": "CLAUDE_CONFIG_DIR"
  },
  "state": "different",
  "observed_entry": {
    "type": "stdio",
    "command": "user-server",
    "argument_count": 2,
    "environment_names": ["TOKEN"],
    "header_names": []
  },
  "server": {"executable": "/path/computer-mcp", "arguments": ["bridge", "--client-identity", "local-mcp", "--socket", "/path/gateway.sock"]},
  "actions": [
    {"step": "remove", "command": {"executable": "/path/claude", "arguments": ["mcp", "remove", "--scope", "user", "computer-mcp"]}},
    {"step": "add", "command": {"executable": "/path/claude", "arguments": ["mcp", "add", "--scope", "user", "computer-mcp", "--", "/path/computer-mcp", "bridge", "--client-identity", "local-mcp", "--socket", "/path/gateway.sock"]}}
  ],
  "requires_confirmation": true,
  "warnings": [],
  "applies_after": "Start a new Claude Code session.",
  "fingerprint": "<64 hexadecimal SHA-256 characters>"
}
```

Optional fields are omitted. A bound configuration directory appears as
`configuration_value`; when Claude Code's override was absent, that field is
absent and the child variable stays unset. Desktop actions contain `file`, a
redacted `before` entry summary when present, and `after` with the generated
command for registration. Desktop plans ask you to close the App and other
programs that edit its configuration. A refused plan includes `refusal_code`.

The fingerprint hashes the complete private plan: client, operation, name,
bound location, client executable, exact child environment, observed state and
complete named entry, generated server command, actions, refusal and warnings.
The private entry and recovery payload are never printed. The observed summary
shows only type, command or URL origin, argument count, and environment/header
names. Argument values, URL userinfo/path/query/fragment, environment/header
values and unrelated configuration fields are excluded.

Without `--dry-run`, safe changes apply directly. Replacing or removing a
`different` entry exits 1 with `confirmation_required` and the displayable plan.
Review a dry run, then repeat the same command with `--expect <fingerprint>`.
Any entry change causes `changed_since_preview`. Apply takes a per-user writer
lock and rechecks the bound location before writing.

| Client | Reads | Writes | Takes effect |
| --- | --- | --- | --- |
| Codex | `mcp get <name> --json` with bound `CODEX_HOME` (default `~/.codex`) | `mcp add <name> -- <command>` or `mcp remove <name>` | New session |
| Claude Code | Only the named entry in `$CLAUDE_CONFIG_DIR/.claude.json`, or `~/.claude.json` | CLI `mcp remove/add --scope user`; replacement recovery uses private `add-json` only while absent | New session |
| Claude Desktop | Named entry in `~/Library/Application Support/Claude/claude_desktop_config.json` | Same-directory atomic rename preserving other fields and existing mode; new files use `0600` and require an existing support directory | Reopen App |

Claude Code replacement requires a restorable stdio entry containing only
`type`, `command`, `args`, `env`, or HTTP/SSE with only `type`, `url`, `headers`.
A failed step with confirmed process exit is reconciled against the file;
recovery never removes another writer's entry. Desktop rejects symbolic links,
nonregular files, malformed/nonobject JSON and a running Desktop App. Its final
check compares bytes, inode, mode and size. Other client writers remain subject
to their own CLI protections; an existing Desktop file can still be overwritten
by a writer racing after the final check.

Registration processes receive exactly `HOME`, `USER`, `LOGNAME`, `TMPDIR`,
`LANG`, the bound configuration variable when present, and a `PATH` beginning
with the client executable's directory followed by host search directories and
`~/.local/bin`. Processes have a 30-second deadline and a 1 MiB limit per output
stream. On timeout the process group receives SIGKILL and its direct child is
reaped before reconciliation. Failure to confirm exit within two seconds
returns `uncertain` and runs no later step. Raw client stdout/stderr are private.

Exit codes: **0** for a successful preview/apply or no-op, **1** for refusal or
failure, **2** for an uncertain process outcome, **64** for invalid CLI options.
Apply JSON includes `outcome`, `steps` (step, outcome, optional exit_code),
`final_state`, optional redacted `final_entry` and `error_code`, and
`applies_after`. Stable error codes are `changed_since_preview`,
`confirmation_required`, `unsupported_entry`, `client_running`, `unavailable`,
`unreadable`, `writer_busy`, `write_failed`, `invalid_input`,
`invalid_server_executable`, `support_directory_missing`, `process_failed`,
and `uncertain`.

## Workspace registration repair

`workspace add` resolves symlinks and is idempotent for an existing canonical
root. `workspace repair <id> <path>` renews folder access or binds an existing
workspace to a selected folder. It preserves the canonical ID, creation time,
aliases and profile grants; the display name stays unchanged unless supplied.
The selected folder receives those existing permissions. A folder registered to
another canonical workspace is rejected. The App exposes the same operation
through each workspace's Repair action and native folder chooser.

Repair invalidates unused approvals for the affected workspace and advances
affected profile authorization, including wildcard grants. Executing operations
retain their state. New calls use the selected folder after candidate validation;
old-owner calls still require their original folder identity and current access.
Failure or concurrent configuration changes preserve the previous registration.

To repair older duplicates, first preview:

```sh
computer-mcp workspace deduplicate [--control-socket <control-socket>]
```

Review canonical ids, aliases, profile changes, and metadata conflicts, then
apply the unchanged plan with its digest. `--allow-metadata-conflicts` is an
explicit choice to keep the oldest registration metadata. The operation never
deletes the workspace directory; retired ids remain aliases for historical
references.

Removal and deduplication commit workspace records, affected profile grants, and
approval invalidation together. A failed commit leaves them unchanged. Each
affected profile receives one new authorization revision; already executing
operations and historical audit records retain their original state. Concurrent
configuration changes invalidate prepared workspace changes and require a retry.

The owner commands for adding, repairing, removing and deduplicating workspaces prepare the
new runtime configuration before committing. Connected clients stay connected;
new calls use the published configuration while existing work keeps its original
runtime. A failed candidate leaves prior registration and routing intact. Removing
a workspace denies new calls in its old scope without stopping existing work.

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
Plugin runtime configuration and execution permissions remain plugin-owned;
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
request. These approvals authorize only the exact host operation.

The App presents the tool title captured when the request was prepared and its
redacted arguments as individual fields. Technical details retain the capability
and request identifiers and original review JSON. Display metadata does not
authorize execution: the exact target, arguments, expiry and current permission
checks still govern the single-use ticket. A request whose details cannot be
read must be sent again before the App can approve it.

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
reads the official static plugin catalog through the same persistent cache as
the App. It returns JSON metadata, not an installation or a permission grant.
Filtering precedes local pagination; follow `next_page` when present. The `catalog`
object reports generation, validation time and stale status. A failed refresh
returns a saved valid snapshot with issues; without one, runtime failures return a
JSON `error` object and a nonzero exit status. Argument parsing
errors use the standard CLI usage diagnostics. See
[Official Search](PluginPackages.md#official-search) for provenance, caching,
network limits, and failure behavior.

`plugins artifacts <owner/repository> --repository-id <id> [--tag <tag>]`
selects catalog release archives locally, defaulting to the latest compatible stable
release. It also returns recorded versions, withdrawal status and prerequisites.
Use the repository name and numeric identity from search, and follow `next_page`
for additional local asset pages. Withdrawn/incompatible releases expose no
installable archives. Save one complete `artifacts` entry as a JSON file;
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
a stopped transport. It prepares candidate runtimes, commits the manifest and
resolved state, then publishes routing while keeping current connections and
old work. Failed candidates or conflicting edits leave the prior admitted state
active. Manifest rollback uses the same candidate and publication checks.

Workspace, profile, manifest, gateway, and Tunnel lifecycle writes all use the
same lifecycle-aware operations as the App. A local CLI call therefore performs
the same validation, publication, and lifecycle behavior as the corresponding
UI action. Explicit gateway restart remains a separate operation.

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

## State import

`state import` moves the state of an installation created before 0.1.0 into a
database with the current schema. Its input is that installation's one-time
schema 1 JSON export: workspaces with their canonical roots and aliases,
profiles, client trust, runtime settings, the latest activated configuration
revision, plugin selections, settings and owned directories, and derived
workspace registrations. Audit history, approvals, operation tickets and
execution receipts are not carried over. The configuration file and Keychain
items stay where they are. `--database` selects a database other than the
App's.

Quit the App and stop every gateway, bridge and tunnel process first. The
command refuses a database that any process has open, a database that already
uses the current schema, and an existing `<database>.before-import`. Database
connections share `<database>.lock` and the import holds it exclusively, so an
import and an open connection exclude each other; earlier versions do not take
this lock and are detected through the process table instead. Keep the lock
file in place.

The import writes the exported rows into `<database>.import`, checks that every
row arrived, that this version reads every imported record and that the
activated configuration parses, and only then installs it. Opening the existing
database lets SQLite finish rolling back an interrupted transaction; nothing
else in it changes. The previous database is kept as
`<database>.before-import`; to return to the earlier version, quit the App and
move that file back to the database name.

While a replacement is underway, `<database>.import-replacing` records it and
the database is not opened. Running the same command again rolls an interrupted
replacement back and then imports.

The import never changes a file it did not create. When it refuses and names a
file:

- `<database>.import` or `<database>.import-replacing.tmp` without
  `<database>.import-replacing`: an earlier import stopped before it changed the
  database. Move the named file out of the directory and run the command again.
- A file named in a refusal while `<database>.import-replacing` exists: the
  record identifies the database and its backup, so the named file is not one
  of them. Move it out of the directory and run the command again.
- A missing database or `<database>.before-import` named by the record: restore
  it before running the command again.
- A `-journal`, `-wal` or `-shm` file: open the database once with the version
  that created it so SQLite completes its recovery, quit that version, and run
  the command again.

## `bridge`

`bridge` translates line-delimited MCP stdio to the App's private gateway
socket:

```sh
computer-mcp bridge
```

The App supplies private credential/profile options to its owned Secure MCP
Tunnel process. Local clients use the local-MCP identity. The command does not
load TOML or start a second control plane.

App-owned `tools call` requests retain their execution owner across CLI process
exits and subsequent calls. Background handles continue through the same owner
after configuration changes. The owner control service works while the gateway
listener is stopped; stopping or restarting that listener does not cancel local
administration work. Stopping the owner control service or exiting the App joins
its owned processes and clears its retained results. Each continuation still
requires current workspace access, permissions and any operation approval.

## Explicit standalone mode

Standalone development requires `--config`:

```sh
computer-mcp serve stdio --config Examples/computer-mcp.toml
COMPUTER_MCP_HTTP_ACCESS_TOKEN=<development-only-value> \
  computer-mcp serve http --config Examples/computer-mcp.toml

computer-mcp tools list --config Examples/computer-mcp.toml [--control-socket <control-socket>]
computer-mcp tools inspect workspace.info --config Examples/computer-mcp.toml [--control-socket <control-socket>]
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
