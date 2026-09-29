# Computer MCP 1.3.0 Production Readiness Report

Status: release record template. This file specifies the required evidence;
the release execution record determines whether those checks have passed.

## Candidate identity

| Field | Final value |
| --- | --- |
| Release date | __RELEASE_DATE__ |
| Commit | `__RELEASE_COMMIT__` |
| Signed tag | `__RELEASE_TAG__` |
| Signed tag object | `__RELEASE_TAG_OBJECT__` |
| App version/build | 1.3.0 (39) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.3.0-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Required source and package evidence

Shared CI checks cover formatting, all Swift tests, Validation fixtures,
dependency identity, CLI contracts, documentation, release scripts and packaging.
Registry decomposition must preserve the complete tool/schema/capability and
policy inventory. Native Windows core and plugin checks identify their exact
source, toolchain, archive and runtime dependency closure independently.

Connected-client acceptance covers workspace, MCP and plugin changes; tool
visibility on an existing connection; retained ownership of in-flight work;
update, rollback and reap; and Secure MCP Tunnel/client continuity. Permission
cases cover Observe/Control, Restricted/Full Access, session consent, persistent
trust, current grants and revocation, including retained host callbacks.

The exact selected plugin packages must pass installation, configuration,
doctor and tool visibility checks. Codex acceptance covers complete adopted
App Server projection, bounded long-thread hydration, exact JSON integers,
approval routing, cancellation and joined cleanup. Host Services and CLI Tree
checks use their declared schemas and authority boundaries. Official catalog
discovery and selected-release provenance are checked separately.

The candidate must come from the official repository's canonical `master`
branch and retain its protected signing and notarization provenance. Actual
bundle metadata, Universal 2 slices, Developer ID identity, entitlements,
notarization, staples and Gatekeeper checks must agree with the exact artifact
accepted in an isolated host. Packaged execution must work without access to
the producing source/build tree. Version/build alone cannot identify bytes.

The formal tag follows successful candidate acceptance. Publication promotes
the accepted artifact and checks downloaded public bytes against it.
Independent plugin and SDK artifacts require their own component evidence;
host signing does not attest those components or vendor executables.

## Evidence boundaries

Source tests do not substitute for artifact acceptance. A development bundle
does not substitute for the signed production candidate. Missing, untrusted or
mismatched results require the affected stages to run again. Failure history
remains available when a corrected candidate is accepted.

Live account, model, native permission and external consumer checks must be
identified by the actual executed case and result. Fixture and native protocol
success do not prove authenticated model behavior. An isolated candidate does
not authorize replacing the production App; production rollout is a separate
reviewed operation. This template does not itself prove installation, cutover
or public delivery.
