# Computer MCP 1.3.1 Release Notes

Status: release record template. Publication requires acceptance of the exact
signed candidate before the formal tag is created.

## Changes

- Apply the canonical Computer MCP icon to the macOS App, Finder, Dock and
  distribution bundle.
- Align bilingual product copy and public artwork around direct, composable,
  governed access to local tools across computers. Codex remains optional.

This compatible patch updates product identity and bundled artwork. Capability,
permission and integration contracts retain their existing owners.

## Installation

Verify the published checksums for `Computer-MCP-1.3.1-universal.dmg` before
installing. Preserve the previous App for rollback and finish active work before
replacing the running host. Preserve plugin directories when restoring state:
copying their contents does not preserve the identity bound to their receipts.

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

The distribution includes the notarized DMG, checksums, SBOM, dependency
manifest, third-party notices and notarization receipts. The Computer MCP
Source-Visible License is not an open-source license.
