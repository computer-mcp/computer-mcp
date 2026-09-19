# Productization Candidate Evidence — 1.0.29

Historical pre-candidate evidence and release provenance, retained for audit. This
record is not a current task or release authorization. Current product requirements
are in [Productization acceptance](../Reference/ProductizationAcceptance.md), with
ownership defined in [Runtime architecture](../Architecture/Runtime.md).

## Candidate succession

The signed `v1.0.23`, `v1.0.24`, `v1.0.25`, and `v1.0.26` tags and their draft
releases are immutable unpublished audit records. They must not be moved,
deleted, replaced, or published. Exact-artifact acceptance rejected 1.0.25 after its installed
full-catalog run received the multi-megabyte Codex Apps directory notification
but exceeded the split 30-second read budget before the bounded page arrived.
The source regression had incorrectly treated that timeout as passing.
Exact-artifact acceptance rejected 1.0.26 after its completed catalog calls
exposed non-idempotent missing-thread cleanup and an unbounded validation
session disconnect after the final audit event.

Version 1.0.28 is the immutable installed baseline for the 1.0.29 unified
control-plane release, not a candidate to rebuild, interrupt, or republish. The
1.0.29 source, shared-control, CLI-contract, documentation, metadata,
CI-equivalent serial regression, and development Universal 2 distribution gates
have passed, so the single v1.0.29 candidate may now be created. That exact
candidate must still pass protected-source, notarized-artifact, installed-App,
catalog, native, Rosetta, ChatGPT, and controlled-publication gates. Evidence
from an earlier version or a rejected candidate may explain provenance but
cannot satisfy a v1.0.29 gate.

## Current evidence ledger

This ledger records current proof, not intent. “Partial” means the listed proof
exists but one or more requirements in that row still lack direct evidence.

