# Tools Reference

Local gateway and coding tools advertise a human-readable `title`, explicit
input schema, generic structured-result output schema, and operational
annotations. Successful calls return the same bounded JSON value as readable
JSON text and as `structuredContent.result`. Downstream MCP tools keep their
provider-declared schemas and result shape when the Swift SDK exposes them.

## `cli.list`

Lists TOML-registered CLI providers. Each entry includes `has_interface` so MCP
consumers can decide whether to call `cli.describe` before using the provider.

## `cli.describe`

Returns one CLI provider's configuration metadata and mechanical interface.
Environment values are not returned.

Arguments:

```json
{
  "id": "lark"
}
```

## `cli.status`

Reports whether registered CLI provider executables can be resolved without
invoking provider command trees. Omit `id` to inspect all configured providers.

Arguments:

```json
{
  "id": "git"
}
```

## `cli.help`

Runs a registered CLI path with `--help` and returns the raw help text plus
mechanical context for constructing a follow-up `cli.exec` MCP call. MCP
consumers should not execute the shown command outside this gateway.

Arguments:

```json
{
  "id": "lark",
  "path": ["im", "+chat-search"]
}
```

Result text contains JSON like:

```json
{
  "id": "lark",
  "path": ["im", "+chat-search"],
  "help_argv": ["im", "+chat-search", "--help"],
  "exec_context": {
    "tool": "cli.exec",
    "id": "lark",
    "argv_prefix": ["im", "+chat-search"]
  },
  "interface": {
    "path_style": "argv",
    "flag_style": "long_flags",
    "flag_case": "kebab",
    "value_style": "separate",
    "format_flag": "--format",
    "default_format": "json",
    "dry_run_flag": "--dry-run"
  },
  "stdout": "...raw CLI help...",
  "stderr": "",
  "exit_code": 0
}
```

## `cli.exec`

Executes a registered local CLI through this MCP gateway with explicit argv.
Use this for follow-up calls after reading `cli.help`.

Arguments:

```json
{
  "id": "lark",
  "argv": [
    "im",
    "+chat-search",
    "--query",
    "design team",
    "--format",
    "json"
  ]
}
```

Result text contains JSON with `stdout`, `stderr`, `exit_code`, `timed_out`, and
truncation flags.

## `mcp.servers.list`

Lists TOML-registered downstream MCP servers.

## `mcp.servers.status`

Reports deterministic readiness metadata for TOML-registered downstream MCP
servers without starting subprocesses or calling downstream tools. For stdio
servers it resolves the configured command. For HTTP servers it reports parsed
URL metadata. Configured environment variable names are listed with values
redacted.

Arguments:

```json
{
  "server": "figma"
}
```

Omit `server` to inspect every registered downstream MCP server.

## `mcp.tools.list`

Calls downstream `tools/list` for one server.
The returned catalog is filtered by that provider's reviewed `allowed_tools`.
`allow_any_tool` is accepted only for trusted local-admin configurations.

Arguments:

```json
{
  "server": "figma"
}
```

## `mcp.tools.describe`

Calls downstream `tools/list` for one server, then returns the exact matching
tool definition by name plus `call_context` for `mcp.tools.call`. Matching is
case-sensitive and exact; this is not semantic tool selection.

Arguments:

```json
{
  "server": "figma",
  "tool": "get_screenshot"
}
```

## `mcp.tools.find`

Calls downstream `tools/list` for one server, then filters the returned tool
definitions with deterministic string matching. It can match `name`,
`description`, or `all`; match modes are `contains`, `prefix`, `suffix`, and
`exact`. This is not semantic tool selection.

Arguments:

```json
{
  "server": "bilibili",
  "query": "video_",
  "match": "prefix",
  "field": "name",
  "case_sensitive": false,
  "max_results": 50
}
```

## `mcp.tools.call`

Calls a tool on one downstream MCP server.
The exact tool name must be present in the provider's reviewed allowlist;
discovery does not grant authority to newly added downstream tools.
Calls wait for the downstream result by default. For a long-running request
that must remain controllable by a sequential MCP consumer, set
`wait_for_result` to `false` and supply a nonempty caller-stable `request_id`.
The call then returns as soon as the downstream request is running. Use
`mcp.requests.list` to observe it and `mcp.requests.cancel` to send the MCP
cancellation notification. The persistent provider session remains usable
after cancellation.

Arguments:

```json
{
  "server": "figma",
  "tool": "get_screenshot",
  "arguments": {
    "fileKey": "...",
    "nodeId": "..."
  }
}
```

Start-only arguments:

```json
{
  "server": "fixture-stdio",
  "tool": "fixture_hang",
  "request_id": "caller-stable-request-id",
  "wait_for_result": false,
  "arguments": {}
}
```

## `mcp.requests.list`

Lists active downstream tool requests for one persistent provider session.
The `request_id` values are the caller-stable identifiers supplied to
`mcp.tools.call`.

## `mcp.requests.cancel`

Cancels one active downstream request by its caller-stable `request_id`. This
is a write-capability call and follows the configured operations-ticket policy.

## `mcp.resources.list`

Calls downstream `resources/list` for one server. Returned resources include
`read_context` for `mcp.resources.read` when a resource URI is present. This
does not read resource content.

Arguments:

```json
{
  "server": "figma",
  "cursor": "optional-page-cursor"
}
```

## `mcp.resources.templates.list`

Calls downstream `resources/templates/list` for one server. The gateway returns
templates as declared by the provider and does not expand URI templates.

Arguments:

```json
{
  "server": "figma",
  "cursor": "optional-page-cursor"
}
```

## `mcp.resources.read`

Calls downstream `resources/read` for one server and URI. The gateway forwards
the URI exactly and does not interpret it as a local filesystem or network path.

Arguments:

```json
{
  "server": "figma",
  "uri": "file:///example"
}
```

## `mcp.prompts.list`

Calls downstream `prompts/list` for one server. Returned prompts include
`get_context` for `mcp.prompts.get` when a prompt name is present. This does
not fetch prompt messages or choose a prompt semantically.

Arguments:

```json
{
  "server": "figma",
  "cursor": "optional-page-cursor"
}
```

## `mcp.prompts.get`

Calls downstream `prompts/get` for one server and prompt name. Prompt arguments,
when supplied, must be string values. The gateway forwards the name and
arguments exactly and does not interpret the returned messages.

Arguments:

```json
{
  "server": "figma",
  "name": "review",
  "arguments": {
    "path": "Sources"
  }
}
```

## MCP-Backed `[[tools]]`

MCP-backed `[[tools]]` entries can expose selected downstream MCP tools as
top-level gateway tools. CLI commands are not exposed through `[[tools]]`.

## Local Provider Bridge

Domain CLIs that already expose MCP should be registered as downstream
`[[mcp.servers]]`, not rebuilt as gateway builtins. The repository includes
`Examples/computer-mcp-local-providers.toml` with examples for `apple-cli-mcp`,
`xhs mcp serve`, `wechat mcp serve`, `bili mcp serve`, `youtube mcp serve`, and
`ins mcp serve`.

`apple-cli-mcp` is the owner for Apple-domain workflows such as clipboard,
notifications, Finder behavior, application launching, and URL opening. The
gateway intentionally does not expose parallel builtins for those operations.
After listing the Apple provider tools, inspect `apple_cli_command_catalog` and
invoke `apple_cli_run` through `mcp.tools.call` when those are the provider tools
selected for the workflow.

When `apple-cli-mcp` cannot resolve its sibling `apple` executable, set
`APPLE_CLI_BIN_DIR` in that server's TOML `env` table to the directory that
contains `apple`. This is provider process configuration, not a gateway-owned
Apple capability.

Recommended flow:

```json
{
  "server": "apple"
}
```

Call `mcp.servers.status` first to check whether the provider executable is
available. For tools, use `mcp.tools.list`, `mcp.tools.describe`,
`mcp.tools.find`, and `mcp.tools.call`. For resources, use
`mcp.resources.list`, `mcp.resources.templates.list`, and `mcp.resources.read`.
For prompts, use `mcp.prompts.list` and `mcp.prompts.get`.

## `process.spawn`, `process.list`, `process.read`, `process.cancel`

Spawn, list, inspect, and cancel long-running commands by registered CLI id.
`process.list` reports only sessions created through `process.spawn`; it is not
a macOS process-table tool. The `chatgpt-operate` profile exposes only the
read-only `process.list` surface. `process.spawn` remains Full Shell-equivalent
and is never tunnel-exposed; use `policy.probe` when acceptance testing its
audited denial.

## `policy.probe`

Evaluate one exact Gateway capability against the active caller, profile, and
workspace without executing the target. An allowed target returns its risk and
bound workspace. A denied target returns the same stable `policy.*` error that
execution would produce, and the probe is written to the Gateway audit log.

## Workspace And Operation Tools

`workspace.list` returns stable workspaces granted to the caller.
`workspace.describe` returns one workspace after grant and bookmark
resolution. Every scoped tool accepts `workspace_id`; omission is rejected when
more than one workspace is available.

`operations.prepare` creates a short-lived, single-use ticket for a configured
destructive atomic. `operations.commit` executes the exact canonical tool name
and arguments bound into that ticket. Tickets do not grant capabilities or
expand a workspace.

## Codex Provider Tools

The `[codex]` provider exposes five independent families:

- `codex.app.*`: App Server status, reviewed method discovery/call, runtime
  ownership and cleanup, stale ownership reconciliation, thread
  start/list/read/recent/fork/release/reclaim, handoff diagnosis, scoped
  execution elevation, native Goal get/set/clear, turns and steering, reviews,
  models, Skills, apps, events, ordinary user-input requests, and durable
  approvals.
- `codex.exec.*`: start, resume, list, cursor events, result, and cancel.
- `codex.mcp.*`: status, upstream tools, run/reply, calls, cursor events,
  result, approvals, approval response, and cancel.
- `codex.run.*`: Computer MCP-owned acceptance runs, evidence, evaluation,
  explicit acceptance, state transitions, and selected child reconciliation.
- `codex.worktree.leases.*`: durable mutation ownership, heartbeat, release,
  conflict reporting, and receipt-only cleanup. `codex.worktree.managed.*`
  reads Computer MCP-owned lifecycle receipts;
  `codex.worktree.provision.plan|perform` creates a reviewed isolated child;
  `codex.worktree.remove.plan|perform` verifies and removes only that clean,
  released child while preserving its branch.

`codex.diagnostics.snapshot` is the workspace-scoped operator view across those
families and recent gateway/Git audit rows. It includes correlation and
generation identifiers but omits command output, file contents, and secrets.

Runtime management is limited to Computer MCP-owned instances. Use
`codex.app.runtimes.list|inspect|history`, preview cleanup, then perform an
explicit reviewed cleanup or stop one exact runtime.
`codex.app.ownership.reconcile.preview|perform` repairs only a digest-bound set
of stale loaded receipts after the referenced runtime and owned process are
proven gone; it never mutates external Codex state or sends a signal.

`codex.app.thread.release` performs a full handoff transaction across every
matching owned runtime. It handles an active turn only when explicitly asked,
refuses unresolved interactive state in graceful mode, verifies the official
loaded set after bounded unsubscription, reaps an empty runtime, and returns
success only when no Computer MCP writer remains and the thread is
`released_persisted`. `codex.app.thread.reclaim` deliberately asks the runtime
to resume a persisted thread after validating its durable registered-workspace
ownership receipt or the official persisted thread index; a competing writer
remains an error and is not terminated.
`codex.app.handoff.diagnose` correlates that receipt with live runtime, process,
connection, thread, turn, approval, and last-runtime evidence before supplying
safe actions. Product surfaces describe those actions and ownership states in
natural, contextual language; “重新接管线程” and “检查线程占用” are illustrative
labels rather than fixed interface copy.

`codex.app.elevation.request|list|read|approve|deny|revoke|effective` manages a
separate, durable execution-sandbox grant. A request does not elevate anything;
approve/deny are local-admin-only, and an approved grant is atomically consumed
only by an eligible future thread/turn start. Next-turn, exact-thread TTL, and
bounded-time modes remain bound to the original workspace canonical root,
profile, caller, connection, and optional thread. Expiry, revocation,
workspace/profile disablement, provider shutdown, and handoff remove future
effect. The grant changes only Codex's sandbox and does not add Computer MCP
tools or capabilities.

`codex.app.thread.recent` reads a snapshot-bounded tail of a persisted rollout
and returns metadata, official Goal state, active/recent turns, messages, items,
and compact progress. Cursor, page bytes, Goal-scan bytes, output bytes, and
elapsed scan limits are explicit. It opens Codex state read-only and reports
`full_history_loaded = false`.

Official Goal state and Computer MCP acceptance state are separate.
`codex.app.goal.get|set|clear` use stable official protocol bindings and native
status semantics. `codex.run.*` adds Computer MCP-owned criteria, evidence,
budgets, pause/cancel behavior, contradictions, and acceptance without
representing those fields as native Codex Goal state. A turn can finish while
either remains active.

App Server approvals are also separate from the `codex.mcp.*` upstream tool
approval flow. `codex.app.approvals.list|read|respond` operates the durable
broker for command, file, permissions, apply-patch, exec-command, and registered
tool requests. Gateway policy decides whether an operation is eligible before
approve-once, bounded session approval, denial, or timeout is offered.
Capability permission and consent remain separate: an allowed mutation can
still require consent. For gateway-owned builtins with a reviewed non-mutating
dry-run implementation, invocation preflight reports read-only consent risk;
for example, `git.add` with `dry_run=true` executes without creating a mutation
approval. Actual writes retain their original risk. Configured and downstream
tools are never downgraded from an unverified `dry_run` argument, and no
remembered decision crosses tool, workspace, profile, caller, or path scope.

Managed worktree provisioning is intentionally two step. The plan validates
the repository, parent lease, branch, start commit, derived path, profile, and
lineage and expires after five minutes. Perform uses the plan revision, creates
the worktree under the App-managed root, registers a child workspace, grants it
to the current profile, and acquires the isolated lease. Reconnect before
routing a turn to that newly registered workspace.

Managed removal is also two step and cannot be forced. Release the child lease,
stop its owned runtime, and ensure the worktree is clean. Removal planning then
binds the exact receipt, Git common directory, and HEAD. Performing the removal
requires confirmation and, through the Gateway, `operations.prepare` followed
by `operations.commit`. The workspace registration and profile grant are
removed, but the branch remains available for review or reconciliation.

All paths use the gateway-selected workspace, sandbox, approval policy, output
bounds, and audit context. Raw argv, arbitrary Codex configuration, unscoped or
caller-supplied `danger-full-access`, login/token mutation, marketplace
mutation, and remote pairing are not part of this tool surface.

`codex.exec.*` invokes the upstream official `--ignore-user-config` mode. It
still uses the local user's existing Codex authentication, but does not load
user-global MCP servers, models, hooks, profiles, or other `config.toml`
settings. This makes the embedded Exec result depend on the reviewed Gateway
request instead of unrelated interactive Codex customization.

## Skills Gateway Contract

`skills.*` belongs to the main gateway, independently of Codex. When
`[skills].enabled = true`, ChatGPT, Codex, or any other authorized MCP client
can discover and read configured skill packages directly. The mechanical flow
is `skills.list` or `skills.search`, then `skills.read`, followed by
`skills.files`, `skills.read_file(s)`, or `skills.read_package` for referenced
content. Skill reads never execute bundled scripts; subsequent actions remain
explicit calls through the same MCP gateway.

## `skills.roots`

Available only when `[skills].enabled = true`. Lists configured local skill
roots and filesystem readiness metadata. It does not read skill contents.

## `skills.list`

Available only when `[skills].enabled = true`. Lists `SKILL.md` entries from
configured roots. Roots can contain a `SKILL.md` directly or immediate child
directories with `SKILL.md`.

Arguments:

```json
{
  "root_id": "showxu",
  "max_results": 100
}
```

Returned rows include `root_id`, `name`, `directory_name`, `description`,
`path`, `skill_directory_path`, file metadata, `describe_context`,
`validate_context`, `read_context` for a follow-up `skills.read` call, and
`files_context` for listing the full skill directory.

## `skills.describe`

Available only when `[skills].enabled = true`. Returns a read-only package
manifest for one configured local skill. It reports entrypoint metadata,
resource directory counts for `agents/`, `references/`, `scripts/`, and
`assets/`, package-level file counts, truncation metadata, and follow-up
contexts. It does not read file contents, execute scripts, or select skills
semantically.

Arguments:

```json
{
  "root_id": "codex-system",
  "name": "skill-creator",
  "max_depth": 6,
  "max_scan_entries": 20000
}
```

Returned data includes `entrypoint.read_context`, package `resources` with
`list_context` for resource directories, `read_context` for `skills.read`, and
`files_context` for a full `skills.files` listing.

## `skills.validate`

Available only when `[skills].enabled = true`. Mechanically validates one
configured local skill package. It checks required `SKILL.md` frontmatter,
canonical naming hints, directory-name mismatch, unreadable paths, symlink
escapes, and truncation status. It returns structured issues with `severity`,
`code`, `message`, and `path`; `valid` is false only when at least one `error`
issue is present. It is read-only and does not execute bundled scripts such as
`quick_validate.py`.

