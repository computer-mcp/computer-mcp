# Computer MCP 1.0.21 Release Notes

Status: CI-rendered notarized draft. The GitHub Release remains a draft until
the publisher completes the 22/22 canonical acceptance checklist against the
exact checksummed artifact recorded below.

## Highlights

- Exact-catalog Codex acceptance now waits for the bounded turn's persisted
  terminal state, interrupts the active outer review turn, closes the owning
  App Server session, and archives validation threads from a fresh
  authenticated session bound to the same fixture workspace.
- Read-only Codex App Server requests receive one bounded retry on a fresh
  connection only when the first request reaches its configured deadline.
  Writes, policy denials, provider failures, and a second timeout still fail
  visibly.
- The public `codex.app.turn.start` input describes only fields preserved by
  the stable typed `swift-codex` request path.
- **Launch at login** remains available when macOS has no background-task
  record for Computer MCP and preserves an existing enabled registration
  across the update without a helper LaunchAgent.
- Validation-owned Codex threads are archived through their selected fixture
  workspace, so cleanup remains deterministic when several workspaces are
  registered.
- Effective configuration exports derive grants and profile state from the
  current persisted control plane; transient acceptance inputs cannot remain
  in replayable output after their owner is removed.
- The production Bundle ID, Developer ID identity, private Keychain access
  group, TCC identity, runtime namespace, Secure MCP Tunnel profile, ChatGPT
  connector, credentials, workspaces, and Full Shell policy are unchanged.
- Official artifacts remain Universal 2, Developer ID signed, notarized,
  stapled, Gatekeeper assessed, checksummed, and produced only by the protected
  GitHub Actions signed-tag workflow.

## Install

1. Download `Computer-MCP-1.0.21-universal.dmg` and `SHA256SUMS` from the same
   GitHub Release.
2. Verify the SHA-256 digest.
3. Open the DMG and drag `Computer MCP.app` to `/Applications`.
4. Cold-start the App from Finder and grant only the macOS permissions needed
   by the capabilities you enable.
5. Use **Install Command Line Tool** if you want the App-owned CLI link at
   `~/.local/bin/computer-mcp`.

The release does not bundle Codex, OpenAI `tunnel-client`, `cloudflared`, or
provider credentials. OpenAI and Cloudflare credentials are supplied by each
user and stored in that user's App-owned Data Protection Keychain.

## Security and compatibility

- `shell.run`, generic CLI execution, process spawning, workspace writes, and
  Full Shell remain disabled until both local policy and the selected profile
  explicitly grant them.
- Remote profiles never inherit `local-admin` authority, and configuration
  exports contain no provider secret, token, credential, Keychain value, or
  resolved proxy value.
- Screen Recording and Accessibility remain local macOS TCC grants for the
  stable signed App identity.
- Replacing 1.0.18 with 1.0.21 preserves the production runtime namespace and
  does not cross-read the separate development namespace.

## Legal and privacy

Computer MCP is proprietary source-visible software, not an open-source Swift
package. Installation and non-commercial use are governed by `LICENSE` and
`EULA.md`. Third-party licenses are reproduced in the App and DMG. Local data
and remote transmission boundaries are described in `PRIVACY.md`.

## Final release record

- Release date: __RELEASE_DATE__
- Candidate commit: `__RELEASE_COMMIT__`
- Signed tag: `__RELEASE_TAG__`
- Signed tag object: `__RELEASE_TAG_OBJECT__`
- Apple Team ID: `__APPLE_TEAM_ID__`
- Architectures: `__APP_ARCHITECTURES__`
- App notarization submission: `__APP_NOTARY_SUBMISSION_ID__`
- DMG notarization submission: `__DMG_NOTARY_SUBMISSION_ID__`
- DMG SHA-256: `__DMG_SHA256__`
- Embedded CLI SHA-256: `__EMBEDDED_CLI_SHA256__`
- GitHub Actions run: __GITHUB_RUN_URL__
- Apple Silicon native installation and lifecycle: required before publishing
  the draft
- x86_64 compatibility under Rosetta 2: required before publishing the draft
- Final acceptance: the publisher must record 22/22 before publishing the
  draft

The GitHub Release upload set contains the notarized DMG, `SHA256SUMS`,
CycloneDX SBOM, dependency manifest, third-party notices, these rendered
release notes, the rendered production-readiness report, and both notarization
receipts. Private raw acceptance evidence is retained separately and is never
uploaded automatically.
