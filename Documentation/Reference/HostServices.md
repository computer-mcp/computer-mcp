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

Standalone manifest workspaces retain their configuration-owned scope even when
the Gateway uses a database for audit or plugin state. Database-owned workspaces
are checked against their current registration on every callback; deleting or
changing that registration revokes the original scope.
The host supplies an authenticated authorization subject independently of
connection tracking. Reconnecting with the same credential retains that
subject; a new transport connection receives a new tracking identity. Clients
sharing a credential also share its subject and grants.

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

Ordinary callbacks use the Gateway's authenticated subject, current profile,
caller and workspace. Connection IDs correlate requests, not authority. The
host filters discovery against the live grant and reauthorizes
execution. Aliases, nested policy/ticket targets and other callback-enabled MCP
registrations cannot create a recursive route or widen the workspace.
Risky tools keep the ordinary `operations.prepare` / local approval /
`operations.commit` contract. The adapter cannot approve its own pending ticket.

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
| `host.workspaces.register` | `worktree` | Register an exact derived worktree and its source profile grant atomically |
| `host.workspaces.authorize_removal` | `worktree` | Check the live destructive operation ticket before removal |
| `host.workspaces.unregister` | `worktree` | Remove the unchanged owned registration, or confirm an ownership-free no-op |
| `host.diagnostics.snapshot` | `limit` | Read bounded host receipts for the verified subject/profile/workspace |

These tools return `structuredContent.result`; rejected calls return `isError`
and a bounded error. They do not accept caller-supplied identity, local approval authority
or arbitrary database operations. Inspect their actual MCP schemas for input
constraints. They require host persistence; directory metadata alone is not a
host-service implementation.

## Derived workspaces and recovery

The plugin owns Git and domain lease/plan records. The host independently
checks the source repository, exact derived path, directory ownership, and Git
common directory before adding registration authority. Its
`pluginDerivedWorkspaces` ledger binds the receipt, source, publisher registration,
verified principal, profile and workspace snapshot. Caller records remain
provenance: the same principal can reconnect through another authorized channel.
Receipts without a verified principal remain historical records and cannot be
adopted or removed through a new caller. Workspace registration, canonical-path ownership
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

Diagnostics report the immutable host subject and filter its verified digest,
workspace and profile before applying `limit` (1–1000). The same subject can
query its records after reconnecting; connection IDs only correlate individual
calls. Historical records without a verified subject remain stored but are not
exposed through this service. They return receipt identities and digests, not command bodies
or raw output. Missing host data is reported as unavailable.
Private service audits retain the originating request/ticket relationship when
one is present.

The inherited transport bounds a message to 1 MiB and queues to 32 messages,
with 16 concurrently admitted callback handlers. Private service arguments are
limited to 64 KiB and responses to 512 KiB. Oversized diagnostics require a
smaller limit. The client bounds host calls to 30 seconds and joins shutdown
on timeout or cancellation; uncertain mutations are not automatically replayed.
The descriptor is closed on EOF/retirement, and ownership cleanup participates
in the same retirement barrier as the managed process.
