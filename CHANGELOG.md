# Changelog

All notable user-visible changes to Computer MCP are documented here.

## Unreleased

## 1.0.28 — 2026-09-03

- Make Codex thread release a deterministic, idempotent handoff transaction
  that removes loaded/subscribed ownership, safely reaps only proven
  Computer-MCP-owned runtimes, preserves the persisted Goal, and reports
  whether another official Codex client can claim immediately.
- Add locally approved, workspace/profile/caller/connection/thread-bound
  Full Access grants with next-turn, thread TTL, and bounded-time modes.
  Running turns never hot-switch; grants expire or revoke back to the safe
  configured sandbox without widening Computer MCP capabilities.
- Add bounded recent-thread and Goal supervision, authoritative handoff
  diagnosis, runtime/request-state separation, automatic stale-ownership
  reconciliation, and bounded validation cleanup.
- Make canonical workspace registration idempotent, add reviewed deduplication,
  strengthen managed-worktree ownership, and distinguish development,
  validation, candidate, and exact-published artifact provenance.
- Pass 920 automated tests, disposable official-client Git/network/handoff and
  30,000-record supervision acceptance, independent review, cold-start audit,
  and the authorized real vehicleOS Full Access/reclaim/release workflow.

## 1.0.27 — 2026-09-02

- Treat the official App Server's exact `no rollout found` response as an
  idempotently complete validation cleanup only for the requested temporary
  thread. Other archive and provider failures remain blocking.
- Shut down a validation session's owned bridge process before disconnecting
  its MCP client, preventing a completed exact-artifact catalog run from
  hanging after its final audit event.
- Keep the immutable signed `v1.0.26` candidate unpublished. Its installed
  artifact completed the catalog calls but exposed these validation lifecycle
  defects, so every protected, notarized, exact-artifact, ChatGPT, and website
  gate moves to version 1.0.27.

## 1.0.26 — 2026-09-02

- Make `codex.app.apps.list` a typed, bounded pagination surface using the
  current Codex 0.147 App Server parameters. Calls default to cached data and a
  20-entry page; callers may provide a cursor, thread scope, refresh choice,
  and a limit from 1 through 100.
- Give `app/list` one explicit, separately configured end-to-end deadline
  (120 seconds by default) instead of splitting the normal 30-second read
  budget across two process generations. A restart can no longer repeat the
  same multi-megabyte `app/list/updated` snapshot before the page response.
- Expand the deterministic long-lived protocol-line regression to 4 MiB and
  require the real official App Server test to return a bounded Apps page.
  A timeout is no longer accepted as a passing real-client result.
- Make every real official-client failure path reap its test-owned App Server.
  A handoff test that has already created a durable thread also interrupts its
  active turn and archives that thread through a fresh workspace-scoped client.
- Keep the immutable signed `v1.0.25` candidate unpublished. Exact-artifact
  full-catalog acceptance showed that its repaired stream transport could
  receive the large Apps snapshot but its 30-second split request budget ended
  before the upstream page arrived. Version 1.0.26 repeats every protected,
  notarized, exact-artifact, ChatGPT, and website gate.

## 1.0.25 — 2026-09-02

- Drain Codex App Server stdout in available chunks instead of requesting and
  processing one byte per actor hop. Chunk consumption is serialized and
  awaited before the protocol stream finishes, so large long-lived responses
  remain interactive and a short-lived process cannot lose its final line.
- Add a deterministic 256 KiB long-lived protocol-response regression and a
  gated official Codex 0.147.0 `skills/list` acceptance test. The 233 KiB
  workspace Skill catalog now completes in under one second in the real
  release environment, with bounded process teardown.
- Keep the immutable signed `v1.0.24` candidate unpublished. Exact-artifact
  acceptance exposed the large-response transport defect, so every protected,
  notarized, exact-artifact, ChatGPT, and website gate moves to a new signed
  `v1.0.25` release candidate.

## 1.0.24 — 2026-09-02

- Treat `app_server_request_timeout_seconds` as one end-to-end App Server call
  budget spanning process startup, workspace validation, the reviewed request,
  and the sole read-only retry. A canceled outer request cannot start a later
  process generation.
- Share one deterministic close operation across concurrent and repeated
  teardown paths. Back-pressured stdin finalization no longer delays the
  bounded EOF, TERM, KILL, and process-reaping sequence.
