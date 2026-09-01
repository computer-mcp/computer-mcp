# Capability Ownership

A capability belongs in gateway core only when Computer MCP owns the stable
cross-provider contract and the wrapper adds containment, typed output,
bounded execution, or a deliberate safety gate.

## Ownership Map

| Owner | Responsibilities |
| --- | --- |
| Computer MCP core | MCP transports, App socket, profiles, workspace grants, audit, operation tickets, CLI/MCP bridges, Skills, typed workspace/file/Git/structured/system tools, Shell, and generic Computer Use |
| Codex provider | App Server, Exec, and MCP session lifecycles through `swift-codex` |
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
`coding.*` provider. It integrates the installed Codex through:

- App Server for stateful threads and turns;
- Exec for isolated JSONL jobs;
- MCP for the upstream `codex` and `codex-reply` tools.

The gateway fixes cwd, sandbox, approval policy, output limits, and session
ownership. Authentication mutation, config writes, marketplace mutation, and
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

Computer MCP can release a thread subscription from its current runtime, stop
one exact owned runtime, and deliberately ask its App Server to resume a
persisted thread. The latter is exposed internally as `thread.reclaim`;
product surfaces describe the action naturally in context, with labels such as
“重新接管线程” treated as illustrative rather than normative. If a different
client owns the writer, Computer MCP reports the conflict and does not signal
or unsubscribe that client.

After Computer MCP creates, forks, or successfully resumes a thread, it stores
a durable thread-to-registered-workspace ownership receipt. A later gateway
generation validates that receipt before asking the official App Server to
resume the thread. An unfamiliar thread falls back to the official persisted
thread index and must still resolve inside the bound workspace. The receipt is
updated to loaded, released, or archived as the official lifecycle changes; it
is evidence of scope, not authority to terminate another client.

Thread handoff diagnosis combines live runtime, process-group, connection,
thread, turn, approval, durable thread ownership, and runtime receipt evidence. It labels external
ownership as inferred when no verifiable Computer MCP owner exists. “Why can't
Codex Desktop open this thread?” is an acceptance scenario for that diagnostic
capability, not required interface copy.

## Approval Ownership

An allowed capability and an approved action are not the same decision. The
gateway first decides whether the caller, profile, registered workspace, path,
and capability permit the proposed operation. When the permitted Codex action
requires consent, the durable approval broker records the redacted request and
the user or authorized caller decides whether to approve it now.

Approve-once, upstream-bounded session approval, denial, timeout, and restart
interruption are explicit terminal receipts. Automatic approval is limited to
configured low-risk workspace writes and cannot expand policy. MCP elicitation
is surfaced as interaction, not treated as permission.

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
2. Declare the exact `allowed_tools` for remote profiles. Use
   `allow_any_tool = true` only in a trusted local-admin manifest.
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
