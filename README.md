# Computer MCP

Computer MCP is a policy-enforced MCP gateway for macOS. `Computer MCP.app`
owns the App Control Plane: one manifest, GRDB database, workspace bookmark
store, Keychain boundary, policy engine, provider lifecycle, transport state,
and audit trail. Its signed `computer-mcp` CLI uses the same Control Socket;
it does not create a second control plane.

```text
ChatGPT Connector -> OpenAI Secure MCP Tunnel -> Gateway Socket
Remote MCP client -> Cloudflare Tunnel -> loopback Streamable HTTP
Local MCP client  -> embedded CLI bridge -> Gateway Socket
                                              |
                         policy + workspace grants + audit
                                              |
      Builtin / Skills / CLI / MCP / Process / Codex / Computer Use
```

The OpenAI Secure MCP Tunnel and Cloudflare Tunnel are independent transports.
They use distinct callers, profiles, credentials, processes, logs, health
checks, and audit provenance, and they may run concurrently.

## Requirements

- macOS 14 or newer;
- Swift 6.2 or newer for source builds;
- optional user-installed `tunnel-client`, `cloudflared` 2025.4.0 or newer,
  Codex, and downstream providers.

The App uses Hardened Runtime without App Sandbox. It does not bundle provider
credentials or an updater.

## Build and install

```sh
Scripts/build-app.sh
Scripts/package-dmg.sh
Scripts/verify-distribution.sh
open "dist/Computer MCP.app"
```

The App bundle contains both entry points:

```text
Computer MCP.app/Contents/MacOS/Computer MCP
Computer MCP.app/Contents/Resources/computer-mcp
```

Use **Install Command Line Tool** in the App to create
`~/.local/bin/computer-mcp` without `sudo`. The installer detects a missing
`PATH` entry, a stale link, and conflicting files.

## Profiles and callers

The first public configuration contract is `schema_version = 1`. It includes
these built-in profiles and permits validated custom profile IDs:

| Profile | Intended caller | Boundary |
| --- | --- | --- |
| `chatgpt-observe` | `secure-tunnel` | Read-only ChatGPT inspection |
| `chatgpt-operate` | `secure-tunnel` | Explicitly granted ChatGPT operations |
| `cloudflare-observe` | `cloudflare-tunnel` | Read-only remote HTTP inspection |
| `cloudflare-operate` | `cloudflare-tunnel` | Explicitly granted remote HTTP operations |
| `local-admin` | local App, CLI, or MCP | Local-only administration and optional Full Shell |

Every profile declares `allowed_callers`. Remote profiles cannot inherit local
administrative authority. More than one authorized workspace requires an
explicit `workspace_id`. Full Shell, generic CLI execution, and process
spawning are disabled by default.

## Configuration and state

Product state is stored under:

```text
~/Library/Application Support/Computer MCP
```

- TOML owns static policy, provider, and transport definitions.
- GRDB owns workspace authorization and desired transport state.
- Keychain owns tokens and credentials.
- Security-scoped bookmarks own App-selected workspace access.

Only the current schema is accepted. Unknown fields and unsupported values are
rejected. There is no migration or compatibility command in the distributed
product.

```sh
computer-mcp config path
computer-mcp config show
computer-mcp config validate
computer-mcp config export --output exported.toml
computer-mcp config import --input candidate.toml
```

Import validates and previews a secret-free structural diff. Applying requires
the preview digest and never starts a transport. See the
[Configuration Reference](Documentation/Reference/Config.md).

## Remote transports

### OpenAI Secure MCP Tunnel

Configure the tunnel in the App, save its API key in Keychain, then create or
refresh the ChatGPT Connector and scan tools. An optional credential-free HTTP
proxy can be configured; otherwise the App follows the fixed macOS HTTPS/HTTP
proxy at Tunnel launch. See the
[ChatGPT Web Runbook](Documentation/Reference/ChatGPTWebRunbook.md).

### Cloudflare Tunnel

The supported release mode is **Remotely Managed** with a named tunnel, public
hostname, and Cloudflare Tunnel Token. The App hosts an authenticated loopback
Streamable HTTP origin, stores a Computer MCP Access Token in Keychain, writes
the Cloudflare token to a temporary owner-only `0600` file, starts
`cloudflared`, monitors its local metrics endpoint, and owns cleanup.

Quick Tunnels are development-only Validation Test Cases. Cloudflare Access may
add a second layer using a consumer-owned Cloudflare Access Service Token;
Computer MCP does not store that consumer credential. See the
[Cloudflare Runbook](Documentation/Reference/CloudflareRunbook.md).

## CLI

The principal command surface is:

```text
app status
config path|show|validate|export|import
workspace list|add|remove|enable
profile list|show|grant
tunnel openai list|doctor|start|stop|logs
tunnel cloudflare list|doctor|start|stop|logs
tools list|inspect|call
install cli|codex
uninstall cli
serve stdio|http
bridge
```

`serve stdio|http --config ...` is explicit standalone development mode.
`bridge` is the internal stdio-to-App adapter. See the
[CLI Reference](Documentation/Reference/CLI.md).

## Capabilities

| Plane | Surface |
| --- | --- |
| Workspace and Builtin | Typed file, Git, structured-data, system, network, and workspace tools |
| Skills | Discovery and bounded skill-package reads |
| CLI | Registered command status, help, and argv execution under policy |
| Process and Policy | Bounded lifecycle and audited policy inspection |
| Downstream MCP | Persistent stdio and Streamable HTTP tools, resources, prompts, cancellation, and notifications |
| Codex | Separate App Server, Exec, and MCP provider lifecycles through `swift-codex` |
| Computer Use | Native display, input, and Accessibility operations with local TCC preflight |

Every exposed tool has typed schemas, bounded results, stable errors, risk
annotations, caller/profile/workspace provenance, and an audit record.

## Development and validation

The root package contains the internal implementation target, App, embedded
CLI, and automated component tests:

```sh
swift-format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
/usr/bin/swift build --build-system native
/usr/bin/swift test --build-system native
/usr/bin/swift run --build-system native computer-mcp \
  config validate --config Examples/computer-mcp.toml
```

All automated tests use Swift Testing. Real Apps, external CLIs, tunnels,
ChatGPT, browsers, and remote consumers are outside automated tests.

Computer MCP Validation Suite is an independent package and is never embedded
in the App, CLI, or DMG:

```sh
/usr/bin/swift build --package-path Tools/Validation --build-system native
/usr/bin/swift test --package-path Tools/Validation --build-system native
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate test-case validate
```

A Validation Test Case passes only when its Validation Evidence Bundle
correlates the external consumer result, transport, gateway request, audit
record, and independent result. A probe is diagnostic evidence and cannot
independently produce PASS. See
[Validation](Documentation/Reference/Validation.md).

## Publication status

Source builds resolve the public `swift-codex` package at the exact supported
version `0.1.1`. Computer MCP itself remains a release candidate until the
signed, notarized Universal 2 artifact and all 23 external Validation Test
Cases are recorded in the
[1.0.0 readiness report](Documentation/Reference/ProductionReadinessReport-1.0.0.md).
Historical development evidence must not be presented as a final release
result.

Architecture and operator documentation starts at
[Documentation](Documentation/README.md).
