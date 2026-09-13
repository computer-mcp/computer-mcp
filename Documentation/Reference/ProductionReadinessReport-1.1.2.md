# Computer MCP 1.1.2 Production Readiness Report

Status: protected-CI release template. Artifact preparation leaves an unpublished
draft. Public release additionally requires local installation acceptance of
that exact package under the [release procedure](Release.md).

## Candidate identity

| Field | Final value |
| --- | --- |
| Release date | __RELEASE_DATE__ |
| Commit | `__RELEASE_COMMIT__` |
| Signed tag | `__RELEASE_TAG__` |
| Signed tag object | `__RELEASE_TAG_OBJECT__` |
| App version/build | 1.1.2 (33) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.1.2-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Source and artifact verification

The source gates cover strict formatting, build/tests, Validation catalog,
package ownership, CLI interface, localization, documentation and dependency
metadata. The packaged-localization regression compiles and launches a disposable
App using the production resource resolver and a failing SwiftPM fallback.
It is a focused regression test, not an installed-product acceptance result.

Artifact gates bind the signed annotated tag, source commit, App/CLI versions,
Universal 2 slices, Developer ID identity, entitlements, accepted notarization,
stapled tickets, Gatekeeper assessment, checksums and uploaded byte identity.
The preparation workflow cannot automatically make the draft public.

## Installation and production acceptance

The operator records the final package identity and outcomes for management
pages, localized controls, workspace and MCP registration, plugin lifecycle,
gateway startup, cleanup, first launch and preserved-state migration before
publication. A changed package requires new installation acceptance.

After publication, production upgrade and regression use the accepted bytes.
Preserve a rollback copy and stop the exact old writers before transferring
Codex ownership. Reconcile new domain records before rolling back; restoring an
outdated snapshot is not a valid recovery after the adapter has written state.

## External boundaries

Live vendor, account and network tests are opt-in; an ordinary CI pass does not
imply they ran. Native CUA caller authentication, actual ChatGPT client hot
refresh and credential GUI write actions require separate evidence. Public
GitHub rate limits can prevent live search or installation. Host signing does
not attest an independent plugin's executable or external dependencies.

This rendered record identifies the artifact and release requirements. Its
presence in a draft does not claim installed acceptance or production cutover
has completed. Prior release records and tags remain immutable.
