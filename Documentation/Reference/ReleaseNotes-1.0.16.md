# Computer MCP 1.0.16 Release Notes

Status: CI-rendered notarized draft. The GitHub Release remains a draft until
the publisher completes the 22/22 canonical acceptance checklist against the
exact checksummed artifact recorded below.

## Highlights

- Workspace **Add** now presents an in-App SwiftUI folder browser on macOS 27,
  avoiding that beta's unreliable system open-panel selection state. Earlier
  supported macOS releases retain the system folder importer and its
  user-selected privacy grant. Both paths update the list in place without a
  full-page refresh.
- Exact-artifact acceptance still calls every advertised capability and
  requires a correlated audit record for every call. A normal success remains
  the preferred result.
- One narrowly defined fail-closed result is now reviewable:
  `codex.app.apps.list` may return the upstream ChatGPT connector-directory
  HTTP 403 challenge only when the result is structured, contains
  `codex.app.request_failed`, and correlates to a failed audit row with
  `gateway.execution_failed`. This does not classify the local App, loopback
  gateway, workspace, or Shell as scraping or hostile traffic. Every other
  provider, network, semantic, or audit failure still blocks publication.
- The mandatory release catalog contains 22 publisher-owned checks. Isolated
  Quick Tunnel validation and automated named-tunnel lifecycle,
  authentication, cleanup, and profile-separation tests remain release gates.
  A live named Cloudflare deployment is a user-owned deployment check because
  its account, domain, public hostname, and runtime token do not belong to the
  product or release workflow.
- Release Evidence Manifest completeness is derived from the canonical catalog
  rather than duplicated as a fixed implementation constant.
- The immutable notarized 1.0.15 draft remains unpublished. Its installed App,
  real ChatGPT Full Shell request, 287 correlated audit rows, and 286 ordinary
  catalog successes were valid; 1.0.16 repeats the protected workflow under
  the corrected upstream and user-credential trust boundaries.
- Official artifacts remain Universal 2, Developer ID signed, notarized,
  stapled, Gatekeeper assessed, checksummed, and produced only by the protected
  GitHub Actions signed-tag workflow.

## Install

1. Download `Computer-MCP-1.0.16-universal.dmg` and `SHA256SUMS` from the same
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
- Configuration export contains no provider secret, token, credential,
  Keychain value, or resolved proxy value.
- Screen Recording and Accessibility are local macOS TCC grants for the signed
  App identity; another app's grant does not transfer to Computer MCP.
- Runtime credentials are never embedded in the App, DMG, examples, logs,
  configuration exports, or GitHub Release.

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