Arguments:

```json
{
  "root_id": "codex-system",
  "name": "skill-creator",
  "max_bytes": 1048576,
  "max_depth": 6,
  "max_scan_entries": 20000
}
```

Returned data includes `frontmatter`, `entrypoint`, `resources`,
`error_count`, `warning_count`, `issues`, `describe_context`, `read_context`,
and `files_context`.

## `skills.frontmatter`

Available only when `[skills].enabled = true`. Reads leading YAML or TOML
frontmatter from one Markdown file inside a configured local skill package.
`path` defaults to `SKILL.md`; pass a skill-relative Markdown path such as
`references/guide.md` to inspect supporting files. The tool is read-only,
requires the file to remain inside the selected skill directory, and does not
infer skill trigger behavior, choose skills, summarize body content, or execute
package scripts.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": "SKILL.md",
  "format": "auto",
  "max_bytes": 1048576,
  "max_depth": 128
}
```

The result includes `found`, `format`, delimiter flags, raw frontmatter text,
line numbers, `body_start_line`, and a parsed `value` when the frontmatter is
valid YAML or TOML. Missing frontmatter returns `found = false` with
`failure.reason = "missing_frontmatter"`. Unterminated frontmatter returns
`found = false` with `failure.reason = "unterminated_frontmatter"`. Malformed
frontmatter returns `found = true`, `parsed = false`, `parse_error`, and
`value = null`.

## `skills.read`

Available only when `[skills].enabled = true`. Reads full bounded `SKILL.md`
content for one configured local skill. The tool is read-only and does not
execute skill scripts or follow relative references by itself.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "coding-plan",
  "max_bytes": 1048576
}
```

`root_id` is optional unless the skill name or directory name is ambiguous.
`max_bytes` is capped by `[skills].max_bytes_per_skill`. The result includes
`content`, `content_bytes_read`, `content_truncated`, and `valid_utf8`.

## `skills.files`

Available only when `[skills].enabled = true`. Lists files inside one
configured skill directory, including `references/`, `scripts/`, `agents/`,
`assets/`, and other local support files. It is read-only and does not execute
scripts or follow symlink directories.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": ".",
  "max_depth": 6,
  "max_results": 500
}
```

Rows include `path`, `type`, `outline_language`, size and modification
metadata, symlink metadata, and `read_context` for file entries. Outline-capable
file entries include `outline_context` for a follow-up `skills.outline` call.
Markdown file entries also include `link_check_context` for a follow-up
`skills.link_check` call. Directory entries include `list_context` for
continuing the listing from that subdirectory.

## `skills.read_file`

Available only when `[skills].enabled = true`. Reads a bounded file from inside
one configured skill directory by skill-relative path. It rejects absolute
paths, `..`, and symlink targets that resolve outside the selected skill
directory.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": "references/source-role-map.md",
  "encoding": "utf8",
  "max_bytes": 1048576
}
```

`encoding` is `utf8` by default and may be `base64` or `auto` for binary
assets. In `auto` mode, valid UTF-8 files return UTF-8 content and non-UTF-8
files return base64 content. The result includes `content`,
`content_bytes_read`, `content_truncated`, `valid_utf8`, and the actual
returned `encoding`.

## `skills.read_files`

Available only when `[skills].enabled = true`. Reads multiple bounded files
from inside one configured skill directory by explicit skill-relative paths. It
uses a uniform requested `encoding` for every file, rejects absolute paths, `..`,
directories, missing files, and symlink targets that resolve outside the
selected skill directory, and does not execute scripts.

Arguments:

```json
{
  "root_id": "codex-system",
  "name": "skill-creator",
  "paths": ["agents/openai.yaml", "references/openai_yaml.md"],
  "encoding": "utf8",
  "max_bytes_per_file": 65536
}
```

`encoding` may be `utf8`, `base64`, or `auto`. In `auto` mode, each returned
file reports its actual encoding. The `paths` array must contain 1 to 50
values. Returned data includes one entry per file with `content`,
`content_bytes_read`, `content_truncated`, `valid_utf8`, and file metadata,
plus aggregate byte and truncation counts.

## `skills.read_package`

Available only when `[skills].enabled = true`. Reads a bounded snapshot of
files inside one configured skill directory, including `SKILL.md`,
`references/`, `scripts/`, `agents/`, `assets/`, and other local package files.
It is read-only, rejects path escapes, skips directories and symlinks, and never
executes bundled scripts.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": ".",
  "encoding": "auto",
  "max_depth": 6,
  "max_files": 100,
  "max_bytes_per_file": 65536,
  "max_total_bytes": 1048576
}
```

`encoding` may be `utf8`, `base64`, or `auto`. In `auto` mode, valid UTF-8
files return UTF-8 content and non-UTF-8 files return base64 content. The result
includes returned `files`, `skipped` entries with reasons, aggregate byte counts,
and truncation metadata. Bounded package reads prioritize `SKILL.md`, then
`agents/openai.yaml`, then references, agents, scripts, assets, and remaining
package files so the entrypoint is preserved when byte budgets are tight.

## `skills.outline`

Available only when `[skills].enabled = true`. Returns a bounded mechanical
outline for one UTF-8 file inside a configured skill package. It uses the same
outline recognizers as `file.outline`, including Markdown headings and common
source declarations. It is read-only, skips fenced Markdown code blocks, does
not summarize content, does not choose files, and does not execute scripts.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": "SKILL.md",
  "include_imports": false,
  "max_bytes": 1048576,
  "max_results": 200
}
```

`path` defaults to `SKILL.md`. Returned items include `line`, `kind`, `level`
when applicable, `name`, and raw outline text. Results also include
`read_file_context` for the same skill-relative file plus `section_context`,
`tables_context`, `links_context`, and `link_check_context` for Markdown files.

## `skills.section`

Available only when `[skills].enabled = true`. Extracts one raw Markdown
section by exact ATX heading text from one file inside a configured skill
package. It uses the same heading-boundary recognizer as `markdown.section`,
defaults to `SKILL.md`, skips fenced code blocks when finding headings, and
keeps the selected file inside the skill directory. The tool does not search
semantically, summarize content, follow links, choose skills, crawl packages,
or execute scripts.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": "SKILL.md",
  "heading": "Baseline",
  "level": 2,
  "occurrence": 1,
  "include_heading": true,
  "max_bytes": 1048576,
  "max_section_bytes": 1048576
}
```

`path` defaults to `SKILL.md`. Use `skills.outline` first when the caller needs
to discover exact heading text and levels. The section starts at the matched
heading and ends before the next heading at the same or higher level. Missing
headings return `matched = false` with `failure.reason = "missing_heading"`.
Results include follow-up contexts for `skills.read_file`, `skills.outline`,
`skills.frontmatter`, `skills.tables`, `skills.links`, and
`skills.link_check` on the same skill-relative file.

## `skills.tables`

Available only when `[skills].enabled = true`. Extracts bounded
GitHub-flavored pipe tables from one Markdown file inside a configured skill
package. It uses the same mechanical table recognizer as `markdown.tables` and
keeps the selected file inside the skill directory. Fenced code blocks are
ignored by default. The tool does not infer table semantics, summarize skill
content, crawl packages, execute scripts, or choose skills.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": "references/schemas.md",
  "include_code_blocks": false,
  "max_tables": 20,
  "max_rows_per_table": 100,
  "max_bytes": 1048576
}
```

`path` defaults to `SKILL.md`. Returned tables include `start_line`,
`end_line`, `header_line`, `delimiter_line`, `headers`, `alignments`, raw table
text, `row_count`, and bounded row data. Each row reports `raw_cells`,
normalized `cells` padded or truncated to the header column count,
`missing_cell_count`, and `extra_cells`. Results also include follow-up
contexts for `skills.read_file`, `skills.outline`, `skills.frontmatter`,
`skills.section`, `skills.links`, and `skills.link_check` on the same
skill-relative file.

## `skills.links`

Available only when `[skills].enabled = true`. Extracts a bounded mechanical
Markdown link inventory from one file inside a configured skill package. It
uses the same Markdown link parser as `markdown.links`, defaults to `SKILL.md`,
resolves reference links when reference definitions are included, maps local
targets to `target_skill_relative_path`, and keeps source and targets inside
the selected skill directory. It does not fetch URLs, check target existence,
check fragments, crawl packages, choose skills, or execute scripts.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": "SKILL.md",
  "include_images": true,
  "include_reference_definitions": true,
  "include_autolinks": true,
  "include_code_blocks": false,
  "max_links": 200,
  "max_bytes": 1048576
}
```

Returned links include source line, link kind, label, raw destination,
`resolved_destination` for reference links, title, raw text, image/local/external
flags, and a `target` object with `target_skill_relative_path` when the target
is package-local. Package-local targets include `target_context` with
follow-up `skills.read_file`, `skills.outline`, `skills.section`,
`skills.tables`, `skills.links`, and `skills.link_check` calls when applicable.
Use `skills.link_check` after `skills.links` when the caller needs existence or
fragment validation.

## `skills.link_check`

Available only when `[skills].enabled = true`. Checks local Markdown links in
one file inside a configured skill package. It resolves reference definitions,
verifies that local targets stay inside the selected skill directory, checks
target existence, and optionally checks Markdown heading/id fragments. External
URLs and email links are reported as unchecked; the tool does not fetch URLs,
crawl packages, execute scripts, select skills, or infer instruction quality.

Arguments:

```json
{
  "root_id": "showxu",
  "name": "skill-creator",
  "path": "SKILL.md",
  "include_images": true,
  "include_reference_definitions": true,
  "include_autolinks": true,
  "include_code_blocks": false,
  "check_fragments": true,
  "max_links": 200,
  "max_bytes": 1048576,
  "max_target_bytes": 1048576
}
```

`path` defaults to `SKILL.md`. Returned checks include source line, link kind,
raw destination, resolved destination for reference links, status, category,
issue text when applicable, and a `target` object with
`target_skill_relative_path` for follow-up `skills.read_file` calls. Status
values are mechanical: `ok`, `missing_target`, `missing_fragment`,
`missing_reference_definition`, `outside_skill`, `empty_destination`,
`external_unchecked`, and `fragment_unchecked`.
Results also include follow-up contexts for `skills.frontmatter`,
`skills.outline`, `skills.section`, `skills.tables`, and `skills.links` on the
same skill-relative Markdown file.

## `skills.search`

Available only when `[skills].enabled = true`. Performs deterministic
substring search over skill metadata and, when requested, bounded `SKILL.md`
content. It is not semantic skill selection.

Arguments:

```json
{
  "query": "swift",
  "root_id": "showxu",
  "search_content": true,
  "max_results": 20,
  "max_bytes_per_skill": 65536
}
```

Matches include `matched_fields` for metadata hits and up to five
`content_matches` per skill when `search_content` is true.

## `skills.search_files`

Available only when `[skills].enabled = true`. Searches files inside one
configured local skill package by deterministic substring matching over
skill-relative paths and, when requested, bounded UTF-8 file content. It is
read-only and does not execute scripts.

Arguments:

```json
{
  "root_id": "codex-system",
  "name": "skill-creator",
  "query": "openai_yaml",
  "search_content": false,
  "max_depth": 6,
  "max_results": 100,
  "max_matches_per_file": 5,
  "max_file_bytes": 65536,
  "max_scan_entries": 20000
}
```

Returned rows include `path`, file metadata, `matched_fields`,
`content_matches` when `search_content=true`, and `read_context` /
`list_context` for follow-up `skills.read_file` or `skills.files` calls.

## `workspace.info`

Available only when `[builtin].enabled` includes `workspace.info`. Returns a
non-secret summary of the configured gateway: workspace root, policy values,
enabled builtins, CLI ids, MCP server ids, configured top-level tools, and
tool auth metadata.

Arguments:

```json
{}
```

## `workspace.status`

Available only when `[builtin].enabled` includes `workspace.status`. Returns a
read-only state summary of the configured workspace root: existence,
read/write capability, bounded top-level file/directory/symlink counts, and
whether a `.git` metadata marker exists at the root. It does not read file
contents, return top-level names, run Git, or traverse recursively.

Arguments:

```json
{
  "include_hidden": false,
  "max_entries": 5000
}
```

## `workspace.manifests`

Available only when `[builtin].enabled` includes `workspace.manifests`.
Returns existence and type metadata for a fixed catalog of common project
manifest and config markers at the configured workspace root, such as
`Package.swift`, `package.json`, `pyproject.toml`, `.github/workflows`, and
`README.md`. It does not read file contents, recurse, run package managers, or
infer the project stack.

Arguments:

```json
{
  "include_missing": false,
  "max_results": 49
}
```

## `workspace.recent_files`

Available only when `[builtin].enabled` includes `workspace.recent_files`.
Returns a bounded list of recently modified regular files under the configured
workspace using filesystem metadata only. It sorts by modification time
descending and then by workspace-relative path for ties. It does not read file
contents, run Git, or infer project semantics.

Arguments:

```json
{
  "include_hidden": false,
  "max_results": 25,
  "max_scan_entries": 10000
}
```

## `workspace.directory_stats`

Available only when `[builtin].enabled` includes `workspace.directory_stats`.
Returns bounded directory-level shape statistics grouped by the first child
under a workspace-contained path. It counts files, directories, symlinks, total
file bytes, and common workspace file categories using metadata only. It does
not read file contents, infer architecture, or run tools. Heavy dependency and
build artifact directories such as `node_modules`, `.build`, `vendor`, and
virtual environments are counted as skipped subtrees by default rather than
recursed into.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 4,
  "max_results": 100,
  "max_scan_entries": 20000
}
```

Returned group rows include `workspace_relative_path`, `name`, `file_count`,
`directory_count`, `symlink_count`, `total_size_bytes`, category counts such as
`source_file_count` and `dependency_file_count`, and `skipped_subtree_count`.

## `workspace.artifact_directories`

Available only when `[builtin].enabled` includes
`workspace.artifact_directories`. Returns a bounded metadata-only list of common
generated, build output, cache, dependency install, coverage, and temporary
directories under a workspace-contained path. It does not read directory
contents, run cleanup commands, run Git, or delete anything.

Arguments:

