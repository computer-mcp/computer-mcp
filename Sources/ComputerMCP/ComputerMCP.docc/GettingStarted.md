# Getting Started

Build and test the root package:

```sh
/usr/bin/swift build --build-system native
/usr/bin/swift test --build-system native
Scripts/build-app.sh
open "dist/Computer MCP.app"
```

The App owns the manifest, database, bookmarks, Keychain secrets,
gateway socket, providers, transports, and audit stream. Add workspaces and
review profile grants before enabling a transport.

Install the signed embedded CLI from the App. It links to
`~/.local/bin/computer-mcp` and uses the App's owner-only control socket:

```sh
computer-mcp app status
computer-mcp workspace list
computer-mcp profile list
computer-mcp tools list
```

OpenAI Secure MCP Tunnel and Cloudflare named tunnel are independent App-owned
transports. Configure, diagnose, and start them separately:

```sh
computer-mcp tunnel openai list
computer-mcp tunnel cloudflare list
```

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
/usr/bin/swift test --package-path Tools/Validation --build-system native
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate test-case validate
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate runbook generate --output validation-runbook.md
```

An external-consumer pass must correlate transport, request, local audit, and
independent result evidence. Local component tests and probes are auxiliary.

## Codex and Skills

Codex App Server, Exec, and MCP are separate `swift-codex` provider lifecycles.
Skills are gateway capabilities independent of Codex. Generic CLI execution,
process spawning, and Full Shell remain local-admin authority.
