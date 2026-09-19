# Production Productization Acceptance Contract

This document states the product's reliability and security acceptance contract.
The [runtime architecture](../Architecture/Runtime.md) defines implementation
ownership: the host owns routing, policy, workspace access and audit; the
independent [Codex plugin](https://github.com/computer-mcp/plugin-codex) owns
App Server, Exec and their domain lifecycles through `swift-codex`.
Codex lifecycle and approval tests belong to that plugin; gateway and integrated
host-boundary tests belong here. A tool schema alone is not execution evidence.

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

- **O1 — orphaned App Server:** listener shutdown or explicit runtime release
  must not leave a Computer MCP-owned App Server holding a writer lease or
  rollout/session file. Transport reconnect retains the verified subject's
  owned runtime until its explicit lifecycle ends.
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
- **O6 — false handoff success:** a successful unsubscribe must not be reported
  as a completed handoff while any live Computer MCP runtime still loads or
  owns the thread.
- **O7 — distorted native permissions:** omitted execution settings must follow
  Codex configuration, including a native Full Access default; explicit native
  sandbox and approval settings must reach Codex faithfully.
- **O8 — unbounded supervision:** ordinary progress checks must not require a
  complete read of a very large persisted rollout.
- **O9 — ambiguous runtime state:** a request timeout must not become a terminal
  runtime shutdown reason while the runtime is still alive.
- **O10 — ambiguous artifact identity:** a development or validation DMG must
  never masquerade as the exact published release asset.

## Reliability and execution-control contract

The handoff operation is a transaction across all matching Computer MCP-owned
runtimes. It binds workspace and thread, serializes against new starts, requires
an explicit active-turn decision, accounts for pending approvals and user
input, performs bounded official unsubscription, validates the loaded set,
reaps an empty runtime, preserves a runtime with other useful work, and rescans
live ownership. Success means `released_persisted`, no Computer MCP writer, an
unchanged persisted Goal/history, and immediate claimability by another
official client. The operation is idempotent and never signals an unverified
external process.

Codex owns its native execution configuration and approvals. Omitted settings
inherit that configuration; explicit supported settings retain their official
meaning. Full Access can be a native default or an explicit override, and the
initial workspace directory does not constrain its operating-system access.
Computer MCP separately authorizes access to the adapter and any host tools
called by Codex. Host denial is explicit and cannot silently downgrade a native
request. Host risk approvals bind the verified subject, workspace, arguments,
provider, target state and authorization revision, with single consumption;
revocation invalidates pending approvals without implicitly stopping unrelated
in-flight work.

Long-thread supervision must use a read-only, canonical-workspace-validated,
bounded rollout-tail reader with snapshot cursors. It returns metadata, native
Goal, active/recent turns, messages, items, and compact progress while reporting
page bytes, Goal-scan bytes, output bytes, record count, and elapsed scan budget.
Full history remains an explicit separate operation, not the supervision
default.

Workspace registration uses the symlink-resolved canonical root as identity.
Repeated registration is idempotent. Historical duplicates use a digest-bound
preview/apply repair that retains aliases, moves profile references, and
preserves audit/ownership history without deleting a user directory.

Runtime lifecycle, connection, process, current request, last request failure,
and terminal shutdown reason are independent state. Stale thread ownership can
be repaired only when the exact runtime and receipted process/supervisor are
proven gone; repair changes local receipts and sends no signal.

Disposable validation gives independent deadlines to primary acceptance, turn
finish, release, runtime stop, process reap, managed-worktree cleanup, and final
diagnostics. Cleanup failure cannot erase a primary success; it produces an
exact-target warning and safe operator-reviewed action. Worktree and process cleanup
requires durable ownership evidence and never selects a target by name or path
heuristic.

Artifact provenance distinguishes `development`, `validation`,
`release_candidate`, and `exact_published_release`. Each receipt binds artifact
name/class/phase, size and SHA-256, source commit, build identity, notarization,
stapling, and release tag/commit as applicable. The published receipt also
binds the downloaded GitHub asset checksum and byte identity. Only a fully
signed, notarized, stapled release candidate may acquire the conventional
release filename, and publication must not rebuild or mutate it.

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
- **B3** listener shutdown terminates and reaps the owned process tree;
- **B4** socket or tunnel reconnect retains execution ownership for the same
  verified subject without granting another subject access;
- **B5** runtime replacement cannot silently transfer control from an older
  instance; unresolved receipts remain explicitly unknown;
- **B6** transport timeout and cancellation delivery remain distinct from
  execution termination and confirmed process cleanup;
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
- **D4** preserve the official acceptance response and its requested scope;
- **D5** preserve supported upstream session and permission-scope semantics;
- **D6** support official rejection and cancellation, and report timeout;
- **D7** retain a terminal audit receipt;
- **D8** redact credentials and sensitive payloads;
- **D9** enforce host capabilities and workspace restrictions when Codex calls
  host tools; apply Codex's own sandbox semantics to native coding execution;
- **D10** apply native Codex approval configuration to native requests and the
  independently configured host confirmation policy to host operations;
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

### Reliability matrix

These 44 automated cases define the reliability matrix. A passing subset does
not establish coverage of the complete matrix.

Handoff and runtime ownership:

1. An active turn cannot silently hand off.
2. Explicit interrupt plus release succeeds.
3. Releasing an idle loaded thread removes its subscription.
4. Release removes live loaded ownership.
5. An empty runtime is reaped.
6. A runtime with another active thread is preserved.
7. The persisted Goal survives release.
8. Another official client can claim immediately after successful release.
9. Release is idempotent.
10. Tunnel disconnect reconciles ownership.
11. Approval timeout does not strand a thread.
12. A user-input request does not strand a released runtime.
13. No external Codex process is signalled.

Native execution permissions and host authority:

14. Omitted overrides inherit the user's Codex configuration.
15. Explicit native Full Access reaches the vendor unchanged.
16. A configured Full Access default applies at a new thread.
17. Cross-subject host access is rejected before a side effect.
18. Expired or revoked host approvals cannot execute.
19. A configuration change does not claim to alter an already running turn.
20. Explicit native sandbox and approval parameters are preserved.
21. A host operation ticket is consumed atomically once.
22. Host approvals retain their fixed expiration.
23. Restart leaves unresolved native approvals as non-replayable receipts.
24. Workspace/profile revocation prevents new host calls.
25. Direct calls, aliases and generic routes enforce the same host authority.
26. Native Full Access does not grant additional Computer MCP capabilities.
27. Diagnostics distinguish native overrides from inherited configuration.
28. Handoff/release cleans the exact owned runtime and subscription.

Bounded long-thread supervision:

29. A very large synthetic thread has a bounded recent read.
30. Snapshot pagination/cursors return correct non-overlapping pages.
31. Goal/status is read without loading full history.
32. I/O, output, and latency budgets remain bounded and observable.

Workspace and persisted state:

33. Duplicate canonical-root registration is idempotent.
34. Deduplication has a non-mutating preview.
35. Applying an unchanged plan preserves aliases and references.
36. Tests cannot pollute the production database.
37. A request timeout does not set a terminal runtime shutdown reason.
38. A stopped runtime has a terminal shutdown reason.
39. Stale ownership reconciliation changes only safely stale receipts.

Validation cleanup and artifacts:

40. Primary success plus cleanup timeout preserves success with a cleanup warning.
41. Cleanup phases use independent bounded deadlines.
42. Cleanup stops only the exact owned process/runtime.
43. A development artifact cannot masquerade as a published release artifact.
44. A release receipt binds commit, tag, checksum, notarization, stapling, and
    published byte identity.

In addition to case 20, cold-start coverage must prove native configuration
inheritance and explicit overrides at the supported thread and turn entry
points, without starting a model turn for a read-only history query.

### Real focused acceptance

With a disposable repository and disposable persisted threads, the real
official App Server acceptance must prove bidirectional handoff: Computer MCP
starts work, releases it, has no live owner, another official App Server client
claims it without a writer conflict, releases it back, Computer MCP reclaims it,
and all temporary runtimes/processes are reaped.

The same disposable acceptance must prove inherited Full Access and explicit
native permission overrides, a real Git commit, a controlled loopback network
operation, a write outside the initial workspace but inside the disposable
fixture, native read-only denial, and exact owned-runtime cleanup. Host
approval denial, expiry and revocation must independently prevent host tool
side effects. A synthetic or disposable large rollout must
separately prove bounded recent supervision.

After all automated and disposable checks pass, the existing user-nominated
real workspace/thread workflow is release-blocking and may be exercised only
with the user's explicit approval. It must preserve the native Goal and history
while proving native execution permissions, handoff to the other official
client, handoff back to Computer MCP, and no stale ownership. Repository
documentation must not publish the user's private identifiers.

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

## Independent public website boundary

The [product site](https://github.com/computer-mcp/computer-mcp.github.io) is a
separate repository. Changes to its security or capability statements must
match verified product behavior. Website checks and deployment authorization
are separate from App acceptance and release authorization. Versioned reports
retain their historical website evidence.

## Repository and release quality

Repository changes require Q1 and Q4–Q9. Preparing a public release additionally
requires the versioning, source and artifact controls below:

- **Q1** current implementation plan and this contract remain aligned;
- **Q2** backwards compatibility or an accepted migration note;
- **Q3** required changelog and release-note updates;
- **Q4** Swift formatting and strict lint;
- **Q5** Swift build and complete test suite;
- **Q6** relevant real CLI and App/package validations;
- **Q7** documentation checks and `git diff --check`;
- **Q8** artifact-provenance and protected release-boundary checks;
- **Q9** independent defect-first review, fixes, and rerun evidence;
- **Q10** logical Conventional Commits in the source repository;
- **Q11** a clean isolated source worktree;
- **Q12** an accepted complete release scope;
- **Q13** release preparation uses a candidate only after every applicable local,
  security, disposable-real, authorized-real, documentation, review, and
  cold-start gate passes; after exact published installation it restores the
  prior App-owned state and leaves the local Computer MCP service running.

## Cold-start maintainability audit

A fresh Codex task with only the source repository must be able to:

- **CS1** explain product positioning;
- **CS2** explain the trust and two-level approval model;
- **CS3** distinguish Computer MCP from Codex Remote;
- **CS4** locate App Server lifecycle ownership and teardown;
- **CS5** diagnose a simulated writer conflict and find runtime owner evidence;
- **CS6** run the complete Swift test suite;
- **CS7** identify stable, experimental, and planned capabilities;
- **CS8** update one small capability safely;
- **CS9** identify the website as a separately owned repository and deployment;
- **CS10** identify the controlled release procedure;
- **CS11** distinguish native Codex permissions from host operation approval,
  and prove inherited defaults and explicit native overrides;
- **CS12** release a disposable thread and interpret ownership diagnostics
  without relying on fixed UI wording;
- **CS13** supervise a large thread through the bounded recent reader;
- **CS14** distinguish development, validation, candidate, and exact published
  artifact provenance.

The audit must succeed without the original conversation. Its source-repository change
must be reviewed and either accepted as part of the batch or cleanly reverted by
the audit task before final release preparation.

## Evidence ownership

Each validation run records its own source revision, tested surfaces, outcomes,
skips and cleanup results. Historical evidence cannot satisfy a current gate.
The [1.0.29 candidate ledger](../Archive/ProductizationCandidateEvidence1.0.29.md)
owns the earlier candidate succession and pre-publication audit record.
Local acceptance, release authorization and production deployment are distinct
decisions; this contract does not authorize any of them by itself.
