# Computer MCP 1.1.0 Production Readiness Report

Status: protected-CI release template. The release workflow publishes this
record only after verifying its exact signed, notarized artifact. External
acceptance boundaries below remain explicit and are not converted into passes
by a successful build.

## Candidate identity

| Field | Final value |
| --- | --- |
| Release date | __RELEASE_DATE__ |
| Commit | `__RELEASE_COMMIT__` |
| Signed tag | `__RELEASE_TAG__` |
| Signed tag object | `__RELEASE_TAG_OBJECT__` |
| App version/build | 1.1.0 (31) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.1.0-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Enforced source and artifact gates

- Strict formatting, root build/tests, Validation package build/tests and
  test-case catalog validation. Live vendor/account/network tests are opt-in;
  an ordinary CI pass does not imply they ran.
- Package ownership, public-repository hygiene, naming, CLI interface,
  localization, examples, DocC and deterministic dependency/license metadata.
- Signed annotated tag bound to the exact source commit and reachable from
  `origin/master`; version, build and release records must agree.
- Universal 2 App and embedded CLI, Developer ID identity, hardened runtime,
  provisioning profile, timestamp and entitlements.
- Accepted App and DMG notarization, valid staples and Gatekeeper assessment.
- Complete checksummed assets, provenance, and uploaded/downloaded DMG byte
  equality before the GitHub release becomes public.

## Architecture and migration coverage

The source suite exercises combined plugin contributions, source selection,
settings preservation, archive safety, rollback and cleanup. MCP coverage
includes all/whitelist exposure, schema changes, caller grants, pagination,
notifications, multimodal responses, cancellation and independent process
ownership. CLI tests cover explicit tree semantics and deterministic argument
encoding; Skills tests cover bounded reads and contribution ownership.

Codex configuration export and offline seven-table import preserve host-owned
workspaces, profiles, grants, audit and credential references. Independent
adapter integration has disposable thread/Goal, approval, interruption,
recovery, release and non-replayed-write evidence. These checks do not perform
production migration. Follow [Codex migration](CodexMigration.md), preserve a
rollback copy and stop the exact old writers before transferring ownership.

## External acceptance boundaries

- Native CUA catalog discovery succeeded, but actual calls from the tested
  caller were rejected by the vendor. A real disposable AX fallback path was
  verified; vendor caller authentication is not bypassed.
- Actual ChatGPT client hot refresh and credential GUI write actions have not
  been manually verified. Server-side refresh tests and signed-host CLI
  Keychain checks are separate evidence, not substitutes for those actions.
- GitHub discovery and package installation depend on public API availability
  and rate limits. Offline archive checks do not prove a successful live
  download in a rate-limited environment.
- Independent plugin architecture/signature requirements remain their own
  contract; host signing does not attest every external executable.

## Legal and publication

The publisher's LICENSE, EULA and privacy policy remain applicable. Third-party
components retain their original licenses. Prior tags and release records are
immutable. Publication of this rendered record attests to the protected
artifact gates, not to unperformed production cutover or the external
acceptance items explicitly identified above.
