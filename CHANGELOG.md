# Changelog

All notable user-visible changes to Computer MCP are documented here.

## Unreleased

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
