# Computer MCP 1.0.27 Release Notes

Status: CI-rendered notarized draft template. The GitHub Release remains a
draft until the publisher completes exact-artifact acceptance and confirms the
coordinated `computer-mcp.github.io` publication from its reviewed commit.

## Highlights

- Exact-artifact validation cleanup now treats the official App Server's
  `no rollout found` response as an idempotently clean result only for the exact
  thread being removed; other provider failures remain blocking.
- Validation socket sessions terminate their owned bridge process before
  disconnecting the MCP client, so a completed full-catalog run cannot hang
  after its final audit record.
- The immutable signed `v1.0.26` candidate remains unpublished. Its installed
  artifact completed catalog calls but exposed these two validator lifecycle
  defects, so every protected and exact-artifact gate moves to this candidate.

- `codex.app.apps.list` now exposes the current typed pagination inputs. It
  defaults to cached directory data and a 20-entry page, while allowing a
  cursor, thread scope, explicit refresh choice, and a limit from 1 through 100.
- Apps directory loading has its own explicit, end-to-end timeout setting,
  bounded to 120 seconds by default. It uses one App Server generation because
  Codex can send a multi-megabyte `app/list/updated` snapshot before the bounded
  page response, and restarting midway would repeat that snapshot.
- Codex App Server stdout is drained in available chunks instead of crossing a
  concurrency boundary for every byte. Chunk consumption is serialized and
  awaited before the protocol stream finishes, preserving both interactive
  long-lived responses and the final line from a short-lived process.
- A deterministic 4 MiB long-lived response regression accompanies real
  official Codex 0.147.0 `skills/list` and bounded `app/list` acceptance tests.
  Both responses must complete normally and every owned process must be reaped;
  a timeout is not accepted as a passing real-client result.
- Real official-client tests now make their exceptional path as strict as their
  success path: every test-owned App Server is reaped, and a handoff failure
  interrupts and archives any durable temporary thread through a fresh client
  bound to the same temporary workspace.
- The normal App Server request timeout remains one end-to-end budget covering
  process startup, workspace validation, the reviewed RPC, and at most one
  fresh-connection read-only retry. Cancellation cannot start another process
  generation after either configured budget expires.
- Concurrent and repeated App Server shutdown paths now share one retirement
  operation. Back-pressured stdin finalization cannot hold up bounded EOF,
  TERM, KILL, and process reaping.
- Deterministic hung-startup, hung-request, back-pressured-writer, canceled
  retry, large notification, and bounded Apps page tests protect the complete
  request and teardown path.
- Build, test, documentation, and release gates use SwiftPM's supported default
  build engine. Release metadata traverses the actual product dependency graph
  emitted by that engine, preserving exact linked-versus-resolved-only SBOM and
  notice classification across supported toolchains without a deprecated
  build-system override.
- Every Computer MCP-owned Codex App Server has a stable runtime identity,
  observable process-group ownership, and deterministic teardown across normal
  close, replacement, timeout, shutdown, and parent death. The lifecycle never
  targets unrelated Codex clients.
- Durable runtime and thread-to-workspace receipts support exact-runtime
  inspection, thread release, deliberate reclaim, reviewed cleanup, and
  actionable writer-conflict diagnosis without claiming control over Codex
  Desktop, IDE, CLI, or user-owned App Server processes.
- Supported Codex approval requests flow through a durable, redacted broker
  that keeps gateway policy, agent approval, and user consent separate.
  Authorized Codex work can use governed tools and Git with workspace
  containment, hooks, operation tickets, and complete audit correlation.
- Stable official Codex Goal get, set, and clear bindings and turn steering are
  exposed without relabeling Computer MCP orchestration as a native Goal.
  Durable acceptance runs add criteria, evidence, pause states, budgets, stall
  detection, contradiction checks, and explicit completion.