- Add deterministic hung-startup, hung-request, back-pressured-writer, retry
  cancellation, and official Codex `app/list` regressions. The same Codex
  0.147.0 call that exceeded the 90-second external validation deadline now
  fails closed within its configured call budget plus bounded teardown.
- Move repository, CI, documentation, and release builds to SwiftPM's supported
  default build engine. Deterministic dependency metadata now validates the
  actual App and CLI closure from the toolchain's emitted build graph, while
  DocC remains an explicit warnings-as-errors documentation input instead of an
  unhandled compile input.
- Keep the immutable signed `v1.0.23` candidate unpublished. Exact-artifact
  acceptance found that its per-attempt deadline, unbounded startup, and
  repeated transport close could amplify one read-only request beyond the
  configured boundary. Version 1.0.24 repeats every protected, exact-artifact,
  ChatGPT, and coordinated website gate from a new signed tag.

## 1.0.23 — 2026-09-01

- Own each Computer MCP Codex App Server as an observable process group and
  deterministically reap its descendants on connection close, replacement,
  timeout, shutdown, or parent death. Shutdown records bounded EOF, TERM, and
  KILL escalation without targeting external Codex processes.
- Persist runtime and thread-to-workspace ownership receipts; add exact-runtime
  inspection, release, stop, reviewed stale-receipt cleanup, deliberate thread
  reclaim, and operator diagnostics for thread occupancy and handoff conflicts.
- Broker supported Codex approval requests through durable, redacted
  policy-and-consent records instead of rejecting them indiscriminately. Dynamic
  Computer MCP tools and governed Git now retain end-to-end request, approval,
  ticket, audit, and result correlation.
- Expose stable official Codex Goal get, set, and clear bindings plus turn
  steering while keeping native Goal state distinct from Computer MCP-owned
  acceptance runs, evidence, budgets, pause states, stall detection, and
  explicit completion acceptance.
- Add exclusive and isolated-worktree writer leases, reviewed managed child
  worktree provisioning/removal, parent-child lineage, and selected-evidence
  reconciliation so concurrent executors cannot silently overwrite one
  worktree.
- Bound and redact App Server, Exec, MCP, approval, event, orchestration, and
  diagnostics payloads; represent credential-like protocol identifiers only by
  digest and reject managed-worktree symlink replacement.
- Replace the root manuals with product-first English and Simplified Chinese
  documentation, and coordinate this batch with the independent
  `computer-mcp.github.io` static product website and its accessibility,
  link, browser-acceptance, and GitHub Pages gates.
- The new Codex lifecycle limits and ownership features are additive. Existing
  configurations remain valid, the Codex provider remains disabled by default,
  and omitted settings use bounded defaults; no workspace, credential, tunnel,
  CLI, or MCP migration is required.

## 1.0.22 — 2026-08-31

- Enforce the Codex App Server deadline even when the underlying RPC ignores
  task cancellation. The timeout race returns without waiting for the losing
  request task to finish.
- Retire a timed-out App Server connection before resuming the caller and
  close its transport asynchronously. A read-only retry therefore uses a
  fresh connection without making transport shutdown part of the deadline.
- Add a non-cooperative RPC regression that fails the previous structured
  timeout implementation and proves the bounded return independently of
  transport cleanup.

## 1.0.21 — 2026-08-30

- Make exact-catalog Codex lifecycle acceptance deterministic: wait for the
  bounded turn's persisted terminal state, interrupt the active outer review
  turn, close the owning provider session, and archive validation threads from
  a fresh authenticated session bound to their fixture workspace.
- Retry a timed-out read-only Codex App Server request once on a fresh
  connection. Write requests, policy denials, provider errors, and a second
  timeout still fail immediately and visibly.
- Keep the public turn-start schema aligned with the stable `swift-codex`
  transport by exposing only fields the typed stable request preserves.
- Keep the immutable signed 1.0.21 candidate unpublished after exact-artifact
  acceptance showed that its structured timeout race still waited for the
  canceled request and connection close. Version 1.0.22 retires the connection
  synchronously and leaves non-cooperative cleanup outside the request bound.

## 1.0.20 — 2026-08-30

