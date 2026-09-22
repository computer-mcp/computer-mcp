# Computer MCP 1.2.2 Release Notes

Status: release record template. Publication requires acceptance of the exact
signed candidate before the formal tag is created.

## Changes

- Complete repeated MCP initialization correctly when a client reuses request
  identifiers immediately after receiving its first response. Queued handshakes
  also receive initialization failures instead of waiting indefinitely.
- Bound managed-process termination by an independent deadline. Process-launch
  overhead no longer accumulates into the configured grace period, and early
  exits reap the deadline timer promptly.
- Clarify that plugin recovery requires connected gateway clients to disconnect.
  Directory identity checks continue to protect installation receipts.
- Generate App and CLI versions from one declaration and verify dependency tags,
  lockfiles, candidate provenance and checkpoint identity during release checks.

These compatible fixes advance the host patch version. The independent plugins
and SDK retain their own versions when their shipped behavior is unchanged.

## Installation

Verify the published checksums for `Computer-MCP-1.2.2-universal.dmg` before
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
