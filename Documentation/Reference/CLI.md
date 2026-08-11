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
computer-mcp app status
computer-mcp doctor [--journey local|chatgpt|cloudflare] [--json]

computer-mcp config path
computer-mcp config show
computer-mcp config validate [--connect] [--config <path>]
computer-mcp config export [--output <path>]
computer-mcp config import --input <path> [--apply --expected-current-digest <digest>]

computer-mcp workspace list
computer-mcp workspace add <path> [--display-name <name>]
computer-mcp workspace remove <id>
computer-mcp workspace enable <id> --profile <profile> [--no-enabled]

computer-mcp profile list
computer-mcp profile show <id>
computer-mcp profile grant <id> --workspace <workspace-id> [--no-enabled]
computer-mcp profile shell <id> [--no-enabled]

computer-mcp tunnel openai list|doctor|start|stop|logs [<id>]
computer-mcp tunnel cloudflare list|doctor|start|stop|logs [<id>]

computer-mcp tools list
computer-mcp tools inspect <name>
computer-mcp tools call <name> --arguments-json '{}'

computer-mcp install cli [--status] [--replace-invalid-link]
computer-mcp uninstall cli
computer-mcp install codex (--app | --config <path>) [--dry-run] [options]

computer-mcp serve stdio|http --config <path> [options]
computer-mcp bridge [options]
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

## App-owned operation

`app`, `workspace`, `profile`, `tunnel`, and `tools` use the App control plane.
If the App is not running, the CLI fails with actionable startup guidance; it
does not silently create another database or gateway.

`config import` is two phase. The first invocation validates the candidate,
shows a secret-free diff, and returns the current digest. `--apply` requires
that digest so a concurrent App edit cannot be overwritten. Apply never starts
a transport.

OpenAI and Cloudflare commands are distinct namespaces and cannot select a
transport from ambient arguments. `doctor` is read-only and redacts secrets.

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
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate test-case validate
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate test-case list
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate runbook generate --output validation-runbook.md
```

There is no pass-entry command. PASS is derived only from a verified Validation
Evidence Bundle with complete transport, request, audit, and independent result
correlations.
