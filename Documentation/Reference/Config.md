# Configuration Reference

Computer MCP accepts one first-public-release contract:
`schema_version = 1`. Unknown fields, unsupported values, and any other schema
version are rejected.

| Data | Owner |
| --- | --- |
| Static policy, provider, and transport definitions | TOML manifest |
| App-managed permission grants/revisions, enabled state, and desired transport state | GRDB |
| Project filesystem access | security-scoped bookmarks |
| Tunnel tokens, Computer MCP Access Tokens, and provider secrets | Keychain |

Secrets are never rendered by `config show` or included in `config export`.

## Minimal manifest

```toml
schema_version = 1

[server]
name = "computer-mcp"

[runtime]
caller = "secure-tunnel"
profile = "chatgpt-observe"

[policy]
default_timeout_ms = 120000
max_output_bytes = 8388608
shell_enabled = false

[[profiles]]
id = "chatgpt-observe"
allowed_callers = ["secure-tunnel"]
full_access = false

[profiles.permissions]
machine = "allow"
skills = "allow"

[profiles.projects]
primary = { access = "read", network = "none" }

[[projects]]
id = "primary"
display_name = "Primary Project"

[builtin]
enabled = ["project.info", "system.time", "file.list", "file.read"]
```

An App-managed project omits `path`; the App resolves its bookmark. In an
explicit standalone manifest, a relative path resolves from the directory
containing the TOML file.


Profile declarations publish with the manifest transaction. Changing or adding a
profile declaration updates its live permissions; removing a custom declaration
retires that profile. Removing an explicit built-in declaration restores its
Machine information and Skills defaults. When a declaration stays unchanged,
local owner edits to the saved profile remain effective. The host records the
last published declarations so a restart can distinguish these cases. A failed
or stale manifest activation leaves profile authority unchanged.

## Callers and profiles

Caller kinds are `secure-tunnel`, `cloudflare-tunnel`, `local-app`,
`local-cli`, and `local-mcp`. Built-in profile IDs are:

- `chatgpt-observe`
- `chatgpt-operate`
- `cloudflare-observe`
- `cloudflare-operate`
- `local-admin`

Profiles store permissions, execution mode and per-project network settings. Their
names do not confer authority. `local-admin` is a reserved local-only admission
identity. Principals created by the App start with Machine information and Skills.
An explicit manifest profile has exactly the permissions it lists, including when
it uses a built-in profile ID; omitted entries do not receive those defaults.
An omitted permission is requestable; `deny` is an explicit refusal that does not create a request.

```toml
[[profiles]]
id = "partner-observe"
allowed_callers = ["cloudflare-tunnel"]
full_access = false

[profiles.permissions]
machine = "allow"
skills = "allow"
screen = "allow"
desktop-control = "deny"

[profiles.projects]
primary = { access = "read", network = "none" }

[profiles.files_and_folders]
downloads = "read"

[profiles.plugins]
codex = "use"

[profiles.mcp_servers]
design = "read"
```

| Table | Values |
| --- | --- |
| `permissions` | `screen`, `desktop-control`, `local-network`, `machine`, `unified-logs`, `skills`: `allow` or `deny` |
| `projects` | Per project: `access` is `read`, `write` or `deny`; `network` is `none`, `trusted`, `full` or a custom table |
| `files_and_folders` | Per category: `read` or `deny` |
| `plugins` | Per plugin ID: `use` or `deny` |
| `mcp_servers` | Per directly registered server ID: `read`, `all` or `deny` |

Project, plugin and MCP server tables accept `"*"` as a fallback. A concrete entry
replaces the fallback for that object. Project access and network resolve their
fallbacks independently; absent network settings mean none. A custom network
entry is `{ level = "custom", hosts = ["example.com"], include_trusted = false }`.
Files and Folders categories are `desktop`, `documents`, `downloads`,
`icloud-drive`, `network-volumes` and `removable-volumes`.

