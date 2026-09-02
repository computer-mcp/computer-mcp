# Computer MCP 1.0.26 Production Readiness Report

Status: **Protected-CI release template; publication requires exact-artifact,
productization-contract, and coordinated website acceptance.**

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
| App version/build | 1.0.26 (27) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.0.26-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Automated gates

| Gate | Required evidence |
| --- | --- |
| Root and Validation strict format/lint | Passed by the bound GitHub Actions run |
| Root and Validation supported-default build/test | Passed by the bound GitHub Actions run |
| App/CLI package and version boundary | 1.0.26 (27), passed by the bound run |
| Validation canonical catalog | 22 publisher-verifiable Test Cases with exact ID equality |
| Production productization contract | All 182 O/A–J/T/R/W/Q/CS criteria resolved with implementation, test, documentation, website, or release evidence |
| End-to-end App Server deadlines | Normal calls share one configured budget across connection startup, workspace validation, reviewed RPC, and the sole read-only retry; `app/list` uses one separately configured generation and must return its bounded page before that deadline |
| Large App Server responses | A deterministic 4 MiB long-lived protocol line, official Codex `skills/list`, and a multi-megabyte `app/list/updated` notification followed by a bounded Apps page complete without waiting for EOF or crossing one actor boundary per byte; tracked draining also preserves the final line from a short-lived process |
| Codex process lifecycle | Owned process-group identity and bounded EOF/TERM/KILL/reap across close, replacement, timeout, shutdown, parent death, stubborn descendants, and back-pressured stdin |
| Close idempotence | Concurrent and repeated teardown paths share one retirement task and do not multiply grace intervals or process signals |
| Real official-client handoff | First owned client completes a turn and is reaped; a second official client resumes and archives the durable thread, then is reaped; exceptional paths reap every test-owned process and archive any created temporary thread through a fresh workspace-scoped client |
| Thread ownership diagnosis | Durable workspace/runtime receipts, safe release/reclaim, reviewed cleanup, and actionable conflict classification without external-process control |
| Approval broker | Persisted approve-once, bounded-session, deny, timeout, malformed, out-of-scope, automatic-low-risk, and restart-interruption coverage with redaction |
| Governed Git | Real temporary-repository stage/commit path, reviewed message, hooks, clean final status, and full request/approval/ticket/audit/result correlation |
| Official Goal boundary | Stable official Goal get/set/clear and steering; native state stays distinct from Computer MCP acceptance runs |
| Long-task orchestration | Durable criteria/evidence, approval pause/resume, budgets, stall and contradiction detection, selected-child reconciliation, and explicit accepted completion |
| Multi-executor safety | Exclusive or isolated worktree leases, lineage, revision conflicts, reviewed managed worktree lifecycle, and no silent overwrite |
| Diagnostic and secret boundary | Bounded/redacted App Server, Exec, MCP, approval, event, run, lease, and audit data with digest-only unsafe identifiers |
| Product documentation | Product-first English and Simplified Chinese manuals, normative acceptance contract, architecture, CLI, configuration, tools, and troubleshooting references |
| Independent product website | Separate `computer-mcp.github.io` repository passes format, HTML, production build, link, Axe, keyboard, mobile, and browser-acceptance gates with no `CNAME` |
| Cold-start maintainability | A fresh Codex task explains product/trust/ownership, diagnoses a conflict, runs the full suite, safely updates one capability, tests the website, and finds release procedure |
| Launch at login | Missing main-App state is registerable; successful registration reaches enabled without a helper LaunchAgent |
| Menu-bar identity and window lifecycle | Native labeled status item remains available after the control center closes; gateway and managed tunnels remain running and the existing window can be restored |
| Stable security identity | Bundle ID, Team, Keychain group, TCC identity, and production runtime namespace are unchanged |
| Workspace selection and containment | Native `NSOpenPanel`, persistent bookmarks, existing-ancestor resolution, and escaping symlink parent/target denial |
| Recursive symlink scanning | Final symlink identity is preserved; recursive content tools never follow targets |
| Authenticated runtime observations | Exact request, Gateway, transport, profile, and audit correlation |
| Full-catalog runtime harness | Every advertised tool is called with bounded fixtures and one correlated audit row |
| Validation lifecycle cleanup | Success and failure paths close and reap the owning provider before a fresh authenticated, workspace-bound session archives temporary threads; an active failed validation turn is interrupted first |
| Read-only provider retry | Only the first deadline-expired normal read may retry on a fresh connection within the same total budget; `app/list` uses one generation because a restart repeats its snapshot, while writes and other failures are never retried |
| Cancellation boundary | A canceled outer call cannot start a retry or later App Server generation |
| Cloudflare publisher boundary | Quick Tunnel isolation and named lifecycle/auth tests are mandatory; live named deployment is user-owned |
| Effective configuration export | Current persisted grants, workspaces, and capabilities without transient entries or secrets |
| Provider lifecycle | App Server, Exec, MCP, HTTP, stdio, downstream, and Tunnel resources terminate with their owner |
| Codex API boundaries | Typed stable `swift-codex` App Server, isolated Exec, and MCP provider lifecycles |
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
| Apple Silicon, macOS 14+ | DMG cold install, Finder launch, login-item registration, labeled menu-bar item, close/reopen lifecycle, TCC/state/CLI lifecycle, and exact catalog | Required before draft publication |
| Apple Silicon with Rosetta 2 | Direct x86_64 App/CLI launch and bounded compatibility check | Required before draft publication |

