# Capability Ownership

A capability belongs in gateway core only when Computer MCP owns the stable
cross-provider contract and the wrapper adds containment, typed output,
bounded execution, or a deliberate safety gate.

## Ownership Map

| Owner | Responsibilities |
| --- | --- |
| Computer MCP core | MCP transports, App socket, profiles, workspace grants, audit, operation tickets, CLI/MCP bridges, Skills, typed workspace/file/Git/structured/system tools, Shell, and generic Computer Use |
| Independent Codex adapter plugin | App Server and Exec lifecycles through `swift-codex`; domain state, native approvals, thread/Goal and worktree receipts |
| `apple-cli` / `apple-cli-mcp` | Clipboard, notifications, Finder, application launching, URL opening, and Apple application/domain workflows |
| Browser provider | Browser engine, page lifecycle, selectors, and browser automation |
| Other downstream MCP providers | Their own business schemas, authentication, and side-effect contracts |

Skills are a first-class gateway plane, not a coding feature. Any authorized MCP
consumer can discover and read an entire registered Skill package without
escaping its root.

`workspace.open` and `workspace.reveal` remain workspace-contained navigation
primitives. They do not form a general Finder or application automation API.

## Codex Boundaries

Computer MCP does not maintain a hand-written coding agent or shell-based
`coding.*` provider. The independent `plugin-codex` package integrates the installed vendor through:

- App Server for stateful threads and turns;
- Exec for isolated JSONL jobs.

The host authorizes the caller, capabilities, and registered workspace.
The adapter preserves Codex's native execution settings and approval semantics;
omitted settings inherit the user's Codex configuration. Output bounds and
vendor session ownership belong to the adapter. Domain persistence belongs to the adapter;
host grants, workspace registrations, tickets and audit remain in the Gateway
Database. Authentication mutation, config writes, marketplace mutation, and
remote-control pairing remain local Codex/App control-plane operations.

There are six deliberately distinct ownership concepts:

| Concept | Owner and meaning |
| --- | --- |
| Quick thread or turn | One ordinary request against the workspace App Server runtime; turn completion is not durable Goal completion |
| Dedicated Computer MCP execution | A Computer MCP-owned runtime, process group, thread subscription, approvals, and audit linkage |
| Official Codex Goal | Native App Server Goal state exposed through official get/set/clear methods; Computer MCP does not invent native statuses |
| Computer MCP acceptance run | A separate durable acceptance, evidence, budget, pause, and reconciliation layer that may reference an official Goal |
| Codex Remote | The official first-party remote-control experience and preferred interface for ordinary remote Codex work |
| Codex Desktop, IDE, or CLI | An external official client whose connection and processes Computer MCP cannot inspect or terminate without verified ownership |

Computer MCP can run one deterministic handoff transaction across every live
Computer MCP runtime that verifiably owns a thread. The transaction refuses an
active turn unless interruption was explicitly requested, refuses unresolved
approval or user-input requests in graceful mode, performs bounded official
unsubscription, verifies that no owned runtime still reports the thread
loaded, and reaps an empty runtime. A runtime with other useful work remains
alive. Success is the postcondition `released_persisted`: the persisted thread
and Goal are unchanged and no live Computer MCP writer remains, so another
official client can claim the thread immediately. Repeating the transaction is
idempotent.

Computer MCP can also stop one exact owned runtime and deliberately ask its App
Server to resume a persisted thread. The latter is exposed internally as
`thread.reclaim`; product surfaces describe the action naturally in context,
with labels such as “重新接管线程” treated as illustrative rather than
normative. If a different client owns the writer, Computer MCP reports the
conflict and does not signal or unsubscribe that client.

After Computer MCP creates, forks, or successfully resumes a thread, it stores
a durable thread-to-registered-workspace ownership receipt. A later gateway
generation validates that receipt before asking the official App Server to
resume the thread. An unfamiliar thread falls back to the official persisted
thread index and must still resolve inside the bound workspace. The receipt is
updated to loaded, released, or archived as the official lifecycle changes; it
is evidence of scope, not authority to terminate another client.