- Bind validation-owned Codex thread cleanup to the selected fixture workspace
  so exact-catalog acceptance remains deterministic when more than one
  workspace is registered. Temporary validation threads are archived through
  their owning workspace before the run can pass.
- Keep the immutable signed 1.0.20 candidate unpublished after exact-artifact
  acceptance found that asynchronous Codex writers could outlive the
  validation connection and that a read-only App directory request could
  encounter a transient deadline. Version 1.0.21 repeats the protected
  workflow with explicit provider shutdown, fresh-session cleanup, and bounded
  read-only retry.

## 1.0.19 — 2026-08-30

- Keep **Launch at login** registerable on a fresh installation when macOS has
  no background-task record for the main App. The official Service Management
  registration call now determines bundle eligibility instead of an absent
  record disabling the control before registration can occur.
- Preserve an existing enabled login item across the update. The production
  Bundle ID, Developer ID identity, private Keychain access group, TCC identity,
  Secure MCP Tunnel profile, credentials, workspaces, and policy are unchanged;
  no migration or remote connector re-registration is required.
- Export effective workspace and profile state from the current persisted
  control plane so transient manifest or acceptance inputs cannot remain in a
  replayable configuration after their owning state is gone.
- Keep the immutable signed 1.0.19 candidate unpublished after exact-artifact
  acceptance found that validation-owned Codex thread cleanup was ambiguous
  when multiple workspaces were registered. Version 1.0.20 repeats the
  protected workflow with cleanup bound to its fixture workspace.

## 1.0.18 — 2026-08-19

- Render the macOS menu-bar item with an explicit `Computer MCP` title and the
  existing live service-state icon. The App remains identifiable when several
  computers or menu-bar tools are active instead of exposing an unlabeled
  glyph.
- Keep the menu-bar item available after the main window closes. Its menu still
  reports service state and reopens the existing Computer MCP control center
  without restarting the gateway or managed tunnels.
- Preserve the production Bundle ID, Developer ID identity, private Keychain
  access group, TCC identity, ChatGPT connector, Secure MCP Tunnel profile,
  workspaces, active `chatgpt-operate` profile, and Full Shell policy. This is
  a presentation-only release and requires no credential or remote connector
  migration.

## 1.0.17 — 2026-08-18

- Replace the macOS 27 in-App directory browser with the native AppKit
  `NSOpenPanel` on every supported macOS release. **Workspaces > Add** now
  always opens the system folder-selection UI, registers the selected URL
  through the existing persistent-bookmark path, and refreshes Workspaces and
  Home in place without replacing the page.
- Keep folder selection local and user initiated. Neither the folder panel nor
  local workspace registration depends on a website, network-security
  classification, anti-scraping decision, Shell policy, or provider runtime.
- Keep the narrowly reviewed `codex.app.apps.list` upstream ChatGPT
  connector-directory HTTP 403 outcome isolated to that provider request. It
  does not classify the local App, loopback gateway, workspace, or Shell as
  hostile and cannot interrupt ordinary local operation.
- Keep the immutable signed `v1.0.16` candidate unpublished. Its release run
  was canceled before draft creation after exact macOS 27 UI acceptance found
  that the separate in-App browser could not complete workspace registration;
  no 1.0.16 GitHub Release was created. Version 1.0.17 repeats the protected
  signed-tag workflow with the native panel fix.

## 1.0.16 — 2026-08-18

- Add an in-App SwiftUI folder browser for macOS 27, where the beta system
  open-panel selection state is unreliable. Earlier supported macOS releases
  retain the system folder importer and its user-selected privacy grant. Both
  paths update the workspace list in place after registration.
- Keep the exact-artifact catalog gate exhaustive while admitting one narrowly
  reviewed fail-closed outcome: `codex.app.apps.list` may encounter the
  upstream ChatGPT connector-directory HTTP 403 challenge only when the MCP
  result is structured, contains the stable provider marker, and correlates to
  a failed audit row with `gateway.execution_failed`. Other provider, network,
  semantic, or audit failures still block publication.
- Make the 22-case mandatory release catalog match the publisher-owned trust
  boundary. Cloudflare Quick Tunnel isolation and named-tunnel lifecycle/auth
  tests remain mandatory; a live named deployment is an optional user-owned
  deployment check because its domain, hostname, and runtime token belong to
  the deploying user rather than the product or release workflow.
