# Computer MCP 1.2.0 Release Notes

Status: protected-CI release template. The final signed and notarized package
must pass local installation acceptance before its draft is made public.

## Highlights

- Configure independent host permission modes, capability and workspace grants,
  and local confirmation policy through the App or management CLI.
- Bind approvals to the verified caller, arguments, target and authorization
  revision; revocation invalidates approvals awaiting a decision.
- Preserve MCP execution receipts across reconnections and restarts, including
  bounded events, cancellation state and writes whose outcome is unknown.
- Use the independent Codex plugin for native App Server and Exec configuration,
  approvals, Full Access, thread ownership and lifecycle management.
- Present CLI, Codex, MCP and Skills through the shared Computer MCP identity,
  with a bilingual website and matching product documentation.

## Installation and recovery

Verify `SHA256SUMS` before installing `Computer-MCP-1.2.0-universal.dmg`.
Preserve the current App and state, and safely hand off active work before
upgrading. Do not replace the backend performing the upgrade itself.

Existing embedded Codex execution requires the explicit
[configuration and state migration](CodexMigration.md). Stop the old writers,
review the offline migration, and retain all new adapter records if recovery
is needed. Configuration import alone does not transfer execution ownership.
Host workspaces, profiles, grants, audit and credential references remain
host-owned. Plugin settings survive package updates; new installs start disabled.

## Availability boundaries

Native CUA action availability depends on vendor caller authentication;
catalog discovery does not prove actions work. Native AX remains available as
a separate fallback. Server catalog notifications do not guarantee actual
ChatGPT client hot refresh. Public GitHub access may be rate limited.
Independent plugins retain their own architecture and signing requirements.

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
