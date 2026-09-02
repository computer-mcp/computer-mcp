# Production Productization Acceptance Contract

This document is the normative acceptance contract for the production-grade
Computer MCP productization batch. It preserves the complete currently accepted
scope in a repository-owned form so implementation, review, release, and a
cold-start maintainer can evaluate the same outcome without access to the
planning conversation.

The release is one indivisible batch with two repositories:

1. `computer-mcp`, containing the gateway, App, CLI, tests, and documentation;
2. `computer-mcp.github.io`, containing the public product website and its
   independent build, accessibility, link, browser-acceptance, and deployment checks.

Neither repository may be released as the completed productization batch while
the other or any requirement below remains unverified. A passing subset is
progress evidence, not permission to publish.

## Product contract

Computer MCP is **a policy-controlled, workspace-scoped local execution gateway
for AI agents**. It connects ChatGPT, Codex, and other MCP-compatible clients to
registered local workspaces, CLIs, desktop applications, development tools, and
optional dedicated Codex runtimes.

Computer MCP is not:

- an unrestricted remote shell;
- merely a large collection of MCP tools;
- a clone or replacement for official Codex Remote;
- a wrapper that silently grants agents full-machine access;
- a Codex-only product.

The product's differentiators are registered workspaces, capability-scoped
profiles, explicit policy and approval boundaries, auditable request
correlation, local execution, extensible tools and CLIs, multiple AI clients,
optional Codex orchestration, and explicit ownership and handoff semantics.

Official Codex Remote is the preferred first-party interface for remotely
controlling ordinary Codex work. Computer MCP complements it with a general
MCP-accessible local tool and execution control plane. Marketing claims must be
demonstrated by implementation and tests; experimental behavior must be labeled
as experimental.

## Defect acceptance baseline

The following are observable product failures to prevent, independent of their
eventual root cause:

- **O1 — orphaned App Server:** a replaced gateway, tunnel, connection, or
  runtime must not leave an older Computer MCP-owned Codex App Server holding a
  writer lease or rollout/session file.
- **O2 — opaque ownership:** an operator must be able to identify the Computer
  MCP runtime, process group, connection generation, thread state, active turn,
  and approval state involved in a handoff.
- **O3 — rejected approvals:** supported App Server approvals must reach a
  durable policy-and-consent broker instead of being rejected indiscriminately.
- **O4 — incomplete governed Git:** an authorized Codex task must be able to
  write, stage, commit with hooks, and verify a clean repository without broad
  shell access or implicit push.
- **O5 — turn-only completion:** a completed turn must not be represented as a
  completed durable Goal or accepted Computer MCP run while acceptance remains
  open.

## A. Runtime model

The architecture and operator reference must describe and agree with the
implemented lifecycle for:

- **A1** gateway socket creation, connection, replacement, and closure;
- **A2** tunnel connection creation, generation replacement, and closure;
- **A3** `GatewayRuntime` ownership;
- **A4** provider and per-workspace runtime ownership;
- **A5** Codex App Server spawning;
- **A6** JSONL/stdio transport lifetime;
- **A7** connection close behavior;
- **A8** notification and server-request consumer tasks;
- **A9** process termination, escalation, and reaping;
- **A10** thread loading, subscription, release, restart, and reconnection.

A deterministic reproduction of O1 must remain as a regression test.

## B. Deterministic App Server lifecycle

Every Computer MCP-owned App Server must satisfy:

- **B1** stable runtime instance ID;
- **B2** observable App Server PID, supervisor PID, parent PID, process group,
  workspace, profile, connection, transport, creation time, and state;
- **B3** normal session closure terminates and reaps the owned process tree;
- **B4** abnormal socket or tunnel closure terminates and reaps it;
- **B5** session replacement cannot silently retain the preceding generation;
- **B6** a timed-out connection is closed and reaped before replacement;
- **B7** shutdown is idempotent;
- **B8** Computer MCP parent termination does not orphan the process tree;
- **B9** a generation cannot control an earlier generation's runtime;
- **B10** unrelated Codex Desktop, IDE, CLI, or user-owned App Server processes
  are never targeted;
