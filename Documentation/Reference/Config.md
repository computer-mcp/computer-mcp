# Configuration Reference

Computer MCP accepts one first-public-release contract:
`schema_version = 1`. Unknown fields, unsupported values, and any other schema
version are rejected.

| Data | Owner |
| --- | --- |
| Static policy, provider, and transport definitions | TOML manifest |
| Workspace grants, enabled state, and desired transport state | GRDB |
| Workspace filesystem access | security-scoped bookmarks |
| Tunnel tokens, Computer MCP Access Tokens, and provider secrets | Keychain |

Secrets are never rendered by `config show` or included in `config export`.

For offline export of embedded Codex execution settings into independently
owned plugin inputs, see [Codex Migration](CodexMigration.md).

## Minimal manifest

```toml
schema_version = 1

[server]
name = "computer-mcp"

[runtime]
caller = "secure-tunnel"
profile = "chatgpt-observe"

[policy]
default_timeout_ms = 30000
max_output_bytes = 1048576
shell_enabled = false

[[profiles]]
id = "chatgpt-observe"
capabilities = ["workspace.list", "workspace.describe", "file.read"]
workspaces = ["primary"]
allowed_callers = ["secure-tunnel"]

[[workspaces]]
id = "primary"
display_name = "Primary Workspace"

[builtin]
enabled = ["workspace.info", "system.time", "file.list", "file.read"]
```

An App-managed workspace omits `path`; the App resolves its bookmark. In an
explicit standalone manifest, a relative path resolves from the directory
containing the TOML file.

## Callers and profiles

Caller kinds are `secure-tunnel`, `cloudflare-tunnel`, `local-app`,
`local-cli`, and `local-mcp`. Built-in profile IDs are:

- `chatgpt-observe`
- `chatgpt-operate`
- `cloudflare-observe`
- `cloudflare-operate`
- `local-admin`

Third parties may define another validated ID with explicit capabilities,
workspaces, and callers:

```toml
[[profiles]]
id = "partner-observe"
capabilities = ["workspace.list", "system.time"]
workspaces = ["primary"]
allowed_callers = ["cloudflare-tunnel"]
full_shell_enabled = false
```

`local-admin` rejects remote callers. Full Shell is eligible only for
`chatgpt-operate` and `local-admin`, and requires both static
`policy.shell_enabled = true` and an explicit local profile grant.

`mcp_servers` grants the named registrations' MCP surface, intersected with each
registration's host tool selection and the profile's risk/workspace boundaries:

```toml
[[profiles]]
id = "chatgpt-operate"
mcp_servers = ["design"]
workspaces = ["primary"]
```

The IDs must reference configured MCP registrations and must be unique. This
grant is independent of current tool names: a registration with
`allow_any_tool = true` authorizes future discovered tools under the same host
risk policy. A whitelist continues to select exact names. The local host may
grant either choice to remote profiles; the remote caller cannot change these
settings. Configuration export and profile persistence retain registration IDs.

An explicit `mcp.tools.call` entry in `capabilities` grants the host-selected
tools across all registrations. Use `mcp_servers` for a narrower registration
scope, or an exact alias/reexport capability for one underlying tool. Aliases,
reexports, and generic calls share that tool's authority. Discovery capabilities
alone do not authorize downstream tools. Generic resource, prompt, event, and
request capabilities explicitly grant their respective surface across
registrations; a tool-only grant does not imply those surfaces.

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
```

Desired running IDs remain in GRDB. OpenAI API keys, Cloudflare Tunnel Tokens,
and generated Computer MCP Access Tokens use canonical accounts in the signed
App's environment-specific Data Protection Keychain service and never appear
in TOML.

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
constructs its workspace and profile sections from the current App-managed
registrations and grants.

## Provider examples

CLI providers support a mechanical argv contract:

```toml
[[cli.commands]]
id = "git"
executable = "git"
cwd = "workspace"
allow_any_args = true
risk = "workspace-write-capable"
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