```json
{
  "path": ".",
  "include_hidden": true,
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned directory rows include `workspace_relative_path`, `name`, `category`,
`kind`, `cleanup_risk`, filesystem metadata, and follow-up contexts for
`file.stat`, `file.disk_usage`, `file.tree`, and `workspace.directory_stats`.
Matched directories are returned as single rows and their descendants are not
recursed into.

## `workspace.empty_directories`

Available only when `[builtin].enabled` includes `workspace.empty_directories`.
Returns a bounded list of actually empty directories under a
workspace-contained path using filesystem metadata only. A directory containing
hidden entries is not treated as empty. `include_hidden` controls whether hidden
directories are traversed and returned. This tool does not delete directories,
run cleanup commands, or follow symlinks as directories.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned directory rows include `workspace_relative_path`, `name`, `depth`,
`is_root`, `child_count`, `modified_at`, and follow-up context for an explicit
`workspace.reveal` call.

## `workspace.git_changes`

Available only when `[builtin].enabled` includes `workspace.git_changes` and a
CLI provider with `id = "git"` is registered. Returns structured
workspace-relative Git working tree change entries from fixed
`git status --porcelain=v1 -z --untracked-files=all` output. It does not read
file contents, run `git diff`, or infer tasks.

Arguments:

```json
{
  "paths": ["Sources"],
  "max_results": 200,
  "timeout_ms": 30000
}
```

Returned change rows include `status`, `index_status`, `worktree_status`,
`workspace_relative_path`, and `original_path` for rename/copy entries. The
payload also includes the exact `argv`, `status_counts`, a `status_legend`,
truncation flags, and command exit/stderr metadata.

## `workspace.file_types`

Available only when `[builtin].enabled` includes `workspace.file_types`.
Returns a bounded extension histogram for regular files under the configured
workspace using filesystem metadata only. It reports extension labels, file
counts, and summed byte sizes. It does not read file contents, run Git, or infer
project semantics.

Arguments:

```json
{
  "include_hidden": false,
  "max_groups": 50,
  "max_scan_entries": 10000
}
```

## `workspace.large_files`

Available only when `[builtin].enabled` includes `workspace.large_files`.
Returns a bounded list of the largest regular files under the configured
workspace using filesystem metadata only. It sorts by byte size descending and
then by workspace-relative path for ties. It does not read file contents, delete
files, or run cleanup commands.

Arguments:

```json
{
  "include_hidden": false,
  "max_results": 25,
  "max_scan_entries": 10000
}
```

## `workspace.symlinks`

Available only when `[builtin].enabled` includes `workspace.symlinks`.
Returns a bounded list of symbolic links under the configured workspace. It
reports each link path, raw destination, resolved target path, whether the
target exists, and whether the target remains workspace-contained. It does not
read target contents or follow links for execution.

Arguments:

```json
{
  "include_hidden": false,
  "max_results": 100,
  "max_scan_entries": 10000
}
```

## `workspace.executable_files`

Available only when `[builtin].enabled` includes `workspace.executable_files`.
Returns a bounded list of regular files under the configured workspace with the
executable bit set, using filesystem metadata only. It sorts by
workspace-relative path. It does not read file contents, infer script language,
or execute files.

Arguments:

```json
{
  "include_hidden": false,
  "max_results": 100,
  "max_scan_entries": 10000
}
```

## `workspace.todos`

Available only when `[builtin].enabled` includes `workspace.todos`. Searches
UTF-8 files under a workspace-contained file or directory for common TODO-style
markers. Defaults to `TODO`, `FIXME`, `HACK`, and `XXX`, with case-insensitive
token matching. Marker tokens are bounded by non-word characters so ordinary
words like `todos` are not returned as `TODO`. It returns mechanical line
matches; it does not summarize, infer priority, or execute commands.

Arguments:

```json
{
  "path": ".",
  "markers": ["TODO", "FIXME", "HACK", "XXX"],
  "case_sensitive": false,
  "include_hidden": false,
  "max_depth": 8,
  "max_files": 500,
  "max_matches": 100,
  "max_bytes_per_file": 1048576
}
```

## `workspace.env_files`

Available only when `[builtin].enabled` includes `workspace.env_files`. Finds
workspace env files such as `.env`, `.env.local`, and `example.env`, then returns
only variable key metadata. Values are always redacted and never returned. By
default the scan includes env files in visible directories and skips hidden
directories such as `.git`.

Arguments:

```json
{
  "path": ".",
  "include_hidden_directories": false,
  "max_depth": 6,
  "max_files": 100,
  "max_keys_per_file": 200,
  "max_bytes_per_file": 262144,
  "max_scan_entries": 20000
}
```

## `workspace.dependency_files`

Available only when `[builtin].enabled` includes `workspace.dependency_files`.
Finds common package manifest, requirements, lock, and checksum files under a
workspace-contained path. It uses filename metadata only and does not read file
contents, parse dependency names, infer install plans, or run package managers.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 6,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `ecosystem`,
`role`, `type`, `size_bytes`, `modified_at`, `is_symlink`, `xml_readable`, and
`xml_context`. XML dependency manifests such as `pom.xml` return
`xml_context.tool = "xml.read"`.

## `workspace.project_roots`

Available only when `[builtin].enabled` includes `workspace.project_roots`.
Groups common dependency manifest, lock, requirements, and checksum files by
containing directory to find candidate project roots using filename metadata
only. It does not read manifests, infer build graphs, choose a primary project,
or run package managers.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 6,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned candidate rows include `workspace_relative_path`, `ecosystems`,
`manifest_files`, `lock_files`, `checksum_files`, `dependency_file_count`,
`dependency_files`, and `is_workspace_root`.

## `workspace.documentation_files`

Available only when `[builtin].enabled` includes `workspace.documentation_files`.
Finds README, AGENTS, CONTRIBUTING, SECURITY, SUPPORT, changelog, license, and
docs-directory documentation files under a workspace-contained path. It uses
filename and path metadata only and does not read contents, summarize documents,
or infer policy.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 6,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `category`,
`source`, `type`, `size_bytes`, `modified_at`, and `is_symlink`. Markdown rows
also include `markdown_links_context` and `markdown_link_check_context` for
explicit follow-up inspection through `markdown.links` and
`markdown.link_check`.

## `workspace.agent_files`

Available only when `[builtin].enabled` includes `workspace.agent_files`.
Finds workspace agent instruction and skill entrypoint files such as
`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`,
`.github/copilot-instructions.md`, Cursor/Windsurf rules, and
`skills/*/SKILL.md` using path metadata only. It does not read instruction
contents or infer policy.

Arguments:

```json
{
  "path": ".",
  "include_hidden": true,
  "max_depth": 8,
  "max_results": 100,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `kind`, `source`,
`scope_workspace_relative_path`, `type`, `size_bytes`, `modified_at`,
`is_symlink`, and `read_context`. Use `read_context.tool = "file.read"` and the
returned path to read selected files through the gateway.

## `workspace.instructions`

Available only when `[builtin].enabled` includes `workspace.instructions`.
Returns the bounded agent instruction files that apply to one target
workspace-contained path. It walks from the workspace root to the target path's
scope directory and checks fixed instruction filenames plus Cursor/Windsurf rule
directories at each level. It does not recursively scan the full workspace,
summarize instructions, merge rules, or infer policy.

Arguments:

```json
{
  "path": "Sources/App/File.swift",
  "path_is_directory": false,
  "include_content": true,
  "max_bytes_per_file": 65536,
  "max_results": 50
}
```

`path` may point at a file, a directory, or a future path that does not exist
yet. When `path_is_directory` is omitted, existing paths use filesystem metadata;
nonexistent paths are treated as files unless the path ends in `/`.

Returned file rows include `workspace_relative_path`, `kind`, `source`,
`scope_workspace_relative_path`, `apply_order`, file metadata,
`content_included`, bounded `content`, `content_bytes_read`,
`content_truncated`, `valid_utf8`, and `read_context`. `apply_order` is root to
leaf; closer directory instructions have larger values.

## `workspace.test_files`

Available only when `[builtin].enabled` includes `workspace.test_files`. Finds
likely test/spec files under a workspace-contained path using path and filename
metadata only. It does not read file contents, infer test frameworks, or run
tests.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `language`,
`match_source`, `style`, `type`, `size_bytes`, `modified_at`, and `is_symlink`.

## `workspace.ci_files`

Available only when `[builtin].enabled` includes `workspace.ci_files`. Finds
common CI/CD and hosted build pipeline configuration files under a
workspace-contained path using path and filename metadata only. It does not
read YAML or JSON contents, infer pipeline semantics, or run automation.

Arguments:

```json
{
  "path": ".",
  "include_hidden": true,
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `provider`,
`category`, `match_source`, `type`, `size_bytes`, `modified_at`, and
`is_symlink`.

## `workspace.infra_files`

Available only when `[builtin].enabled` includes `workspace.infra_files`. Finds
likely infrastructure, deployment, container, orchestration, and platform
configuration files such as Dockerfile, docker-compose, devcontainer,
Kubernetes manifests, Helm charts, Terraform, Packer, Nomad, Pulumi,
Serverless, Cloudflare Wrangler, Vercel, Netlify, Fly, Render, Railway, and
Procfile under a workspace-contained path using filename, extension, and
infra-directory metadata only. It does not read config contents, parse IaC,
infer topology, validate manifests, or run deployment tools.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

`include_hidden` defaults to false, but `.devcontainer` is scanned because it is
a common project infrastructure directory.

Returned file rows include `workspace_relative_path`, `name`, `extension`,
`category`, `provider`, `kind`, `format`, `match_source`, `json_readable`,
`toml_readable`, `yaml_readable`, `xml_readable`, `type`, `size_bytes`, `modified_at`,
`is_symlink`, `read_lines_context`, `stat_context`, `metadata_context`,
`json_context`, `toml_context`, `yaml_context`, and `xml_context`. Use the context objects for
explicit follow-up inspection through `file.read_lines`, `json.read`,
`toml.read`, `yaml.read`, `xml.read`, `file.stat`, or
`file.metadata`.

## `workspace.config_files`

Available only when `[builtin].enabled` includes `workspace.config_files`.
Finds common editor, formatter, linter, toolchain, and build-tool configuration
files under a workspace-contained path using path and filename metadata only.
It does not read config contents, infer rules, or run tools.

Arguments:

```json
{
  "path": ".",
  "include_hidden": true,
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `tool`,
`category`, `match_source`, `type`, `size_bytes`, `modified_at`, and
`is_symlink`.

## `workspace.ignore_files`

Available only when `[builtin].enabled` includes `workspace.ignore_files`.
Finds common ignore-rule files such as `.gitignore`, `.dockerignore`,
`.rgignore`, `.prettierignore`, deployment ignore files, and agent context
ignore files under a workspace-contained path using path metadata only. It does
not parse ignore rules, decide whether a path is ignored, or read file
contents. Use `git.ignored` when you need Git to check explicit paths against
Git ignore rules.

Arguments:

```json
{
  "path": ".",
  "include_hidden": true,
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `provider`,
`category`, `match_source`, `type`, `size_bytes`, `modified_at`, `is_symlink`,
and `read_context`. Use `read_context.tool = "file.read"` and the returned path
to read selected ignore files through the gateway.

## `workspace.asset_files`

Available only when `[builtin].enabled` includes `workspace.asset_files`.
Finds common project asset files such as images, icons, fonts, audio, video,
PDFs, presentations, and design-source files under a workspace-contained path
using extension and path metadata only. It does not read asset contents,
generate previews, inspect dimensions, extract metadata, or infer where assets
are used. Image rows include a follow-up `image.info` context for explicit
metadata inspection. PDF rows include a follow-up `pdf.info` context for
explicit page and document metadata inspection. Audio and video rows include a
follow-up `media.info` context for explicit AVFoundation metadata inspection.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 500,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `extension`,
`category`, `subtype`, `type`, `size_bytes`, `modified_at`, `is_symlink`,
`stat_context`, `metadata_context`, and, for selected formats,
`image_info_context`, `pdf_info_context`, or `media_info_context`. Use the
context objects to inspect a selected asset through `file.stat`,
`file.metadata`, `image.info`, `pdf.info`, or `media.info`.

## `workspace.archive_files`

Available only when `[builtin].enabled` includes `workspace.archive_files`.
Finds common archive, compressed stream, installer, disk image, and application
package files under a workspace-contained path using extension and path metadata
only. It does not list archive entries, extract files, inspect package manifests,
or read contents.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 500,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `extension`,
`category`, `format`, `list_supported`, `type`, `size_bytes`, `modified_at`,
`is_symlink`, `stat_context`, `metadata_context`, `list_context`, and
`read_file_context`. `list_context` and `read_file_context` are present only
for formats supported by `archive.list` and `archive.read_file`, such as zip,
jar, war, ear, and tar-family archives. `read_file_context.entry` is `null`
until the MCP consumer selects a concrete member from `archive.list`.

## `workspace.log_files`

Available only when `[builtin].enabled` includes `workspace.log_files`. Finds
likely log, process output, trace, and crash-report files under a
workspace-contained path using filename, extension, rotated suffix, and
`logs`-directory metadata only. It does not read log contents, infer severity,
summarize events, or follow live streams.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 500,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `extension`,
`category`, `kind`, `match_source`, `type`, `size_bytes`, `modified_at`,
`is_symlink`, `tail_context`, `search_context`, and `stat_context`. Use
`tail_context.tool = "file.tail"` for explicit bounded tail reads, or
`search_context.tool = "file.search"` with a query for explicit content search.

## `workspace.data_files`

Available only when `[builtin].enabled` includes `workspace.data_files`. Finds
common data artifacts such as CSV, TSV, JSONL, SQLite, DuckDB, Parquet, Arrow,
Avro, ORC, Excel, and structured files in data-like directories under a
workspace-contained path using extension and path metadata only. It does not
read data contents, infer schemas, count rows, sample values, or inspect
databases.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 500,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `extension`,
`category`, `format`, `match_source`, `text_readable`, `json_readable`,
`jsonl_readable`, `yaml_readable`, `xml_readable`, `type`, `size_bytes`, `modified_at`, `is_symlink`,
`stat_context`, `metadata_context`, `read_lines_context`, `tail_context`,
`count_context`, `json_context`, `jsonl_context`, `yaml_context`, and `xml_context`.
Text-readable data files return explicit `file.read_lines`, `file.tail`, and
`file.count` contexts. JSON files return `json_context.tool = "json.read"` only
when they are found inside a data-like directory. JSONL/NDJSON files return
`jsonl_context.tool = "jsonl.read"`. YAML files return
`yaml_context.tool = "yaml.read"`. XML files return
`xml_context.tool = "xml.read"`.

## `workspace.schema_files`

Available only when `[builtin].enabled` includes `workspace.schema_files`.
Finds likely API, interface, data, and database schema/contract files such as
OpenAPI, Swagger, AsyncAPI, GraphQL, Protocol Buffers, JSON Schema, Avro schema,
Prisma, WSDL, XSD, Thrift, FlatBuffers, and SQL migrations under a
workspace-contained path using filename, extension, and schema-directory
metadata only. It does not read schema contents, validate contracts, infer
models, generate clients, or inspect databases.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 500,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `extension`,
`category`, `schema_kind`, `format`, `match_source`, `json_readable`,
`yaml_readable`, `xml_readable`, `type`, `size_bytes`, `modified_at`, `is_symlink`,
`read_lines_context`, `stat_context`, `metadata_context`, `json_context`,
`yaml_context`, and `xml_context`. Use `read_lines_context` for explicit bounded inspection
through `file.read_lines`; JSON-readable schema files also return
`json_context.tool = "json.read"` and YAML schema files return
`yaml_context.tool = "yaml.read"`. XML schema files such as XSD and WSDL return
`xml_context.tool = "xml.read"`.

## `workspace.source_files`

Available only when `[builtin].enabled` includes `workspace.source_files`.
Finds likely source, script, component, markup, style, header, and query files
under a workspace-contained path using file extension and path metadata only.
It does not read source contents, infer architecture, or run tools. Files that
also match `workspace.test_files` are excluded by default.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "include_tests": false,
  "max_depth": 8,
  "max_results": 500,
  "max_scan_entries": 20000
}
```

Returned file rows include `workspace_relative_path`, `name`, `language`,
`kind`, `match_source`, `type`, `size_bytes`, `modified_at`, and `is_symlink`.

## `workspace.outline`

Available only when `[builtin].enabled` includes `workspace.outline`. Returns a
bounded mechanical outline across outline-capable workspace files by extracting
Markdown headings and common source declarations. It reads bounded UTF-8
windows from candidate files and does not summarize, infer architecture, build
a semantic graph, or run tools.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "include_tests": false,
  "include_imports": false,
  "max_depth": 8,
  "max_files": 200,
  "max_items": 1000,
  "max_bytes_per_file": 262144,
  "max_scan_entries": 20000
}
```

Returned outline rows include `workspace_relative_path`, `language`, `line`,
`kind`, `level`, `name`, raw outline `text`, and follow-up contexts for
`file.read_context` and `file.outline`. Build/cache/vendor directories are
skipped by default through the same source-file traversal boundary.

## `workspace.commands`

Available only when `[builtin].enabled` includes `workspace.commands`.
Finds deterministic project command entrypoints from common manifests such as
`package.json` scripts, `Makefile` targets, `Justfile` recipes, and standard
SwiftPM, Cargo, and Go project commands. It reads only bounded manifest bytes,
does not execute commands, and returns `cli.exec` context plus whether the
suggested CLI provider is registered.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 4,
  "max_results": 200,
  "max_scan_entries": 20000,
  "max_bytes_per_file": 262144
}
```

Returned command rows include `source_workspace_relative_path`,
`cwd_workspace_relative_path`, `ecosystem`, `kind`, `name`, `definition`,
`definition_source`, `executor_tool`, `suggested_cli_id`,
`registered_cli_provider`, `required_executable`, `argv`, and
`file_truncated`. For nested manifests, callers must respect
`cwd_workspace_relative_path`; `cli.exec` itself still uses the registered
provider working directory.

## `workspace.governance_files`

Available only when `[builtin].enabled` includes `workspace.governance_files`.
Finds workspace governance and collaboration entrypoints such as
`_ops/bin/workspace`, `refs.yaml`, `refs.lock.yaml`, `references/upstreams`,
`references/forks`, workspace skill instructions, `AGENTS.md`, and `CODEOWNERS`
using path and filename metadata only. It does not execute the workspace CLI,
mutate refs, parse governance files, inspect Git internals, or infer policy.

Arguments:

```json
{
  "path": ".",
  "include_hidden": true,
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

Returned rows include `workspace_relative_path`, `category`, `provider`,
`kind`, `format`, `match_source`, `type`, `yaml_readable`, `xml_readable`, `size_bytes`,
`modified_at`, file-only `is_executable`, `is_symlink`, `stat_context`,
`metadata_context`, and for file entries `read_lines_context`. JSON, TOML, and
YAML governance manifests also include `json_context`, `toml_context`, or
`yaml_context`; XML governance manifests include `xml_context`.

## `system.info`

Available only when `[builtin].enabled` includes `system.info`. Returns a
non-secret macOS and current gateway process summary. It does not return the
process environment.

Arguments:

```json
{}
```

## `system.kernel`

Available only when `[builtin].enabled` includes `system.kernel`. Returns
read-only macOS kernel and machine identity from `uname`, plus OS version and
processor counts from `ProcessInfo`. It does not execute a subprocess.

Arguments:

```json
{}
```

## `system.software`

Available only when `[builtin].enabled` includes `system.software`. Returns
read-only macOS product name, product version, and build version using fixed
`/usr/bin/sw_vers` argv, plus `ProcessInfo` version fields. It does not
execute a shell command.

Arguments:

```json
{
  "timeout_ms": 10000
}
```

## `system.locale`

Available only when `[builtin].enabled` includes `system.locale`. Returns
read-only current locale, preferred languages, calendar, and time-zone summary
from Foundation. It does not execute a subprocess.

Arguments:

```json
{}
```

## `system.memory`

Available only when `[builtin].enabled` includes `system.memory`. Returns
read-only macOS virtual-memory page counters and memory event counters using
`host_statistics64`. It does not inspect individual processes and does not
execute a subprocess.

Arguments:

```json
{}
```

## `system.load`

Available only when `[builtin].enabled` includes `system.load`. Returns
read-only macOS 1, 5, and 15 minute load averages using `getloadavg`, plus the
same values normalized by active processor count. It does not inspect
individual processes and does not execute a subprocess.

Arguments:

```json
{}
```

## `system.cpu`

Available only when `[builtin].enabled` includes `system.cpu`. Returns
read-only CPU counts, machine/model identifiers, optional CPU brand/frequency
fields, and architecture support flags from `ProcessInfo`, `sysctlbyname`, and
`uname`. Fields unavailable on a given Mac are returned as `null`. It does not
inspect processes and does not execute a subprocess.

Arguments:

```json
{}
```

## `system.thermal`

Available only when `[builtin].enabled` includes `system.thermal`. Returns
read-only thermal state, a mechanical thermal-state rank, low-power-mode status,
and processor counts from `ProcessInfo`. It does not inspect processes, read
files, execute subprocesses, or interpret the state.

Arguments:

```json
{}
```

## `system.time`

Available only when `[builtin].enabled` includes `system.time`. Returns the
current local time, Unix timestamp, current time zone, and system uptime. It is
read-only and does not execute a subprocess.

Arguments:

```json
{}
```

## `system.uptime`

Available only when `[builtin].enabled` includes `system.uptime`. Returns
read-only system uptime and a derived boot-time snapshot from
`ProcessInfo.systemUptime` and `Date`. It does not inspect processes, read
files, or execute subprocesses.

Arguments:

```json
{}
```

## `system.user`

Available only when `[builtin].enabled` includes `system.user`. Returns
read-only POSIX identity for the current gateway process: real/effective user
and group ids, passwd entry fields for those users, and group names for those
groups. It does not enumerate all users and does not execute subprocesses.

Arguments:

```json
{}
```

## `system.groups`

Available only when `[builtin].enabled` includes `system.groups`. Returns
read-only supplementary POSIX groups for the current gateway process, plus the
real and effective primary group ids. It resolves only those group ids through
`getgrgid`; it does not enumerate all groups and does not execute subprocesses.

Arguments:

```json
{}
```

## `system.power`

Available only when `[builtin].enabled` includes `system.power`. Runs the fixed
read-only command `/usr/bin/pmset -g batt` and returns the raw command result
with stdout, stderr, exit code, timeout, and truncation metadata.

Arguments:

```json
{
  "timeout_ms": 10000
}
```

## `system.volumes`

Available only when `[builtin].enabled` includes `system.volumes`. Lists mounted
macOS volumes with non-secret mount and capacity metadata. Hidden volumes are
skipped by default.

Arguments:

```json
{
  "include_hidden": false
}
```

## `system.processes`

Available only when `[builtin].enabled` includes `system.processes`. Runs fixed
`/bin/ps` argv and returns a bounded read-only process snapshot. It reports
process ids, parent ids, user, state, CPU/memory percentages, elapsed time, and
the executable command field; it does not request full argument strings or
environment variables. This tool is not enabled in the ChatGPT tunnel sample
profile by default because process names can reveal local activity.

Arguments:

```json
{
  "query": "Terminal",
  "max_results": 200,
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `system.which`

Available only when `[builtin].enabled` includes `system.which`. Locates an
executable basename on the gateway process `PATH` without running a shell and
without invoking the executable. The response includes whether it was found, the
first resolved path, optional all-match paths, and the number of PATH entries
searched; it does not return the full environment.

Arguments:

```json
{
  "name": "cloudflared",
  "all_matches": false
}
```

## `system.path`

Available only when `[builtin].enabled` includes `system.path`. Returns
structured gateway process `PATH` search directories without running a shell and
without returning other environment values. Each entry includes the original
path, standardized path, existence, directory/read/write/execute flags, and
duplicate information.

Arguments:

```json
{
  "include_missing": true,
  "max_entries": 200
}
```

## `logs.query`

Available only when `[builtin].enabled` includes `logs.query`. Queries a
bounded recent window of the macOS unified log with fixed
`/usr/bin/log show --style ndjson` argv. Both `last_seconds` and `max_entries`
are required; the tool does not start a live stream or invoke a shell.

The response separates decoded NDJSON `events` from `unparsed_lines` and
includes observed, returned, omitted, timeout, and truncation metadata. Unified
logs can contain sensitive local activity, so this tool belongs only in an
explicitly trusted profile and is not enabled by the ChatGPT tunnel or no-auth
examples.

Arguments:

```json
{
  "last_seconds": 300,
  "max_entries": 100,
  "predicate": "process == \"computer-mcp\"",
  "include_info": true,
  "include_debug": false,
  "timeout_ms": 30000,
  "max_output_bytes": 1048576
}
```

`last_seconds` is limited to 604800, `max_entries` to 10000, and `predicate`
to 4096 UTF-8 bytes. The predicate is passed as one argv value and is not shell
interpolated.

## `service.status`

Available only when `[builtin].enabled` includes `service.status`. Inspects one
macOS launchd service with fixed `/bin/launchctl print` argv. `domain` must be
`system`, `user`, or `gui`; user and GUI targets are always restricted to the
current gateway user id. `label` accepts only letters, digits, dots,
underscores, and hyphens.

The response reports `found` and an allowlisted set of status fields such as
state, pid, run count, program, and path. It intentionally omits raw launchctl
stdout and environment blocks. This slice is read-only and provides no
start/stop/enable/disable operation. It is available in the full local example,
not the ChatGPT tunnel or no-auth examples.

Arguments:

```json
{
  "domain": "gui",
  "label": "com.apple.Finder",
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `network.interfaces`

Available only when `[builtin].enabled` includes `network.interfaces`. Runs
`/sbin/ifconfig` with fixed argv and returns the raw command result. Pass
`interface` to inspect one interface, or omit it to run `ifconfig -a`.
Interface names are validated as names, not arbitrary options.

Arguments:

```json
{
  "interface": "lo0",
  "timeout_ms": 10000
}
```

## `network.dns`

Available only when `[builtin].enabled` includes `network.dns`. Runs the fixed
read-only command `/usr/sbin/scutil --dns` and returns the raw command result
with stdout, stderr, exit code, timeout, and truncation metadata.

Arguments:

```json
{
  "timeout_ms": 10000
}
```

## `network.resolve`

Available only when `[builtin].enabled` includes `network.resolve`. Resolves a
hostname or IP address through the system resolver using `getaddrinfo` and
returns numeric addresses. It does not run shell commands. Unresolved hosts are
returned as a normal result with `resolved: false`, `error_code`, and `error`
instead of an MCP protocol error.

Arguments:

```json
{
  "host": "localhost",
  "family": "any",
  "max_results": 50
}
```

`family` may be `any`, `all`, `ipv4`, `inet`, `ipv6`, or `inet6`.

## `network.proxy`

Available only when `[builtin].enabled` includes `network.proxy`. Runs the fixed
read-only command `/usr/sbin/scutil --proxy` and returns the raw command result
with stdout, stderr, exit code, timeout, and truncation metadata. This reads the
current macOS proxy configuration; it does not make outbound network requests.

Arguments:

```json
{
  "timeout_ms": 10000
}
```

## `network.services`

Available only when `[builtin].enabled` includes `network.services`. Runs fixed
read-only `/usr/sbin/networksetup -listallnetworkservices` argv and returns the
raw command result with stdout, stderr, exit code, timeout, and truncation
metadata. This reads local macOS network service names and disabled markers; it
does not make outbound network requests.

Arguments:

```json
{
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `network.hardware_ports`

Available only when `[builtin].enabled` includes `network.hardware_ports`. Runs
fixed read-only `/usr/sbin/networksetup -listallhardwareports` argv and returns
the raw command result with stdout, stderr, exit code, timeout, and truncation
metadata. This reads local macOS hardware port mappings and can include device
names and Ethernet addresses, so keep it out of public or anonymous profiles
unless that behavior is intentional.

Arguments:

```json
{
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `network.wifi`

Available only when `[builtin].enabled` includes `network.wifi`. Uses fixed
read-only `/usr/sbin/networksetup` argv to discover or accept a Wi-Fi interface
device, then reads power state and current network association. It does not
scan nearby networks, join networks, change settings, make outbound network
requests, or expose full hardware-port raw output.

Arguments:

```json
{
  "device": "en0",
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

Returned fields include `available`, `device`, `hardware_port`, `power`,
`associated`, `ssid`, fixed argv arrays, and bounded command summaries for
discovery, power, and current-network reads.

## `network.vpn`

Available only when `[builtin].enabled` includes `network.vpn`. Runs fixed
read-only `/usr/sbin/scutil --nc list` argv and parses macOS Network
Connection/VPN services into structured rows. It does not start, stop, select,
trigger, enable, disable, or show detailed VPN configuration.

Arguments:

```json
{
  "max_results": 100,
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

Returned service rows include `enabled`, `status`, `connected`, `id`, `name`,
`protocol`, `type`, and `description`. The command summary intentionally omits
raw stdout.

## `network.locations`

Available only when `[builtin].enabled` includes `network.locations`. Runs
fixed read-only `/usr/sbin/networksetup -getcurrentlocation` and
`/usr/sbin/networksetup -listlocations` argv and returns both raw command
results with stdout, stderr, exit code, timeout, and truncation metadata. This
reads local macOS network location names and does not make outbound network
requests; keep it out of public or anonymous profiles unless that behavior is
intentional.

Arguments:

```json
{
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `network.routes`

Available only when `[builtin].enabled` includes `network.routes`. Runs fixed
read-only `/usr/sbin/netstat -rn` argv and returns the raw command result with
stdout, stderr, exit code, timeout, and truncation metadata. This reads the
local routing table; it does not make outbound network requests.

Arguments:

```json
{
  "family": "all",
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

`family` may be `all`, `inet`, or `inet6`.

## `network.connections`

Available only when `[builtin].enabled` includes `network.connections`. Runs
fixed read-only `/usr/sbin/netstat -an` argv and returns the raw command result
with stdout, stderr, exit code, timeout, and truncation metadata. This reads the
local connection table and can reveal local and remote endpoints, so keep it out
of public or anonymous profiles unless that behavior is intentional.

Arguments:

```json
{
  "family": "all",
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

`family` may be `all`, `inet`, or `inet6`.

## `network.arp`

Available only when `[builtin].enabled` includes `network.arp`. Runs fixed
read-only `/usr/sbin/arp -an` argv and returns the raw command result with
stdout, stderr, exit code, timeout, and truncation metadata. This reads the
local IPv4 ARP neighbor cache and can reveal local network devices, so keep it
out of public or anonymous profiles unless that behavior is intentional.

Arguments:

```json
{
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `network.ping`

Available only when `[builtin].enabled` includes `network.ping`. Runs bounded
`/sbin/ping -c <count> <host>` argv and returns the raw command result with
stdout, stderr, exit code, timeout, and truncation metadata. This performs ICMP
network I/O, so keep it out of public or anonymous profiles unless that
behavior is intentional.

Arguments:

```json
{
  "host": "127.0.0.1",
  "count": 3,
  "timeout_ms": 30000,
  "max_output_bytes": 1048576
}
```

## `network.tcp_check`

Available only when `[builtin].enabled` includes `network.tcp_check`. Runs fixed
`/usr/bin/nc -G <seconds> -zv <host> <port>` argv and returns the raw command
result with stdout, stderr, exit code, timeout, and truncation metadata. This
performs TCP network I/O to a caller-provided host, so keep it out of public or
anonymous profiles unless that behavior is intentional.

Arguments:

```json
{
  "host": "127.0.0.1",
  "port": 443,
  "connect_timeout_seconds": 5,
  "timeout_ms": 30000,
  "max_output_bytes": 1048576
}
```

## `network.http_check`

Available only when `[builtin].enabled` includes `network.http_check`. Runs
fixed `/usr/bin/curl` argv against one absolute `http` or `https` URL. It
supports `HEAD` and `GET`, returns curl metadata such as HTTP status, effective
URL, content type, redirect URL, transfer time, downloaded byte count, exit
code, stderr, timeout, and truncation flags, and can optionally return a bounded
GET body prefix. It does not send custom headers, request bodies, cookies, or
shell commands.

This performs outbound HTTP network I/O, so keep it out of public or anonymous
profiles unless that behavior is intentional. The full local sample enables it;
the ChatGPT tunnel, no-auth, and local-provider bridge samples do not.

Arguments:

```json
{
  "url": "http://127.0.0.1:8080/mcp",
  "method": "HEAD",
  "include_body": false,
  "follow_redirects": false,
  "max_redirects": 5,
  "connect_timeout_seconds": 5,
  "timeout_ms": 30000,
  "max_body_bytes": 4096,
  "max_output_bytes": 20480
}
```

Returned fields include `http_code`, `url_effective`, `content_type`,
`redirect_url`, `time_total_seconds`, `size_download_bytes`, optional bounded
`body`, `body_truncated`, `meta_found`, and the fixed curl `argv`.

## `network.listeners`

Available only when `[builtin].enabled` includes `network.listeners`. Runs fixed
`/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN` argv and returns the raw command result
with stdout, stderr, exit code, timeout, and truncation metadata. This does not
make outbound network requests, but it can reveal local process names and
listening ports, so keep it out of public or anonymous profiles unless that
behavior is intentional.

Arguments:

```json
{
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `macos.user_directories`

Available only when `[builtin].enabled` includes `macos.user_directories`.
Returns a fixed read-only catalog of common macOS user and application
directories such as Home, Desktop, Documents, Downloads, Movies, Music,
Pictures, user Library, user Applications, `/Applications`,
`/System/Applications`, and the current process temporary directory. It reports
existence and filesystem metadata only; it does not list directory contents,
read files, open Finder, or run shell commands.

Arguments:

```json
{
  "include_missing": true,
  "include_system": true,
  "include_temporary": true
}
```

Returned rows include `id`, `category`, `description`, `path`, `exists`,
`type`, `size_bytes`, `created_at`, `modified_at`, `is_readable`,
`is_writable`, `is_traversable`, `is_symlink`, and `symlink_destination`.

## `macos.default_application`

Available only when `[builtin].enabled` includes
`macos.default_application`. Returns the default macOS application, and
optionally candidate applications, that LaunchServices would use for either an
existing workspace-contained file path or an `http`, `https`, or `mailto` URL.
It is read-only: it does not open files, launch applications, make network
requests, or inspect UI content.

Provide exactly one target:

```json
{
  "path": "README.md",
  "url": "https://example.com",
  "include_candidates": false,
  "max_candidates": 20
}
```

For `path`, the file or directory must exist and remain inside the configured
workspace. For `url`, only `http`, `https`, and `mailto` schemes are accepted.
The result includes `target`, `default_application_available`,
`default_application`, `candidate_count`, `candidate_applications`, and
`truncated`.

## `macos.applications`

Available only when `[builtin].enabled` includes `macos.applications`. Lists
installed application bundles from standard macOS Applications directories. It
does not inspect windows, UI state, or the process table.

Arguments:

```json
{
  "include_system": true,
  "include_user": true,
  "max_results": 500,
  "max_depth": 3,
  "max_visited": 20000
}
```

## `macos.screens`

Available only when `[builtin].enabled` includes `macos.screens`. Lists
attached macOS screens with frame, visible frame, backing scale, color-space,
and device metadata. It is read-only and does not capture pixels.

Arguments:

```json
{}
```

## `macos.spotlight_search`

Available only when `[builtin].enabled` includes `macos.spotlight_search`.
Runs `/usr/bin/mdfind -onlyin` against a workspace-contained directory and
returns bounded, workspace-contained results. The `query` is the raw Spotlight
query string passed to `mdfind`; the gateway does not parse or optimize the
query language.

Arguments:

```json
{
  "path": ".",
  "query": "kMDItemFSName == '*.swift'",
  "max_results": 100,
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `macos.running_applications`

Available only when `[builtin].enabled` includes
`macos.running_applications`. Lists running applications visible to the current
user session. It is read-only and does not inspect windows, screen content, or
app-specific state.

Arguments:

```json
{
  "include_background": false,
  "query": "Safari",
  "match": "contains",
  "case_sensitive": false,
  "max_results": 200
}
```

## `macos.frontmost_application`

Available only when `[builtin].enabled` includes
`macos.frontmost_application`. Returns the current frontmost macOS application
reported by the user session. It is read-only.

Arguments:

```json
{}
```

## `env.describe`

Available only when `[builtin].enabled` includes `env.describe`. Reports
environment variable names declared by gateway configuration and whether those
names exist in the gateway process environment. Values are always redacted. It
does not dump the full environment.

Arguments:

```json
{}
```

## `file.exists`

Available only when `[builtin].enabled` includes `file.exists`. Checks whether
a workspace-contained path exists without treating absence as an error. Use
`file.stat` when metadata is needed.

Arguments:

```json
{
  "path": "Package.swift"
}
```

## `file.list`

Available only when `[builtin].enabled` includes `file.list`. Lists entries
under a workspace-contained directory with deterministic sorting and bounded
output. Dotfiles are hidden unless `include_hidden` is true.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "recursive_depth": 0,
  "max_entries": 200
}
```

## `file.tree`

Available only when `[builtin].enabled` includes `file.tree`. Returns a bounded
hierarchical JSON tree for a workspace-contained directory. It follows the same
containment, hidden-file, sorting, and symlink non-recursion rules as
`file.list`, but preserves parent/child structure for browsing.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "max_depth": 2,
  "max_entries": 500,
  "directories_only": false
}
```

## `file.stat`

Available only when `[builtin].enabled` includes `file.stat`. Returns file
metadata without reading content.

Arguments:

```json
{
  "path": "Package.swift"
}
```

## `file.permissions`

Available only when `[builtin].enabled` includes `file.permissions`. Returns
POSIX mode, owner/group ids and names when available, current-process
read/write/execute access, and common macOS file flags for a
workspace-contained path. It is read-only and does not change permissions.

Arguments:

```json
{
  "path": "script.sh"
}
```

## `file.chmod`

Available only when `[builtin].enabled` includes `file.chmod`. Sets the POSIX
mode for a workspace-contained path without invoking `/bin/chmod`. This is a
non-recursive write operation. Use `expected_current_mode` when the caller wants
to assert the old mode before changing it. Set `dry_run` to validate the mode
change and return `would_mode_after_octal` without changing permissions.

Arguments:

```json
{
  "path": "script.sh",
  "mode": "0755",
  "expected_current_mode": "0644",
  "dry_run": false
}
```

## `file.type`

Available only when `[builtin].enabled` includes `file.type`. Returns MIME type
and charset for a workspace-contained file using fixed `/usr/bin/file -b --mime`
argv. It is read-only and does not return file content.

Arguments:

```json
{
  "path": "Package.swift",
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `file.count`

Available only when `[builtin].enabled` includes `file.count`. Returns line,
word, and byte counts for a workspace-contained file using fixed
`/usr/bin/wc -l -w -c` argv. It is read-only and does not return file content.

Arguments:

```json
{
  "path": "README.md",
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `file.disk_usage`

Available only when `[builtin].enabled` includes `file.disk_usage`. Returns
disk usage for a workspace-contained file or directory using fixed
`/usr/bin/du -sk` argv. It is read-only and returns allocated disk usage, not a
semantic project-size estimate.

Arguments:

```json
{
  "path": ".",
  "timeout_ms": 30000,
  "max_output_bytes": 1048576
}
```

## `file.volume_info`

Available only when `[builtin].enabled` includes `file.volume_info`. Returns
the mounted volume and filesystem capability metadata for a workspace-contained
path using Foundation URL resource values. It is read-only, does not run shell
commands, and complements `file.disk_usage`: use it to check the volume, free
capacity, read-only state, and supported filesystem features for a path.

Arguments:

```json
{
  "path": "."
}
```

## `file.find`

Available only when `[builtin].enabled` includes `file.find`. Finds files or
directories by name under a workspace-contained directory. Matching is
deterministic string matching; no semantic search or command catalog inference
is performed.

Arguments:

```json
{
  "path": ".",
  "query": ".swift",
  "match": "suffix",
  "case_sensitive": false,
  "include_hidden": false,
  "max_depth": 8,
  "max_results": 200,
  "max_visited": 20000
}
```

`match` can be `contains`, `prefix`, `suffix`, or `exact`.

## `file.search`

Available only when `[builtin].enabled` includes `file.search`. Searches UTF-8
text content under a workspace-contained file or directory. Output is bounded by
file count, match count, and bytes per file.

Arguments:

```json
{
  "path": ".",
  "query": "GatewayToolRegistry",
  "case_sensitive": false,
  "include_hidden": false,
  "max_depth": 8,
  "max_files": 500,
  "max_matches": 100,
  "max_bytes_per_file": 1048576
}
```

## `file.timeline`

Available only when `[builtin].enabled` includes `file.timeline`. Lists regular
non-symlink files under a workspace-contained directory using filesystem
modification timestamps. It does not read file contents, run Git, infer
"recent" semantics, or parse natural-language dates.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "modified_after": "2026-07-09T00:00:00Z",
  "modified_before": "2026-07-10T00:00:00Z",
  "sort": "modified_desc",
  "max_depth": 8,
  "max_results": 200,
  "max_scan_entries": 20000
}
```

`modified_after` and `modified_before` are optional inclusive ISO8601 timestamp
bounds. `sort` is `modified_desc`, `modified_asc`, or `path`. Returned rows
include file metadata, follow-up read/stat/open/reveal contexts, and scan plus
result truncation flags.

## `file.read`

Available only when `[builtin].enabled` includes `file.read`. Reads a
workspace-contained file as UTF-8 text.

Arguments:

```json
{
  "path": "README.md",
  "max_bytes": 8192
}
```

## `file.read_files`

Available only when `[builtin].enabled` includes `file.read_files`. Reads
multiple explicitly named workspace-contained files in one call. This is a
batch form for known paths; it does not search, infer related files, follow
references, or walk directories. Use `file.find`, `file.search`, or
workspace inventory tools first when the paths are not known.

All files in one call use the same `encoding`, either `utf8` or `base64`.
Each file is capped independently by `max_bytes_per_file`; the response reports
per-file truncation plus aggregate byte and truncation counts. The call fails
deterministically if any path is missing, escapes the workspace, or is not a
regular file.

Arguments:

```json
{
  "paths": ["Package.swift", "README.md"],
  "encoding": "utf8",
  "max_bytes_per_file": 65536
}
```

## `file.read_window`

Available only when `[builtin].enabled` includes `file.read_window`. Reads a
bounded UTF-8 text byte window from a workspace-contained file. Use it when a
consumer already has a byte offset, for example after a previous
`file.read_window`, `file.hexdump`, or external offset-bearing diagnostic. This
tool does not search, infer structure, or treat the file as binary; use
`file.hexdump` for byte-level inspection.

Arguments:

```json
{
  "path": "logs/build.log",
  "offset_bytes": 1048576,
  "max_bytes": 65536
}
```

The payload includes `content`, `bytes_read`, `next_offset_bytes`, `eof`,
`truncated`, and `valid_utf8`. If `valid_utf8` is false, the decoded content may
contain replacement characters because the selected byte window splits a UTF-8
sequence or contains non-text bytes.

## `file.read_lines`

Available only when `[builtin].enabled` includes `file.read_lines`. Reads a
bounded one-based line range from a workspace-contained UTF-8 file. The tool
scans at most `max_bytes` from the start of the file and reports whether that
scan was truncated.

Arguments:

```json
{
  "path": "README.md",
  "start_line": 40,
  "max_lines": 80,
  "max_bytes": 1048576
}
```

## `file.read_context`

Available only when `[builtin].enabled` includes `file.read_context`. Reads a
bounded UTF-8 line window around a one-based target line from a
workspace-contained file. Use it after `file.search`, `git.grep`, compiler
diagnostics, or any result that already provides a line number. It does not
search for text, parse diagnostics, or infer semantics.

Arguments:

```json
{
  "path": "Sources/App.swift",
  "line": 120,
  "before": 5,
  "after": 5,
  "max_bytes": 1048576
}
```

Returned rows include `line`, `relative_line`, `is_target`, and `text`. The
payload also includes `start_line`, `end_line`, `target_line_returned`,
`file_truncated`, and `range_may_be_truncated` when the byte scan may not have
reached the requested line range.

## `file.head`

Available only when `[builtin].enabled` includes `file.head`. Reads the first
lines from a workspace-contained UTF-8 file using a bounded byte window. This
is the direct counterpart to `file.tail` for quick file orientation. When the
byte window ends in the middle of a line, the final returned line is flagged as
truncated.

Arguments:

```json
{
  "path": "README.md",
  "max_lines": 200,
  "max_bytes": 1048576
}
```

Returned line rows include `line`, `head_index`, `text`, and
`line_truncated`.

## `file.outline`

Available only when `[builtin].enabled` includes `file.outline`. Returns a
bounded mechanical outline for a workspace-contained UTF-8 file by extracting
Markdown headings and common source declaration lines. It does not summarize,
infer architecture, or build a semantic graph.

Arguments:

```json
{
  "path": "README.md",
  "include_imports": false,
  "max_results": 200,
  "max_bytes": 1048576
}
```

Returned items include `line`, `kind`, `level`, `name`, and raw `text`.
Supported markers are intentionally simple: Markdown headings, common source
declarations such as classes/functions/types/extensions, optional import-like
lines, and Makefile targets.

## `markdown.links`

Available only when `[builtin].enabled` includes `markdown.links`. Extracts a
bounded mechanical link inventory from a workspace-contained UTF-8 Markdown
file. It reports inline links, image links, reference-style links, reference
definitions, autolinks, local target path context, and truncation flags. It
does not follow links, fetch URLs, summarize documents, or infer document
semantics.

Arguments:

```json
{
  "path": "README.md",
  "include_images": true,
  "include_reference_definitions": true,
  "include_autolinks": true,
  "include_code_blocks": false,
  "max_links": 200,
  "max_bytes": 1048576
}
```

Returned links include `line`, `kind`, `label`, `reference_label`,
`destination`, `title`, raw source text, `is_image`, and a `target` object.
For relative or absolute local paths, `target` reports whether the destination
is workspace-contained and, when it is, the normalized
`target_workspace_relative_path` for follow-up `file.*` calls.

## `markdown.tables`

Available only when `[builtin].enabled` includes `markdown.tables`. Extracts
bounded GitHub-flavored pipe tables from a workspace-contained UTF-8 Markdown
file. A table is recognized mechanically as a header row followed immediately
by a delimiter row such as `| --- | ---: |`. Fenced code blocks are ignored by
default. The tool does not infer table semantics, summarize content, or execute
code blocks.

Arguments:

```json
{
  "path": "README.md",
  "include_code_blocks": false,
  "max_tables": 20,
  "max_rows_per_table": 100,
  "max_bytes": 1048576
}
```

Returned tables include `start_line`, `end_line`, `header_line`,
`delimiter_line`, `headers`, `alignments`, raw table text, `row_count`, and
bounded row data. Each row reports `raw_cells`, normalized `cells` padded or
truncated to the header column count, `missing_cell_count`, and `extra_cells`.
Escaped pipe characters such as `\\|` are treated as cell content.

## `markdown.section`

Available only when `[builtin].enabled` includes `markdown.section`. Extracts
one raw Markdown section by exact ATX heading text from a workspace-contained
UTF-8 Markdown file. Use `file.outline` first when the caller needs to discover
available heading text and line numbers. This tool does not search
semantically, summarize content, follow links, or parse arbitrary Markdown
blocks.

Arguments:

```json
{
  "path": "README.md",
  "heading": "Installation",
  "level": 2,
  "occurrence": 1,
  "include_heading": true,
  "max_bytes": 1048576,
  "max_section_bytes": 1048576
}
```

The section starts at the matched heading and ends before the next heading at
the same or higher level. Fenced code blocks are ignored when finding headings.
The result includes `matched`, `match_count`, `matched_heading`,
`following_heading`, line numbers, raw `content`, and truncation flags. Missing
headings return `matched = false` with `failure.reason = "missing_heading"`.

## `markdown.frontmatter`

Available only when `[builtin].enabled` includes `markdown.frontmatter`. Reads
leading YAML or TOML frontmatter from a workspace-contained UTF-8 Markdown file.
The opening delimiter must be the first line: exactly `---` for YAML or `+++`
for TOML. YAML closes with `---` or `...`; TOML closes with `+++`. The tool
does not infer skill semantics, summarize Markdown body content, or scan for
frontmatter later in the file.

Arguments:

```json
{
  "path": "SKILL.md",
  "format": "auto",
  "max_bytes": 1048576,
  "max_depth": 128
}
```

The result includes `found`, `format`, delimiter flags, raw frontmatter text,
line numbers, `body_start_line`, and a parsed `value` when the frontmatter is
valid YAML or TOML. Missing frontmatter returns `found = false` with
`failure.reason = "missing_frontmatter"`. Unterminated frontmatter returns
`found = false` with `failure.reason = "unterminated_frontmatter"`. Malformed
frontmatter returns `found = true`, `parsed = false`, `parse_error`, and
`value = null`.

## `markdown.link_check`

Available only when `[builtin].enabled` includes `markdown.link_check`. Checks
local Markdown links from one workspace-contained UTF-8 Markdown file. It
resolves reference definitions, checks whether workspace-contained local targets
exist, and optionally checks Markdown heading/id fragments. External URLs and
email links are reported as unchecked; the tool does not fetch URLs, crawl
documents, summarize content, or infer documentation semantics.

Arguments:

```json
{
  "path": "README.md",
  "include_images": true,
  "include_reference_definitions": true,
  "include_autolinks": true,
  "include_code_blocks": false,
  "check_fragments": true,
  "max_links": 200,
  "max_bytes": 1048576,
  "max_target_bytes": 1048576
}
```

Returned checks include source line, link kind, raw destination, resolved
destination for reference links, status, category, issue text when applicable,
and target existence/fragment metadata. Status values are mechanical:
`ok`, `missing_target`, `missing_fragment`, `missing_reference_definition`,
`outside_workspace`, `empty_destination`, `external_unchecked`, and
`fragment_unchecked`.

## `file.tail`

Available only when `[builtin].enabled` includes `file.tail`. Reads the last
lines from a workspace-contained UTF-8 file using a bounded tail window. When
the file is larger than `max_bytes`, returned line numbers are reported as
unknown instead of guessed, and a partial first line cut by the window is
dropped and flagged.

Arguments:

```json
{
  "path": "logs/build.log",
  "max_lines": 200,
  "max_bytes": 1048576
}
```

## `file.hexdump`

Available only when `[builtin].enabled` includes `file.hexdump`. Reads a
bounded byte window from a workspace-contained file and returns deterministic
hex/ascii rows. It is read-only and useful for inspecting binary headers,
encoding clues, and small non-UTF-8 snippets without reading the whole file.

Arguments:

```json
{
  "path": "image.png",
  "offset_bytes": 0,
  "max_bytes": 256
}
```

## `file.xattrs`

Available only when `[builtin].enabled` includes `file.xattrs`. Lists extended
attributes for a workspace-contained file or directory. By default it returns
only names and sizes; set `include_values` to return bounded base64 and UTF-8
value previews. Values larger than `max_value_bytes` are reported as truncated
without being read. It is read-only and useful for macOS metadata such as
quarantine flags, Finder tags, and downloaded-file diagnostics.

Arguments:

```json
{
  "path": "Downloads/example.zip",
  "include_values": false,
  "max_value_bytes": 1024
}
```

## `file.remove_xattr`

Available only when `[builtin].enabled` includes `file.remove_xattr`. Removes
one extended attribute from a workspace-contained file or directory using the
macOS xattr API. This is a non-recursive write operation. It is useful for
explicit metadata cleanup such as removing `com.apple.quarantine` after the
caller has inspected attributes with `file.xattrs`. Set `dry_run` to validate
that the attribute exists and return `would_attributes_after` without removing
it.

Arguments:

```json
{
  "path": "Downloads/example.zip",
  "name": "com.apple.quarantine",
  "dry_run": false
}
```

## `file.metadata`

Available only when `[builtin].enabled` includes `file.metadata`. Reads
Spotlight metadata for a workspace-contained file or directory using fixed
`/usr/bin/mdls -plist -` argv. This is read-only and macOS-specific. Optional
`attributes` filter returned keys after plist parsing; the runtime validates
attribute names but does not interpret metadata semantics.

Arguments:

```json
{
  "path": "Downloads/example.zip",
  "attributes": ["kMDItemDisplayName", "kMDItemContentType"],
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `file.readlink`

Available only when `[builtin].enabled` includes `file.readlink`. Reads the raw
destination of a workspace-contained symbolic link without following the final
link. The link path itself must be inside the workspace, and symlinked parent
directories may not escape the workspace. The destination may point outside the
workspace; the response reports whether it is workspace-contained.

Arguments:

```json
{
  "path": "current"
}
```

## `file.resolve`

Available only when `[builtin].enabled` includes `file.resolve`. Resolves a
workspace-contained path mechanically without reading file contents or creating
missing paths. The response includes the lexical workspace path, existence,
final symlink destination when present, resolved path, and whether the resolved
destination remains inside the workspace.

Arguments:

```json
{
  "path": "current"
}
```

## `image.info`

Available only when `[builtin].enabled` includes `image.info`. Reads mechanical
metadata for a workspace-contained image file using ImageIO. It reports format,
MIME, dimensions, frame count, color metadata, orientation, DPI, and optional
bounded raw ImageIO property dictionaries. It does not decode pixels, OCR,
classify image contents, generate thumbnails, or infer visual semantics.

Arguments:

```json
{
  "path": "Resources/icon.png",
  "include_properties": false,
  "max_property_depth": 2
}
```

The result includes `type_identifier`, `mime_type`, `frame_count`,
`pixel_width`, `pixel_height`, `depth`, `orientation`, `dpi_width`,
`dpi_height`, `has_alpha`, `is_float`, `color_model`, `profile_name`,
`properties_included`, `properties_truncated`, and `truncated`. Raw
`properties` and `global_properties` are returned only when
`include_properties` is true.

## `pdf.info`

Available only when `[builtin].enabled` includes `pdf.info`. Reads mechanical
metadata for a workspace-contained PDF file using PDFKit. It reports page
count, encryption and permission flags, optional document attributes, and
bounded page box metadata. It does not extract text, OCR, render pages, inspect
embedded images, or summarize document contents.

Arguments:

```json
{
  "path": "Docs/report.pdf",
  "max_pages": 20,
  "include_page_boxes": true,
  "include_attributes": true
}
```

The result includes `page_count`, `returned_page_count`, `pages_truncated`,
`is_encrypted`, `is_locked`, `allows_copying`, `allows_printing`,
`attributes_included`, `attributes_truncated`, and `pages`. Page rows include
one-based `number`, optional `label`, `rotation`, and, when enabled, `boxes`
for media, crop, bleed, trim, and art boxes.

## `pdf.text`

Available only when `[builtin].enabled` includes `pdf.text`. Extracts bounded
searchable text from a workspace-contained PDF file using PDFKit
`PDFPage.string`. It is read-only, respects PDF locking and copying flags, and
does not OCR, render pages, inspect embedded images, or summarize document
contents.

Arguments:

```json
{
  "path": "Docs/report.pdf",
  "start_page": 1,
  "max_pages": 10,
  "max_characters": 100000
}
```

The result includes `page_count`, `start_page`, `returned_page_count`,
`page_range_truncated`, `text_truncated`, `total_extracted_character_count`,
and `pages`. Page rows include one-based `number`, optional `label`, extracted
`text`, raw `character_count`, bounded `extracted_character_count`, and
per-page `text_truncated`.

## `media.info`

Available only when `[builtin].enabled` includes `media.info`. Reads mechanical
metadata for a workspace-contained audio or video file using AVFoundation. It
reports duration, playability, protected-content state, available metadata
formats, track types, codecs, dimensions, frame rate, and data rate. It does not
decode samples, transcode, extract frames, play media, inspect visual/audio
content, or infer semantics.

Arguments:

```json
{
  "path": "Resources/demo.mov",
  "max_tracks": 20,
  "load_timeout_ms": 5000
}
```

The result includes `duration_seconds`, `is_playable`,
`has_protected_content`, `track_count`, `returned_track_count`,
`tracks_truncated`, `media_types`, `available_metadata_formats`, and `tracks`.
Track rows include `media_type`, optional `duration_seconds`, `natural_size`,
`nominal_frame_rate`, `estimated_data_rate`, `language_code`, and
`codec_types`.

## `json.read`

Available only when `[builtin].enabled` includes `json.read`. Reads and parses
a workspace-contained JSON file into a JSON value using the gateway JSON
decoder. This is read-only and does not execute a subprocess.

Arguments:

```json
{
  "path": "package.json",
  "max_bytes": 1048576
}
```

## `jsonl.read`

Available only when `[builtin].enabled` includes `jsonl.read`. Reads a bounded
preview of a workspace-contained JSON Lines / NDJSON UTF-8 file by parsing each
nonblank line as an independent JSON value. It reports parse errors separately;
it does not infer schemas, summarize records, execute subprocesses, or read past
the configured byte budget.

Arguments:

```json
{
  "path": "data/events.jsonl",
  "start_line": 1,
  "max_records": 100,
  "max_errors": 50,
  "skip_blank_lines": true,
  "include_partial_line": false,
  "max_bytes": 1048576
}
```

Returned data includes parsed `records` with source line numbers, parse
`errors` with bounded raw previews, record/error truncation flags,
`content_truncated`, and `partial_line_dropped` when the byte window cuts
through the final line.

## `json.write`

Available only when `[builtin].enabled` includes `json.write`. Serializes a
provided JSON value and writes it to a workspace-contained path. It defaults to
`dry_run = true`, pretty printed output, sorted keys, trailing newline, no
overwrite, and no parent directory creation. Real writes require
`dry_run = false` and `confirm_write = true`.

Arguments:

```json
{
  "path": "config/generated.json",
  "value": {"enabled": true, "names": ["computer-mcp"]},
  "create_directories": true,
  "overwrite": false,
  "dry_run": true,
  "confirm_write": false,
  "include_preview": true,
  "preview_max_bytes": 8192,
  "max_bytes": 1048576
}
```

The result reports whether the file already existed, whether it would create or
overwrite, byte counts before and after, and a bounded encoded preview when
requested.

## `toml.read`

Available only when `[builtin].enabled` includes `toml.read`. Reads and parses
a workspace-contained TOML file into a JSON value using the existing
`swift-toml` decoder. This is read-only and does not execute a subprocess.
TOML local date/time values are returned as typed JSON objects.

Arguments:

```json
{
  "path": "config.toml",
  "max_bytes": 1048576
}
```

## `yaml.read`

Available only when `[builtin].enabled` includes `yaml.read`. Reads and parses
a workspace-contained YAML file into JSON-compatible values using Yams. This is
read-only, supports multiple YAML documents, does not execute subprocesses, and
does not infer business semantics. YAML timestamps are returned as typed date
objects; non-finite numeric values are returned as typed objects instead of JSON
numbers.

Arguments:

```json
{
  "path": ".github/workflows/ci.yml",
  "max_bytes": 1048576,
  "max_documents": 50,
  "max_depth": 128
}
```

Returned data includes `document_count`, `returned_document_count`,
`document_count_truncated`, `documents`, and `value`. `documents` preserves
YAML document boundaries; `value` is the single document value, an array of
document values for multi-document files, or `null` for an empty stream.
`conversion` reports mechanical conversion counts such as non-string YAML keys,
key collisions after JSON key stringification, dates, unsupported values, and
non-finite numbers.

## `xml.read`

Available only when `[builtin].enabled` includes `xml.read`. Reads and parses a
workspace-contained XML file into a bounded element tree using Foundation
`XMLParser`. This is read-only, disables external entity resolution, does not
execute subprocesses, and does not validate schemas or infer business
semantics.

Arguments:

```json
{
  "path": "pom.xml",
  "max_bytes": 1048576,
  "max_nodes": 10000,
  "max_depth": 64,
  "max_text_bytes": 8192,
  "trim_text": true
}
```

Returned data includes `element_count`, `returned_element_count`,
`max_depth_observed`, truncation flags, and `root`. Each returned element
includes its `name`, optional namespace metadata, sorted `attributes`, bounded
direct `text`, `child_count`, `returned_child_count`, and returned `children`.

## `plist.read`

Available only when `[builtin].enabled` includes `plist.read`. Reads and parses
a workspace-contained macOS property list file into JSON using Foundation
`PropertyListSerialization`. This is read-only and does not execute a
subprocess. Property-list `date` and `data` values are returned as typed JSON
objects.

Arguments:

```json
{
  "path": "Info.plist",
  "max_bytes": 1048576
}
```

## `structured.get`

Available only when `[builtin].enabled` includes `structured.get`. Reads one
value at an explicit path from a workspace-contained JSON, YAML, TOML, or plist
file. This is read-only and deterministic: `query_path` is an array where
strings select object keys and non-negative integers select array indexes. It
does not implement JSONPath, JQ, filters, wildcards, schema inference, or field
semantics.

Arguments:

```json
{
  "path": "package.json",
  "format": "auto",
  "query_path": ["scripts", "test"],
  "max_bytes": 1048576,
  "max_documents": 50,
  "max_depth": 128
}
```

`format` may be `auto`, `json`, `yaml`, `toml`, or `plist`. `auto` uses the file
extension. YAML multi-document streams expose a single document as that value,
multiple documents as an array of document values, and an empty stream as
`null`. Missing keys, wrong container types, and out-of-range indexes return
`matched = false`, `value = null`, and a mechanical `failure` object naming the
failing segment.

## `plist.write`

Available only when `[builtin].enabled` includes `plist.write`. Serializes a
provided JSON value as a workspace-contained macOS property list using
Foundation `PropertyListSerialization`. It defaults to XML output,
`dry_run = true`, no overwrite, and no parent directory creation. Real writes
require `dry_run = false` and `confirm_write = true`.

Arguments:

```json
{
  "path": "Generated/Info.plist",
  "value": {
    "CFBundleIdentifier": "com.example.tool",
    "CreatedAt": {"type": "date", "iso8601": "2026-07-09T00:00:00Z"},
    "Payload": {"type": "data", "base64": "3q2+7w=="}
  },
  "format": "xml",
  "create_directories": true,
  "overwrite": false,
  "dry_run": true,
  "confirm_write": false,
  "include_preview": true,
  "preview_max_bytes": 8192,
  "max_bytes": 1048576
}
```

Supported values are objects, arrays, strings, finite numbers, booleans, and
typed date/data objects compatible with `plist.read` output. Property lists do
not support `null`; calls containing null values fail deterministically.

## `csv.read`

Available only when `[builtin].enabled` includes `csv.read`. Reads a bounded
preview of a workspace-contained CSV/TSV-style UTF-8 text file. It parses
delimiter characters, quoted fields, rows, and cells mechanically; it does not
infer column meaning, summarize data, execute subprocesses, or read outside the
configured byte budget.

Arguments:

```json
{
  "path": "data/export.csv",
  "delimiter": "auto",
  "has_header": true,
  "max_rows": 100,
  "max_columns": 200,
  "max_bytes": 1048576
}
```

`delimiter` may be `auto`, `comma`, `tab`, `semicolon`, `pipe`, or one literal
non-newline character. The result includes `headers`, row objects with
`record_number` and `cells`, delimiter metadata, `bytes_read`,
`content_truncated`, `row_count_truncated`, `column_count_truncated`, and
`parse_incomplete` flags.

## `sqlite.schema`

Available only when `[builtin].enabled` includes `sqlite.schema`. Inspects a
workspace-contained SQLite database schema using fixed
`/usr/bin/sqlite3 -batch -readonly -json` argv. It returns rows from
`sqlite_schema`; it does not execute user-provided SQL and does not read table
data.

Arguments:

```json
{
  "path": "data/app.db",
  "include_views": true,
  "include_indexes": true,
  "include_triggers": true,
  "include_internal": false,
  "include_sql": true,
  "max_entries": 500,
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

Returned entries include SQLite `type`, `name`, `tbl_name`, and `sql` fields as
reported by the SQLite CLI. Output is bounded with `max_entries` and
`max_output_bytes`.

## `sqlite.query`

Available only when `[builtin].enabled` includes `sqlite.query`. Runs one
read-only SQLite statement against a workspace-contained database using fixed
`/usr/bin/sqlite3 -batch -readonly -json` argv. Accepted statements are
`SELECT`, `WITH`, and non-assigning `PRAGMA`; mutating SQL, DDL, attach/detach,
vacuum/reindex/analyze, and multiple statements are rejected before execution.

Arguments:

```json
{
  "path": "data/app.db",
  "query": "SELECT id, name FROM items ORDER BY id LIMIT 20",
  "max_rows": 100,
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

`SELECT` and `WITH` statements are executed through an outer `LIMIT
max_rows+1`; returned rows are truncated to `max_rows` with `truncated=true`
when more rows are present. `PRAGMA` statements are forwarded without an outer
wrapper, but only read-only non-assignment forms are accepted. The gateway does
not infer schema semantics, rewrite column values, or execute shell
interpolation.

## `file.hash`

Available only when `[builtin].enabled` includes `file.hash`. Computes a
SHA-256 digest for a workspace-contained file without returning file content.

Arguments:

```json
{
  "path": "Package.swift",
  "algorithm": "sha256"
}
```

## `file.diff`

Available only when `[builtin].enabled` includes `file.diff`. Returns a bounded
unified diff between two workspace-contained files using fixed `/usr/bin/diff`
argv. This is read-only. Exit code `0` means no differences, exit code `1`
means files differ, and other nonzero values should be treated as command
errors in the returned `result`.

Arguments:

```json
{
  "source": "before.txt",
  "target": "after.txt",
  "context_lines": 3,
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `file.compare_trees`

Available only when `[builtin].enabled` includes `file.compare_trees`. Compares
two workspace-contained directories by relative path using bounded
deterministic traversal. By default it compares only metadata: entry presence,
type, symlink destination, and file size. Set `compare_hashes=true` to SHA-256
compare same-size files within `max_hash_files` and `max_hash_file_bytes`.

The tool is read-only, does not run shell commands, and returns counts plus a
bounded `differences` array. Use `result_truncated` and `scan_truncated` to know
whether to rerun with narrower paths or higher limits.

Arguments:

```json
{
  "left": "before",
  "right": "after",
  "include_hidden": false,
  "max_depth": 8,
  "max_entries": 20000,
  "max_results": 200,
  "compare_hashes": false,
  "max_hash_files": 1000,
  "max_hash_file_bytes": 10485760
}
```

## `file.duplicates`

Available only when `[builtin].enabled` includes `file.duplicates`. Finds
duplicate regular files under one workspace-contained directory by first
grouping eligible files by size and then confirming duplicates with bounded
SHA-256 hashing. The tool is read-only, skips symlinks, does not delete files,
and does not decide which file should be kept.

Use `scan_truncated`, `result_truncated`, `hash_skipped_file_count`, and
`hash_skipped_size_bucket_count` to know whether to narrow the path or increase
limits. Each duplicate group includes the hash, file size, file count,
redundant byte estimate if one file per group were kept, and follow-up contexts
for `file.read`, `file.stat`, and `file.hash`.

Arguments:

```json
{
  "path": ".",
  "include_hidden": false,
  "min_size_bytes": 1,
  "max_depth": 8,
  "max_entries": 20000,
  "max_hash_files": 5000,
  "max_hash_file_bytes": 10485760,
  "max_groups": 100,
  "max_files_per_group": 20
}
```

## `archive.list`

Available only when `[builtin].enabled` includes `archive.list`. Lists entries
in a workspace-contained zip or tar archive using fixed read-only argv. Zip-like
archives use `/usr/bin/zipinfo -1`; tar-like archives use `/usr/bin/tar -tf`.
The tool does not extract files and does not run shell interpolation.

Supported suffixes:
`.zip`, `.jar`, `.war`, `.ear`, `.tar`, `.tar.gz`, `.tgz`, `.tar.bz2`,
`.tbz`, `.tbz2`, `.tar.xz`, and `.txz`.

Arguments:

```json
{
  "path": "dist/app.zip",
  "max_entries": 1000,
  "timeout_ms": 10000,
  "max_output_bytes": 1048576
}
```

## `archive.read_file`

Available only when `[builtin].enabled` includes `archive.read_file`. Reads one
file member from a workspace-contained zip or tar archive using fixed read-only
argv. Zip-like archives use `/usr/bin/unzip -p`; tar-like archives use
`/usr/bin/tar -xOf`. The tool streams only the selected member to stdout, does
not extract files, does not write to disk, and does not run shell interpolation.

Entry paths are normalized and must name one file-like member. Absolute paths,
parent-directory escapes, directory paths, option-like names, and archive
wildcard patterns are rejected so a single tool call cannot expand to multiple
members. `encoding` defaults to `utf8`; use `base64` for binary members or
`auto` to return UTF-8 text when valid and base64 otherwise.

Arguments:

```json
{
  "path": "dist/app.zip",
  "entry": "README.md",
  "encoding": "utf8",
  "max_bytes": 1048576,
  "timeout_ms": 10000
}
```

## `archive.extract`

Available only when `[builtin].enabled` includes `archive.extract`. Extracts a
workspace-contained zip or tar archive into a workspace-contained destination
directory using fixed argv. The tool defaults to `dry_run=true`, validates all
entry paths before extraction, refuses link entries, and requires
`confirm_extract=true` when `dry_run=false`.

Zip-like archives use `/usr/bin/unzip`; tar-like archives use `/usr/bin/tar`.
The destination directory must already exist unless `create_directories=true`.
Existing destination paths are rejected unless `overwrite=true`.

Arguments:

```json
{
  "path": "dist/app.zip",
  "destination": "tmp/app",
  "create_directories": true,
  "overwrite": false,
  "dry_run": true,
  "confirm_extract": false,
  "max_entries": 100000,
  "max_preview_entries": 100,
  "timeout_ms": 30000,
  "max_output_bytes": 1048576
}
```

## `archive.create`

Available only when `[builtin].enabled` includes `archive.create`. Creates a zip
or tar archive from explicit workspace-contained source files/directories using
fixed argv. The tool defaults to `dry_run=true`, refuses symlink sources and
symlink entries, rejects unsupported source file types, prevents writing the
archive inside any source directory, and requires `confirm_create=true` when
`dry_run=false`.

Zip-like suffixes use `/usr/bin/zip -qry`. Tar-like suffixes use
`/usr/bin/tar` with the create flag selected from the output suffix. The archive
parent directory must already exist unless `create_directories=true`. Existing
archive files are rejected unless `overwrite=true`.

Arguments:

```json
{
  "path": "dist/app.zip",
  "sources": ["src", "README.md"],
  "format": "zip",
  "create_directories": true,
  "overwrite": false,
  "dry_run": true,
  "confirm_create": false,
  "max_entries": 100000,
  "max_preview_entries": 100,
  "timeout_ms": 30000,
  "max_output_bytes": 1048576
}
```

## `file.download`

Available only when `[builtin].enabled` includes `file.download`. Downloads an
absolute HTTP or HTTPS URL to a workspace-contained file using fixed
`/usr/bin/curl` argv. The tool defaults to `dry_run=true`, rejects URLs with
userinfo credentials, sends no custom headers, cookies, or request body, writes
through a deterministic temp file in the destination directory, and requires
`confirm_download=true` when `dry_run=false`.

The destination parent directory must already exist unless
`create_directories=true`. Existing destination files are rejected unless
`overwrite=true`. Use `network.http_check` first when the caller only needs
HTTP status, content type, effective URL, or a bounded response-body prefix.

Arguments:

```json
{
  "url": "https://example.com/report.txt",
  "path": "downloads/report.txt",
  "create_directories": true,
  "overwrite": false,
  "dry_run": true,
  "confirm_download": false,
  "follow_redirects": false,
  "max_redirects": 5,
  "connect_timeout_seconds": 5,
  "timeout_ms": 30000,
  "max_download_bytes": 10485760,
  "max_output_bytes": 16384
}
```

## `file.write`

Available only when `[builtin].enabled` includes `file.write`. Writes UTF-8 text
under the configured workspace. Set `dry_run` to true to validate parent
directory and overwrite behavior without creating directories or writing
content.

Arguments:

```json
{
  "path": "notes/debug.txt",
  "content": "ready",
  "create_directories": true,
  "overwrite": true,
  "dry_run": false,
  "include_preview": false,
  "preview_max_bytes": 8192
}
```

## `file.write_files`

Available only when `[builtin].enabled` includes `file.write_files`. Writes
multiple explicitly named UTF-8 files under the workspace. This is a batch form
for known output paths; it does not discover files, patch existing content, or
merge partial edits. Use `file.replace_text`, `file.replace_lines`, or
`file.insert_text` for targeted edits to existing files.

Unlike `file.write`, this tool defaults to `dry_run = true`. Real writes require
both `dry_run = false` and `confirm_write = true`. `overwrite` defaults to
false, and missing parent directories are created only when
`create_directories = true`. The call preflights every entry first and fails
deterministically for duplicate paths, workspace escapes, directories, missing
parents, existing files when overwrite is false, or content above the configured
policy limit.

Arguments:

```json
{
  "files": [
    { "path": "Sources/App/Feature.swift", "content": "..." },
    { "path": "Tests/AppTests/FeatureTests.swift", "content": "..." }
  ],
  "create_directories": true,
  "dry_run": true,
  "preview_max_bytes": 4096
}
```

## `file.append`

Available only when `[builtin].enabled` includes `file.append`. Appends UTF-8
text to a workspace-contained file without rewriting existing content. The file
is created by default when missing; parent directories are created only when
`create_directories` is true. Set `dry_run` to true to validate the append
without creating files/directories or writing content.

Arguments:

```json
{
  "path": "logs/session.txt",
  "content": "ready",
  "create_if_missing": true,
  "create_directories": false,
  "append_newline": true,
  "dry_run": false,
  "include_preview": false,
  "preview_max_bytes": 8192
}
```

## `file.replace_text`

Available only when `[builtin].enabled` includes `file.replace_text`. Performs
exact UTF-8 string replacement in a workspace-contained file. It does not parse
or semantically edit code. By default it replaces the first non-overlapping
match; set `replace_all` to replace all matches. Use `expected_replacements` to
turn the operation into an exact assertion. Set `dry_run` to true to validate
the match count and return bounded search/replacement previews without writing.

Arguments:

```json
{
  "path": "notes/debug.txt",
  "search": "old text",
  "replacement": "new text",
  "replace_all": false,
  "expected_replacements": 1,
  "dry_run": false,
  "include_preview": false,
  "preview_max_bytes": 8192,
  "max_bytes": 1048576
}
```

## `file.insert_text`

Available only when `[builtin].enabled` includes `file.insert_text`. Inserts
exact UTF-8 text before or after an existing one-based line in a
workspace-contained file. It does not parse or semantically edit content. Use
`expected_line` to assert the target line text before inserting. Set `dry_run`
to true to validate the target line and return bounded target/insert previews
without writing.

Arguments:

```json
{
  "path": "notes/debug.txt",
  "line": 3,
  "content": "inserted line",
  "position": "before",
  "expected_line": "old line 3",
  "append_newline": true,
  "dry_run": false,
  "include_preview": false,
  "preview_max_bytes": 8192,
  "max_bytes": 1048576
}
```

## `file.replace_lines`

Available only when `[builtin].enabled` includes `file.replace_lines`. Replaces
or deletes an exact one-based line range in a workspace-contained UTF-8 file. It
does not parse or semantically edit content. Use `expected_content` to assert
the selected line range before writing. Set `content` to an empty string to
delete the selected lines. Set `dry_run` to true to validate the selected range
and return bounded selected/replacement previews without writing.

Arguments:

```json
{
  "path": "notes/debug.txt",
  "start_line": 3,
  "end_line": 5,
  "content": "replacement line",
  "expected_content": "old line 3\nold line 4\nold line 5\n",
  "append_newline": true,
  "dry_run": false,
  "include_preview": false,
  "preview_max_bytes": 8192,
  "max_bytes": 1048576
}
```

## `file.mkdir`

Available only when `[builtin].enabled` includes `file.mkdir`. Creates a
workspace-contained directory. Missing parents are created by default. Set
`dry_run` to validate the create intent without creating directories.

Arguments:

```json
{
  "path": "notes/archive",
  "intermediate_directories": true,
  "dry_run": false
}
```

## `file.touch`

Available only when `[builtin].enabled` includes `file.touch`. Creates an empty
workspace-contained file if it is missing, or updates an existing file's
modification time. It does not write content, and it rejects directories. Set
`dry_run` to validate create/update intent without creating parent directories,
creating the file, or changing timestamps.

Arguments:

```json
{
  "path": "notes/debug.txt",
  "create_if_missing": true,
  "create_directories": false,
  "dry_run": false
}
```

## `file.copy`

Available only when `[builtin].enabled` includes `file.copy`. Copies a file or
directory between workspace-contained paths. Existing destinations are rejected
unless `overwrite` is true. Set `dry_run` to validate source, destination,
overwrite policy, and parent-directory creation intent without copying or
overwriting.

Arguments:

```json
{
  "source": "notes/source.txt",
  "destination": "notes/archive/source.txt",
  "overwrite": false,
  "create_directories": true,
  "dry_run": false
}
```

## `file.move`

Available only when `[builtin].enabled` includes `file.move`. Moves or renames a
file or directory between workspace-contained paths. Existing destinations are
rejected unless `overwrite` is true. Set `dry_run` to validate source,
destination, overwrite policy, and parent-directory creation intent without
moving the source or overwriting the destination.

Arguments:

```json
{
  "source": "notes/draft.txt",
  "destination": "notes/archive/draft.txt",
  "overwrite": false,
  "create_directories": true,
  "dry_run": false
}
```

## `file.symlink`

Available only when `[builtin].enabled` includes `file.symlink`. Creates a
symbolic link at a workspace-contained path. By default the raw destination must
resolve inside the workspace; set `allow_external_destination` only when an
external target is intentional. Existing link paths are rejected unless
`overwrite` is true, including broken symlinks. Set `dry_run` to validate link
path, destination containment, overwrite policy, and parent-directory creation
intent without creating the link.

Arguments:

```json
{
  "path": "current",
  "destination": "releases/v1",
  "overwrite": false,
  "create_directories": true,
  "allow_external_destination": false,
  "dry_run": false
}
```

## `file.trash`

Available only when `[builtin].enabled` includes `file.trash`. Moves a
workspace-contained file or directory to the macOS Trash. This is a write
operation, but it is preferred over permanent delete for gateway-level file
organization. Set `dry_run` to validate the path without moving it to Trash.

Arguments:

```json
{
  "path": "notes/obsolete.txt",
  "dry_run": false
}
```

## `workspace.open`

Available only when `[builtin].enabled` includes `workspace.open`. Opens the
workspace root or an in-workspace path with macOS `open`.

## `workspace.reveal`

Available only when `[builtin].enabled` includes `workspace.reveal`. Reveals a
workspace-contained path in Finder using macOS `open -R`.

Arguments:

```json
{
  "path": "Package.swift"
}
```

## Read-Only Git Atomics

Available only when listed in `[builtin].enabled`. These tools require a
registered CLI provider with `id = "git"` and execute that provider through argv,
not a shell. Path arguments are literal workspace-relative paths passed after
`--`; absolute paths, `..`, and Git pathspec magic are rejected. Use `cli.exec`
with the `git` provider when raw Git behavior is required.

### `git.root`

Runs fixed read-only `git rev-parse` repository identity checks through the
registered `git` CLI provider.

Arguments:

```json
{
  "timeout_ms": 30000
}
```

### `git.config`

Runs fixed read-only
`git config --list --show-origin --show-scope --null` through the registered
`git` CLI provider and returns structured config entries. Values are redacted
by default, sensitive-looking values stay redacted even when
`include_values = true`, and raw stdout is not returned.

Arguments:

```json
{
  "include_values": false,
  "scope": "all",
  "max_results": 200,
  "timeout_ms": 30000
}
```

`scope` may be `all`, `system`, `global`, `local`, `worktree`, or `command`.

### `git.remotes`

Runs fixed read-only `git remote --verbose` through the registered `git` CLI
provider. This reads local remote configuration and does not contact remotes.

Arguments:

```json
{
  "timeout_ms": 30000
}
```

### `git.worktrees`

Runs fixed read-only `git worktree list --porcelain` through the registered
`git` CLI provider. This reads local worktree metadata and does not create,
move, prune, or remove worktrees.

Arguments:

```json
{
  "timeout_ms": 30000
}
```

### `git.stashes`

Runs fixed read-only `git stash list --date=iso-strict` through the registered
`git` CLI provider. This lists local stash entries and does not apply, pop, or
drop stashes.

Arguments:

```json
{
  "timeout_ms": 30000
}
```

### `git.stash_show`

Runs fixed read-only `git stash show` for one local stash through the registered
`git` CLI provider. The `stash` argument is constrained to `stash@{N}` syntax,
defaults to `stash@{0}`, and optional paths are literal workspace-relative
pathspecs passed after `--`. When paths are supplied, the gateway uses fixed
read-only `git diff <stash>^1 <stash> -- <paths...>` argv because local Git
does not accept pathspecs in `git stash show` consistently.

Arguments:

```json
{
  "stash": "stash@{0}",
  "stat": true,
  "patch": false,
  "context_lines": 3,
  "paths": ["Sources/ComputerMCP/GatewayToolRegistry.swift"],
  "timeout_ms": 30000
}
```

### `git.tags`

Runs fixed read-only `git tag --list --sort=-creatordate --format=...` through
the registered `git` CLI provider. Output is tab-separated tag metadata and does
not contact remotes.

Arguments:

```json
{
  "timeout_ms": 30000
}
```

### `git.tag_show`

Shows one local tag with fixed `git show --date=iso-strict` argv against
`refs/tags/<name>` through the registered `git` CLI provider. This does not
accept arbitrary revisions, contact remotes, or change the index or working
tree. By default it includes `--stat`; set `stat` to false to use `--no-patch`
for commit/tag metadata without a diffstat.

Before showing the tag, the gateway verifies that `refs/tags/<name>` exists
locally with:

- `git show-ref --verify --quiet refs/tags/<name>`

Arguments:

```json
{
  "name": "v1.0.0",
  "stat": true,
  "timeout_ms": 30000
}
```

### `git.tag_create`

Creates one lightweight local tag with fixed `git tag <name> <target>` argv
through the registered `git` CLI provider. This does not create annotated tags,
sign tags, force-replace existing tags, push tags, fetch remotes, or change the
index or working tree. Because `git tag` has no portable native dry-run for
creation, `dry_run` means gateway preflight only. The tool first runs
deterministic preflight checks:

- `git check-ref-format refs/tags/<name>`
- `git rev-parse --verify <target>^{object}`
- `git show-ref --verify --quiet refs/tags/<name>`

Set `confirm_create` to true and `dry_run` to false to create the lightweight
local tag after preflight checks pass.

Arguments:

```json
{
  "name": "v1.0.0",
  "target": "HEAD",
  "dry_run": true,
  "confirm_create": false,
  "timeout_ms": 30000
}
```

### `git.tag_delete`

Deletes one local tag with fixed `git tag -d <name>` argv through the
registered `git` CLI provider. This does not push remote tag deletion, fetch
remotes, force-delete anything else, or change the index or working tree.
Because `git tag -d` has no non-mutating native dry-run, `dry_run` means
gateway preflight only. The tool first runs deterministic preflight checks:

- `git show-ref --verify --quiet refs/tags/<name>`
- `git rev-parse --verify refs/tags/<name>^{object}`

Set `confirm_delete` to true and `dry_run` to false to delete the local tag
after preflight checks pass.

Arguments:

```json
{
  "name": "v1.0.0",
  "dry_run": true,
  "confirm_delete": false,
  "timeout_ms": 30000
}
```

### `git.ignored`

Runs fixed read-only `git check-ignore --verbose -- <paths...>` through the
registered `git` CLI provider. It requires explicit workspace-relative paths.
Git uses its exit code to distinguish ignored from non-ignored paths.

Arguments:

```json
{
  "paths": ["build/output.log"],
  "timeout_ms": 30000
}
```

### `git.submodules`

Runs fixed read-only `git submodule status --recursive` through the registered
`git` CLI provider. This reads local submodule status and does not initialize,
update, sync, or fetch submodules.

Arguments:

```json
{
  "timeout_ms": 30000
}
```

### `git.files`

Runs fixed read-only `git ls-files --stage --eol` through the registered `git`
CLI provider. Optional paths are literal workspace-relative paths passed after
`--`. Output is Git's raw tracked-file index metadata.

Arguments:

```json
{
  "paths": ["Sources"],
  "timeout_ms": 30000
}
```

### `git.grep`

Runs bounded read-only fixed-string `git grep --line-number -I --null` through
the registered `git` CLI provider. Optional paths are literal
workspace-relative paths passed after `--`. It searches Git-tracked content and
does not run shell commands or interpret the query as a regular expression.

Arguments:

```json
{
  "query": "needle",
  "paths": ["Sources"],
  "case_sensitive": true,
  "max_results": 200,
  "timeout_ms": 30000
}
```

Returned match rows include `workspace_relative_path`, `line`, `text`,
`raw_record`, and `read_context` for a follow-up `file.read_lines` call through
the gateway.

### `git.blame`

Runs bounded read-only `git blame --line-porcelain -L <start>,+<count>` through
the registered `git` CLI provider. The path is a literal workspace-relative file
path passed after `--`. Output is Git's raw line porcelain blame data.

Arguments:

```json
{
  "path": "Sources/main.swift",
  "start_line": 1,
  "max_lines": 200,
  "timeout_ms": 30000
}
```

### `git.file_history`

Runs bounded read-only `git log` for one workspace-relative file through the
registered `git` CLI provider. It defaults to `--follow` so history can continue
across renames. It does not change refs, the index, or the working tree.

Arguments:

```json
{
  "path": "Sources/main.swift",
  "limit": 50,
  "max_results": 50,
  "follow": true,
  "include_merges": true,
  "timeout_ms": 30000
}
```

Returned entries include `commit`, `abbreviated_commit`, `committed_at`,
`author`, `subject`, and `raw_line`. The payload also includes bounded
`raw_lines` and command metadata.

### `git.file_at_revision`

Runs fixed read-only `git show <revision>:<path>` through the registered `git`
CLI provider and returns bounded UTF-8 content for one workspace-relative file
at a constrained revision. It does not change refs, the index, or the working
tree.

Arguments:

```json
{
  "revision": "HEAD",
  "path": "Sources/main.swift",
  "max_bytes": 65536,
  "timeout_ms": 30000
}
```

Returned data includes `content`, `bytes_returned`, `line_count`,
`content_truncated`, `stdout_truncated`, the Git `object_spec`, and command
metadata.

### `git.staged_file`

Runs fixed read-only `git show :<path>` through the registered `git` CLI
provider and returns bounded UTF-8 content for one workspace-relative file from
the Git index. It does not change refs, the index, or the working tree.

Arguments:

```json
{
  "path": "Sources/main.swift",
  "max_bytes": 65536,
  "timeout_ms": 30000
}
```

Returned data includes `content`, `bytes_returned`, `line_count`,
`content_truncated`, `stdout_truncated`, `source`, `index_stage`, the Git
`object_spec`, and command metadata.

### `git.conflicts`

Runs fixed read-only `git ls-files --unmerged` through the registered `git` CLI
provider. Optional paths are literal workspace-relative paths passed after `--`.
Output is Git's raw unmerged index entries for conflict inspection.

Arguments:

```json
{
  "paths": ["Sources"],
  "timeout_ms": 30000
}
```

### `git.status`

Runs `git status --short --branch --porcelain=v1`.

Arguments:

```json
{
  "paths": ["Sources"],
  "timeout_ms": 30000
}
```

### `git.tracking_status`

Runs read-only `git status --branch --porcelain=v1` through the registered
`git` CLI provider and parses the first branch header line into current
branch/upstream tracking metadata. It does not fetch, pull, push, or contact a
remote.

Arguments:

```json
{
  "timeout_ms": 30000
}
```

Returned status includes `branch`, `upstream`, `has_upstream`, `ahead`,
`behind`, `detached`, `unborn`, `flags`, `state`, and `raw_branch_line`.
Possible states include `up_to_date`, `ahead`, `behind`, `diverged`,
`no_upstream`, `detached`, `unborn`, and `gone`.

### `git.clean_preview`

Runs read-only `git clean --dry-run -d` through the registered `git` CLI
provider and parses the preview rows. It does not delete files. Use
`include_ignored` for `-x` or `ignored_only` for `-X`; they cannot be combined.

Arguments:

```json
{
  "include_ignored": false,
  "ignored_only": false,
  "paths": ["Sources"],
  "max_results": 200,
  "timeout_ms": 30000
}
```

Returned items include `action`, `workspace_relative_path`, `directory`, and
`raw_line`. The payload also includes bounded `raw_lines` and command metadata.

### `git.reflog`

Runs read-only `git reflog show --date=iso-strict` through the registered
`git` CLI provider and returns bounded local HEAD reflog entries. It does not
change refs, the index, or the working tree.

Arguments:

```json
{
  "limit": 50,
  "max_results": 50,
  "timeout_ms": 30000
}
```

Returned entries include `commit`, `abbreviated_commit`, `selector`, `action`,
`message`, `committed_at`, and `raw_line`. The payload also includes bounded
`raw_lines` and command metadata.

### `git.refs`

Runs read-only `git for-each-ref` through the registered `git` CLI provider and
returns a bounded inventory of local branches, remote-tracking branches, and
optionally tags. It does not change refs, the index, or the working tree.

Arguments:

```json
{
  "include_branches": true,
  "include_remotes": true,
  "include_tags": false,
  "limit": 200,
  "max_results": 200,
  "timeout_ms": 30000
}
```

Returned refs include `kind`, `refname`, `short_name`, `object`,
`abbreviated_object`, `object_type`, `committer_date`, `subject`, and
`raw_line`. The payload also includes the queried namespaces, bounded
`raw_lines`, and command metadata.

### `git.resolve_ref`

Runs fixed read-only `git rev-parse --verify <ref>^{object}` and
`git cat-file -t <object>` through the registered `git` CLI provider. It
returns the resolved object id and Git object type for one constrained ref,
branch, tag, `HEAD`, or commit hash. It does not fetch, push, merge, or change
refs.

Arguments:

```json
{
  "ref": "HEAD",
  "timeout_ms": 30000
}
```

Returned data includes `object_spec`, `object`, `object_type`, fixed `argv`,
and command metadata for each underlying Git command.

### `git.merge_base`

Runs fixed read-only `git merge-base` through the registered `git` CLI provider
for 2 to 16 constrained refs. It returns one or more merge-base object ids;
with `all=true`, it passes `--all`. Git exit code 1 is represented as
`has_merge_base=false` with an empty `merge_bases` array. Other nonzero exit
codes surface as deterministic errors. The tool does not fetch, push, merge, or
change refs.

Arguments:

```json
{
  "refs": ["main", "topic"],
  "all": false,
  "timeout_ms": 30000
}
```

Returned data includes `merge_base`, `merge_bases`, `merge_base_count`,
`has_merge_base`, fixed `argv`, and command metadata.

### `git.compare_refs`

Runs read-only `git rev-list --left-right --count`, `git merge-base`, and
bounded `git log --left-right` through the registered `git` CLI provider for a
constrained `base...head` range. It does not fetch, push, merge, or change refs.

Arguments:

```json
{
  "base": "main",
  "head": "origin/main",
  "limit": 20,
  "max_results": 20,
  "cherry_pick": false,
  "timeout_ms": 30000
}
```

Returned data includes `base_only_count`, `head_only_count`, `head_ahead`,
`head_behind`, `merge_base`, bounded left/right `commits`, bounded `raw_lines`,
and command metadata for each underlying Git command.

### `git.is_ancestor`

Runs fixed read-only `git merge-base --is-ancestor <ancestor> <descendant>`
through the registered `git` CLI provider and returns `is_ancestor` as a
boolean. Exit code 0 maps to true, exit code 1 maps to false, and other exit
codes surface as deterministic errors. Inputs are constrained Git ref tokens.
The tool does not fetch, push, merge, or change refs.

Arguments:

```json
{
  "ancestor": "main",
  "descendant": "origin/main",
  "timeout_ms": 30000
}
```

### `git.diff`

Runs a bounded read-only `git diff`.

Arguments:

```json
{
  "staged": false,
  "stat": false,
  "context_lines": 3,
  "paths": ["Sources"]
}
```

### `git.diff_summary`

Runs read-only `git diff --numstat -z` and `git diff --summary` through the
registered `git` CLI provider, then returns a structured file-level overview.
It does not return patch text or summarize intent. Use `git.diff` for raw patch
inspection after choosing files from this result.

Arguments:

```json
{
  "staged": false,
  "paths": ["Sources"],
  "max_results": 200,
  "timeout_ms": 30000
}
```

Returned rows include per-file `additions`, `deletions`, `binary`,
`workspace_relative_path`, optional `old_path` for renames/copies, and summary
events such as create, delete, rename, copy, and mode changes.

### `git.diff_check`

Runs read-only `git diff --check` through the registered `git` CLI provider and
returns structured issue rows plus bounded raw output lines. This reports the
same whitespace and leftover conflict-marker checks that Git reports; it does
not inspect patch intent or apply style rules.

Arguments:

```json
{
  "staged": false,
  "paths": ["Sources"],
  "max_results": 200,
  "timeout_ms": 30000
}
```

Returned issue rows include `workspace_relative_path`, `line`, `message`, and
`raw_line`. The payload also includes `passed`, the command `exit_code`, and
bounded `raw_lines` for the exact Git output context.

### `git.branch`

Runs read-only `git branch`.

Arguments:

```json
{
  "all": true,
  "verbose": true
}
```

### `git.log`

Runs read-only `git log` with a bounded commit limit and tab-separated fields:
full hash, short hash, ISO date, author name, and subject.

Arguments:

```json
{
  "limit": 20,
  "paths": ["Sources"]
}
```

### `git.commit_files`

Runs fixed read-only `git show -s` and
`git diff-tree --root --no-commit-id --name-status -M -r -z <revision>` through
the registered `git` CLI provider. It returns commit metadata and bounded file
change rows for one constrained revision, without returning patch text or
changing refs, the index, or the working tree.

Arguments:

```json
{
  "revision": "HEAD",
  "max_results": 200,
  "timeout_ms": 30000
}
```

Returned file rows include `status`, `kind`, `path`, `old_path`, `score`, and
`raw_record`. Rename and copy rows use the new path as `path` and preserve the
old path separately.

### `git.show`

Runs read-only `git show` for one revision or object. Defaults to `HEAD` and no
patch.

Arguments:

```json
{
  "revision": "HEAD",
  "stat": true,
  "patch": false,
  "context_lines": 3,
  "paths": ["Package.swift"]
}
```

## Git Write Atomics

Available only when listed in `[builtin].enabled`. These tools require a
registered CLI provider with `id = "git"` and execute that provider through argv,
not a shell. `git.add`, `git.unstage`, and `git.restore_worktree` accept only
explicit workspace-relative paths; they will not stage, unstage, or discard the
entire repository implicitly. `git.clean` requires explicit `paths` or
`all_paths=true` before deleting untracked files/directories.
`git.restore_worktree`, `git.clean`, and local branch write atomics default to
dry-run and require their matching confirmation flag when `dry_run` is false:
`confirm_discard=true`, `confirm_delete=true`, `confirm_create=true`, or
`confirm_rename=true`. `git.tag_create` creates lightweight local tags only and
requires `confirm_create=true` for mutation; `git.tag_delete` deletes local tags
only and requires `confirm_delete=true` for mutation. `git.branch_switch` uses
gateway preflight dry-run because `git switch` has no portable native dry-run
option; real switches require `confirm_switch=true`, and dirty working trees
additionally require `allow_dirty=true`. `git.stash_push`
requires explicit `paths` or `all_paths=true` before it can stash changes. Set
`dry_run` to use the preview argv shown by each tool without mutating the Git
index, creating a commit, creating a stash, creating or deleting local tags,
creating/deleting/renaming local branches, switching branches, discarding
working tree content, or deleting untracked files.

### `git.add`

Stages explicit workspace-relative paths with `git add -- <paths...>`. Set
`dry_run` to run `git add --dry-run` instead.

Arguments:

```json
{
  "paths": ["Sources/ComputerMCP/GatewayToolRegistry.swift"],
  "intent_to_add": false,
  "dry_run": false,
  "timeout_ms": 30000
}
```

### `git.unstage`

Unstages explicit workspace-relative paths with
`git restore --staged -- <paths...>`. This changes the Git index but does not
discard working tree file contents. Set `dry_run` to run
`git diff --cached --name-only -- <paths...>` and preview staged matches without
changing the index.

Arguments:

```json
{
  "paths": ["Sources/ComputerMCP/GatewayToolRegistry.swift"],
  "dry_run": false,
  "timeout_ms": 30000
}
```

### `git.restore_worktree`

Discards unstaged working-tree changes for explicit workspace-relative paths
with `git restore --worktree -- <paths...>`. This can destroy local file
content that is not staged, so `dry_run` defaults to true. Set
`confirm_discard` to true and `dry_run` to false to perform the restore.

Arguments:

```json
{
  "paths": ["Sources/ComputerMCP/GatewayToolRegistry.swift"],
  "dry_run": true,
  "confirm_discard": false,
  "timeout_ms": 30000
}
```

### `git.clean`

Removes untracked files/directories with `git clean -d -f` through the
registered `git` CLI provider. This is destructive, so `dry_run` defaults to
true and runs `git clean --dry-run -d` instead. The caller must pass explicit
`paths` or set `all_paths` to true; `paths` cannot be combined with
`all_paths=true`. Set `confirm_delete` to true and `dry_run` to false to delete
files.

Arguments:

```json
{
  "paths": ["build"],
  "all_paths": false,
  "include_ignored": false,
  "ignored_only": false,
  "dry_run": true,
  "confirm_delete": false,
  "timeout_ms": 30000
}
```

### `git.branch_create`

Creates a local branch ref with fixed
`git branch <name> <start_point>` argv through the registered `git` CLI
provider. This does not checkout or switch branches, fetch, push, set upstreams,
or change working-tree files. It defaults to dry-run and first runs deterministic
preflight checks:

- `git check-ref-format --branch <name>`
- `git show-ref --verify --quiet refs/heads/<name>`
- `git rev-parse --verify <start_point>^{commit}`

Set `confirm_create` to true and `dry_run` to false to create the branch after
those preflight checks pass.

Arguments:

```json
{
  "name": "feature/local-work",
  "start_point": "HEAD",
  "dry_run": true,
  "confirm_create": false,
  "timeout_ms": 30000
}
```

### `git.branch_delete`

Deletes one local branch ref with fixed `git branch -d <name>` or
`git branch -D <name>` argv through the registered `git` CLI provider. This
does not checkout or switch branches, fetch, push, delete remote branches, or
change working-tree files. It defaults to dry-run and first runs deterministic
preflight checks:

- `git check-ref-format --branch <name>`
- `git show-ref --verify --quiet refs/heads/<name>`
- `git branch --show-current`

The tool refuses to delete the current branch. Set `confirm_delete` to true and
`dry_run` to false to delete the branch after preflight checks pass. Set
`force` to true to use `git branch -D`; otherwise it uses `git branch -d`.

Arguments:

```json
{
  "name": "feature/local-work",
  "force": false,
  "dry_run": true,
  "confirm_delete": false,
  "timeout_ms": 30000
}
```

### `git.branch_rename`

Renames one local branch ref with fixed `git branch -m <old_name> <new_name>` or
`git branch -M <old_name> <new_name>` argv through the registered `git` CLI
provider. This does not checkout or switch branches, fetch, push, set upstreams,
delete remote branches, or change working-tree files. It defaults to dry-run and
first runs deterministic preflight checks:

- `git check-ref-format --branch <old_name>`
- `git check-ref-format --branch <new_name>`
- `git show-ref --verify --quiet refs/heads/<old_name>`
- `git show-ref --verify --quiet refs/heads/<new_name>`
- `git branch --show-current`

The tool allows renaming the currently checked-out branch because `git branch
-m/-M <old_name> <new_name>` preserves the checkout and only changes the local
branch ref. Set `confirm_rename` to true and `dry_run` to false to rename the
branch after preflight checks pass. Set `force` to true to use `git branch -M`;
otherwise the tool refuses to overwrite an existing local target branch.

Arguments:

```json
{
  "old_name": "feature/local-work",
  "new_name": "feature/local-work-renamed",
  "force": false,
  "dry_run": true,
  "confirm_rename": false,
  "timeout_ms": 30000
}
```

### `git.branch_switch`

Switches to one existing local branch with fixed
`git switch --no-guess <name>` argv through the registered `git` CLI provider.
This does not create branches, fetch, guess remote branches, detach HEAD, force
checkout, discard changes, merge, push, or set upstreams. Because `git switch`
does not provide a portable native dry-run option, `dry_run` means gateway
preflight only. The tool first runs deterministic preflight checks:

- `git check-ref-format --branch <name>`
- `git show-ref --verify --quiet refs/heads/<name>`
- `git branch --show-current`
- `git status --porcelain=v1 -z`

Set `confirm_switch` to true and `dry_run` to false to run the switch after
preflight checks pass. If the working tree has changes, the tool refuses a real
switch unless `allow_dirty` is true. Even with `allow_dirty`, the underlying
`git switch --no-guess` command may still reject conflicts; the gateway does not
force, merge, or discard changes.

Arguments:

```json
{
  "name": "feature/local-work",
  "dry_run": true,
  "confirm_switch": false,
  "allow_dirty": false,
  "timeout_ms": 30000
}
```

### `git.commit`

Creates a commit with `git commit -m <message>`. The message is required and
bounded to 10000 characters. Set `dry_run` to run `git commit --dry-run` without
creating a commit.

Arguments:

```json
{
  "message": "Update gateway atomics",
  "all": false,
  "allow_empty": false,
  "dry_run": false,
  "timeout_ms": 30000
}
```

### `git.stash_push`

Creates a stash with fixed `git stash push -m <message>` argv through the
registered `git` CLI provider. This changes the working tree and possibly the
index, so it is available only when explicitly enabled. The caller must pass
explicit `paths` or set `all_paths` to true; the tool will not silently stash
the whole workspace. Set `dry_run` to preview matching changes with read-only
`git status --porcelain=v1 -z` instead of creating a stash.

Arguments:

```json
{
  "message": "save focused work",
  "paths": ["Sources/ComputerMCP/GatewayToolRegistry.swift"],
  "all_paths": false,
  "include_untracked": false,
  "keep_index": false,
  "dry_run": false,
  "timeout_ms": 30000
}
```

## Computer Use

The Computer Use provider exposes generic macOS observation and input tools.
It requires the corresponding Screen Recording or Accessibility permission to
already belong to the signed app or active development executable; remote calls
never trigger permission prompts.

`computer.permissions`, `computer.displays`, and
`computer.pointer.position` do not request TCC access. The pointer tool returns
the current absolute point without moving it and is the intended source for a
subsequent read-only `computer.verify` call. Display discovery uses Core
Graphics when active-display metadata is available and falls back to AppKit
when a locked or background session reports an empty Core Graphics list.

Use `computer.windows` with narrow mechanical filters so an MCP client does not
need to consume a large unfiltered CoreGraphics window table:

```json
{
  "on_screen_only": true,
  "exclude_desktop_elements": true,
  "owner_name_contains": "Safari",
  "title_contains": "ChatGPT",
  "layer": 0,
  "minimum_alpha": 0.5,
  "case_sensitive": false,
  "max_results": 5
}
```

`owner_process_id` provides an exact PID filter. Owner and title matching is
case-insensitive by default. `max_results` defaults to 10 and is capped at 200;
filtering occurs before truncation.

## Full Shell

`shell.run`, `shell.spawn`, `shell.list`, `shell.read`, `shell.write`, and
`shell.cancel` are available only when the manifest enables Shell and the
eligible `chatgpt-operate` or `local-admin` profile grant enables Full Shell.

The plane supports explicit argv or shell-script mode, selected environment,
workspace/cwd binding, stdin, separate stdout/stderr cursors, timeout,
cancellation, exit status, signals, truncation metadata, and process-group
cleanup.

Full Shell gives the caller the current macOS user's effective terminal
authority. Prefer typed tools or registered CLI argv execution when that
authority is unnecessary.

For App-managed profiles, use `computer-mcp profile shell chatgpt-operate` to
enable the persisted grant after activating a manifest with
`policy.shell_enabled = true`. Use `--no-enabled` to disable it again.
