# Computer MCP

[简体中文](README.zh-CN.md)

Computer MCP is a policy-enforced MCP gateway for macOS. The App owns the
gateway, profiles, workspace grants, provider and tunnel lifecycles, Keychain
credentials, and redacted audit trail. Local MCP clients, ChatGPT, and public
MCP consumers connect to that same App-owned gateway.

> Normal App users do not need a TOML file. TOML is for explicit standalone
> development and advanced configuration only.

## Install the release

Computer MCP requires macOS 14 or later.

1. Download `Computer-MCP-1.0.3-universal.dmg` and `SHA256SUMS` from the
   release that supplied your build.
2. Verify the DMG digest, open it, and drag **Computer MCP** to Applications.
3. Open the installed App from Finder. Do not run a copied executable outside
   its App bundle: macOS privacy grants belong to the signed App identity.
4. Optionally choose **Install Command Line Tool** on Home. This creates
   `~/.local/bin/computer-mcp` without `sudo`.

Official release artifacts are Developer ID signed, notarized, and published
with checksums through GitHub Releases. Source-built and ad-hoc-signed
artifacts are development builds, not official releases.

## First launch

The welcome page offers four direct paths:

- **Connect ChatGPT**
- **Connect through Cloudflare**
- **Connect a local MCP client**
- **Explore Dashboard**

It remembers only `onboarding_version = 1`. Connection progress is always
derived from the current App, gateway, dependencies, Keychain entries,
transport process, and audit records. You can reopen Welcome from the sidebar.

Home shows one recommended next step at a time. A connection is:

| Status | Meaning |
| --- | --- |
| Not configured | No connection definition exists |
| Blocked | A required dependency, credential, or component is unavailable |
| Needs attention | Setup exists but a required runtime step is incomplete |
| Ready | Local components, configuration, dependencies, and transport are healthy |
| Verified | A matching successful request occurred after the current gateway or tunnel start |

## Connect a local MCP client

1. Open **Home** and start the Gateway.
2. Under **Connect a local MCP client**, copy the displayed stdio command and
   arguments into your MCP client.
3. For Codex, choose **Register with Codex**, review the exact command, and
   confirm. The registration uses:

   ```text
   computer-mcp bridge --client-identity local-mcp
   ```

   It does not use TOML. The internal Codex provider is a separate advanced
   feature under **Providers**.
4. Make one MCP tool call, then refresh Home. The path becomes Verified only
   after a matching `local-mcp` audit event is observed.

## Connect ChatGPT

Open **ChatGPT** under Get Started and follow the checks in order:

1. Confirm the target ChatGPT account/workspace can create custom MCP apps and
   enable developer mode. Availability and administrative controls vary by
   plan; see OpenAI's current [developer mode and MCP apps guide][openai-apps].
2. Create or select an OpenAI Secure MCP Tunnel and install the official
   [`tunnel-client` release][tunnel-client]. Computer MCP detects it but never
   downloads it.
3. Choose **Add Connection**, enter the Tunnel identity and gateway profile,
   and save the runtime API key. The key is stored in Keychain.
4. Run Diagnostics, start the connection, and wait for Ready.
5. In ChatGPT Web, create or update the custom app, scan tools, start a new
   chat, and invoke one Computer MCP tool.
6. Return to the ChatGPT page and choose **Check for Request**. Verified
   requires the current tunnel identity, caller, profile, start boundary, and a
   successful audit decision to match.

Computer MCP does not automate ChatGPT account settings. ChatGPT connects to a
remote MCP server; Secure MCP Tunnel keeps the local gateway off the public
Internet. See the full [ChatGPT runbook](Documentation/Reference/ChatGPTWebRunbook.md).

## Connect through Cloudflare

Open **Cloudflare** under Get Started:

1. Install `cloudflared` 2025.4.0 or newer. This version is required for the
   owner-only named-tunnel token file used by Computer MCP.
2. In Cloudflare, create a remotely managed named tunnel and route its public
   hostname to the loopback origin shown by the App. Quick Tunnels are for
   development validation only.
