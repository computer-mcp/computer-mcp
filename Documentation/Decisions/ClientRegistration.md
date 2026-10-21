# Local Client Registration

## Status

Accepted.

## Context

Local MCP clients reach the gateway through the App-owned bridge, a stdio
command that connects to the Gateway Socket:

```text
<embedded computer-mcp> bridge --client-identity local-mcp --socket <gateway socket>
```

Computer MCP can register that command only with Codex, through
`CodexMCPInstaller` and `computer-mcp install codex`. Claude Code and Claude
Desktop users copy the command by hand. The App also resolves `codex` through
its own `PATH`, which for an App started by launchd does not include Homebrew or
`~/.local/bin`, so registration from the App fails where the CLI is installed.

Each client stores MCP servers differently:

- **Codex** keeps them in `config.toml` under `CODEX_HOME`, by default
  `~/.codex`, and manages them with `codex mcp add|get|remove`. `add` silently
  replaces an entry of the same name, including fields the user set on it;
  `get --json` reads an entry without starting it and fails when the name is
  absent.
- **Claude Code** keeps user-scoped servers under `mcpServers` in
  `$CLAUDE_CONFIG_DIR/.claude.json`, or `~/.claude.json` when that variable is
  unset, and manages them with `claude mcp add|add-json|remove --scope user`.
  `add` refuses an existing name. `claude mcp get` and `list` start servers to
  check their health, so they are not read-only. Running Claude Code sessions
  also rewrite that file.
- **Claude Desktop** has no CLI. It reads `mcpServers` from
  `~/Library/Application Support/Claude/claude_desktop_config.json` when it
  starts, and the file also holds the user's other settings.

## Decision

### One registration service for three clients

`ComputerMCPControlPlane` owns a client registration service with one registrar
per client kind: `codex`, `claude-code` and `claude-desktop`. It replaces
`CodexMCPInstaller`. Every registrar registers the same command under one server
name, `computer-mcp` by default: the App-owned bridge in App mode, or
`serve stdio --config <path>` for a standalone manifest from the CLI. Nothing
else is written: no environment variables, tokens or manifest contents.

| Client | Read | Write | Applies after |
| --- | --- | --- | --- |
| Codex | `codex mcp get <name> --json` | `codex mcp add <name> -- <command>`; `codex mcp remove <name>` | a new Codex session |
| Claude Code | `mcpServers.<name>` in the user-scope file | `claude mcp add --scope user <name> -- <command>`, after `claude mcp remove --scope user <name>` when replacing | a new Claude Code session |
| Claude Desktop | `mcpServers.<name>` in its configuration file | replace only `mcpServers.<name>` in that file | reopening Claude Desktop |

Clients with a CLI are changed only through it, so their own format and
validation stay authoritative. Claude Code's state is read from its file
because its CLI has no read-only query.

### Configuration location

A plan binds one configuration location per client, resolved once from the
invoking process: Codex's `CODEX_HOME` or `~/.codex`, and Claude Code's
`CLAUDE_CONFIG_DIR` (present or absent) with the file it selects. Every read,
write and recovery step for that plan uses the bound location: client CLIs run
with `CODEX_HOME` set to it, or with `CLAUDE_CONFIG_DIR` set exactly as bound
and absent when unbound. Plans show the location.

### States

Each registrar reports one state:

- **unavailable**: the client is not installed (no CLI found, or for Claude
  Desktop no application with bundle identifier
  `com.anthropic.claudefordesktop`), its CLI cannot run in the environment
  below (its `--version` probe fails), or the platform has no implementation
  (Claude Desktop outside macOS);
- **not registered**: positively observed absence: Codex's `get` exits 1 with
  its "No MCP server named" message, or the file has no entry with the name;
- **registered**: the entry's command and arguments equal the planned strings
  exactly; a symlink or another path to the same executable is not equal;
- **different**: an entry with the name runs something else, for example an
  earlier App location or the user's own server;
- **unreadable**: any other outcome, including other exit codes, timeouts,
  truncated or malformed output, files that do not parse, a top level or
  `mcpServers` that is not a JSON object, or an unsupported file type.

Only **not registered**, **registered** and **different** permit a write.
Registering an already **registered** client changes nothing.

### Preview, then apply exactly what was previewed

Registration and removal are two steps. Preview returns a plan: the client, the
bound location, the observed state and entry, the exact actions (client
commands and arguments, or the Claude Desktop file with the entry before and
after) and a fingerprint, a digest of all of these. Apply receives the plan or,
from the CLI, its fingerprint, reads the state again and refuses with
`changed_since_preview` unless it reproduces the same fingerprint.

- The App keeps the reviewed plan and applies that plan object.
- The CLI's `--dry-run` prints the plan with its fingerprint. Without
  `--dry-run`, the CLI applies a fresh plan only when it destroys nothing: the
  state is **not registered**, or **registered** for registration, or the
  removal of an entry that is **registered**. Replacing or removing a
  **different** entry requires `--expect <fingerprint>` from a reviewed dry run
  and otherwise fails with `confirmation_required`, printing the plan.

