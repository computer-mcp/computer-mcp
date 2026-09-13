# Computer MCP 1.1.1 Release Notes

Status: protected-CI release template. The final signed and notarized package
must pass local installation acceptance before its draft is made public.

## Highlights

- Fix a packaged-App crash when opening plugin and MCP management pages.
  Localized controls resolve resources from the installed App bundle.
- Check packaged localization independently of SwiftPM build directories.
- Prepare releases as unpublished drafts. Publish the exact locally accepted
  package, then verify the production upgrade.
- Add separate live installation checks for each official plugin.

## Installation and recovery

Verify `SHA256SUMS` before installing `Computer-MCP-1.1.1-universal.dmg`.
Preserve the current App and state, and safely hand off active work before
upgrading. Do not replace the backend performing the upgrade itself.

Existing embedded Codex execution requires the explicit
[configuration and state migration](CodexMigration.md). Stop the old writers,
review the offline migration, and retain all new adapter records if recovery
is needed. Configuration import alone does not transfer execution ownership.
Host workspaces, profiles, grants, audit and credential references remain
host-owned. Plugin settings survive package updates; new installs start disabled.

## Availability boundaries

Native CUA action availability still depends on vendor caller authentication;
catalog discovery does not prove actions work. Native AX remains available as
a separate fallback. Actual ChatGPT client hot refresh and credential GUI
write actions require their own acceptance evidence; server and CLI tests are
not substitutes. Public GitHub access may be rate limited. Independent plugins
retain their own architecture and signing requirements.

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