3. Choose **Add Connection** and enter the hostname, named-tunnel token, and
   gateway profile. Tokens are stored in Keychain.
4. Ask the App to generate a Computer MCP Access Token. Copy it immediately
   into the external consumer's secret store; after the one-time view closes,
   the App cannot display it again.
5. Run Diagnostics, start the named tunnel, connect the public MCP consumer,
   and make one successful tool call.
6. Choose **Check for Request**. Ready becomes Verified only for a request that
   matches the current named tunnel, profile, caller, and start boundary.

Cloudflare Access may add consumer-owned Service Token headers. Computer MCP
does not store those credentials. See the full
[Cloudflare runbook](Documentation/Reference/CloudflareRunbook.md) and
Cloudflare's official [tunnel token documentation][cloudflare-token].

## Diagnose and recover

Every setup page remains usable after a failed dependency check, external
browser trip, permission denial, or transport failure. Use **Retry**, the
step-by-step fallback, or **Open Advanced Diagnostics**; setup is not trapped in
a one-time modal.

The App-owned CLI exposes the same readiness model:

```sh
computer-mcp doctor
computer-mcp doctor --journey local|chatgpt|cloudflare
computer-mcp doctor --journey chatgpt --json
```

Doctor exits 0 only for Ready or Verified. Schema-1 JSON remains parseable when
the App is unavailable and never includes a credential value. More recovery
steps are in [Troubleshooting](Documentation/Reference/Troubleshooting.md).

## Permissions

Accessibility and Screen Recording block only capabilities that actually need
them. Read-only file, system, provider, and non-Computer-Use paths continue to
work without those grants.

The App preflights the permission, calls the public macOS request API, attempts
to open the correct System Settings page, shows a fallback path, and polls again
when you return. Screen Recording grants must target the signed
`Computer MCP.app` that executes the protected operation. A Terminal or Codex
grant does not transfer to Computer MCP.

## Security boundaries

- The App Control Socket and gateway socket are owner-only local endpoints.
- Built-in profiles keep local administration separate from ChatGPT and
  Cloudflare callers.
- `shell.run`, generic CLI execution, process spawning, workspace writes, and
  Full Shell are disabled unless policy and the selected profile both grant
  them.
- More than one eligible workspace requires an explicit `workspace_id`.
- API keys and tunnel tokens live in the macOS Data Protection Keychain under
  the signed App's private access group. Examples, Doctor, logs, diagnostics,
  configuration exports, and audit rows contain only placeholders or redacted
  summaries.
- HTTP v1 remains loopback-bound and bearer protected; Cloudflare owns the
  public transport, not the origin authorization boundary.

## Advanced development

Standalone mode is explicit and uses exactly one TOML file per process:

```sh
swift run computer-mcp serve stdio --config Examples/computer-mcp.toml
swift run computer-mcp config validate --config Examples/computer-mcp.toml
swift run computer-mcp tools list --config Examples/computer-mcp.toml
```

Standalone mode does not use the App's bookmarks, database, or Keychain tunnel
credentials. Do not run it as a second owner of App state. The examples are
classified in [Examples/README.md](Examples/README.md); exhaustive commands,
protocol details, and tool schemas live in the
[Reference documentation](Documentation/Reference/README.md).

Build and test from the repository root:

```sh
swift-format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
/usr/bin/swift build --build-system native
/usr/bin/swift test --build-system native
```

Local builds are development and release-rehearsal artifacts only. Official
DMGs come exclusively from the protected GitHub Actions workflow triggered by
an SSH-signed annotated `vMAJOR.MINOR.PATCH` tag. The workflow signs with
Developer ID, notarizes and staples the App and DMG, verifies Gatekeeper, and
creates a draft GitHub Release. See the
[Release reference](Documentation/Reference/Release.md).

The root package exposes only the App and CLI products. It resolves
`swift-codex` exactly at `0.1.1`; the Validation package remains independent
under `Tools/Validation`.

[openai-apps]: https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt
[tunnel-client]: https://github.com/openai/tunnel-client/releases/latest
[cloudflare-token]: https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/
