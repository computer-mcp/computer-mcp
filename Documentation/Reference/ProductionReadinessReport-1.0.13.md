# Computer MCP 1.0.13 Production Readiness Report

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
| App version/build | 1.0.13 (14) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.0.13-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Automated gates

| Gate | Current evidence |
| --- | --- |
| Root and Validation strict format/lint | Passed by the bound GitHub Actions run |
| App/CLI package boundary | Passed by the bound GitHub Actions run |
| Exact swift-codex dependency | `0.1.2` / `0bdd92a53fa3b91cd5fb8934eb11c7878a6e022b` |
| Root and Validation native build/test | Passed by the bound GitHub Actions run |
| Validation 23-case catalog schema | Passed by the bound GitHub Actions run |
| Codex child proxy environment | App Server, Exec, and MCP resolve fixed macOS HTTP/HTTPS/SOCKS proxies; explicit inherited variables win; loopback bypasses the proxy; no derived value is persisted or logged |
| Codex production proxy regression | A source-built standalone Gateway with no inherited proxy variables must complete `codex.app.apps.list` through the active fixed macOS proxy |
| Authenticated runtime observation contract | OpenAI Secure MCP Tunnel evidence requires complete audit-derived instance, profile, and socket identities and remains consumer-free |
| Validation Observation / Evidence schema | Schema 2 binds `passed`, policy `expected_denial`, and reviewed fail-closed `expected_failure` to exact audit decisions; raw failures remain inadmissible |
| Effective configuration export | Replayable workspace grants, profile capabilities, and persisted Full Shell state with no credential or proxy material |
| Gateway provider lifecycle | Disconnect and stop regressions release App Server, Exec, MCP, HTTP, stdio, workspace, and downstream resources |
| Codex App Server API boundary | Reviewed methods use typed `swift-codex` calls with policy and workspace checks |
| Codex Exec user-config isolation | New and resumed sessions use the typed upstream `--ignore-user-config` boundary while retaining user-owned `CODEX_HOME` authentication |
| Full-catalog runtime harness | Bounded timeout, isolated Computer Use helper, real Full Shell lifecycle, structured failure and audit validation |
| Exact-artifact catalog acceptance | Requires 287/287 semantic passes and correlated audit decisions before publication |
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
| `PRIVACY.md` SHA-256 | `e55fcf9c8e64ea65e873c9f21faced866b98774086f4188bd2acaa26ee8d5586` |
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
| Apple Silicon, macOS 14+ | DMG cold install, Finder launch, TCC/state/CLI lifecycle, Codex fixed-proxy resolution | Required before draft publication |
| Apple Silicon with Rosetta 2 | Direct x86_64 App/CLI launch and bounded compatibility check | Required before draft publication |

A physical Intel Mac is not a 1.0.13 release gate. Universal 2 slice checks and
Rosetta 2 checks cover x86_64 compatibility; the full installation and
acceptance lifecycle runs natively on Apple Silicon.

## Publication acceptance

The workflow creates a draft and cannot publish it. Before publication, the
publisher must complete all 23 Test Cases against the checksummed DMG above,
including 287/287 advertised tool calls and correlated audit decisions after a
normal Finder launch. Each PASS must bind its schema-2 result class, consumer
result or runtime request, authenticated transport or Tunnel instance, Gateway
request ID, one audit row, result digest, and cleanup digest to this candidate
identity. The exact-artifact `config.export` inventory must match the effective
authenticated catalog, including persisted Full Shell and workspace grants.
OpenAI acceptance uses a fresh Connector scan and a new ChatGPT session.
Cloudflare named-tunnel acceptance uses a test or user-owned account, hostname,
and runtime token; no Cloudflare credential belongs to the product or release
workflow, and Quick Tunnel evidence cannot substitute for this case.

Publishing the existing GitHub draft is the operator attestation that the
installation matrix and all 23 Test Cases passed on this exact artifact. The
publisher must not rebuild or replace any checksummed asset between acceptance
and publication.
