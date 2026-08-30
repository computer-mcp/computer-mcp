# Computer MCP 1.0.19 Release Notes

Status: CI-rendered notarized draft. The GitHub Release remains a draft until
the publisher completes the 22/22 canonical acceptance checklist against the
exact checksummed artifact recorded below.

## Highlights

- **Launch at login** remains available on a fresh installation when macOS has
  not yet created a background-task record for Computer MCP. The App can now
  perform the official Service Management registration instead of presenting
  the missing record as an unavailable feature.
- Existing enabled login items remain enabled across the update. Registration
  errors still fail visibly; the App does not install a separate helper or a
  user-maintained LaunchAgent.
- Effective configuration exports now derive workspace and profile state from
  the current persisted control plane. Transient manifest or acceptance inputs
  cannot survive in replayable output after their owning state is gone.
- The production Bundle ID, Developer ID identity, private Keychain access
  group, TCC identity, Secure MCP Tunnel profile, ChatGPT connector,
  credentials, workspaces, and Full Shell policy are unchanged. Existing users
  do not need to migrate Keychain data or recreate the ChatGPT connector.
- Exact-artifact acceptance still calls every advertised capability and
  requires a correlated audit record for every call. The mandatory catalog
  contains 22 publisher-owned checks; live Cloudflare named deployment remains
  a user-owned deployment check because its account, domain, hostname, and
  token belong to the deploying user.
- Official artifacts remain Universal 2, Developer ID signed, notarized,
  stapled, Gatekeeper assessed, checksummed, and produced only by the protected
  GitHub Actions signed-tag workflow.

## Install

1. Download `Computer-MCP-1.0.19-universal.dmg` and `SHA256SUMS` from the same
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

## Security and compatibility

- `shell.run`, generic CLI execution, process spawning, workspace writes, and
  Full Shell remain disabled until both local policy and the selected profile
  explicitly grant them.
- Remote profiles never inherit `local-admin` authority, and configuration
  exports contain no provider secret, token, credential, Keychain value, or
  resolved proxy value.
- Screen Recording and Accessibility remain local macOS TCC grants for the
  stable signed App identity.
- Replacing 1.0.18 with 1.0.19 preserves the production runtime namespace and
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
