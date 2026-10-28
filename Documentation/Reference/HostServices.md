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

Calls to these registrations require a project. With one registered project,
the Gateway selects it automatically and still checks the caller's grant. With
multiple projects, provide `project_id` or use a project-bound connection.
For `mcp.tools.call`, `project_id` belongs in the outer Gateway arguments beside
`server`, `tool` and `arguments`, not inside the downstream `arguments` object.

Standalone manifest projects retain their configuration-owned scope even when
the Gateway uses a database for audit or plugin state. Database-owned projects
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
caller and project. Connection IDs correlate requests, not authority. The
host lists requirements within managed limits and reauthorizes
execution. Aliases, forwarded targets and other callback-enabled MCP
registrations cannot create a recursive route or widen the project.
Every callback uses the permission library. Missing permissions follow the same
request-and-explicit-retry contract; an adapter cannot answer its own request.

Configuration and builtin profile grants do not require a persisted profile
record. If the runtime was initialized with a persisted profile, deleting that
record revokes host access instead of restoring configuration authority.
Existing persisted restrictions are checked again during callback authorization.

Private `host.*` tools are listed only on this inherited connection, never as
northbound Gateway tools. Dynamic tool requests from a vendor cannot target the
private namespace. The host records a short-lived, in-memory reference to each
currently forwarded operation. Permission-sensitive private calls must match
exactly one such operation and its arguments; a claimed caller or request ID
from the adapter is insufficient. An independently started downstream request
retains its reference after the Gateway returns its started receipt. A confirmed
response or confirmed local teardown releases that request's reference;
cancellation delivery alone does not.

| Private tool | Required inputs | Purpose |
| --- | --- | --- |
| `host.invocations.describe` | `invocation_id` | Inspect an exact invocation retained by a request or validated work on this private channel |
| `host.workspaces.register` | `worktree` | Register an exact derived worktree and its source permission relationship atomically |
| `host.workspaces.authorize_removal` | `worktree` | Check the exact live removal call before removal |
| `host.workspaces.unregister` | `worktree` | Remove the unchanged owned registration, or confirm an ownership-free no-op |
| `host.diagnostics.snapshot` | `limit` | Read bounded host receipts for the verified subject/profile/project |

These tools return `structuredContent.result`; rejected calls return `isError`
and a bounded error. They do not accept caller-supplied identity, local permission-answer authority
or arbitrary database operations. Inspect their actual MCP schemas for input
constraints. They require host persistence; directory metadata alone is not a
host-service implementation.

## Invocation context

For callback-enabled registrations, the Gateway supplies its own invocation
UUID in `tools/call` request metadata under
`_meta["io.github.computer-mcp/host-invocation"]`. Ordinary registrations do not
receive this entry. Downstream arguments cannot set or replace it. The adapter
passes this UUID to `host.invocations.describe` on its inherited connection.
The UUID is correlation, not a credential: another channel, an expired
invocation, or revoked current authorization cannot use it.

Providers that declare the ordinary MCP work resource retain this context while
their validated resources reference the creating acquisition, including derived
work after the initial call returns. The host releases it only after a complete
observation establishes that no owner remains. Missing or invalid observations
retain uncertainty. Background contexts have a separate lifetime from active
request admission. Mutation callbacks still require their exact active request.

The version-1 result includes `invocation_id`, `generation_id`,
`registration_id`, `plugin_id`, `contribution_id`, `principal_id`, `profile_id`,
`caller`, `workspace_id`, `request_id`, `authorization_revision`,
`capability_id`, `tool`, `risk`, `host_action`, `arguments_digest` and `ticket_id`.
`generation_id` identifies the originating runtime. `authorization_revision`
is the grant revision admitted for that invocation; inspection checks current
authorization again. Plugin/contribution identities come from host composition
and are null for a direct registration. The argument digest uses SHA-256 over
the host-recorded downstream argument object encoded as sorted-key JSON.
`ticket_id` is a version-1 compatibility field and is always null. Callbacks
validate the live call record and its permission-ledger authorization. Workspace mutations require a verified client identity;
inspection records the identity supplied by the host, which can be absent on local
unauthenticated connections. Identity fields and
authorization revisions cannot be overridden in the inspection request.

Concurrent invocations have distinct identities even when their tool and
arguments match. This inspection contract carries no authority to start new
work, answer permission requests or retain a background job after its downstream
request has completed.

## Derived projects and recovery

The plugin owns Git and domain lease/plan records. The host independently
checks the source repository, exact derived path, directory ownership, and Git
common directory before adding registration authority. Its
`derivedProjects` ledger retains plugin provenance and binds the receipt, source, publisher registration,
verified principal, profile and project snapshot. Caller records remain
provenance: the same principal can reconnect through another authorized channel.
Receipts without a verified principal remain historical records and cannot be
adopted or removed through a new caller. Project registration and canonical-path ownership commit with source inheritance
in the generic ledger; no derived profile grant is copied. Existing identities,
pre-existing grants or independent path registrations are not adopted.