Thread handoff diagnosis combines live runtime, process-group, connection,
thread, turn, approval, user-input, durable thread ownership, and runtime
receipt evidence. Live evidence outranks persisted receipts. A stopped runtime
cannot remain the authoritative owner, and a released thread cannot
simultaneously appear in an owned runtime's loaded set. Stale loaded receipts
are reconciled only after both the runtime directory and exact receipted
process/supervisor are proven gone; reconciliation changes local receipts only
and sends no signal. External ownership is explicitly inferred when no
verifiable Computer MCP owner exists. Questions about why another official
client cannot claim a thread are an acceptance scenario for this diagnostic
capability, not required interface copy.

## Workspace Identity

A workspace registration is identified by its symlink-resolved canonical root,
not by the spelling of the submitted path. Registering the same canonical root
again is idempotent and returns the existing workspace. A conflicting explicit
display name requires review rather than silently changing metadata.

Older duplicate rows are repaired by a digest-bound preview/apply operation.
The oldest registration remains canonical, profile references move to it, and
the retired IDs become durable aliases so historical audit and ownership
receipts continue to resolve. Deduplication never deletes the underlying
workspace and never treats equal-looking path text as sufficient ownership.

## Approval Ownership

Host capability authorization and human confirmation are separate decisions.
The host decides whether the authenticated caller may use a capability in a
registered workspace, then applies its confirmation policy to that operation.
Only the local control plane resolves pending host approval tickets.

Codex native execution approvals are owned by Codex and adapted through
`swift-codex`. The adapter retains official response fields and decision
scope, including acceptance, denial and cancellation. A native approval does
not approve a host operation ticket. Dynamic calls from Codex to host tools
follow the same host authorization and confirmation path as other callers.
MCP elicitation is interaction, not permission.

## Multi-executor Worktrees

A mutation lease names the registered workspace, agent, optional thread/run,
parent lease, branch, heartbeat, expiry, and revision. One active lease owns a
worktree at a time. A turn that targets a leased workspace must present the
matching lease; concurrent writers receive a conflict instead of sharing the
directory.

Computer MCP can create an isolated child worktree only from a persisted,
five-minute provision plan linked to an active parent lease. It derives the
path under its Application Support-managed root, validates the source Git root,
new branch, start commit, and exact Git common directory, then registers the
child as a workspace, carries the current profile's workspace grant forward,
and creates the isolated child lease. A new gateway session discovers the new
workspace.

Removal is a separate reviewed lifecycle. The child lease must first be
released, no Computer MCP runtime may remain live, the Git linkage and
ownership receipt must still match, the worktree must be clean, and HEAD must
not change between plan and execution. The destructive perform call also uses
a single-use gateway operation ticket. It removes only the exact managed
worktree and workspace grant; the local branch is preserved. A user-created or
otherwise unreceipted worktree cannot be selected for removal.

## External Provider Composition

For `apple-cli-mcp` or another local MCP provider:

1. Register it under `[[mcp.servers]]`.
2. Select exact `allowed_tools` or explicitly choose `allow_any_tool = true`.
   Grant the registration to the intended profile through `mcp_servers`, or
   grant particular tool capabilities. Registration policy remains host-owned.
3. Check `mcp.servers.status`.
4. Inspect `mcp.tools.list` and `mcp.tools.describe`.
5. Invoke through `mcp.tools.call`, or opt into a reviewed pinned/reexported
   surface.

Missing optional providers do not prevent Computer MCP from starting.

## Builtin Admission Gate

A new typed builtin must satisfy all of these:

1. No existing CLI or MCP provider clearly owns the domain.
2. The action is common and stable, not project-specific business behavior.
3. The wrapper adds real structure, containment, safety, or high-frequency
   ergonomics beyond `cli.exec` or `mcp.tools.call`.
4. Input maps directly to deterministic execution.
5. Traversal, time, output, and result limits are explicit.
6. Risk, profile, workspace, network, and TCC effects are classified.
7. Focused tests and real dogfood cover success and representative failure.

Wrappers that merely rename an existing command do not enter gateway core.
