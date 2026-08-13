# Troubleshooting

Start with the journey-specific readiness result:

```sh
computer-mcp doctor --journey local
computer-mcp doctor --journey chatgpt
computer-mcp doctor --journey cloudflare
computer-mcp doctor --journey chatgpt --json
```

The command exits 0 only for Ready or Verified. A blocked App connection still
returns parseable, redacted schema-1 JSON.

## App Does Not Start

Run the bundled executable directly to capture startup diagnostics:

```sh
"dist/Computer MCP.app/Contents/MacOS/Computer MCP"
```

Check:

```text
~/Library/Logs/Computer MCP/computer-mcp.jsonl
~/Library/Application Support/Computer MCP/
```

The App rejects symlinked or foreign-owned control-plane directories. Product
log files should be mode `0600`.

## Bridge Cannot Connect

Confirm the App is running and the socket shown in Diagnostics exists. Then:

```sh
"dist/Computer MCP.app/Contents/Resources/computer-mcp" bridge
```

A stale socket should be recovered on App startup. Normal Quit removes the
owned socket. Do not start a second product owner with `serve`.

Custom control-plane test directories must keep the Unix socket path within the
platform `sockaddr_un` limit. A deeply nested temporary home can fail with
`SocketAddressError`; the standard
`~/Library/Application Support/Computer MCP/Runtime/gateway.sock` path is
supported.

## No Workspace Tools

A fresh App intentionally exposes only onboarding-safe tools until a workspace
is registered. Add a folder in **Workspaces**, verify its bookmark is
Available, and retry `workspace.list`.

When multiple workspaces are granted, include `workspace_id`; Computer MCP does
not maintain a global current workspace.

## Manifest Does Not Validate

Use the Diagnostics manifest editor or:

```sh
swift run computer-mcp config validate --config <path>
```

Typical failures include duplicate IDs, invalid workspace grants, a remote
`local-admin` binding, unknown capabilities, missing MCP transport fields,
reexport prefix conflicts, and `danger-full-access` Codex sandbox.

## ChatGPT Cannot Connect

ChatGPT Web cannot connect directly to local stdio or `localhost`. Follow the
[ChatGPT Web Runbook](ChatGPTWebRunbook.md).

Verify:

- Developer mode and custom Apps are available for the account/workspace;
- the Tunnel is associated with the exact ChatGPT workspace;
- both runtime key and app creator have `Tunnels Read + Use`;
- the App Tunnel state is Running;
- `/healthz` and `/readyz` succeed;
- the local MCP subprocess remains alive.

Custom MCP Apps are web-configured. ChatGPT Pro is read/fetch only; eligible
Business, Enterprise, and Edu workspaces can expose write/modify tools.

## Tunnel Doctor Fails

Verify the installed client:

```sh
command -v tunnel-client
tunnel-client --version
```

The App uses a Keychain runtime key. Re-enter it if revoked. Platform Tunnel
creation/edit requires `Read + Manage`; running/selecting requires
`Read + Use`.

If ChatGPT reports an SSE probe failure and the Tunnel log contains an HTTP 403
before any Gateway request is recorded, compare Safari connectivity with the
App-launched Tunnel. Leave the Tunnel HTTP proxy field blank to follow the
fixed macOS HTTPS/HTTP proxy, or configure a credential-free `http://` or
`https://` proxy URL explicitly. Run Diagnostics validates the profile but
cannot prove that a later long-poll reached the OpenAI control plane; confirm
the live Tunnel log and a correlated Gateway request.

When the App already owns a running OpenAI Tunnel, Run Diagnostics keeps the
saved runtime health address unchanged and gives the diagnostic subprocess an
ephemeral loopback health listener. This prevents Doctor from reporting the
managed Tunnel's own listener as an unrelated port conflict. A stopped Tunnel
is still diagnosed against its saved health-listener configuration so a real
conflict is caught before launch.

If a rebuilt App leaves a Tunnel in Starting while no Tunnel process appears,
inspect its signature and provisioning before changing the profile. The live
App requires a non-ad-hoc Team ID, a matching environment/Bundle ID, an
embedded provisioning profile, and the exact private Data Protection Keychain
group `<TeamID>.<BundleID>`. Apple Development and Developer ID certificates
for the same Team and production Bundle share that group and do not require a
older file-based Keychain owner prompt. An ad-hoc build fails the App control plane closed
rather than reading or migrating production secrets. Never copy a key into TOML
or logs as a workaround. Run Diagnostics to verify credential availability;
list views intentionally do not query Keychain.

