---
name: computer-mcp-config
description: Generate, review, import, and validate Computer MCP schema 1 manifests. Use for static provider, policy, transport, caller/profile, workspace-declaration, Codex, Skills, CLI, and downstream MCP configuration. Never place secrets, live process state, App bookmarks, or dynamic planning in TOML.
---

# Computer MCP Config

## Ownership

- Manifest: static policy, providers, transports, profile capabilities, and
  allowed callers.
- GRDB: workspace grants and expected lifecycle state.
- Keychain: OpenAI/Cloudflare/provider credentials and gateway bearer.
- App bookmarks: workspace filesystem authorization.

Never copy a secret into TOML, examples, logs, diffs, or diagnostics.

## Workflow

1. Use `schema_version = 1`; every other version and every unknown field is
   rejected.
2. Give every declared workspace a stable id; omit its path when the App owns a
   bookmark.
3. Bind each profile to exact capabilities, workspace ids, and
   `allowed_callers`.
4. Use the built-ins `chatgpt-observe`, `chatgpt-operate`,
   `cloudflare-observe`, `cloudflare-operate`, or local-only `local-admin`, or
   define a validated custom id.
5. Keep Shell, generic CLI execution, and process spawning disabled for remote
   callers.
6. Use two-phase `config import`; applying must not start a transport.

```toml
schema_version = 1

[runtime]
caller = "secure-tunnel"
profile = "chatgpt-observe"

[[workspaces]]
id = "primary"
display_name = "Primary Workspace"

[[profiles]]
id = "chatgpt-observe"
capabilities = ["workspace.list", "workspace.describe", "file.read"]
workspaces = ["primary"]
allowed_callers = ["secure-tunnel"]
```

## Providers

Inspect real CLI `--help`, schema, and dry-run behavior. Store only mechanical
argv conventions. The MCP flow is `cli.describe -> cli.help -> cli.exec`; do
not generate a top-level MCP tool for every subcommand.

Downstream MCP must preserve live schemas. Prefer fixed `mcp.*` proxy tools and
explicit remote `allowed_tools`. Re-export requires a unique prefix and catalog
drift review.

Codex uses three independent `swift-codex` paths:

```toml
[codex]
enabled = true
executable = "codex"
app_server_enabled = true
exec_enabled = true
mcp_enabled = true
experimental_api = true
app_server_request_timeout_seconds = 30
sandbox = "workspace-write"
approval_policy = "never"
```

Do not expose raw Codex argv/config overrides or `danger-full-access` remotely.

## Transport rules

- OpenAI Connector uses the App-owned Secure MCP Tunnel bridge/socket.
- Cloudflare uses an App-owned loopback Streamable HTTP origin, gateway bearer,
  named remotely-managed tunnel, Keychain token, and temporary `0600` token
  file.
- Quick Tunnel and anonymous production endpoints are invalid.
- Cloudflare Access consumer service tokens are external consumer-owned.

## Validation

```sh
swift run computer-mcp config validate --config <path>
swift run computer-mcp tools list --config <path>
swift run computer-mcp config validate --connect --config <path>
```

`--connect` may start configured providers or make network requests. Run root
Swift Testing after changing checked-in examples.
