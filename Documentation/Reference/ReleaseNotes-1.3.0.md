# Computer MCP 1.3.0 Release Notes

Status: release record template. Publication requires acceptance of the exact
signed candidate before the formal tag is created.

## Changes

- Apply workspace, downstream MCP and plugin configuration changes to connected
  clients. New calls use the current configuration; existing work retains its
  owning runtime until it finishes or is explicitly stopped.
- Separate Observe/Control, Restricted/Full Access and session/persistent trust.
  Local consent and revocation govern remote workspace, profile and plugin
  management through the same typed control plane used by the App and CLI.
- Discover official plugins through one static publisher catalog while
  preserving verified release provenance for each selected installation.
- Share scoped Host Services with independent plugins, including approval
  callbacks, caller attribution and owned-process cleanup.
- Validate and author CLI Trees, preserve exact JSON integers, and expose
  bounded long-thread history through the independent Codex adapter.
- Support platform-specific plugin entrypoints and native Windows core
  process, filesystem and transport boundaries. The desktop App remains a
  macOS product; each independent plugin declares its supported platforms.

These compatible capabilities advance the host minor version. Independent
plugins and SDKs retain their own release identities and acceptance evidence.

## Installation

Verify the published checksums for `Computer-MCP-1.3.0-universal.dmg` before
installing. Preserve the previous App for rollback and finish active work before
replacing the running host. Configuration updates inside a running host retain
existing runtime ownership; replacing the App is a separate operation.
Preserve plugin directories when restoring state: copying their contents does
not preserve the directory identity bound to their receipts.

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
