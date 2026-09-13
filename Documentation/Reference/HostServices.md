# Scoped host services

An owned stdio MCP registration can use a private, inherited MCP connection to
its originating Gateway. This is an explicit host choice, not a manifest grant
or another plugin runtime. Both directly registered and plugin-provided MCP
servers use the same transport and authorization path.

## Enable and identify the scope

Direct registration uses `host_services = true` inside `[[mcp.servers]]`. A
plugin's host-owned MCP settings use `"hostServices": true`; the App presents
**Allow scoped host services**. Both default to false. HTTP registrations reject
this option. Changing a package's manifest cannot enable it.

Calls to these registrations require a workspace. With one registered workspace,
the Gateway selects it automatically and still checks the caller's grant. With
multiple workspaces, provide `workspace_id` or use a workspace-bound connection.
For `mcp.tools.call`, `workspace_id` belongs in the outer Gateway arguments beside
`server`, `tool` and `arguments`, not inside the downstream `arguments` object.

Enable this only for an adapter trusted to use the already authorized scope.
The adapter inherits a connected Unix stream descriptor identified by
`COMPUTER_MCP_HOST_FD`. It receives no control-socket pathname, credential, or
local-admin identity. The host replaces reserved environment entries after
merging launch settings. Descriptor ownership is limited to the adapter; its
supervisor/watchdog and vendor subprocesses do not retain the callback endpoint.
The endpoint uses standard MCP initialization and newline-delimited JSON-RPC,
including `tools/list` and `tools/call`.

`COMPUTER_MCP_HOST_CONTEXT` remains provenance, not authentication. Its optional
`managedWorkspaceRoot` is selected by the host beside its file-backed database,
not by per-call arguments or a plugin manifest. Clients without the inherited
endpoint cannot reconstruct authority from copied JSON. A same-user native
executable still runs with the process's operating-system permissions; this
channel is not an OS sandbox for malicious plugin code.

## Tool execution and private services

Ordinary callbacks use the Gateway's current profile, caller, connection and
workspace. The host filters discovery against the live grant and reauthorizes
execution. Aliases, nested policy/ticket targets and other callback-enabled MCP
registrations cannot create a recursive route or widen the workspace.
Destructive tools keep the ordinary `operations.prepare` / `operations.commit`
contract; the adapter does not bypass tickets.

Configuration and builtin profile grants do not require a persisted profile
record. If the runtime was initialized with a persisted profile, deleting that
record revokes host access instead of restoring configuration authority.
Existing persisted restrictions are checked again during callback authorization.

Private `host.*` tools are listed only on this inherited connection, never as
northbound Gateway tools. Dynamic tool requests from a vendor cannot target the
private namespace. The host records a short-lived, in-memory reference to each
currently forwarded operation. Permission-sensitive private calls must match
exactly one such operation and its arguments; a claimed caller or request ID
from the adapter is insufficient. The reference expires when the forwarded call
returns or fails and is never sent as a reusable capability token.

| Private tool | Required inputs | Purpose |
| --- | --- | --- |
| `host.elevation.claim` | `runtime_id`, `action`; optional `thread_id` | Claim an existing locally approved grant for an eligible live start |
| `host.elevation.commit` | `claim_id`, `runtime_id`, `thread_id`; optional `turn_id` | Activate that claim during its original authorized invocation |
| `host.elevation.invalidate_claim` | `claim_id`, `reason` | Invalidate this connection's uncommitted claim |
| `host.elevation.invalidate` | `runtime_ids`, `reason`; optional `thread_id` | Invalidate consumed runtime grants; a thread selector requires the matching live release invocation and also invalidates its unused grants |
| `host.workspaces.register` | `worktree` | Register an exact derived worktree and its source profile grant atomically |
| `host.workspaces.authorize_removal` | `worktree` | Check the live destructive operation ticket before removal |
| `host.workspaces.unregister` | `worktree` | Remove the unchanged owned registration, or confirm an ownership-free no-op |
| `host.diagnostics.snapshot` | `limit` | Read bounded host receipts for the exact caller/profile/workspace/connection |

These tools return `structuredContent.result`; rejected calls return `isError`
and a bounded error. They do not accept caller-supplied clocks, grant approvals
or arbitrary database operations. Inspect their actual MCP schemas for input
constraints. They require host persistence; directory metadata alone is not a
host-service implementation.

## Elevation ownership

Local approval stays in the host's existing approval workflow. The adapter can
consume a matching approved grant but cannot request approval on behalf of a
local administrator or create a grant. The host checks current time, workspace,
caller, profile, connection, optional thread and the live start operation.
Pending, revoked and expired records cannot establish full access. A claim
cannot be committed by a later invocation or another runtime.

A next-turn grant is consumed once. Connection cleanup invalidates only records
claimed or consumed by that adapter connection. Thread release additionally
invalidates pending and approved grants for the exact thread, originating host
connection, workspace, profile and caller. Unbound grants and other threads or
connections retain their state. The thread selector must match the host's live
`codex.app.thread.release` invocation; a plugin assertion is insufficient.
If invalidation fails, the exact owned
records remain available for a bounded cleanup retry and session retirement
stays unconfirmed; process exit alone is not reported as successful cleanup.
Persistent recovery across a host crash is a separate lifecycle obligation.

## Derived workspaces and recovery

The plugin owns Git and domain lease/plan records. The host independently
checks the source repository, exact derived path, directory ownership, and Git
common directory before adding registration authority. Its
`pluginDerivedWorkspaces` ledger binds the receipt, source, publisher registration,
profile and workspace snapshot. Workspace registration, canonical-path ownership
and the added profile grant commit in one transaction. Existing identities,
pre-existing grants or independent path registrations are not adopted.

Removal requires the exact executing outer operation ticket. The host refuses
independent edits, aliases or grants held by another profile. It removes only
its own unchanged registration and grant; filesystem removal remains with the
plugin. A child lease is released through a child-workspace connection after
that registration is available; an existing immutable Gateway runtime does not
silently acquire a new workspace router.

If Git removal succeeds but host metadata cleanup fails, the domain receipt
remains `removing`, not `active`. Review it again with `remove.plan`, then use
its current revision and a new host operation ticket with `remove.perform`.
This recovery verifies that the path is absent, its parents/source remain
valid, and Git no longer registers it. It then cleans metadata without repeating
Git deletion. A replacement path, including a symbolic link, is never removed.

If provisioning fails and host rollback is unconfirmed, the plugin preserves
its remaining Git worktree and branch and reports incomplete recovery. Inspect
the domain receipt and host registration before any manual reconciliation;
uninstalling the plugin does not authorize deleting that content. A branch
advanced independently is not removed by the rollback's compare-and-delete.

## Diagnostic and transport bounds

Diagnostics filter workspace, profile, caller and connection before applying
`limit` (1–1000). They return receipt identities and digests, not command bodies
or raw output. In-flight grant handles are redacted while preserving the fact
that a claim is pending. Missing host data is unknown, not a zero-grant snapshot.
Private service audits retain the originating request/ticket relationship when
one is present.

The inherited transport bounds a message to 1 MiB and queues to 32 messages,
with 16 concurrently admitted callback handlers. Private service arguments are
limited to 64 KiB and responses to 512 KiB. Oversized diagnostics require a
smaller limit. The client bounds host calls to 30 seconds and joins shutdown
on timeout or cancellation; uncertain mutations are not automatically replayed.
The descriptor is closed on EOF/retirement, and ownership cleanup participates
in the same retirement barrier as the managed process.