`full_access = true` permits the owner to consent to Full access for a connection;
it grants no permission by itself. Apple events are blocked in the sandbox. A
principal whose programs control other apps needs Full access, where macOS asks
for consent under each program's own identity. Managed limits can further narrow
permissions, network access, execution mode and resource limits.
`policy.shell_enabled` remains false by default. See the current
[execution availability and launch scopes](../Architecture/SecurityAndPrivacy.md#execution-admission)
for host helpers, local stdio MCP, plugin programs and remote HTTP services.

MCP `read` permits listing, resources, prompts and host-classified read-only tools;
`all` permits the server's selected surface. Both intersect with the registration's
`allowed_tools` or `allow_any_tool` selection. Plugin contributions require the
owning Plugin permission. Aliases, reexports and generic calls resolve to the same
host-owned target and requirements; discovery never grants tool execution.

Permission revisions belong to the host and cannot be set in TOML. App/CLI edits
compare the reviewed revision, update the shared profile and reconcile requests,
consent and running executions atomically. Export writes the permission tables.
Retired profile fields are rejected even when empty or false. Their replacements
are:

| Retired input | Current replacement |
| --- | --- |
| `mode` | `full_access` plus the permission tables; mode alone grants no permission. |
| `capabilities` | `permissions`, `projects`, `plugins` and `mcp_servers` tables. |
| `workspaces` | `projects` table with per-project `access` and `network`. |
| `full_shell_enabled` | `full_access`, with local owner consent. |
| `confirmation_policy` | Permission grants; calls within their grants execute directly. |
| `authorization_revision` | Host-owned authorization revisions; omit from TOML. |
| `projects` array | `projects` table with `access` and `network` entries. |
| `mcp_servers` array | `mcp_servers` table with `read`, `all` or `deny` entries. |

## Managed limits

Managed limits cap permissions; they never grant them. The sources are:

| Source | Location and control |
| --- | --- |
| Machine file | `/Library/Application Support/Computer MCP/policy.toml`; a protected administrator-owned regular file. The entire parent chain must resist replacement; symlinks and writable parents, including mutation grants in ACLs, are rejected. |
| Managed preferences | Forced `Policy` key in the `com.showxu.computer-mcp` preferences domain, containing a UTF-8 TOML string in the same format. Ordinary user preferences do not supply this source. |
| Owner policy | Per-profile policy stored in the permission database. It currently has no owner-facing setting: neither the App nor the public CLI can set it. Profile permissions and connection limits are separate controls. |
| Connection limits | `clients limit` or `profile.limit`, using [ManagedPolicy JSON](#managedpolicy-json); can only narrow the existing connection ceiling. |

Each TOML document is bounded to 1 MiB. Its top-level fields are:

| Field | Shape and default when omitted |
| --- | --- |
| `permissions` | Same permission keys as a profile; `allow` or `deny`. Missing entries impose no ceiling. |
| `projects` | Project ID or `"*"` → `read`, `write` or `deny` (a scalar value, not the profile's access/network table). |
| `files_and_folders` | Folder category → `read` or `deny`. |
| `plugins` | Plugin ID or `"*"` → `use` or `deny`. |
| `mcp_servers` | Server ID or `"*"` → `read`, `all` or `deny`. |
| `full_access`, `remote_full_access` | Booleans, both default `true`; remote callers must satisfy both. |
| `network` | `none`, `trusted`, `full`, or `{ level = "custom", hosts = [...], include_trusted = false }`; defaults to `full`. The [trusted host list](../Architecture/ExecutionEnvironment.md#outbound-connections) is fixed by the host. |
| `denied_read_locations` | Array of absolute normalized paths, default empty. Paths resolve through their nearest accessible prefix; missing or protected suffixes stay denied. |
| `execution` | Optional positive integer ceilings: `time_ms`, `output_bytes`, `memory_bytes`, `retention_seconds`, `retained_output_bytes`. Omitted dimensions impose no additional ceiling. Unsupported enforcement, including memory ceilings on a backend without it, refuses execution. |

For example, a machine file can cap all projects at Read, block remote Full access
and restrict network destinations without granting access to any of them:

```toml
remote_full_access = false
network = { level = "custom", hosts = ["github.com"], include_trusted = false }
denied_read_locations = ["/Users/Shared/Private"]

[permissions]
screen = "deny"

[projects]
"*" = "read"

[execution]
time_ms = 30000
output_bytes = 1048576
retention_seconds = 3600
retained_output_bytes = 8388608
```

Each source resolves its concrete entries before its `*` fallback. Across sources,
permission levels and numeric ceilings take the strictest value, every Boolean
must allow, denied paths accumulate, and each network destination must satisfy
every source. Absent sources impose no ceiling. An existing unreadable, malformed
or unprotected source fails closed for every dimension it can limit; an unknown
field is malformed. Nonblocking file checks also handle FIFO locations safely.
Local owner diagnostics and revocation remain available. The owner projection
shows source identity, revision and bounded failure diagnostics without exposing
policy contents. Unchanged meaning preserves authority evidence; tightening
resource ceilings also affects running work and retained output.

### ManagedPolicy JSON

The control interfaces accept the Codable `ManagedPolicy` object, not the TOML
profile shape. Keys are camelCase. A complete draft that disables Full access and
network access, without adding permission ceilings, is:

```json
{
  "identity": {"id": "00000000-0000-0000-0000-000000000000", "generation": 0, "isEdited": false},
  "permissionCeilings": {"entries": [], "grantIDs": []},
  "allowsFullAccess": false,
  "network": {"configuration": {"none": {}}, "customRules": []},
  "executionLimits": {"timeMilliseconds": 30000, "outputBytes": 1048576},
  "deniedReadRules": []
}
```

All six top-level keys are required. Optional numeric ceiling members may be
omitted or null; present values must be positive. `executionLimits` also accepts
`memoryBytes`, `retentionSeconds` and `retainedOutputBytes`.

- `identity` contains UUID `id`, unsigned `generation` and Boolean `isEdited`.
  New draft identities use the zero values above. Existing snapshots retain their
  identities; the host owns committed identities and generations.
- `permissionCeilings.entries` and `grantIDs` are alternating key/value arrays,
  because permission keys are enums. A permission is `{"screen": {}}`,
  `{"desktopControl": {}}`, `{"localNetwork": {}}`, `{"machineInformation": {}}`,
  `{"unifiedLogs": {}}`, `{"skills": {}}`, `{"project": {"_0": "project-id"}}`,
  `{"plugin": {"_0": "plugin-id"}}`, `{"mcpServer": {"_0": "server-id"}}`, or
  `{"filesAndFolders": {"_0": "downloads"}}`. Folder values are `desktop`,
  `documents`, `downloads`, `iCloudDrive`, `networkVolumes`, `removableVolumes`.
  A state is `{"denied": {}}`, `{"notGranted": {}}`, or
  `{"granted": {"_0": "read"}}` (also `write`, `use`, `all`, `access`, as allowed
  by that permission). Every granted entry needs a matching key and identity in
  `grantIDs`; denied and notGranted entries have none. For example, a Screen
  denial is `"entries": [{"screen": {}}, {"denied": {}}]`, `"grantIDs": []`.
- `network.configuration` is `{"none": {}}`, `{"full": {}}`, `{"trusted": {}}`,
  or `{"custom": {"hosts": ["example.com"], "includesTrusted": false}}`.
  `customRules` contains `{ "identity": <identity>, "host": "example.com" }`
  for each custom host. Full and trusted configurations carry `fullRule` or
  `trustedRule` identities respectively; custom configurations including trusted
  hosts also carry `trustedRule`.
- `deniedReadRules` contains objects with `identity`, `root` (an absolute normalized
  path string), and `kind: {"denied": {}}`.

Use fresh draft identities for new rules or preserve the matching identities from
a reviewed connection snapshot. Submission still needs the reviewed connection
revision and must be no broader than its current limits. This shape grants no
permission and cannot change the machine or owner policy.

## Transport definitions

Non-secret OpenAI and Cloudflare definitions live in the manifest:

```toml
[[transports.openai]]
id = "chatgpt"
tunnel_client_profile = "computer-mcp"
tunnel_id = "tunnel_example"
gateway_profile = "chatgpt-observe"
tunnel_client_path = "/usr/local/bin/tunnel-client"
http_proxy = "http://127.0.0.1:6152"
requires_api_key = true

[[transports.cloudflare]]
id = "partner"
tunnel_name = "computer-mcp-release"
public_hostname = "mcp.example.com"
gateway_profile = "cloudflare-observe"
local_port = 8765
metrics_port = 20241
cloudflared_path = "/usr/local/bin/cloudflared"
oauth_enabled = false
oauth_client_allowlist = ["claude.ai", "claude.com"]
```

Desired running IDs remain in GRDB. OpenAI API keys, Cloudflare Tunnel Tokens,
and generated Computer MCP Access Tokens use canonical accounts in the signed
App's environment-specific Data Protection Keychain service and never appear
in TOML.

`oauth_enabled` defaults to `false`. When enabled, the connection's public HTTPS
origin serves OAuth discovery, pairing, token and revocation routes. The
`oauth_client_allowlist` contains exact lowercase CIMD hostnames, with no wildcard,
scheme, port or path; its default is `claude.ai` and `claude.com`. An empty list
admits no new clients. The owner control plane can update both settings while the
listener is running. Omitting them from an existing connection's CLI save
preserves their current values. Each locally approved grant selects its own
remote gateway profile; `gateway_profile` remains the Access Token's profile.
See [Cloudflare OAuth pairing](CloudflareRunbook.md#oauth-client-pairing).

`http_proxy` is optional. When it is absent, the App follows the active fixed
macOS HTTPS proxy and then the fixed HTTP proxy; an explicit value takes
precedence. Only `http://` and `https://` proxy URLs are accepted. Credentials,
queries, fragments, and non-root paths are rejected so secrets cannot enter the
manifest, process arguments, or logs. Proxy auto-configuration scripts are not
evaluated by Computer MCP.

## Validate, export, and import

```sh
computer-mcp config show
computer-mcp config validate
computer-mcp config export --output public-settings.toml
computer-mcp config import --input candidate.toml
computer-mcp config import --input candidate.toml \
  --apply --expected-current-digest <preview-digest>
```

Export is secret-free. Import accepts only the current schema, validates the
candidate, and returns a structural diff before applying. Apply uses the
current digest to prevent races and never changes the desired state of a
transport. `config show` preserves the active static manifest. `config export`
constructs its project and profile sections from the current App-managed
registrations and grants.

## Provider examples

The generated default manifest discovers Codex from the process's `PATH`, then
known installation locations, and stores the selected absolute entry path.
Symbolic links are preserved so an installer can update their targets without
changing the manifest; for Homebrew this is `/opt/homebrew/bin/codex`. If Codex
is unavailable, the default is the command name `codex`. Existing manifests
retain their configured executable until explicitly edited.

CLI providers support a mechanical argv contract:

```toml
[[cli.commands]]
id = "git"
executable = "git"
cwd = "project"
allow_any_args = true
risk = "project-write-capable"
discovery = ["help"]

[cli.commands.interface]
path_style = "argv"
flag_style = "long_flags"
flag_case = "kebab"
value_style = "separate"
```

An optional `tree` source instead projects validated typed MCP tools; it requires
`allow_any_args = false`. File, native exporter, and helper sources share the
[CLI Tree contract](CLITrees.md). Interface style hints alone do not constitute
a discovered command tree.

Downstream MCP providers use a host-owned tool selection:

```toml
[[mcp.servers]]
id = "design"
transport = "streamable_http"
url = "https://mcp.example.com/mcp"
exposure = "gateway"
allowed_tools = ["get_screenshot", "get_design_context"]
capabilities = ["tools", "resources", "prompts"]

[mcp.servers.tool_risks]
get_screenshot = "read-only"
get_design_context = "read-only"
```

`enabled` defaults to `true` for directly registered MCP servers. Set it to
`false` to retain a registration's launch settings and profile references while
excluding its tools, mapped aliases and session capabilities from the gateway.
The App's new-registration editor starts disabled. Manual registration changes
are available through the App and [`mcp` management commands](CLI.md#manual-mcp-registrations).

`allowed_tools` is the host's exact tool selection; an explicitly empty list
grants no tool calls, including configured aliases. `allow_any_tool = true`
and a nonempty `allowed_tools` list conflict. For a document that omits both
selection fields, configured MCP `[[tools]]` mappings are normalized into the
server's explicit whitelist when decoded, and export retains that selection.
Explicit selection fields take precedence over mappings.

### Downstream risk and permission values

`tool_risks` contains host classifications, independently of tool selection.
The host takes the higher of configured risk and a valid downstream declaration.
These values map to the following requirements for directly registered servers:

| Effective risk | MCP server permission | Project permission when the call names a project | Full access required |
| --- | --- | --- | --- |
| `read-only` | `read` (also satisfied by `all`) | `read` | No |
| `project-write` | `all` | `write` | No |
| `external-write` | `all` | `write` | No |
| `destructive` | `all` | `write` | No |
| `full-shell` (the current wire value for execution risk) | `all` | `write` | Yes for remote HTTP servers; local stdio follows the program execution path |

`full-shell` remains the accepted risk field value; it does not name a profile
permission. Plugin-owned servers require Plugin `use` in place of the directly
registered MCP server permission. Declared host provisioning/removal actions also
require Source Project `write`. Each target's path and execution requirements
remain conjunctive. See [execution availability](../Architecture/SecurityAndPrivacy.md#execution-admission).

Unclassified downstream tools default to `external-write` even when MCP annotations
claim read-only behavior. A configured MCP mapping's `risk` applies to the same
underlying tool across aliases and reexports; conflicting host declarations are
rejected. Classification alone selects no tool and grants no permission. An MCP
server permission of `read` accepts only host-classified read-only tools, even
when `allow_any_tool = true`. These mappings apply to downstream MCP risk; builtin
and CLI tool requirements come from their own catalog declarations.

Local stdio providers use a fixed command and argv. Re-export requires an explicit
`prefix`: a nonempty prefix produces `<prefix>.<downstream-name>`; `prefix = ""`
preserves the downstream tool name exactly. Nonempty prefixes must be unique.
Multiple native-name registrations may coexist only when their discovered names
are disjoint. No registration may shadow a built-in or host management tool;
initialization rejects collisions and a failed refresh preserves the last
validated routes. Names are not grants: selection, registration identity and
host risk policy remain authoritative. An empty selection exposes no tools.
Persistent sessions support tools, resources, templates, prompts, cancellation,
notifications, and reconnect.

`startup_timeout_ms` bounds connection and MCP initialization;
`request_timeout_ms` bounds the operation after that connection is ready.
Each defaults to 30,000 ms. A slow initialization does not consume a tool
request's budget, and a long request budget does not extend startup. Timeout
errors identify the stage. An expired connection is invalidated; a timed-out
tool call is never automatically replayed.

### HTTP credentials

An HTTP registration can bind a host-owned Keychain bearer token:

```toml
[mcp.servers.authentication]
endpoint = "https://mcp.example.com/mcp"
keychain_account = "mcp.example"
```

Place this table under its `[[mcp.servers]]` entry. `endpoint` must exactly match
that registration's `url`. HTTPS is required except for loopback HTTP. URLs
with embedded credentials or fragments are rejected. The table contains a
reference, never the token. Omit it for anonymous HTTP; stdio registrations use
their existing process environment and reject this table.

Plugin MCP host settings accept the same `authentication` object. It is not a
package manifest field. An update that changes the package's HTTP destination
cannot use an existing binding for a different destination.

Save or remove the token using **Manage credential** in the App's MCP list, or
`mcp credential status/set/remove`. The credential status supplies the binding
digest required for a CLI mutation; a changed registration/source invalidates
that digest. Removing an integration retains user-owned credentials. Removing
a credential retains its registration, selection and profile grants.

Every new HTTP exchange resolves the current Keychain value without prompting.
Missing, inaccessible or malformed credentials fail closed. The App's actual
Keychain identity must have access; standalone `--config` runtimes have no App
Keychain provider and report unavailable rather than sending an anonymous
request. Tokens are not passed to child processes, persisted in configuration,
returned in status, or included in credential-operation audit digests.

This is host-supplied bearer-token authentication, not automatic OAuth discovery,
sign-in or refresh. Obtain tokens using the provider's supported flow. Rotation
affects subsequent requests, not already issued requests or the provider's token
revocation state. HTTP redirects are rejected, including same-origin redirects,
so a write cannot be replayed implicitly or a credential forwarded elsewhere.

### Scoped stdio host services

`host_services = true` explicitly delegates the originating Gateway scope to a
trusted owned stdio adapter over a private inherited MCP connection. It defaults
to false and is rejected for HTTP registrations. It neither changes the tool
selection nor grants local administration. The reserved descriptor cannot be
supplied through registration environment overrides. See
[Scoped host services](HostServices.md) for the callback and ownership contract.

## Standalone HTTP

Explicit development mode may configure loopback Streamable HTTP:

```toml
[server.http]
host = "127.0.0.1"
port = 8765
path = "/mcp"
health_path = "/health"
access_token_env = "COMPUTER_MCP_HTTP_ACCESS_TOKEN"
```

## Worktree availability

Worktree lifecycle tools use durable host storage: App distribution storage or
regions beside a standalone database. Memory-only hosts omit the routes. Enable
`git.worktree_add`, `git.worktree_list`, `git.worktree_remove` and `git.merge` in
`[builtin].enabled`; the defaults already include them. The source Project grant
and effective sandbox settings apply to derived projects on every call. Shell
execution also requires `[policy].shell_enabled = true` and its declared limits
and permissions. See [Worktrees](Worktrees.md).

New manifests reject `git.worktrees` and the two retired delivery builtin IDs.
During installed-manifest upgrade, `git.worktrees` becomes `git.worktree_list`;
`delivery.apply` and `delivery.scopes.list` are removed from the enabled builtin
list. The startup report identifies removed IDs; see
[Permission store activation](#permission-store-activation) for diagnostic channels.
The frozen permission migration catalog
retains its historical classifications. Stored configuration revisions are unchanged.

A `delivery` configuration section still fails with worktree replacement guidance:
it represents work state, so reconcile unfinished work with its existing owner
before replacing it. Configuration loading does not delete historical journals.

## Permission store activation

Startup activates permission profiles before admitting client calls. Conversion
uses a fixed migration catalog and a consistent snapshot of profiles, projects,
aliases and plugin origins; it does not launch providers. The transaction binds
converted authority to the external epoch, advances revisions, clears saved
connection consent and removes the obsolete ticket table. Derived-project source
relationships preserve ownership and receipt provenance. A completed activation
is idempotent, including after later profile edits. A non-empty upgrade report
appears once at activation: in the App's `computer-mcp.jsonl` log
(`permissions.upgrade`), or on standalone CLI stderr. It lists removed builtin
IDs and the total number of dropped grants; grant payloads and profile details
are omitted. Subsequent startup without an upgrade emits no notice.
Project network access starts at `none`, including when the old profile enabled
`file.download`. A destination that needs access produces a request; an Always
answer adds that host to the project's `custom` list.

App-owned legacy manifests are converted through the existing manifest transaction.
Standalone files are user-owned and must use the current table format. With a
current manifest, startup can convert a legacy standalone database using the
captured catalog and saved legacy grants, then publish the explicitly supplied
profile declarations. The manifest bytes remain unchanged. App-managed databases
cannot be adopted by standalone; use a separate database and the App control
socket for App-owned state. Database restore detection suspends standing authority until owner confirmation and discards
transient requests and answers. Historical project-terminology migration records
retain their original contract; activation does not make their old profile format
an accepted runtime input.

A database migration converts stored profiles from their effective
authorization (wildcards expanded against registered tools, projects and
servers):

| Old | New |
| --- | --- |
| `local-full-access` with Full Shell | `full_access = true` (consent still per connection or saved trust); projects at `write` |
| `local-full-access` without Full Shell, or `workspace-operations` | sandbox; each project at `write` if the profile held any project write tool, else `read` |
| Workspace `*` | project `*` at the same access, so projects registered later stay covered |
| `read-only` | sandbox; each project at `read`; only Screen, Machine information, Unified logs and Skills can be granted |
| Any tool of a per-principal permission | that permission, subject to the row above; `logs.query` maps to Unified logs |
| Network-using project tools (`file.download`) | network access `none`; each host the tool reaches produces a request that adds the host to the project's `custom` list |
| `mcp.tools.call` | `"*"` at `all`, or at `read` for a `read-only` profile; downstream tools classified as execution need Full access, as they needed Full Shell |
| MCP listing, resource, prompt, event and request-reading tools without `mcp.tools.call` | `"*"` at `read`, the servers they applied to; `mcp.requests.cancel` and `mcp.connections.close` held without `mcp.tools.call` are dropped and reported |
| `mcpServerIDs` | each server at `all`, or at `read` for a `read-only` profile |
| Individual downstream tools or aliases | each tool's current server, at `read` if every granted tool of that server is read-only and the profile allowed no more, else at `all`; unresolvable grants are dropped and reported |
| Plugins | Plugin `*` at `use` for profiles that held any plugin contribution, else not granted |
| `confirmation_policy` | removed |

Files and Folders, Local network and managed limits are new and start not
granted or empty. Widened: profiles that held some tools of a permission
receive the whole permission, and calls a confirmation policy held now
execute. Narrowed: sandboxed principals write only in worktrees, so projects
whose root is not a Git repository's top level become read-only to them;
their programs run in the sandbox, where they cannot send Apple events;
`file.download` asks once for each new host; `git.branch_create`, `rename`,
`switch`, `git.tag_*` and `git.stash_push` need Full access.

Conversion derives Machine information and Skills from the old effective tool grants;
it does not insert them when those grants are absent.