`tool_risks` contains host classifications, independent of tool selection.
Values are `read-only`, `workspace-write`, `external-write`, `destructive`, or
`full-shell`. Unclassified downstream tools have `external-write` risk even
when their MCP annotations claim read-only behavior. A configured MCP mapping's
`risk` applies to the same underlying tool across aliases and reexports;
conflicting host declarations are rejected. Classification alone does not
select a tool or grant a profile access. The built-in observe profiles accept
only host-classified read-only capabilities, including when their capability
grant contains `*`.

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

## Codex configuration import

Codex execution is configured in the independent adapter's JSON file. The
host accepts `[codex]` fields for lossless configuration migration. These fields
do not configure a running plugin. Runtime creation rejects
`enabled = true`: first export and review the adapter configuration and plugin
settings with [config migrate-codex](CodexMigration.md). This does not start an
executor or migrate a live database.

The migration report places execution settings in `adapterConfiguration` and
omits `[codex]` from `hostTOML`. Ordinary configuration import/export preserves
an explicitly supplied `[codex]` section until this migration is requested;
configurations without that section do not acquire one during export.

The host's elevation tools report matching host grants for the next eligible
start. Their `effective_sandbox` is `null` when no grant matches, and
`danger-full-access` when a matching grant is available. They do not infer a
plugin's baseline or a running turn's permissions from imported settings.
Use the adapter's runtime diagnostics for applied sandbox state. Approval and
revocation leave an already running turn unchanged.

The importable fields are:

```toml
[codex]
enabled = false
executable = "codex"
app_server_enabled = true
exec_enabled = true
mcp_enabled = true
experimental_api = true
app_server_request_timeout_seconds = 30
app_server_app_list_timeout_seconds = 120
app_server_termination_grace_milliseconds = 1000
app_server_kill_grace_milliseconds = 2000
app_server_approval_timeout_seconds = 300
app_server_auto_approve_workspace_writes = false
sandbox = "workspace-write"
approval_policy = "never"
```

In the adapter, App Server, Exec, and MCP are separate `swift-codex` lifecycles. Remote callers
receive only exact granted tool IDs and cannot supply arbitrary Codex argv or
configuration overrides. `app_server_request_timeout_seconds` bounds a normal
complete App Server call, including connection startup, workspace validation,
the reviewed RPC, and the single fresh-connection retry available to read-only
calls. The first read-only attempt receives half of that budget; writes are
never retried. `app_server_app_list_timeout_seconds` separately bounds
`app/list`, whose first bounded page may follow a multi-megabyte upstream
directory snapshot. That request uses one process generation because restarting
mid-snapshot would repeat the same work. A deadline is recorded as a recoverable
request failure, independently from runtime, connection, and process state. If
the connection must be replaced, Computer MCP completes its separately bounded
retirement before a read-only retry; cancellation cannot start a later
generation after the request has resolved.

`app_server_termination_grace_milliseconds` is the EOF and TERM grace interval
(0–30000 ms). `app_server_kill_grace_milliseconds` is the final reaping wait
after KILL (100–30000 ms). `app_server_approval_timeout_seconds` bounds a live
approval request (1–3600 seconds). Automatic workspace-write approval is off by
default; enabling it does not bypass caller, profile, workspace, path, risk, or
capability policy.

The manifest cannot set `sandbox = "danger-full-access"`, and a caller cannot
smuggle the value through aliases, spelling changes, nested parameters, or raw
Codex configuration. Temporary full access is available only through a durable
`codex.app.elevation.request` followed by an exact local-admin approval. It is
bound to the requesting workspace/profile/caller/connection and optional
thread, activates only on a future eligible start, and expires or can be
revoked. There is deliberately no global or persistent always-full-access
configuration switch.

Exec requests deliberately ignore the user's global Codex `config.toml` while
continuing to use that user's `CODEX_HOME` authentication. This prevents global
MCP servers, models, hooks, profiles, or defaults from changing an embedded
Gateway request. Computer MCP supplies the registered workspace, sandbox, and
approval policy explicitly. App Server and MCP remain independent provider
lifecycles and keep their own upstream configuration contracts.

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