- **B11** shutdown uses bounded EOF/graceful completion, then TERM and KILL only
  when required, and records escalation.

Tests must cover the entire owned process group, including descendants.

## C. Runtime ownership and handoff

Supported tools or product surfaces must provide:

- **C1** list active Computer MCP-owned Codex runtimes;
- **C2** inspect one runtime;
- **C3** report PID, supervisor, process group, and health;
- **C4** report loaded, subscribed, active, idle, released, or persisted thread
  state where the available evidence supports it;
- **C5** report active turn and pending approval state;
- **C6** report gateway socket or tunnel generation ownership;
- **C7** release a thread from the current owned runtime;
- **C8** stop one exact Computer MCP-owned runtime;
- **C9** safely release every thread owned by that runtime;
- **C10** detect stale or orphaned Computer MCP receipts/process state;
- **C11** preview cleanup without mutation;
- **C12** perform explicitly reviewed cleanup;
- **C13** deliberately attempt to reclaim a persisted thread;
- **C14** classify Computer MCP-owned, released/persisted, suspected external,
  reclaim, and writer-conflict states with an actionable next step.

Computer MCP must state when external ownership is only inferred. It must never
claim it can unsubscribe or terminate another application's connection without
verified ownership and an implemented capability.

Product surfaces must explain the available action and ownership state in
natural, contextual language. Labels such as “重新接管线程” and “检查线程占用” are
illustrative, not required strings; internal capability names may remain
technical. “Why can't Codex Desktop open this thread?” defines the diagnostic
scenario, not user-interface copy.

## D. Durable approval broker

The implementation must keep three decisions distinct:

1. Computer MCP policy authorization for the capability;
2. the App Server agent's approval request;
3. explicit consent by the user or gateway caller.

For command execution, file change, permissions, apply-patch, exec-command,
registered Computer MCP tools, and other supported App Server approval requests,
the broker must:

- **D1** persist a durable pending approval record;
- **D2** record request kind, normalized redacted details, risk, workspace,
  runtime, thread, turn, correlation IDs, timeout, and proposed action;
- **D3** expose list, read, and respond operations;
- **D4** support approve once;
- **D5** support upstream-bounded session approval only where policy and the
  official protocol allow it;
- **D6** support deny and timeout;
- **D7** retain a terminal audit receipt;
- **D8** redact credentials and sensitive payloads;
- **D9** reject requests that expand outside registered workspaces or granted
  capabilities;
- **D10** permit automatic approval only for explicitly configured, bounded,
  low-risk operations;
- **D11** surface MCP elicitation without treating it as a permission bypass;
- **D12** preserve interrupted records across restart while truthfully stating
  that the original live upstream request cannot be resumed.

The broker must not turn rejection-by-default into approval-by-default.

## E. Governed Git

The authorized Git path must provide repository and workspace validation,
status, diff, stage, unstage, commit, branch, and log while preserving:

- **E1** path allowlisting and symlink-safe workspace containment;
- **E2** reviewed commit messages;
- **E3** repository hooks;
- **E4** repository policy;
- **E5** no implicit push;
- **E6** no credential exposure;
- **E7** deterministic and idempotent failure reporting;
- **E8** exact Codex request, approval, gateway invocation, operation ticket,
  audit, and Git-result correlation.

The real-repository acceptance sequence is: write a file, request the governed
Git capability, surface and accept approval, stage the file, create a commit,
run hooks, and finish with a clean worktree.

## F. Codex Goal and ownership modes

The product and its API must distinguish:

- **F1** quick thread/turn execution;
- **F2** dedicated Computer MCP-owned Codex execution;
- **F3** an official persisted Codex Goal;
- **F4** official Codex Remote ownership;
- **F5** external Codex Desktop or IDE ownership;
- **F6** a Computer MCP acceptance run that complements rather than impersonates
  the official Goal.

