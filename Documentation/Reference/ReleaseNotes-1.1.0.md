# Computer MCP 1.1.0 Release Notes

Status: protected-CI release template. Publication requires the exact candidate
to pass signed-tag, signing, notarization, staple, Gatekeeper, checksum,
provenance and uploaded-byte verification.

## Highlights

- Plugins combine MCP, CLI and Skills in independent repositories. Bundled,
  downloaded and development packages use the same registration, policy,
  diagnostics and installation lifecycle.
- The App and management CLI provide official GitHub search, release selection,
  verified downloads, installation, saved exposure settings, enable/disable,
  upgrade, rollback and uninstall.
- MCP all-tools and whitelist exposure follow current schemas, pagination and
  reconnects. Validated catalogs and routes refresh atomically; notifications
  reflect each caller's visible tools. Multimodal results, structured content,
  cancellation and errors retain their protocol semantics.
- Verified CLI trees define deterministic argv/stdin mapping and explicit
  structured coverage. Installation does not install vendor software or alter
  global PATH. Skills remain bounded resources, not implicitly executed scripts.
- Codex execution is provided by the independent standard-MCP plugin. The host
  retains grants, approvals, workspace authorization and audit; the adapter owns
  its separate App Server, Exec and Codex MCP lifecycles and domain state.

## Upgrade and recovery

1. Verify `SHA256SUMS` and install `Computer-MCP-1.1.0-universal.dmg` when active
   work can be safely handed off. Do not replace the backend performing the
   upgrade itself.
2. Existing embedded Codex settings require the explicit
   [configuration and state migration](CodexMigration.md). Export configuration,
   stop the old owned writers, review an offline domain-state snapshot, then
   configure the independent plugin. Configuration import alone does not perform
   this handoff or activate Codex execution.
3. Preserve the old host build, configuration and stopped database snapshot.
   After the new adapter writes state, do not restore the stale snapshot as a
   rollback shortcut; reconcile the authoritative records first.

Host workspaces, profiles, credential references, grants and audit remain
host-owned. Package upgrades retain user settings. Plugin installation starts
disabled and grants no tool or system permissions.

## Availability boundaries

- The native Computer Use catalog was verified, but the tested vendor rejected
  actual calls because of caller authentication. A disposable native AX
  observe–act–verify path was verified. This release does not promise native CUA
  actions work for every caller.
- Actual ChatGPT client hot refresh was not verified; reconnect may be required.
  Server-side notification and route-switching tests do not prove client UI
  refresh behavior.
- Signed-host CLI Keychain operations were verified separately from the
  credential GUI. GUI credential entry/save/delete has not been manually
  exercised in this release's acceptance record.
- Public GitHub access is unauthenticated and may be rate limited. Official
  release downloads still require provenance and digest checks; source identity
  does not grant tool authority.
- The separately distributed Codex 0.1.0 binary is macOS arm64 and ad-hoc signed,
  not Developer ID notarized. The host's Universal 2 distribution does not imply
  that every third-party plugin is universal or notarized.

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

The release includes the notarized DMG, checksums, SBOM, dependency manifest,
third-party notices, rendered records and accepted notarization receipts.
The Computer MCP Source-Visible License is not an open-source license.