- Derive Release Evidence Manifest completeness from the bundled Test Case
  catalog instead of duplicating a fixed count across code and CLI output.
- Keep the immutable notarized 1.0.15 draft unpublished: its App, Shell,
  ChatGPT tunnel, 286 successful catalog calls, and all audit correlations
  passed, but the previous policy incorrectly treated an upstream connector
  directory challenge and publisher-owned Cloudflare domain as product release
  failures. Version 1.0.16 repeats the protected signed-tag workflow and exact
  artifact acceptance under the corrected boundary.

## 1.0.15 — 2026-08-18

- Preserve the final symlink entry during recursive read-only workspace scans.
  `file.list`, `file.tree`, `file.find`, `file.search`, `workspace.todos`, and
  `workspace.env_files` report or skip symlinks without following their
  targets, so a dangling link or a link outside the workspace cannot abort an
  otherwise safe scan or expose target content.
- Build directory children from lexical names and retain each symlink's
  workspace-relative identity while explicit reads, writes, operation tickets,
  and symlink destinations continue to enforce canonical containment.
- The immutable 1.0.14 candidate passed signing, notarization, installation,
  real ChatGPT Full Shell, and the escaping-symlink write denial. Its
  exact-artifact catalog run then found that a safe dangling link caused two
  recursive read-only tools to fail, so its draft remains unpublished and
  1.0.15 repeats the complete workflow.

## 1.0.14 — 2026-08-18

- Resolve workspace paths through the deepest existing ancestor before
  authorizing reads, writes, links, or operation tickets. A write whose missing
  destination sits below a symlink that leaves the registered workspace is now
  denied before preparation and cannot create content outside the grant.
- Reuse the same canonical containment rule for built-in tools and
  `operations.prepare`, classify state-path escape audits as denied, and add
  regressions for direct writes, symlink destinations, and ticket preparation.
- Preserve the authenticated OpenAI Secure MCP Tunnel identity in runtime
  validation observations and add repeatable evidence for downstream drift
  denial, cancellation propagation, and provider reconnection.
- The immutable 1.0.13 candidate passed signing, notarization, installation,
  ChatGPT Full Shell, and 287/287 runtime calls. Exact-artifact acceptance then
  reproduced a missing-target write through an escaping workspace symlink, so
  its draft remains unpublished and 1.0.14 repeats the complete workflow.

## 1.0.13 — 2026-08-17

- Resolve the active fixed macOS HTTP, HTTPS, and SOCKS proxies for every
  Codex App Server, Exec, and MCP child lifecycle. Finder-launched production
  Apps now reach the same Codex control plane as Safari without requiring
  proxy variables in the App launch environment.
- Preserve an explicitly inherited proxy environment, mirror conventional
  uppercase and lowercase variables for runtime compatibility, and keep
  loopback plus macOS bypass hosts in `NO_PROXY`. Resolved fixed proxies are
  child-process-only state: Computer MCP does not persist or log them, and
  does not evaluate proxy auto-configuration scripts.
- The immutable 1.0.12 candidate passed CI, Developer ID signing, Apple
  notarization, installation, and real ChatGPT Full Shell acceptance. Its
  exact-artifact catalog run then proved that a normal GUI launch omitted the
  system proxy from Codex App Server and returned HTTP 403 from `apps/list`;
  its draft remains unpublished and 1.0.13 repeats the full workflow.

## 1.0.12 — 2026-08-17

- Accept runtime observations over the OpenAI Secure MCP Tunnel only when the
  audit-derived Tunnel instance, Tunnel profile, and Gateway Socket connection
  are complete. These probes remain consumer-free runtime evidence and cannot
  claim a ChatGPT result.
- Add a full collector regression that correlates an authenticated Secure
  Tunnel runtime request through its exact audit row and verifies the sealed
  Evidence Bundle.
- Upgrade Validation Observation and Evidence Bundles to schema 2. Reviewed
  fail-closed execution paths now use `expected_failure`, require an exact
  failed audit row with a stable error code, and remain distinct from policy
  denial and unexpected failure. Only the two reviewed no-active-request
  lifecycle response tools may use this outcome.
