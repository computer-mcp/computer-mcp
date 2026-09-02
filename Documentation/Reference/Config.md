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

CLI providers describe a mechanical argv contract:

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

Remote downstream MCP providers require an explicit allowlist:

```toml
[[mcp.servers]]
id = "design"
transport = "streamable_http"
url = "https://mcp.example.com/mcp"
exposure = "gateway"
allowed_tools = ["get_screenshot", "get_design_context"]
capabilities = ["tools", "resources", "prompts"]
```

Local stdio providers use a fixed command and argv. Re-export requires a unique
prefix and reviewed catalog. Persistent sessions support tools, resources,
templates, prompts, cancellation, notifications, and reconnect.

## Codex

```toml
[codex]
enabled = true
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

App Server, Exec, and MCP are separate `swift-codex` lifecycles. Remote callers
receive only exact granted tool IDs and cannot supply arbitrary Codex argv or
configuration overrides. `app_server_request_timeout_seconds` bounds a normal
complete App Server call, including connection startup, workspace validation,
the reviewed RPC, and the single fresh-connection retry available to read-only
calls. The first read-only attempt receives half of that budget; writes are
never retried. `app_server_app_list_timeout_seconds` separately bounds
`app/list`, whose first bounded page may follow a multi-megabyte upstream
directory snapshot. That request uses one process generation because restarting
mid-snapshot would repeat the same work. After either deadline, Computer MCP
completes the separately bounded process-group teardown before returning, and
cancellation cannot start a later generation.

`app_server_termination_grace_milliseconds` is the EOF and TERM grace interval
(0–30000 ms). `app_server_kill_grace_milliseconds` is the final reaping wait
after KILL (100–30000 ms). `app_server_approval_timeout_seconds` bounds a live
approval request (1–3600 seconds). Automatic workspace-write approval is off by
default; enabling it does not bypass caller, profile, workspace, path, risk, or
capability policy.

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
