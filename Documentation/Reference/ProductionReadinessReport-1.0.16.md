# Computer MCP 1.0.16 Production Readiness Report

Status: **Notarized CI candidate; publication requires 22/22 exact-artifact
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
| App version/build | 1.0.16 (17) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.0.16-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Automated gates

| Gate | Required evidence |
| --- | --- |
| Root and Validation strict format/lint | Passed by the bound GitHub Actions run |
| Root and Validation native build/test | Passed by the bound GitHub Actions run |
| App/CLI package and version boundary | 1.0.16 (17), passed by the bound run |
| Validation canonical catalog | 22 publisher-verifiable Test Cases with exact ID equality |
| Workspace selection | System user-selected folder importer on macOS 14–26; in-App SwiftUI directory browser on macOS 27; both enter the same bookmark grant path and update in place |
| Workspace containment | Existing ancestors resolve before authorization; escaping symlink parents and targets remain denied |
| Recursive symlink scanning | Final symlink identity is preserved; recursive content tools never follow targets |
| Authenticated runtime observations | Exact request, Gateway, transport, profile, and audit correlation |
| Full-catalog runtime harness | Every advertised tool is called with bounded fixtures and one correlated audit row |
| Reviewed upstream directory challenge | Only structured `codex.app.request_failed` HTTP 403 with failed `gateway.execution_failed` audit is admissible as `expected_failure` |
| Cloudflare publisher boundary | Quick Tunnel isolation and named lifecycle/auth unit tests are mandatory; live named deployment uses user-owned account, hostname, and token |
| Effective configuration export | Replayable grants and capabilities without credentials or proxy material |
| Provider lifecycle | App Server, Exec, MCP, HTTP, stdio, downstream, and Tunnel resources terminate with their owner |
| Codex API boundaries | Typed `swift-codex` App Server, isolated Exec, and MCP provider lifecycles |
| English / zh-Hans localization | Passed by the bound GitHub Actions run |
| Standalone examples and CLI interface | Passed by the bound GitHub Actions run |
| Signed-tag provenance | Fresh canonical checkout, verified signature, exact commit, and master reachability |
| Protected credential boundary | Apple secrets available only after no-secret verification and production Environment approval |
| Universal 2 binaries | `arm64` and `x86_64` slices verified in App and embedded CLI |
| Developer ID and Hardened Runtime | Valid Team, timestamp, entitlements, and provisioning profile |
| Notarization / staple / Gatekeeper | Accepted and validated for both App and DMG |
| Release assets | Complete deterministic root layout and checksum read-back |
| Legal approval | Publisher-approved `LICENSE`, `EULA.md`, and `PRIVACY.md` are present in the signed tag |
| `LICENSE` SHA-256 | `35f08f36a403bfdd958723e1fc32166400f607ac22521f6d5f86c4a173ab53f3` |
| `EULA.md` SHA-256 | `de5f383b73fd5a3f43c4708c33abd30e80a28650979c671b38345cc4e49f8941` |
| `PRIVACY.md` SHA-256 | `e55fcf9c8e64ea65e873c9f21faced866b98774086f4188bd2acaa26ee8d5586` |
| Dependency / license / SBOM reproducibility | 13 linked, 28 resolved-only, 41 total |
| Repository and secret hygiene | Passed before protected credentials are exposed |

## Installation matrix

| Environment | Required coverage | Result |
| --- | --- | --- |
| Apple Silicon, macOS 14+ | DMG cold install, Finder launch, workspace panel, TCC/state/CLI lifecycle, and exact catalog | Required before draft publication |
| Apple Silicon with Rosetta 2 | Direct x86_64 App/CLI launch and bounded compatibility check | Required before draft publication |

A physical Intel Mac is not a 1.0.16 release gate. Universal 2 slice checks and
Rosetta 2 checks cover x86_64 compatibility; the full installation and
acceptance lifecycle runs natively on Apple Silicon.

## Publication acceptance

The workflow creates a draft and cannot publish it. Before publication, the
publisher must complete all 22 canonical Test Cases against the checksummed DMG
above and resolve every advertised catalog tool to either a semantic success,
a policy-defined expected denial, or a specifically reviewed fail-closed
expected failure. Every tool call must retain its exact correlated audit row.

The upstream HTTP 403 exception is limited to `codex.app.apps.list` and the
complete structured marker/audit tuple described above. It does not waive
ChatGPT acceptance: a new ChatGPT session must still discover Computer MCP and
complete the real Full Shell request through the authenticated Secure MCP
Tunnel. Local workspace, Shell, tunnel, and audit paths must succeed normally.

Cloudflare live named-tunnel deployment is supported but conditional on a
deploying user's own account, domain, hostname, and runtime token. The release
does not acquire, store in CI, or manufacture those user production resources.
The mandatory Cloudflare journey record covers the isolated transport and
authentication boundary; users validate their own named deployment with the
Cloudflare runbook.

Publishing the existing GitHub draft is the operator attestation that the
installation matrix and all canonical Test Cases passed on this exact
artifact. The publisher must not rebuild or replace any checksummed asset
between acceptance and publication.