- Exclusive and isolated-worktree leases prevent silent concurrent mutation.
  App Server, Exec, MCP, approvals, diagnostics, and worktree inputs remain
  bounded and redacted.
- Product-first English and Simplified Chinese manuals are coordinated with the
  independent accessible static site at `https://computer-mcp.github.io/`.

## Install

1. Download `Computer-MCP-1.0.27-universal.dmg` and `SHA256SUMS` from the same
   GitHub Release.
2. Verify the SHA-256 digest.
3. Open the DMG and drag `Computer MCP.app` to `/Applications`.
4. Cold-start the App from Finder and grant only the macOS permissions needed
   by the capabilities you enable.
5. Use **Install Command Line Tool** if you want the App-owned CLI link at
   `~/.local/bin/computer-mcp`.

The release does not bundle Codex, OpenAI `tunnel-client`, `cloudflared`, or
provider credentials. OpenAI and Cloudflare credentials are supplied by each
user and stored in that user's App-owned Data Protection Keychain.

## Security and compatibility

- Existing schema-1 configurations remain valid. New Codex lifecycle and
  approval limits use bounded defaults, and the Codex provider remains disabled
  until explicitly configured.
- `shell.run`, generic CLI execution, process spawning, workspace writes, and
  Full Shell remain disabled until both local policy and the selected profile
  explicitly grant them.
- Automatic workspace-write approval remains off by default. A permitted
  higher-risk action still requires a caller or user decision unless an
  explicit bounded low-risk policy applies.
- Remote profiles never inherit `local-admin` authority, and configuration
  exports contain no provider secret, token, credential, Keychain value, or
  resolved proxy value.
- Computer MCP may stop only a runtime it can prove it owns. A writer conflict
  with another official Codex client is reported rather than forcibly cleared.
- The production Bundle ID, Developer ID identity, private Keychain access
  group, TCC identity, runtime namespace, Secure MCP Tunnel profile, connector,
  credentials, workspaces, and policy remain compatible with 1.0.22 and the
  unpublished 1.0.23 through 1.0.26 candidates. The new Apps directory timeout
  has a bounded default, so no data, credential, tunnel, CLI, MCP,
  configuration, or workspace migration is required.
- The immutable signed `v1.0.23`, `v1.0.24`, `v1.0.25`, and `v1.0.26`
  candidates remain unpublished. Their exact-artifact audits exposed the
  lifecycle deadline, large-response transport, large Apps snapshot deadline,
  and validation cleanup defects corrected by the current candidate.

## Product boundaries

Computer MCP is a policy-controlled, workspace-scoped local execution gateway
for ChatGPT, Codex, and other MCP clients. It is not an unrestricted remote
shell or a replacement for official Codex Remote. Use Codex Remote for ordinary
first-party remote Codex control; use Computer MCP when a general MCP-accessible
local tool, app, workspace, or governed orchestration plane is required.

The advanced Codex ownership, approval, orchestration, and managed-worktree
surfaces remain explicitly enabled experimental capabilities. Stable gateway,
workspace, policy, tunnel, and audit behavior continues to fail closed.

## Legal and privacy

Computer MCP is proprietary source-visible software, not an open-source Swift
package. Installation and non-commercial use are governed by `LICENSE` and
`EULA.md`. Third-party licenses are reproduced in the App and DMG. Local data
and remote transmission boundaries are described in `PRIVACY.md`.

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
- Apple Silicon native installation and lifecycle: required before publishing
  the draft
- x86_64 compatibility under Rosetta 2: required before publishing the draft
- Main repository exact-artifact acceptance: 22/22 required before publishing
- Productization contract and website deployment gates: required before the
  coordinated release is announced

The GitHub Release upload set contains the notarized DMG, `SHA256SUMS`,
CycloneDX SBOM, dependency manifest, third-party notices, these rendered
release notes, the rendered production-readiness report, and both notarization
receipts. Private raw acceptance evidence is retained separately and is never
uploaded automatically.
