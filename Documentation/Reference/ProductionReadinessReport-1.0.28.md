# Computer MCP 1.0.28 Production Readiness Report

Status: **Protected-CI release template; all source, disposable-real,
authorized vehicleOS, independent-review, and cold-start gates passed before
tagging. Publication remains fail-closed on the exact signed and notarized
artifact.**

This report is rendered by the protected GitHub release job and bound to the
signed tag, source commit, Universal 2 App, embedded CLI, notarized DMG,
notarization receipts, and workflow run below.

## Candidate identity

| Field | Final value |
| --- | --- |
| Release date | __RELEASE_DATE__ |
| Commit | `__RELEASE_COMMIT__` |
| Signed tag | `__RELEASE_TAG__` |
| Signed tag object | `__RELEASE_TAG_OBJECT__` |
| App version/build | 1.0.28 (29) |
| Architectures | `__APP_ARCHITECTURES__` |
| Apple Team ID | `__APPLE_TEAM_ID__` |
| Embedded CLI SHA-256 | `__EMBEDDED_CLI_SHA256__` |
| DMG | `Computer-MCP-1.0.28-universal.dmg` |
| DMG SHA-256 | `__DMG_SHA256__` |
| App notarization submission | `__APP_NOTARY_SUBMISSION_ID__` |
| DMG notarization submission | `__DMG_NOTARY_SUBMISSION_ID__` |
| GitHub Actions run | __GITHUB_RUN_URL__ |

## Acceptance evidence

| Gate | Evidence |
| --- | --- |
| Automated regression | Strict format/lint and supported-default builds passed; 824 root + 25 App + 71 Validation tests = 920 |
| Handoff | Multi-runtime transactional release, exact-runtime reaping, idempotence, external-claim verification, reclaim, and no external process signaling |
| Scoped Full Access | Default denial, remote request, local-only exact approval, next eligible start, no active-turn hot-switch, atomic consumption, expiry/revoke, restart/disable cleanup, and no capability-policy bypass |
| Real disposable Codex | Official `skills/list` 3.045 s; bounded Apps 39.981 s; startup Full Access 37.416 s; Git/loopback/revoke 87.531 s; three-runtime handoff 53.056 s |
| Long thread | A synthetic 30,000-record rollout returned bounded Goal, recent activity, cursor, output, and latency evidence |
| Real vehicleOS | Exact persisted thread reclaimed; official Goal and recent history read; Full Access effective for the next eligible start; grant revoked to `workspace-write`; graceful release preserved the Goal and returned externally claimable with no writer ownership remaining |
| Runtime/data repair | Startup/stop stale-receipt reconciliation, canonical-root workspace idempotence and reviewed dedup, runtime/request state separation, and backward-compatible migrations |
| Validation cleanup | Independent per-phase deadlines preserve the primary result and identify only exact owned cleanup targets |
| Worktree safety | Explicit lease ownership, heartbeat/TTL, deterministic release, and no path-heuristic deletion of external worktrees |
| Artifact provenance | Development and validation artifacts cannot use the final release name; candidate and exact-published receipts bind commit, tag, build identity, checksum, notarization, staple, and byte equality |
| Security review | Workspace, profile, caller, connection, thread, approval, ticket, redaction, symlink, secret, and external-process boundaries passed |
| Documentation and CLI | Architecture, reference, troubleshooting, public manuals, generated CLI surface, examples, DocC, localization, and repository gates passed |
| Independent review | Defect-first review found and closed elevation-expiry precedence and stale CLI contract gaps |
| Cold start | A context-free maintainer audit reconstructed the trust model, lifecycle, handoff, elevation, long-thread, workspace, provenance, website, and release boundaries with no remaining source defect |
| Website boundary | Separate accepted `computer-mcp.github.io` repository remains unchanged; no product statement required a website release |

## Protected artifact gates

The tag workflow must still prove all of the following against one fresh
artifact closure before publication:

- signed annotated tag, exact commit, and `origin/master` reachability;
- Universal 2 App and CLI, Developer ID, Hardened Runtime, provisioning profile,
  timestamp, entitlements, and stable production identity;
- accepted App and DMG notarization records, valid staples, and Gatekeeper;
- complete checksummed release assets, candidate provenance, uploaded/downloaded
  DMG byte equality, and exact-published provenance;
- repository, dependency, license, SBOM, secret, release-boundary, and
  production-Environment gates.

The workflow creates no replaceable partial public artifact. A failure remains
closed; a source correction requires a new version and never moves this tag.

## Migration and compatibility

The database applies backward-compatible migrations for scoped elevation,
runtime/request observations, ownership reconciliation, canonical workspace
identity, validation receipts, worktree leases, and artifact provenance.
Existing workspaces, profile grants, tunnel configuration, Keychain data, and
audit history are preserved. No raw credentials, environment dumps, or
unbounded approval payloads are persisted.

## Legal and release identity

Publisher-approved `LICENSE`, `EULA.md`, and `PRIVACY.md` remain unchanged.
Their digests are verified by the protected workflow. v1.0.27 remains the
immutable production predecessor and is not rebuilt, retagged, or replaced.

## Final attestation

Publication of the rendered record attests that the exact candidate passed the
protected artifact gates and that the public GitHub asset is byte-identical to
the signed, notarized, stapled, Gatekeeper-assessed candidate.
