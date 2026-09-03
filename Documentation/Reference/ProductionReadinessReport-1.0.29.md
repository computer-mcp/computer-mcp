# Computer MCP 1.0.29 Production Readiness Report

Status: **Protected-CI release template. All local source, control-plane,
documentation, metadata, and development-distribution gates passed before
tagging; publication remains fail-closed on the exact signed and notarized
artifact.**

This report is rendered by the protected GitHub release job and bound to the
signed tag, source commit, Universal 2 App, embedded CLI, notarized DMG,
notarization receipts, and workflow run below.

## Candidate identity

| Field | Final value |
| --- | --- |
| Release date | __RELEASE_DATE__ |
| Commit | `__RELEASE_COMMIT__` |
| Signed tag | `__RELEASE_TAG__` |
| Signed tag object | `__RELEASE_TAG_OBJECT__` |
| App version/build | 1.0.29 (30) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.0.29-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Acceptance evidence

| Gate | Evidence |
| --- | --- |
| Shared control plane | App adapter and owner-only control Socket exercise the same lifecycle-aware operations for gateway, workspace, profile, configuration, provider, and tunnel administration; focused integration and App adapter regressions passed |
| Capability contract | Control tool contracts exactly match the machine-readable catalog at runtime; read-only annotations and CLI command mappings passed executable-derived verification |
| CLI surface | Generated help and documented commands match; every new owner-control command parses and returns structured errors consistently |
| Secret handling | OpenAI API keys and Cloudflare tunnel tokens are accepted only through bounded standard input, stored in Data Protection Keychain, redacted from results, and restored on failed persistence |
| Accessibility safety | Self-target Accessibility actions fail with `computer_use.self_target_forbidden`; action execution is dispatched through the main actor |
| Ownership boundary | Remote MCP cannot register workspaces or invoke the owner CLI through a self-registered provider; local administration remains owner-only |
| Compatibility | Schema-1 configuration, workspaces, profiles, grants, audit history, tunnel references, Bundle ID, Team ID, Keychain group, and runtime namespace are preserved |
| Automated regression | Strict format/lint and supported builds passed; 827 root + 25 App + 71 Validation tests = 923; 22 Validation Test Cases passed catalog validation |
| Documentation and metadata | CLI, examples, 483-key English/Simplified-Chinese localization, naming, DocC warnings-as-errors, release templates, and deterministic 13 linked + 28 resolved-only dependency metadata gates passed |
| Development distribution | Independent arm64 and x86_64 release builds produced a provenance-bound 1.0.29 (30) ad-hoc development App and DMG; mounted distribution verification passed |
| Runtime isolation | Candidate builds and tests used repository or temporary paths. Installed 1.0.28 (29) remained at `/Applications/Computer MCP.app` under its unchanged PID throughout validation |

## Protected artifact gates

The tag workflow must prove all of the following against one fresh artifact
closure before publication:

- signed annotated tag, exact commit, and `origin/master` reachability;
- Universal 2 App and CLI, Developer ID, Hardened Runtime, provisioning profile,
  timestamp, entitlements, and stable production identity;
- accepted App and DMG notarization records, valid staples, and Gatekeeper;
- complete checksummed release assets, candidate provenance, uploaded/downloaded
  DMG byte equality, and exact-published provenance;
- repository, dependency, license, SBOM, secret, release-boundary, and protected
  production-Environment gates.

The workflow creates no replaceable partial public artifact. A failure remains
closed; a source correction requires a new version and never moves this tag.

## Migration and compatibility

No database migration is required for the control-plane consolidation. Existing
configuration, bookmarks, profile grants, tunnel configuration, Keychain data,
and audit history are preserved. The new local capability catalog is additive
and versioned independently with `schema_version: 1`.

## Legal and release identity

Publisher-approved `LICENSE`, `EULA.md`, and `PRIVACY.md` remain unchanged.
Their digests are verified by the protected workflow. v1.0.28 remains the
immutable production predecessor and is not rebuilt, retagged, replaced, or
interrupted by candidate validation.

## Final attestation

Publication of the rendered record attests that the exact candidate passed the
protected artifact gates and that the public GitHub asset is byte-identical to
the signed, notarized, stapled, Gatekeeper-assessed candidate.
