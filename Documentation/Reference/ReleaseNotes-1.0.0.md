# Computer MCP 1.0.0 Release Notes

Status: CI-rendered notarized draft. The GitHub Release must remain a draft
until the publisher completes the 23/23 acceptance checklist against the exact
checksummed artifact recorded below.

## Highlights

- Native macOS App and embedded CLI with a single App-owned control plane.
- Universal 2 support for Apple Silicon and Intel Macs running macOS 14 or
  newer.
- Explicit caller/profile/workspace policy with read-only observe and reviewed
  operate surfaces.
- Local bridge, authenticated Streamable HTTP, OpenAI Secure MCP Tunnel, and
  Cloudflare remotely managed named tunnel transports.
- Builtin, Skills, registered CLI, downstream MCP, process, Codex, and native
  Computer Use providers.
- Keychain-managed transport credentials, security-scoped workspace grants,
  bounded logs, and correlated audit evidence.

## Install

1. Download `Computer-MCP-1.0.0-universal.dmg` and `SHA256SUMS` from the same
   GitHub Release.
2. Verify the SHA-256 digest.
3. Open the DMG and drag `Computer MCP.app` to `/Applications`.
4. Cold-start the App from Finder and complete only the macOS permissions your
   selected capabilities require.
5. Use **Install Command Line Tool** if you want the App-owned CLI link at
   `~/.local/bin/computer-mcp`.

The release does not bundle Codex, OpenAI `tunnel-client`, `cloudflared`, or
other external providers.

## Security defaults

- `shell.run` and general Full Shell access are off by default. They can be
  enabled only for `chatgpt-operate` or `local-admin` through explicit local
  policy and profile grants.
- Bearer authentication is checked before request bodies are accumulated.
- HTTP v1 limits are 16 KiB headers, 8 MiB bodies, 128 active sessions, and a
  15-minute idle expiry.
- Remote profiles never inherit `local-admin` authority.
- Screen Recording and Accessibility permissions remain local macOS TCC
  grants and cannot be granted by a remote caller.

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
release notes, the rendered production-readiness report, and the App and DMG
notarization receipts. Private raw acceptance evidence is retained separately
and is never uploaded automatically.