### Writes and concurrency

Computer MCP's own writers (the App and any CLI process) serialize registration
changes through an exclusive advisory lock on a file in Computer MCP's per-user
state directory. Other programs cannot take that lock, so the guarantee against
them is narrower:

- Codex and Claude Code are changed through their own CLIs and get exactly the
  protection those CLIs give against their other writers. The recheck closes
  the window between preview and apply, not the window inside the client's own
  write.
- Claude Desktop changes require Claude Desktop not to be running; the plan
  says so and apply refuses with `client_running` otherwise. The final check
  compares the file's bytes, inode, mode and size immediately before the
  replace, which is a same-directory rename of a temporary file created
  exclusively with mode `0600` before any content is written. The result keeps
  the existing file's mode, or `0600` for a new file. A missing file is created
  only when the Claude Desktop support directory exists, by an exclusive rename
  that fails if the path appeared meanwhile. A configuration path that is a
  symbolic link or not a regular file is **unreadable**. A write by another
  program between the final check and the replace of an existing file is not
  detected and is lost; the plan asks the user to close other programs that
  edit the file.

### Client processes

Client CLIs are resolved from an explicit path when one is given, otherwise from
the platform's executable search directories followed by `~/.local/bin`, never
from the App's inherited `PATH`. They run with exactly `HOME`, `USER`,
`LOGNAME`, `TMPDIR`, `LANG`, the bound configuration variable and a `PATH` that
starts with the CLI's directory followed by the search directories, with a
bounded time and output. On timeout the process group is killed and the service
waits for its exit before doing anything else; if the exit cannot be confirmed
the outcome is **uncertain** and no later step runs.

### Claude Code replacement and recovery

Replacing a **different** Claude Code entry is `remove`, then `add`. It is
planned only when the observed entry can be restored by `add-json`: a stdio
entry with only `type`, `command`, `args` and `env`, or an HTTP or SSE entry
with only `type`, `url` and `headers`; otherwise the plan is refused as
`unsupported_entry`. After a step that failed or timed out and whose process
exit was confirmed, the service reads the entry again and reconciles:

- the planned entry is present: the registration succeeded;
- no entry is present after the removal: the observed entry is restored with
  `add-json`, only while the name is still absent, and the entry is read again;
- anything else is another writer's change, which is left untouched.

When a step's exit cannot be confirmed, the result stays **uncertain**: nothing
is restored, success is not reported, and the result names the step and the
last observed state. Otherwise the result reports each step's outcome and the
final observed state.

### Presentation and privacy

A plan's displayable form contains the location, the planned command and
arguments, which Computer MCP generates and which hold no secrets, and for an
observed entry only its type, its command or its URL's origin (scheme, host and
port), the number of its arguments, and the names of its environment variables
and headers. An observed entry's argument values, URL userinfo, path, query and
fragment, and environment and header values are never shown. The complete
observed entry stays in the private plan for comparison and recovery and is
never printed, logged or returned in errors; recovery `add-json` payloads are
likewise never shown. Nothing outside the named entry is read into a plan.

### Interfaces

- The CLI provides `computer-mcp install <client>` and
  `computer-mcp uninstall <client>`, with `--app` or `--config` for install,
  `--name`, `--client-cli` for clients that have one, `--server-executable`,
  `--dry-run` and `--expect`. Removal does not validate a manifest or an
  executable.
- The App's Home lists the three clients with their state and offers Connect,
  Update or Remove. Each opens the plan for review; confirming applies that
  plan and states when the change takes effect. The Welcome page's local client
  choice leads there.

### Verification

Each client is accepted when a real registration from the App lets that client
call `workspace.list` and Home reports Local MCP as Verified. Verified remains
the local journey's state, not a per-client state.

## Consequences

- Codex, Claude Code and Claude Desktop connect without copying commands, and
  an outdated registration after the App moves shows as **different** with an
  Update action.
- The service depends on Claude Code's user-scope file layout and Claude
  Desktop's configuration file; a change in either shows as **unreadable**
  rather than causing a write.
- Changes made by a client while it runs can still race its own CLI; Computer
  MCP adds no write the client's own CLI would not make, and changes Claude
  Desktop's file only while it is closed.
- Claude Desktop's configuration loses its original formatting on the first
  change, but none of the content read at the final check.

## Alternatives Considered

- Editing every client's configuration file directly: duplicates parsers for
  TOML and two JSON layouts and bypasses the CLIs' validation.
- Reading Claude Code state with `claude mcp get`: starts the bridge and every
  other configured server as a side effect of a preview.
- Claude Desktop extensions (`.mcpb` bundles): suited to distributing a server,
  not to pointing Claude Desktop at a bridge the App already owns.
- Per-client Verified states: needs client identity in audit records, which the
  gateway does not have; the local journey already proves the registered path.