Removal requires the exact live call record and an in-process request lease. The
host records identity, route, action, argument digest, project scope and admission
revisions before dispatch, and checks current authorization after Git verification
for both removal authorization and unregister. A saved record or invocation ID
alone cannot convey authority; completed records and lost leases cannot be reused.
The host refuses independent edits, aliases or grants held by another profile. It removes only
its own unchanged registration; filesystem removal remains with the plugin.
A child lease is released through a child-project connection after that registration
is available. Runtime publication makes registered projects available on the next
call while retaining the original execution owners. Plugin receipts retain their
wire format and cannot mint the private Git context used by host worktrees.

If Git removal succeeds but host metadata cleanup fails, the domain receipt
remains `removing`, not `active`. Review it again with `remove.plan`, then use
its current revision with a new admitted `remove.perform` call.
This recovery verifies that the path is absent, its parents/source remain
valid, and Git no longer registers it. It then cleans metadata without repeating
Git deletion. A replacement path, including a symbolic link, is never removed.

If provisioning fails and host rollback is unconfirmed, the plugin preserves
its remaining Git worktree and branch and reports incomplete recovery. Inspect
the domain receipt and host registration before any manual reconciliation;
uninstalling the plugin does not authorize deleting that content. A branch
advanced independently is not removed by the rollback's compare-and-delete.

## Diagnostic bounds

Diagnostics report the immutable host subject and filter its verified digest,
project and profile before applying `limit` (1–1000). The same subject can
query its records after reconnecting; connection IDs only correlate individual
calls. Historical records without a verified subject remain stored but are not
exposed through this service. They return receipt identities and digests, not command bodies
or raw output. Missing host data is reported as unavailable.
Private service audits retain the originating invocation and permission authorization when
one is present.

## Semantic action admission

A downstream tool using private services declares its effect in MCP tool
metadata, independently of its public name:

```json
{"_meta":{"io.github.computer-mcp/host-action":"workspaces.provision"}}
```

The host recognizes these actions and imposes the corresponding minimum risk:

| Action | Minimum risk | Arguments bound to the forwarded invocation |
| --- | --- | --- |
| `diagnostics.snapshot` | `read-only` | `limit` bounds the callback's requested count; omission means 100 |
| `workspaces.provision` | `project-write` | `plan_id` equals the receipt ID, `expected_revision` is one below its provisioning revision, `confirm_provision` is true |
| `workspaces.remove` | `destructive` | `managed_worktree_id` and `expected_revision` match the reviewed receipt, `confirm_remove` is true; the exact live call record and current authority are required |

The declaration selects host validation; it grants no project or capability.
Unknown or malformed declarations fail closed. The host records the recognized
action in its admitted capability before permission admission, and exposes it as
`host_action` in invocation inspection. Live call records bind the capability, exact arguments, provider identity and
permission authorization. A changed action invalidates that binding even if its
risk is unchanged. Dispatch checks the current provider declaration again.
Callbacks use the captured action without rediscovering a provider that may be
waiting for the callback; current subject, profile and project access are
still rechecked.

Private callbacks require one matching active invocation on their inherited
channel. Ambiguous concurrent matches are rejected, rather than assigning a
callback to an arbitrary request. Retained background context can be inspected
but does not extend the active mutation window. Callback arguments cannot
declare an action, impersonate another principal or supply an approval.

Generic derived receipts use `derived-workspace-<lowercase-UUID>` as their
project ID. The host also accepts the exact `codex-worktree-<lowercase-UUID>`
format for compatible Codex receipts. Neither prefix conveys authority:
registration origin, principal, source, exact receipt digest and Git identity
remain mandatory. Persisted identities are never renamed during registration
or cleanup. Private actions require the tool’s explicit host-action metadata.

## Transport bounds

The inherited transport bounds a message to 1 MiB and queues to 32 messages,
with 16 concurrently admitted callback handlers. Private service arguments are
limited to 64 KiB and responses to 512 KiB. Oversized diagnostics require a
smaller limit. The client bounds host calls to 30 seconds and joins shutdown
on timeout or cancellation; uncertain mutations are not automatically replayed.
The descriptor is closed on EOF/retirement, and ownership cleanup participates
in the same retirement barrier as the managed process.

Plugin launch metadata and private host services use stable wire names:
`workspace`, `managedWorkspaceRoot`, `workspace_id` and `source_workspace_id`.
The derived ownership payload uses `workspace` and `sourceWorkspaceID`; receipt
hashes include `workspaceID` and `sourceWorkspaceID`. These names are part of the
persistent plugin contract. Invocation inspection reports `workspace-write` for
project write risk on this private interface.