Stable official protocol bindings take priority over local imitation. Where
supported, Computer MCP must expose Goal set/get/clear, status observation,
turn steering, approvals, stopping conditions, and persisted progress. Official
Goal status semantics must not be extended with invented native states.

Pause, resume, cancel, acceptance criteria, and evidence that belong to a
Computer MCP run must be labeled as Computer MCP-owned. Clearing an official
Goal removes it; it is not represented as a native cancellation state. A turn
may complete while the Goal or acceptance run remains active.

## G. Acceptance-driven orchestration

A Computer MCP long-running acceptance run must persist:

- **G1** objective and accepted scope;
- **G2** current phase;
- **G3** acceptance criteria and their states;
- **G4** completed evidence;
- **G5** active turn;
- **G6** pending approval;
- **G7** blockers;
- **G8** last meaningful progress;
- **G9** next action;
- **G10** terminal reason;
- **G11** revision and execution budgets.

The engine must detect and report:

- **G12** a completed turn with open acceptance;
- **G13** repeated planning without a repository change;
- **G14** repeated identical failure without persisting sensitive failure text;
- **G15** a command with no recorded progress for a bounded period;
- **G16** a dirty worktree after completion is claimed;
- **G17** missing required build or test evidence;
- **G18** contradictions among agent summary, Git state, and acceptance state;
- **G19** duration, turn, repeated-failure, and no-progress budget exhaustion.

The engine must pause distinctly for pending consent, avoid an unbounded silent
loop, and require explicit acceptance before completion.

## H. Multi-executor write safety

For multiple agents, threads, or child runs:

- **H1** repository/worktree mutation ownership is explicit and durable;
- **H2** concurrent mutation of one worktree is rejected unless explicitly
  allowed by a future reviewed policy;
- **H3** independent implementation work prefers separate branches/worktrees;
- **H4** parent/child runs and worktree leases retain lineage;
- **H5** only explicitly selected evidence from an accepted child is reconciled
  into the parent;
- **H6** unselected child output cannot overwrite the accepted mainline;
- **H7** stale leases and Computer MCP-owned runtimes have safe cleanup paths;
- **H8** temporary worktree creation/removal, when Computer MCP owns it, is
  governed, reviewed, and cannot remove user-owned worktrees;
- **H9** conflicts are surfaced rather than resolved by overwriting files.

Lease expiry cleanup changes receipts only. Filesystem or Git worktree cleanup
requires a separate verified ownership receipt and reviewed operation.

## I. Observability and operator diagnosis

Structured diagnostics must correlate:

- **I1** runtime and process state;
- **I2** thread ownership and state;
- **I3** active turns;
- **I4** pending approvals;
- **I5** tool executions;
- **I6** Git mutations;
- **I7** request, invocation, ticket, MCP request, and correlation IDs;
- **I8** socket and tunnel generations;
- **I9** shutdown reason and termination escalation;
- **I10** stale process or receipt detection;
- **I11** last error and an actionable recovery state.

Logs and diagnostics must remain useful without payload or credential leakage.
At least one operator-facing command or App surface must explain why a thread
cannot be opened in Codex Desktop without requiring `ps` or `lsof` investigation.

## J. Security invariants

Production behavior must preserve or improve:

- **J1** registered workspace boundaries;
- **J2** profile capability restrictions and caller binding;
- **J3** path validation and symlink handling;
- **J4** explicit approval for mutation;
- **J5** command allowlisting or registered CLI/tool dispatch;
- **J6** local-only sensitive execution;
- **J7** request auditability;
- **J8** credential and sensitive-text redaction;
- **J9** least privilege;
- **J10** fail-closed defaults;
- **J11** no unverified external-process control;
- **J12** bounded input, output, persistence, and lifecycle resources.

The public explanation must describe the two-level model: Computer MCP first
decides whether a capability is permitted at all; the user or caller then
decides whether a permitted higher-risk action is approved now.

## Automated acceptance scenarios

### Runtime lifecycle