- The immutable 1.0.11 candidate passed CI, Developer ID signing, Apple
  notarization, installation, effective configuration export, and 287/287
  exact-artifact calls. Final evidence sealing exposed the remaining runtime
  layer contract mismatch; its draft remains unpublished and 1.0.12 repeats
  the complete production workflow and exact-artifact acceptance.

## 1.0.11 — 2026-08-17

- Derive full-catalog observation provenance from the correlated audit rows,
  preserve the authenticated OpenAI Secure MCP Tunnel instance and profile
  identifiers, and reject missing, mixed, or incomplete identities instead of
  silently relabeling a remote run as a local Gateway Socket run.
- Make `config.export` project the effective App-owned workspace grants,
  profile capabilities, and persisted Full Shell state into a validated,
  replayable TOML document while `config.show` continues to expose the
  unchanged source manifest.
- The immutable 1.0.10 candidate passed signing, notarization, installation,
  real ChatGPT Full Shell, and 287/287 exact-artifact runtime calls. Final
  evidence correlation exposed the two fail-closed validation defects above;
  its draft remains unpublished and 1.0.11 repeats the complete production
  workflow and exact-artifact acceptance.

## 1.0.10 — 2026-08-17

- Run the embedded Codex Exec lifecycle with the official
  `--ignore-user-config` boundary. User authentication remains in the user's
  existing `CODEX_HOME`, while global MCP servers, models, hooks, profiles,
  and other `config.toml` settings can no longer delay or alter a Gateway
  request.
- Pin `swift-codex` 0.1.2 and regression-test the typed isolation option for
  both new and resumed Exec sessions.
- The immutable 1.0.9 candidate passed signing, notarization, packaging, and
  286/287 exact-artifact catalog calls, but final acceptance exposed a stale
  user-global MCP server adding a 30-second startup timeout to Codex Exec. Its
  draft remains unpublished; 1.0.10 repeats the complete production workflow
  and exact-artifact acceptance with the isolated lifecycle.

## 1.0.9 — 2026-08-15

- Close every App Server, Exec, MCP, HTTP, stdio, and Gateway provider runtime
  when its owning client session disconnects or the gateway stops. Repeated
  ChatGPT and Full Shell connections no longer leave Codex child processes
  behind or eventually stall later tool calls.
- Route the reviewed Codex App Server method surface through typed
  `swift-codex` requests, retain the existing per-method policy checks, and
  add explicit runtime shutdown contracts with disconnect regressions.
- Make the independent full-catalog acceptance probe fail within a bounded
  timeout instead of hanging, exercise real Full Shell and Computer Use
  lifecycles in an isolated helper process, and validate expected provider
  failures together with their structured result and failed audit decision.
- Complete a development-candidate runtime rehearsal covering 287/287
  advertised tools with 287/287 semantic results and 287/287 correlated audit
  rows. The same fail-closed suite remains required against the exact
  checksummed notarized 1.0.9 artifact before its draft Release is published.

## 1.0.8 — 2026-08-14

- Refresh the App-managed OpenAI `tunnel-client` profile with the current
  embedded CLI, gateway socket, gateway profile, and Tunnel identity before
  every start. This automatically migrates an existing connection when the App
  is updated or moved, then runs doctor before launching the tunnel process.
- Add fail-closed regressions for the required `init --force`, doctor, and run
  ordering and for a profile-refresh failure that must prevent process launch.
  The immutable `v1.0.7` attempt completed Developer ID signing, App and DMG
  notarization, Gatekeeper, checksums, credential cleanup, draft creation, exact
  DMG installation, and installed-CLI binary verification successfully. Exact
  ChatGPT acceptance then found that the existing Tunnel Client YAML still
  launched a bridge from the old development App path; its draft remains
  unpublished and no public GitHub Release was created. Subsequent exhaustive
  catalog acceptance also exposed provider runtimes surviving disconnected
  gateway sessions, so the immutable 1.0.8 candidate was not promoted.

## 1.0.7 — 2026-08-14

- Update a user-owned `~/.local/bin/computer-mcp` symlink from an older
  Computer MCP App bundle to the newly installed App automatically. Regular
  files, non-App targets, and links not owned by the user remain protected.