| Scope | Current evidence | State |
| --- | --- | --- |
| 1.0.29 local control plane | `AppControlPlaneOperations`; exhaustive `AppControlCapabilityCatalog`; owner-only control Socket and CLI mappings; main-actor Accessibility action dispatch; self-target refusal; bounded standard-input secret handling; App/Socket integration tests; CLI/documentation parity | Implemented, serial-regression tested, documented, and verified in an isolated development Universal 2 App/DMG without changing the installed 1.0.28 baseline |
| O1, B1–B11 | `CodexAppServerProcessTransport.swift`; lifecycle/process-tree, two-workspace, 4 MiB long-lived-response, and immediate-exit final-line tests; serialized and awaited available-chunk stdout framing; one normal end-to-end request budget with a sole read-only retry; one separately configured `app/list` generation; shared bounded retirement; gated `RealCodexAppServerAcceptanceTests` requiring official `skills/list`, a bounded Apps page, teardown, failure-path process reaping and temporary-thread archival, and the two-client resume/archive lifecycle | Current disposable official-client acceptance passed: `skills/list` in 3.045 seconds, bounded Apps listing in 39.981 seconds, approved Full Access at eligible startup in 37.416 seconds, real Git/loopback/revocation in 87.531 seconds, and three-runtime handoff in 53.056 seconds. Temporary diagnostics were archived and cleaned |
| O2, O6–O10 focused hardening | Transactional multi-runtime handoff/reclaim/diagnostics; durable scoped Full Access grants; bounded rollout-tail supervision; canonical workspace repair; runtime/request-state separation; stale ownership reconciliation; bounded cleanup; worktree safety; artifact and build-identity provenance | All focused automated cases, disposable official-client acceptance, the 30,000-record bounded-read acceptance, final complete source rerun, defect-first review, cold-start source audit, and authorized real vehicleOS run passed. Exact candidate gates remain open |
| C1–C14 | `codex.app.runtimes.*`, `thread.release`, `thread.reclaim`, `handoff.diagnose`; durable thread-to-workspace ownership receipts; runtime receipt tests; `computer-mcp codex diagnose-thread` and operator references | Implemented, integration-tested, CLI-verified, and operator-documented |
| D1–D12 | `CodexApprovalBroker.swift`; persisted database records; per-kind, bounded-session, malformed-request, restart-interruption, redaction, timeout, delivery-failure, and policy-boundary tests | Implemented; focused and complete regression reruns passed |
| E1–E8 | governed built-in Git tools, dynamic policy dispatch, operation tickets, audit correlation; real hook/commit test | Implemented; focused and complete regression reruns passed |
| F1–F6 | stable `swift-codex` Goal get/set/clear and turn/steer bindings; explicit Computer MCP run naming; architecture, tool, and operator documentation | Implemented, protocol-tested, and documented |
| G1–G19 | `CodexOrchestration.swift`; persistence, stall, contradiction, redaction, revision, budget, external-blocker, acceptance, and public-tool-surface completion tests | Implemented; focused and complete regression reruns passed |
| H1–H9 | durable exclusive/isolated leases, parent lineage, selected child evidence reconciliation, and real Git managed-worktree provision/dirty-refusal/removal/branch-race integration tests | Implemented; focused and complete regression reruns passed |
| I1–I11 | `codex.diagnostics.snapshot`, handoff diagnosis, runtime/process/thread-ownership/approval/run/lease/audit receipts; `computer-mcp codex diagnose-thread|diagnostics`; architecture and troubleshooting references | Implemented, integration-tested, CLI-verified, and operator-documented |
| J1–J12 | gateway policy/caller/workspace/ticket/audit suites; App/Exec/MCP bounded-runtime tests; universal event and approval redaction; digest-only unsafe protocol IDs; canonical managed-root and symlink-replacement refusal tests; no external-process-control invariant | Implemented; security review and complete regression reruns passed |
| Swift regression | Final v1.0.29 source format and strict lint passed; the supported-default build passed; root tests passed 827 tests in 52 suites plus 25 App tests in 4 suites; Validation passed 71 tests in 12 suites. The exact automated total is 923 tests. The development Universal 2 App and provenance-bound DMG package gates also passed | Complete for the pre-candidate local source gate. The later protected candidate must rebuild from the clean signed-tag source and pass its own exact-artifact gates |
| R1–R15 | Product-first English and Simplified Chinese root manuals cover positioning, the 30-second model, use cases, maturity labels, trust and approval, architecture, quick start, Codex ownership, Codex Remote, limitations, troubleshooting, and development | Implemented; DocC, naming, localization, CLI, example, and repository gates passed |
| Website boundary | Independent sibling repository `computer-mcp.github.io`; reviewed 1.0.27 site remains the accepted public product surface | Outside this focused batch; no source change requires a website text correction, binding, build, or deployment |
| Q1–Q13 | Strict format/lint, supported-default root and Validation builds, all 923 automated tests, exact focused cases, disposable real Codex acceptance, development Universal 2 App/DMG verification, documentation, complete executable-derived CLI contract, repository and protected release-boundary regressions | All pre-candidate local, security, disposable-real, documentation, review, and authorized vehicleOS gates passed. The single protected signed-tag candidate, notarized artifact, installed exact-artifact, state restoration, live-service checks, and controlled publication remain required |
| CS1–CS14 | A fresh read-only v1.0.28 audit reconstructed product/trust positioning, provider lifecycles, ownership/handoff, elevation expiry and local approval, cleanup, workspace repair, provenance, release procedure, and the unchanged website boundary. It reported no implementation defect outside the CLI reference; after the executable-derived CLI contract was installed, a new context-free remediation audit concluded: “The CLI remediation gate passes with no remaining source defect.” | Passed for the pre-candidate source gate; authorized vehicleOS and later exact-artifact release checks are separate gates |

The Goal may be completed only when every row is directly proven, the isolated
source worktree is clean, the website remains unmodified, and the hardening
batch is release-ready.