Automated tests must start an owned App Server, load or create a disposable
thread, close the gateway path, verify process exit and reaping, and verify the
old writer lease/session resource is released. Repeat for:

- **T-R1** normal connection closure;
- **T-R2** abrupt socket loss;
- **T-R3** tunnel restart and rapid reconnect;
- **T-R4** timeout retirement;
- **T-R5** explicit Computer MCP shutdown;
- **T-R6** parent-process death;
- **T-R7** multiple registered workspaces;
- **T-R8** a stubborn descendant requiring TERM/KILL escalation.

### Writer conflict

- **T-W1** one Computer MCP client loads a disposable thread;
- **T-W2** releasing only the current subscription is not misrepresented as
  stopping a different stale runtime;
- **T-W3** after the owning runtime releases or shuts down, a second App Server
  client can load or resume the thread;
- **T-W4** no stale Computer MCP-owned process, process-group member, writer
  lease, or ownership receipt remains active.

A protocol fixture is acceptable in CI. A separately gated local integration
receipt is required when a real second official client is impractical in CI.

### Approval broker

Automated coverage must include approve once, bounded session approval, deny,
timeout, malformed decision/request, out-of-scope permission, configured
low-risk automatic approval, every supported approval kind, and restart
interruption/recovery semantics.

### Git, Goal, and orchestration

- **T-G1** create a real temporary-repository commit through the approved
  governed Git path and verify hooks and clean status;
- **T-G2** distinguish a completed turn from an active incomplete Goal/run;
- **T-G3** distinguish completed accepted, paused-for-approval, budget-limited,
  and hard-external-blocker states;
- **T-G4** reject concurrent run or lease revisions;
- **T-G5** reconcile only selected accepted child evidence.

### Existing product regression

All existing unit, integration, gateway, tunnel, workspace, policy, CLI, App,
App Server, and packaging tests must run. New tests extend this baseline; they
must not weaken an existing assertion to make the batch pass.

## Root README acceptance

The first screen of the root README must answer what Computer MCP is, the
problem it solves, who it is for, what it enables, why it is safer than a shell,
how it relates to Codex Remote, and how to try it.

The README must include:

- **R1** a concise product narrative and one-sentence positioning;
- **R2** a 30-second conceptual diagram;
- **R3** primary use cases;
- **R4** a stable/experimental/planned capability matrix;
- **R5** a ChatGPT-orchestrates/Codex-executes example;
- **R6** the workspace and profile security model;
- **R7** the explicit two-level approval model;
- **R8** architecture overview;
- **R9** installation and quick start;
- **R10** the first successful command;
- **R11** Codex integration and ownership modes;
- **R12** when to use official Codex Remote;
- **R13** troubleshooting and documentation map;
- **R14** contributing and development guidance;
- **R15** honest limitations.

It must lead with the product rather than package internals or a tool inventory.

## Independent public website acceptance

The `computer-mcp.github.io` repository must be a maintainable static GitHub
Pages product site, not generated API documentation. It does not use a custom
domain unless a later explicit product decision changes this contract.

Required sections are:

- **W1** hero with product name, positioning, Get Started, and GitHub/docs CTA;
- **W2** the controlled-local-access problem;
- **W3** workflow from AI client through authenticated gateway, policy/profile,
  registered workspace/tool, local execution, audit, and result;
- **W4** core capabilities;
- **W5** real use cases;
- **W6** security, trust, refusal behavior, and limitations;
- **W7** the complementary Computer MCP/Codex Remote relationship;
- **W8** architecture diagram;
- **W9** quick start;
- **W10** current status and honest roadmap;
- **W11** footer links to GitHub, documentation, security, and license.

The site must be responsive, accessible, keyboard navigable, technically
credible, and have clear typography. It must not use fake testimonials, fake
logos, unsupported claims, copied brand assets, or a generic AI-gradient visual
template. It needs useful mobile and desktop layouts, metadata, a social image,
favicon, SEO basics, automated production build, link validation, accessibility
checks, browser-behavior tests, and compatible GitHub Pages deployment.

