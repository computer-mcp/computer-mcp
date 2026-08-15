# Computer MCP 1.0.9 Production Readiness Report

Status: **Notarized CI candidate; publication requires 23/23 artifact
acceptance**.

This report is rendered by the protected GitHub release job only after signing,
notarization, stapling, Gatekeeper, and checksum gates pass. It is bound to the
signed tag, App, embedded CLI, notarized DMG, notarization receipts, and
workflow run recorded below. Development runs are regression context and do
not satisfy this record.

## Candidate identity

| Field | Final value |
| --- | --- |
| Release date | __RELEASE_DATE__ |
| Commit | `__RELEASE_COMMIT__` |
| Signed tag | `__RELEASE_TAG__` |
| Signed tag object | `__RELEASE_TAG_OBJECT__` |
| App version/build | 1.0.9 (10) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.0.9-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Automated gates

| Gate | Current evidence |
| --- | --- |
| Root and Validation strict format/lint | Passed by the bound GitHub Actions run |
| App/CLI package boundary | Passed by the bound GitHub Actions run |
| Exact swift-codex dependency | `0.1.1` / `e2d745cdba3281c62519906c2e1b1579bf053b8f` |
| Root and Validation native build/test | Passed by the bound GitHub Actions run |
| Validation 23-case catalog schema | Passed by the bound GitHub Actions run |
| Gateway provider lifecycle | Disconnect and stop regressions release App Server, Exec, MCP, HTTP, stdio, workspace, and downstream resources |
| Codex App Server API boundary | Reviewed methods use typed `swift-codex` calls with policy and workspace checks |
| Full-catalog runtime harness | Bounded timeout, isolated Computer Use helper, real Full Shell lifecycle, structured failure and audit validation |
| Development-candidate catalog rehearsal | 287/287 semantic passes, 287/287 audit correlations, zero retained App Server/MCP children after disconnect |
| English / zh-Hans localization | Passed by the bound GitHub Actions run |
| Standalone example configurations | Passed by the bound GitHub Actions run |
| Fresh canonical checkout and branch reachability | Passed for `__RELEASE_TAG__` / `__RELEASE_COMMIT__` |
| Protected runner tool boundary | Formal release path uses no Homebrew or ripgrep dependency |
| DMG signing order and signature records | Passed positive and negative pre-secret gates |
| Notarization response parsing | Passed accepted/rejected/missing/malformed/invalid-ID fixtures |
| Release asset layout and checksums | Passed deterministic root-level assembly and complete read-back verification |
| Installed CLI upgrade | Passed user-owned old-App-to-new-App symlink migration without weakening ownership protection |
| Managed OpenAI Tunnel target upgrade | Passed forced profile refresh before doctor and launch, including fail-closed refresh-error coverage |
| Legal text approval gate | Publisher-approved legal files are present in the signed tag |
| `LICENSE` SHA-256 | `35f08f36a403bfdd958723e1fc32166400f607ac22521f6d5f86c4a173ab53f3` |
| `EULA.md` SHA-256 | `de5f383b73fd5a3f43c4708c33abd30e80a28650979c671b38345cc4e49f8941` |
| Universal 2 binary gate | Passed for `__APP_ARCHITECTURES__` |
| App Developer ID / Hardened Runtime / timestamp | Passed for Team `__APPLE_TEAM_ID__` |
| DMG Developer ID / timestamp | Passed for Team `__APPLE_TEAM_ID__` |
| Notarization / staple / Gatekeeper | Passed for both recorded submissions |
| DocC warning gate | Passed by the bound GitHub Actions run |
| Dependency / license / SBOM reproducibility | Passed: 13 linked, 28 resolved-only, 41 total |
| Repository and secret hygiene | Passed before protected credentials were exposed |

## Installation matrix

| Environment | Required coverage | Result |
| --- | --- | --- |
| Apple Silicon, macOS 14+ | DMG cold install, Finder launch, TCC/state/CLI lifecycle | Required before draft publication |
| Apple Silicon with Rosetta 2 | Direct x86_64 App/CLI launch and bounded compatibility check | Required before draft publication |

A physical Intel Mac is not a 1.0.9 release gate. Universal 2 slice checks and
Rosetta 2 checks cover x86_64 compatibility; the full installation and
acceptance lifecycle runs natively on Apple Silicon.

## Publication acceptance

The workflow creates a draft and cannot publish it. Before publication, the
publisher must complete all 23 Test Cases against the checksummed DMG above.
Each PASS must bind consumer result, transport or tunnel instance, Gateway
request ID, one audit row, result digest, and cleanup digest to this candidate
identity. OpenAI acceptance uses a fresh Connector scan and a new ChatGPT
session. Cloudflare named-tunnel acceptance uses a test or user-owned account,
hostname, and runtime token; no Cloudflare credential belongs to the product or
release workflow, and Quick Tunnel evidence cannot substitute for this case.

Publishing the existing GitHub draft is the operator attestation that the
installation matrix and all 23 Test Cases passed on this exact artifact. The
publisher must not rebuild or replace any checksummed asset between acceptance
and publication.
