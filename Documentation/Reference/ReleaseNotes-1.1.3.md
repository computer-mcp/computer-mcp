# Computer MCP 1.1.3 Release Notes

Status: protected-CI release template. The final signed and notarized package
must pass local installation acceptance before its draft is made public.

## Highlights

- Expose `workspace_id` in the `mcp.tools.call` input schema. Clients can
  select the workspace required by downstream host-service invocations.
- Support host callbacks from standalone manifest workspaces with an audit or
  plugin database; persisted workspace changes continue to revoke the old scope.
- Keep a connection identity for each standalone stdio run so callback and
  thread-release attribution remains bound to that run.
- Exercise discovered argument fields through native execution, Goal
  preservation, release and reconnection with direct and generic tool routes.

## Installation and recovery

Verify `SHA256SUMS` before installing `Computer-MCP-1.1.3-universal.dmg`.
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
