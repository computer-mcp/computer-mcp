# Computer MCP 1.3.2 Release Notes

Status: release record template. Publication requires acceptance of the exact
signed candidate before the formal tag is created.

## Changes

- Keep managed plugin directory ownership valid when macOS renumbers mount
  devices after a reboot, using persistent volume UUIDs with inode and birth time.
- Launch declared env script interpreters through their resolved dependency
  bindings, retaining interpreter options, script paths and configured arguments.
  Plugin diagnostics, stdio MCP and CLI execution use the same launch resolution.
- Upgrade verified legacy directory receipts while preserving plugin selection,
  settings, grants and configuration revision. Unverified directories remain
  protected from adoption or cleanup.

This compatible patch repairs plugin startup. The production Bundle ID, signing
identity, privacy permission flow and Keychain access group retain their existing
contracts. Legacy receipts with changed device numbers require reinstallation before they
can acquire a durable volume identity. Durable receipts retain compatible device
metadata for immediate executable rollback to the previous host.

## Installation

Verify the published checksums for `Computer-MCP-1.3.2-universal.dmg` before
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
