# Computer MCP 1.2.2 Production Readiness Report

Status: release record template. This file specifies the required evidence;
the release execution record determines whether those checks have passed.

## Candidate identity

| Field | Final value |
| --- | --- |
| Release date | __RELEASE_DATE__ |
| Commit | `__RELEASE_COMMIT__` |
| Signed tag | `__RELEASE_TAG__` |
| Signed tag object | `__RELEASE_TAG_OBJECT__` |
| App version/build | 1.2.2 (38) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.2.2-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Required source and package evidence

Shared CI checks cover formatting, all Swift tests, Validation fixtures,
dependency identity, the CLI, documentation, release scripts and packaging.
Lifecycle regressions cover concurrent startup/shutdown, initialization response
reentrancy, queued initialization errors, cancellation, reconnect, crash recovery,
process deadlines and plugin directory restoration.

The candidate must come from the official repository's main branch and retain
its protected signing and notarization provenance. Actual bundle metadata,
Universal 2 slices, Developer ID identity, entitlements, notarization, staples and
Gatekeeper checks must agree with the exact artifact accepted locally.

Installation acceptance binds cold-start concurrent operations, workspace
operations, plugin management and complete cleanup to that artifact's digest.
Packaged execution must work without access to the producing source/build tree.
Product version and build number alone cannot identify accepted bytes.

The formal tag follows successful candidate acceptance. Publication promotes
the accepted artifact and checks the downloaded public bytes against it.
Independent plugin and SDK artifacts require their own component evidence;
host signing does not attest those components or vendor executables.

## Evidence boundaries

Source tests do not substitute for installation acceptance. A development
bundle does not substitute for the signed production candidate. Missing,
untrusted or mismatched results require the affected stages to run again.
Failure history remains available when a corrected candidate is accepted.

Live account, model, native permission and external consumer checks must be
identified by the actual executed case and result. Ordinary CI does not imply
that these checks ran. This template does not itself prove installation,
production cutover or public delivery.