- Add a regression that performs the exact old-App-to-new-App CLI link
  migration required by the installation acceptance Test Case. The immutable
  `v1.0.6` attempt completed Developer ID signing, App and DMG notarization,
  Gatekeeper, checksums, credential cleanup, and draft creation successfully.
  Exact installation acceptance then found the old valid App-owned CLI link
  was classified as installed but refused migration; its draft remains
  unpublished and no public GitHub Release was created.

## 1.0.6 — 2026-08-14

- Copy accepted App and DMG notarization receipts into the root release-asset
  directory before generating `SHA256SUMS`, so every checksummed basename is
  also an uploadable root-level file.
- Add fail-closed, regression-tested asset-layout and checksum assembly gates
  that reject nested, external, missing, duplicate, symlinked, or misplaced
  release inputs before production credentials are available. The immutable
  `v1.0.5` attempt successfully Developer ID signed, notarized, stapled, and
  passed Gatekeeper for both the App and DMG, then stopped while assembling
  checksums because the two accepted receipt files had not been copied out of
  `ReleaseMetadata`. Credential cleanup succeeded and no GitHub Release was
  created.

## 1.0.5 — 2026-08-14

- Developer ID sign the final DMG container with a secure timestamp before
  submitting it to Apple, then independently verify its signature, Team ID,
  notarization ticket, Gatekeeper result, and checksum.
- Add no-secret signature-record and packaging-order regressions that reject a
  missing Developer ID authority, Team ID, timestamp, container signature, or
  a DMG signed only after notarization. The immutable `v1.0.4` attempt
  successfully signed and notarized the App, notarized and stapled the DMG,
  and passed mounted-App Gatekeeper assessment. It then stopped because the
  unsigned DMG container produced `source=no usable signature`; credential
  cleanup succeeded and no GitHub Release was created.

## 1.0.4 — 2026-08-13

- Parse Apple notarization responses through a dedicated fail-closed verifier
  that avoids zsh special parameters and validates the accepted status and UUID
  submission ID before stapling.
- Exercise accepted, rejected, missing, malformed, and invalid-ID notarization
  records before production credentials become available. The immutable
  `v1.0.3` attempt successfully built and Developer ID signed the Universal 2
  App, then stopped after the App notarization command returned because the
  packaging script declared zsh's read-only `status` parameter. Its ephemeral
  credentials were removed and it produced no GitHub Release or distributable
  artifact.

## 1.0.3 — 2026-08-13

- Make the protected release job self-contained by limiting its formal
  build/sign/notarize path to macOS and Xcode tools instead of relying on a
  Homebrew tool installed in the preceding job.
- Add positive and negative release-boundary gates that reject Homebrew or
  ripgrep dependencies after production credentials become available. The
  immutable `v1.0.2` attempt stopped at the first production tooling preflight,
  before protected credentials were validated or used, and produced no GitHub
  Release or production artifact.

## 1.0.2 — 2026-08-12

- Make `git.branch` deterministic across Git configurations by explicitly
  disabling paging, color, and column output and requesting list semantics.
- Verify that the reusable `fixture-base` branch exists when generating the
  Validation Git fixture. The immutable `v1.0.1` attempt stopped in the
  no-secret Validation job and produced no GitHub Release or production
  artifact.

## 1.0.1 — 2026-08-12

- Preserve and verify the remote SSH-signed annotated tag object after GitHub
  Actions checkout before any protected production credential is available.
- Notarized Universal 2 DMG release candidate. The immutable
  `v1.0.0` attempt stopped in the no-secret verification job and produced no
  GitHub Release or production artifact.

## 1.0.0 — 2026-08-12 (unpublished candidate)

- Initial App/CLI release candidate for macOS 14+ as a Universal 2 DMG.
- Policy-enforced local and remote MCP gateway with explicit caller, profile,
  workspace, risk, TCC, and audit boundaries.
- Independent OpenAI Secure MCP Tunnel and Cloudflare remotely managed named
  tunnel lifecycles.
- Typed builtin, Skills, CLI, downstream MCP, process, Codex, and Computer Use
  capability families.
- App-owned configuration, GRDB state, Keychain secrets, security-scoped
  workspaces, Control Socket, embedded CLI, and launch-at-login lifecycle.
- Signed-tag releases capture accepted App and DMG notarization receipts and
  render artifact-bound records before creating the checksummed draft.