A physical Intel Mac is not a 1.0.26 release gate. Universal 2 slice checks and
Rosetta 2 checks cover x86_64 compatibility; the full installation and
acceptance lifecycle runs natively on Apple Silicon.

## Coordinated publication acceptance

The protected workflow creates a draft and cannot publish it. Before
publication, the publisher must complete all 22 canonical Test Cases against
the checksummed DMG above and resolve every advertised catalog tool to a
semantic success, a policy-defined expected denial, or a specifically reviewed
fail-closed expected failure. Every tool call must retain its correlated audit
row. The exact-artifact full-catalog run must use the installed candidate and
must return a bounded Apps page and must not rely on an outer validator to
terminate a Codex request. An Apps timeout is inadmissible.

The same release decision must bind the reviewed main-repository commit to the
reviewed `computer-mcp/computer-mcp.github.io` commit. The website must be built
from its own clean repository, deploy through GitHub Pages without a custom
domain, and expose the product, security, documentation, license, and release
links verified by its automated gates. Neither repository is announced as the
productization release while the other remains incomplete.

On a clean login-item state, **Launch at login** must be available before the
first registration and reach Enabled after registration. Reopening the App
must report the same enabled system state without a separate helper or user
LaunchAgent.

The installed candidate must show **Computer MCP** beside its live status icon.
After the control-center window closes, the App process, local gateway, and
configured Secure MCP Tunnel must remain running. Selecting **Open Computer
MCP** from the status menu must restore the existing control center without
recreating the tunnel, connector, Keychain credential, workspace, or policy.

ChatGPT acceptance must use the existing connector and a new conversation to
discover Computer MCP and complete one real Full Shell request through the
authenticated Secure MCP Tunnel. Local workspace, Shell, tunnel, and audit
paths must succeed normally.

Cloudflare live named-tunnel deployment is supported but conditional on a
deploying user's own account, domain, hostname, and runtime token. The release
does not acquire, store in CI, or manufacture those user production resources.

Publishing the 1.0.26 GitHub draft and enabling the reviewed Pages deployment
are the operator attestations that the installation matrix, canonical Test
Cases, productization contract, and two-repository coordination passed. No
checksummed application asset or reviewed website commit may be rebuilt or
replaced between acceptance and publication. The immutable `v1.0.23`,
`v1.0.24`, and `v1.0.25` tags and their unpublished drafts remain the audit
records for the rejected candidates; they must never be moved or substituted
for 1.0.26.
