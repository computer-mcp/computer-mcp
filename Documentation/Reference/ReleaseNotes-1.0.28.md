# Computer MCP 1.0.28 Release Notes

Status: protected-CI release template. The workflow publishes only the exact
candidate that passes signed-tag, signing, notarization, staple, Gatekeeper,
checksum, provenance, and byte-identity gates.

## Highlights

- `codex.app.thread.release` is now a deterministic high-level handoff. It
  reconciles active, loaded, subscribed, persisted, and process ownership;
  reaps only exact Computer-MCP-owned runtimes; preserves the Goal; and returns
  success only when another official Codex client can claim the thread.
- `codex.app.thread.reclaim` and `codex.app.handoff.diagnose` make deliberate
  ownership transfer and writer-conflict diagnosis explicit without signaling
  Codex Desktop, IDE, CLI, or any other external process.
- A remote caller may request a scoped Codex Full Access grant, but only a local
  administrator may approve it. Grants bind the exact workspace root, profile,
  caller, connection, and optional thread, support one-turn and bounded TTL
  modes, and can be revoked or expired.
- Elevation never hot-switches a running turn or widens the Computer MCP tool
  policy. The next eligible start uses the approved Codex sandbox; later starts
  return to the configured safe sandbox after consumption, expiry, or revoke.
- Bounded recent-thread supervision reads Goal state, current/recent activity,
  approvals, user input, and progress without loading an unbounded rollout.
- Startup and runtime-stop reconciliation repair stale Computer MCP ownership
  receipts without mutating external Codex state. Runtime lifecycle, request
  failure, connection state, and process state are reported separately.
- Workspace registration is idempotent by canonical root, with reviewed
  deduplication for historical duplicates. Managed worktrees retain explicit
  owners and are never removed by path heuristic alone.
- Release artifacts now identify development, validation, release-candidate,
  and exact-published classes with commit, build identity, checksum,
  notarization, staple, tag, and publication provenance.

## Validation

- 920 automated tests passed: 824 root tests in 52 suites, 25 App tests in
  4 suites, and 71 Validation tests in 12 suites.
- Disposable official-client acceptance passed for startup Full Access,
  governed Git and loopback networking, revocation, three-runtime handoff, and
  a 30,000-record bounded recent reader.
- The authorized real vehicleOS thread completed request/local approval,
  `danger-full-access` effective-next-start verification, reclaim, Goal and
  recent-history read, revoke to `workspace-write`, and graceful release.
  Release reported `externally_claimable = true`, Goal preservation, and no
  remaining Computer MCP writer ownership.
- Independent defect-first review and a context-free cold-start maintainer
  audit passed before the release candidate was created.

## Install

1. Download `Computer-MCP-1.0.28-universal.dmg` and `SHA256SUMS` from this
   GitHub Release.
2. Verify the checksums, open the DMG, and drag `Computer MCP.app` to
   `/Applications`.
3. Launch the App and enable only the profiles, workspaces, tools, and macOS
   permissions you intend to use.

The release does not bundle Codex, OpenAI `tunnel-client`, `cloudflared`, or
provider credentials. User credentials remain in the App-owned Data Protection
Keychain and are never release inputs.

## Security and compatibility

- The default Codex sandbox remains `workspace-write`; static
  `danger-full-access` configuration remains rejected.
- Secure-tunnel callers cannot approve their own elevation or select a more
  powerful active profile. Local approval is exact and auditable.
- `shell.run`, Full Shell, generic CLI execution, mutation tickets, and
  destructive tools retain their independent policy and approval boundaries.
- Existing schema-1 configuration, production Bundle ID, Team ID, Keychain
  group, TCC identity, runtime namespace, profiles, workspaces, and tunnel
  credentials remain compatible. Database migrations are automatic and
  backward-compatible; no credential or workspace migration is required.
- v1.0.27 and all earlier tags and release records remain immutable.

## Product boundary

Computer MCP remains a policy-controlled, workspace-scoped local execution
gateway for AI agents. It is not an unrestricted remote shell or a replacement
for official Codex Remote. The public website remains the already accepted
separate `computer-mcp.github.io` repository; this focused release does not
redesign it.

## Final release record

- Release date: __RELEASE_DATE__
- Candidate commit: `__RELEASE_COMMIT__`
- Signed tag: `__RELEASE_TAG__`
- Signed tag object: `__RELEASE_TAG_OBJECT__`
- Apple Team ID: `__APPLE_TEAM_ID__`
- Architectures: `__APP_ARCHITECTURES__`
- App notarization submission: `__APP_NOTARY_SUBMISSION_ID__`
- DMG notarization submission: `__DMG_NOTARY_SUBMISSION_ID__`
- DMG SHA-256: `__DMG_SHA256__`
- Embedded CLI SHA-256: `__EMBEDDED_CLI_SHA256__`
- GitHub Actions run: __GITHUB_RUN_URL__

The GitHub Release contains the notarized DMG, complete `SHA256SUMS`, CycloneDX
SBOM, dependency manifest, third-party notices, rendered release notes and
readiness report, and both accepted notarization receipts.