Use the official local admin UI and endpoints:

```text
/ui
/healthz
/readyz
/metrics
```

If ChatGPT asks for OAuth, recreate the integration as a Tunnel connection
instead of pasting the OpenAI-hosted Tunnel endpoint as a Server URL.

## Provider Is Unavailable

Open **Providers** and run Doctor. Optional providers do not block the gateway.
Confirm the executable is available in the App launch environment, not only an
interactive shell.

For downstream MCP:

```sh
swift run computer-mcp config validate --connect --config <path>
```

Then use `mcp.servers.status`, `mcp.tools.list`, and provider events to separate
startup, protocol, authentication, and downstream tool failures.

## CLI Call Fails

Use `cli.describe` and `cli.help`, then execute the returned argv through
`cli.exec`. No shell expansion is performed. `cli.exec` is unavailable to a
remote caller unless its locally selected profile grants Full Shell-equivalent
authority.

## Codex Call Fails

Run Provider Doctor and inspect each path independently:

- `codex.app.status`
- `codex.exec.list`
- `codex.mcp.status`

The installed Codex must support the configured experimental App Server API.
Computer MCP fails closed on incompatible methods and does not silently fall
back from App Server to Exec.

Non-Git registered workspaces are supported. The gateway supplies
`--skip-git-repo-check` to Exec while retaining its registered workspace and
sandbox policy.

## Computer Use Is Denied

Open **Permissions**. Grant Accessibility or Screen Recording to the signed
`Computer MCP.app` with the local **Request Access** action, complete the
highlighted step in System Settings, then relaunch if macOS requires it. The
App automatically rechecks the permission while the guide is visible. Remote
calls never trigger TCC prompts.

Accessibility and Screen Recording block only enabled capabilities that need
them. Revoking either grant does not stop ordinary file, system, provider, or
non-Computer-Use paths. The grant must belong to the signed App bundle that
performs the protected action, not Terminal, Codex, or a copied executable.

For local builds, `Scripts/build-app.sh` automatically uses the only available
Apple Development identity and compatible provisioning profile. A stable signed
Bundle identity matters for TCC grants. Keychain access is separate: the modern
Data Protection Keychain uses the provisioned Team ID plus Bundle ID access
group, so Development and Developer ID builds of the production Bundle can
share credentials without per-build ACL prompts. If several identities or
profiles are installed, set `SIGNING_IDENTITY` and `PROVISIONING_PROFILE`
explicitly. Use `ADHOC_SIGNING=1` only for isolated packaging tests; the live
App rejects ad-hoc identity before opening the control plane.

## Release Artifact Is Rejected

Development builds use Apple Development signing when exactly one identity is
available; otherwise they are ad-hoc signed. Neither path is notarized. For
official distribution, push a signed `vMAJOR.MINOR.PATCH` tag and inspect the
GitHub `Release` workflow. Do not promote a local DMG. The protected release job
must report successful Developer ID signing, App and DMG notarization, stapling,
Gatekeeper assessment, and checksum assembly before it creates a draft Release.

For a downloaded draft candidate, run:

```sh
shasum -a 256 -c SHA256SUMS
spctl --assess --type open --context context:primary-signature --verbose=2 \
  Computer-MCP-<version>-universal.dmg
xcrun stapler validate Computer-MCP-<version>-universal.dmg
```

Common workflow failures are intentionally fail-closed:

- A failure in `Verify trusted runner tooling` means the protected job cannot
  prove its system/Xcode tool boundary. GitHub jobs have isolated filesystems:
  a Homebrew tool installed by `verify` is not available to `release`. The
  formal build/sign/notarize path must remain free of Homebrew and ripgrep;
  `verify-protected-release-boundary.sh` and its negative regression enforce
  this before tagging.
- `Release ref verification failed` means the tag is unsigned, not annotated,
  does not match the App version, or is not reachable from `origin/master`.
- `Release readiness verification failed` means legal approval is incomplete
  or a release-record template has missing, obsolete, or unexpected render
  tokens.
- `Missing protected release value` means the GitHub `production` Environment
  variable or Secret set is incomplete.
- `No provisioning profile authorizes ...` means the embedded certificate,
  production App ID, and private Keychain group do not match the CI profile.
- `Invalid credentials` from `notarytool` means the Team API key, key ID, or
  issuer ID is wrong. Individual API keys cannot notarize.
- `Unnotarized Developer ID` from `spctl` means the artifact was assessed
  before Apple accepted and stapled the exact App/DMG, or a different artifact
  was substituted afterward.

See [Release](Release.md).
