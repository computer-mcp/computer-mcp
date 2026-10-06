# Computer MCP __VERSION__ Production Readiness Report

## Candidate identity

| Field | Final value |
| --- | --- |
| Release date | __RELEASE_DATE__ |
| Commit | `__RELEASE_COMMIT__` |
| Signed tag | `__RELEASE_TAG__` |
| Signed tag object | `__RELEASE_TAG_OBJECT__` |
| App version/build | __VERSION__ (__BUILD__) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-__VERSION__-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Required evidence

The protected cloud release pipeline owns source checks, packaged distribution
verification, Developer ID signing, notarization and publication. Its shared
checks cover dependency identity, formatting, Swift and Validation fixtures,
interfaces, documentation, release boundaries and distribution. The brand check
verifies imported brand resources. The exact App and DMG must agree with their
candidate manifest, Universal 2 architectures, signature, entitlements,
notarization and staples.

The signed tag identifies the candidate's canonical master commit. Publication
promotes the unchanged notarized DMG, verifies every uploaded asset and checks
unauthenticated public downloads. The website automatically imports the public
release record through its Pages workflow and deploys the verified generation.
Independent plugins retain their own versions and release evidence.

## Evidence boundaries

This report describes cloud release evidence. Native TCC permissions, local App
navigation, workspace operations and installed-plugin integration depend on the
user's Mac; this report supplies no result for those checks. Local installation
and optional installed diagnostics are separate operations from publication.
