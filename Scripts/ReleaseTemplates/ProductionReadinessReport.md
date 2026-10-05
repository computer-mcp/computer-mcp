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

The shared release pipeline owns source, package and installed acceptance.
Its existing checks cover dependency identity, formatting, Swift and Validation
fixtures, interfaces, documentation, release boundaries and distribution.
The brand check binds editable sources to generated exports and the App icon
declaration. Distribution verification compares the bundled icon bytes with
the canonical export and checks the packaged App against the producing App.
Each change's regression evidence is part of its reviewed pull request.

The candidate comes from the official repository's canonical `master` and
retains protected production signing and notarization provenance. Universal 2
slices, Developer ID identity, entitlements, notarization, staples and Gatekeeper
must agree with the exact accepted artifact. Development bundles do not supply
that evidence.

Installed acceptance verifies exact App identity, native permissions, cold and
concurrent packaged execution without access to its producing source tree,
App navigation, workspace operations and the installed Codex plugin's controlled
fixture integration. The App and plugin identities must remain unchanged through
acceptance. Fixture execution does not attest an authenticated real model.

Production replacement is a separately authorized operation. The formal signed
tag follows successful installed acceptance; publication promotes the accepted
bytes and verifies downloaded public artifacts. The website imports the public
delivery record only after publication. Independent plugins retain their own
versions and release evidence.

## Evidence boundaries

Source checks do not substitute for signed artifact acceptance. Missing,
untrusted or mismatched evidence requires the affected existing stage to run
again. This report specifies the gate; it does not itself prove installation,
production cutover or public delivery.