## Repository and release quality

The batch requires:

- **Q1** current implementation plan and this contract remain aligned;
- **Q2** backwards compatibility or an accepted migration note;
- **Q3** required changelog and release-note updates;
- **Q4** Swift formatting and strict lint;
- **Q5** Swift build and complete test suite;
- **Q6** relevant real CLI and App/package validations;
- **Q7** documentation checks and `git diff --check`;
- **Q8** website format, type/build, link, accessibility, and browser-behavior checks;
- **Q9** independent defect-first review, fixes, and rerun evidence;
- **Q10** logical Conventional Commits in both repositories;
- **Q11** clean worktrees in both repositories;
- **Q12** one coordinated release-ready batch with no partial publication.

## Cold-start maintainability audit

A fresh Codex task with only the repositories must be able to:

- **CS1** explain product positioning;
- **CS2** explain the trust and two-level approval model;
- **CS3** distinguish Computer MCP from Codex Remote;
- **CS4** locate App Server lifecycle ownership and teardown;
- **CS5** diagnose a simulated writer conflict and find runtime owner evidence;
- **CS6** run the complete Swift test suite;
- **CS7** identify stable, experimental, and planned capabilities;
- **CS8** update one small capability safely;
- **CS9** build and test the website;
- **CS10** identify the coordinated release procedure.

The audit must succeed without the original conversation. Its repository change
must be reviewed and either accepted as part of the batch or cleanly reverted by
the audit task before final release preparation.

## Candidate succession

The signed `v1.0.23`, `v1.0.24`, and `v1.0.25` tags and their draft releases are
immutable unpublished audit records. They must not be moved, deleted, replaced,
or published. Exact-artifact acceptance rejected 1.0.25 after its installed
full-catalog run received the multi-megabyte Codex Apps directory notification
but exceeded the split 30-second read budget before the bounded page arrived.
The source regression had incorrectly treated that timeout as passing.

Version 1.0.26 is the only current candidate. It must return a bounded Apps page
within a separate explicit deadline and repeat every protected-source,
notarized-artifact, installed-App, catalog, native, Rosetta, ChatGPT,
cold-start-maintenance, website, and coordinated-publication gate. Evidence from
a rejected candidate may explain provenance but cannot satisfy a 1.0.26 gate.

## Current evidence ledger

This ledger records current proof, not intent. “Partial” means the listed proof
exists but one or more requirements in that row still lack direct evidence.

