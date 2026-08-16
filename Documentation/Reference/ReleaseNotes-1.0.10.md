# Computer MCP 1.0.10 Release Notes

Status: CI-rendered notarized draft. The GitHub Release must remain a draft
until the publisher completes the 23/23 acceptance checklist against the exact
checksummed artifact recorded below.

## Highlights

- Codex Exec now uses the upstream official `--ignore-user-config` boundary.
  The user's existing Codex authentication remains available, but global MCP
  servers, models, hooks, profiles, and other interactive configuration cannot
  delay or change embedded Gateway requests.
- New and resumed Exec sessions both apply the same explicit workspace,
  sandbox, approval, output, and user-config isolation policy through the typed
  `swift-codex` 0.1.2 API.
- Gateway connections continue to own and close their complete App Server,
  Exec, MCP, downstream MCP, HTTP, stdio, workspace, and child-process
  lifecycle.
- Exact-artifact acceptance repeats all 287 advertised tool calls and their
  correlated audit decisions. The Codex Exec call that exposed the 1.0.9
  isolation defect must reach a terminal result within the bounded probe.
- Official release artifacts remain Universal 2, Developer ID signed,
  notarized, stapled, Gatekeeper assessed, checksummed, and produced only by
  the protected GitHub Actions signed-tag workflow.

## Install

1. Download `Computer-MCP-1.0.10-universal.dmg` and `SHA256SUMS` from the same
   GitHub Release.
2. Verify the SHA-256 digest.
3. Open the DMG and drag `Computer MCP.app` to `/Applications`.
4. Cold-start the App from Finder and grant only the macOS permissions needed
   by the capabilities you enable.
5. Use **Install Command Line Tool** if you want the App-owned CLI link at
   `~/.local/bin/computer-mcp`.

The release does not bundle Codex, OpenAI `tunnel-client`, `cloudflared`, or
provider credentials. OpenAI and Cloudflare runtime credentials are supplied
by each user and stored in that user's App-owned Data Protection Keychain.

## Security defaults

- `shell.run`, generic CLI execution, process spawning, workspace writes, and
  Full Shell remain disabled until both local policy and the selected profile
  explicitly grant them.
- Remote profiles never inherit `local-admin` authority.
- Screen Recording and Accessibility are local macOS TCC grants for the signed
  App identity; another app's grant does not transfer to Computer MCP.
- Runtime credentials are not release inputs and are never embedded in the
  App, DMG, examples, logs, configuration exports, or GitHub Release.

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
- Final acceptance: the publisher must record 23/23 before publishing the
  draft

The GitHub Release upload set contains the notarized DMG, `SHA256SUMS`,
CycloneDX SBOM, dependency manifest, third-party notices, these rendered
release notes, the rendered production-readiness report, and both notarization
receipts. Private raw acceptance evidence is retained separately and is never
uploaded automatically.
