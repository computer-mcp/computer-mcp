# Getting Started

Build and test the root package:

```sh
/usr/bin/swift build
/usr/bin/swift test
Scripts/build-app.sh
open "dist/Computer MCP.app"
```

The App owns the manifest, database, bookmarks, Keychain secrets,
gateway socket, providers, transports, and audit stream. Add workspaces and
review profile grants before enabling a transport.

Normal App use does not require a TOML file. On first launch, choose the local
MCP, ChatGPT, or Cloudflare path. Home shows the one action that currently
blocks readiness, while the remote pages keep setup, retry, fallback, and real
request verification together.

Install the signed embedded CLI from the App. It links to
`~/.local/bin/computer-mcp` and uses the App's owner-only control socket:

```sh
computer-mcp app status
computer-mcp workspace list
computer-mcp profile list
computer-mcp tools list
computer-mcp doctor --journey local
```

Register the App-owned bridge with Codex after reviewing the generated command:

```sh
computer-mcp install codex --app --dry-run
computer-mcp install codex --app
```

OpenAI Secure MCP Tunnel and Cloudflare named tunnel are independent App-owned
transports. Configure, diagnose, and start them separately:

```sh
computer-mcp tunnel openai list
computer-mcp tunnel cloudflare list
computer-mcp doctor --journey chatgpt
computer-mcp doctor --journey cloudflare --json
```

`doctor` JSON uses stable `schema_version: 1`, contains only redacted targets,
and exits successfully only when the selected path is `ready` or `verified`.

Schema 1 manifests declare static providers, policy, and profile
`allowed_callers`. Runtime workspace grants live in GRDB and secrets remain in
Keychain.

## Standalone development

Explicit standalone mode does not use App state:

```sh
swift run computer-mcp config validate --config Examples/computer-mcp.toml
swift run computer-mcp tools list --config Examples/computer-mcp.toml
swift run computer-mcp serve stdio --config Examples/computer-mcp.toml
```

Do not run it as a second service owner.

## Validation

Real Apps, tunnels, external CLIs, ChatGPT, and browsers are maintained in the
independent Computer MCP Validation Suite:

```sh
/usr/bin/swift test --package-path Tools/Validation
/usr/bin/swift run --package-path Tools/Validation \
  computer-mcp-validate test-case validate
/usr/bin/swift run --package-path Tools/Validation \
  computer-mcp-validate runbook generate --output validation-runbook.md
```

An external-consumer pass must correlate transport, request, local audit, and
independent result evidence. Local component tests and probes are auxiliary.

## Codex and Skills

Codex App Server, Exec, and MCP are separate `swift-codex` provider lifecycles.
Skills are gateway capabilities independent of Codex. Generic CLI execution,
process spawning, and Full Shell remain off by default and require an explicit
`chatgpt-operate` or `local-admin` grant.