| Scope | Current evidence | State |
| --- | --- | --- |
| O1, B1–B11 | `CodexAppServerProcessTransport.swift`; lifecycle/process-tree, two-workspace, 4 MiB long-lived-response, and immediate-exit final-line tests; serialized and awaited available-chunk stdout framing; one normal end-to-end request budget with a sole read-only retry; one separately configured `app/list` generation; shared bounded retirement; gated `RealCodexAppServerAcceptanceTests` requiring official `skills/list`, a bounded Apps page, teardown, failure-path process reaping and temporary-thread archival, and the two-client resume/archive lifecycle | Implemented; focused 1.0.26 lifecycle 34/34, transport 7/7, provider 14/14, Validation plan 5/5, complete root 52 suites/799 tests, and real official-client 3/3 passed; the latest bounded Apps page returned in 21.838 seconds |
| C1–C14 | `codex.app.runtimes.*`, `thread.release`, `thread.reclaim`, `handoff.diagnose`; durable thread-to-workspace ownership receipts; runtime receipt tests; `computer-mcp codex diagnose-thread` and operator references | Implemented, integration-tested, CLI-verified, and operator-documented |
| D1–D12 | `CodexApprovalBroker.swift`; persisted database records; per-kind, bounded-session, malformed-request, restart-interruption, redaction, timeout, delivery-failure, and policy-boundary tests | Implemented; focused and complete regression reruns passed |
| E1–E8 | governed built-in Git tools, dynamic policy dispatch, operation tickets, audit correlation; real hook/commit test | Implemented; focused and complete regression reruns passed |
| F1–F6 | stable `swift-codex` Goal get/set/clear and turn/steer bindings; explicit Computer MCP run naming; architecture, tool, and operator documentation | Implemented, protocol-tested, and documented |
| G1–G19 | `CodexOrchestration.swift`; persistence, stall, contradiction, redaction, revision, budget, external-blocker, acceptance, and public-tool-surface completion tests | Implemented; focused and complete regression reruns passed |
| H1–H9 | durable exclusive/isolated leases, parent lineage, selected child evidence reconciliation, and real Git managed-worktree provision/dirty-refusal/removal/branch-race integration tests | Implemented; focused and complete regression reruns passed |
| I1–I11 | `codex.diagnostics.snapshot`, handoff diagnosis, runtime/process/thread-ownership/approval/run/lease/audit receipts; `computer-mcp codex diagnose-thread|diagnostics`; architecture and troubleshooting references | Implemented, integration-tested, CLI-verified, and operator-documented |
| J1–J12 | gateway policy/caller/workspace/ticket/audit suites; App/Exec/MCP bounded-runtime tests; universal event and approval redaction; digest-only unsafe protocol IDs; canonical managed-root and symlink-replacement refusal tests; no external-process-control invariant | Implemented; security review and complete regression reruns passed |
| Swift regression | `/usr/bin/swift test --no-parallel`: 52 suites/799 tests passed on 2026-09-02. Strict root format/lint and the supported-default build passed. Validation passed 11 suites/67 tests. All three gated official-client tests passed: `skills/list` in 0.483 seconds, bounded `app/list` in 37.880 seconds, and two-client resume/archive in 34.908 seconds; the latest Apps-only rerun passed in 53.295 seconds | Local 1.0.26 source and real-client gates passed; protected signed-tag CI and exact-artifact reruns remain required |
| R1–R15 | Product-first English and Simplified Chinese root manuals cover positioning, the 30-second model, use cases, maturity labels, trust and approval, architecture, quick start, Codex ownership, Codex Remote, limitations, troubleshooting, and development | Implemented; DocC, naming, localization, CLI, example, and repository gates passed |
| W1–W11 | Independent sibling Git repository `computer-mcp.github.io`; static product site, responsive control-path design, metadata/social assets, no `CNAME`, Vite build, HTML/link checks, Axe, desktop/mobile Playwright, CI, and Pages workflow; signed commit `0657fcda80247ef755f30d633aee083f4fe2634f` remains the clean historical binding to rejected 1.0.25 | Partial: the site must be rebound to the exact 1.0.26 candidate, rerun all gates, and remain private with deployment disabled until the coordinated publication decision |
| Q1–Q12 | Strict format/lint, supported-default root and Validation builds, complete tests, 22 canonical Test Case definitions, real Codex acceptance, development Universal 2 App/DMG verification, documentation and release-boundary regressions, website gates, and clean coordinated publication | Partial: root 52/799, Validation 11/67, real Codex 3/3, and an isolated Universal 2 1.0.26 (27) App/DMG passed; distinct temporary main and Git workspaces returned successful authenticated `workspace.describe` and `git.status` calls. Protected signed-tag CI, notarized artifact, installed exact-artifact catalog 22/22, UI, new-conversation ChatGPT, website, and coordinated publication gates remain required |
| CS1–CS10 | The independent 1.0.25 cold-start audit passed 10/10 against source parent `32c47d33b10ff49f4cd4578ee6c36b6278d4d0c8` and website `0657fcda80247ef755f30d633aee083f4fe2634f`, including its documented source tests, conflict diagnosis, safely reverted capability update, website checks, release procedure, capability boundaries, metadata closure, and clean worktrees | Historical proof only: a fresh 1.0.26 cold-start audit must repeat all ten criteria and may not reuse the rejected candidate's conclusion |

The Goal may be completed only when every row is directly proven, both
repositories are clean, and the two-repository batch is release-ready.
