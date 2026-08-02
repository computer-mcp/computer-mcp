# Computer MCP 1.0.0 Production Readiness Report

Status: **NOT READY — release gates remain open**.

This report is bound only to the final signed App, embedded CLI, notarized DMG,
commit, and evidence manifest recorded below. Historical 279/279, 17/17, or
development 23-case runs are regression context and cannot satisfy this
release record.

## Candidate identity

| Field | Final value |
| --- | --- |
| Commit | Pending |
| Signed tag | Pending |
| App version/build | 1.0.0 (1) |
| Architectures | Pending (`arm64`, `x86_64` required) |
| Apple Team ID | Pending |
| Embedded CLI SHA-256 | Pending |
| DMG | `Computer-MCP-1.0.0-universal.dmg` |
| DMG SHA-256 | Pending |
| Notarization submission | Pending |
| Evidence archive SHA-256 | Pending |

## Automated gates

| Gate | Current evidence |
| --- | --- |
| Root strict format/lint | Passed locally on 2026-08-09 |
| App/CLI package boundary | Passed locally on 2026-08-09 |
| Exact swift-codex dependency | `0.1.1` / `e2d745cdba3281c62519906c2e1b1579bf053b8f` |
| Root native build/test | 687 tests, 40 suites, 0 failures on 2026-08-09 |
| Validation native build/test | 45 tests, 8 suites, 0 failures on 2026-08-09 |
| Fresh remote clone | Pending for final public commit/tag |
| Legal text approval | Pending approval by Xudong Xu and legal review |
| Universal 2 binary gate | Development gate passed; final Developer ID gate pending |
| Developer ID / Hardened Runtime / timestamp | Pending |
| Notarization / staple / Gatekeeper | Pending |
| DocC warning gate | Passed locally on 2026-08-09 |
| Dependency / license / SBOM reproducibility | Passed locally: 13 linked, 28 resolved-only, 41 total |
| Repository and secret hygiene | Passed locally on 2026-08-09 |

The development-only Universal 2 App and DMG gate passed locally from two newly
built architecture slices. The artifact is ad-hoc signed regression evidence
only; it does not close any final distribution gate above and must not be
published as the 1.0.0 release.

Local results above prove the current working tree only. They will be rerun on
the final candidate and replaced by CI and release-artifact evidence.

## Installation matrix

| Environment | Required coverage | Result |
| --- | --- | --- |
| Apple Silicon, macOS 14+ | DMG cold install, Finder launch, TCC/state/CLI lifecycle | Pending |
| Apple Silicon with Rosetta 2 | Direct x86_64 App/CLI launch and bounded compatibility smoke | Pending |

A physical Intel Mac is not a 1.0.0 release gate. The Universal 2 slice checks
and Rosetta 2 smoke cover x86_64 compatibility; the full installation and
acceptance lifecycle runs natively on Apple Silicon.

## Final 23 Test Cases

Pending. Each PASS must bind consumer result, transport/tunnel instance,
gateway request ID, one audit row, result digest, and cleanup digest to the
candidate identity above. Cloudflare requires a remotely managed named tunnel
and a public external MCP client. OpenAI requires a fresh Connector scan and a
new ChatGPT session. Quick Tunnel evidence cannot substitute for named-tunnel
evidence.

The status may change to **1.0.0 production ready** only after every pending
field and all 23 Test Cases pass on the same final artifact.
