# Scoped host services

This reference defines the accepted project host-service contract. An owned
stdio MCP registration uses one private, inherited MCP connection to its
originating Gateway. Both directly registered and plugin-provided servers use
the same transport and permission checks. A declaration or copied launch context
cannot create this channel or its authority.

## Enable and identify the scope

Direct registration uses `host_services = true` inside `[[mcp.servers]]`. A
plugin's host-owned MCP settings use `"hostServices": true`; the App presents
**Allow scoped host services**. Both default to false. HTTP registrations reject
this option. Changing a package's manifest cannot enable it.

Calls to these registrations require a project. With one registered project,
the Gateway selects it automatically and still checks the caller's grant. With
multiple projects, provide `project_id` or use a project-bound connection.
For `mcp.tools.call`, this belongs in the outer Gateway arguments beside
`server`, `tool` and `arguments`. A downstream argument cannot select another
callback scope.

Standalone manifest projects retain their configuration-owned scope even when
the Gateway uses a database for audit or plugin state. Database-owned projects
are checked against their registration generation on every callback; changing
or removing the registration revokes the original scope. The authenticated
subject is independent of connection tracking. Reconnecting with the same
credential retains that subject; a new connection has a new tracking identity.
Clients sharing a credential share its subject and grants.

The prepared provider context carries one opaque, verified, host-created service
channel, with an exact descriptor mapping. The adapter receives the connected
Unix stream descriptor through `COMPUTER_MCP_HOST_FD`, never a control-socket
path, credential or local-admin identity. The host replaces reserved environment
entries after merging launch settings. The adapter marks its inherited endpoint
close-on-exec before spawning children; the supervisor, watchdog and vendor
subprocesses do not retain it. Arbitrary descriptor inheritance is not allowed.
The channel does not enlarge sandbox filesystem or network permissions.

The endpoint uses MCP initialization and newline-delimited JSON-RPC, including
`tools/list` and `tools/call`. Ordinary callbacks use the authenticated subject,
current profile and selected project. Aliases and forwarding cannot create a
recursive route or widen scope. Every call goes through permission admission;
a missing permission uses the ordinary request-and-explicit-retry flow. An
adapter cannot answer its own request.

## Contract and launch context

The contract identifier is the exact string `projects-v1`. It identifies this
project lifecycle protocol independently of the manifest's `plugin_api = 1`.
A package's stdio contribution declares `host_service_contract = "projects-v1"`
in its reviewed manifest. Direct registrations use the same peer handshake
without a package declaration. This protocol marker is excluded from the
[declaration digest](PluginPackages.md#permission-entries); channel enablement
remains host-owned.

Both the provider's ordinary MCP server and the private host MCP server advertise
this entry in their initialization result's `capabilities.experimental`:

```json
{"io.github.computer-mcp/host-service-contract":"projects-v1"}
```

The host checks the reviewed contribution marker, when packaged, the provider's
observed marker and project launch context before forwarding a lifecycle action.
The adapter validates the host marker and context before accepting such an
action or sending a lifecycle callback. Missing, unknown or mismatched markers
fail before mutating dispatch. An obsolete adapter cannot be rescued by its
API 1 declaration or by renaming a method.

The actionable error is `host.unsupported_contract`, with `required_contract:
"projects-v1"`, `observed_contract` (string or null) and a message instructing
the owner to update Computer MCP and the affected plugin together and restart
the provider. An adapter connected to an older host reports this error itself.
An updated manifest presented to an older strict parser can also be refused
before launch for its unsupported fields. Peers must agree on the contract
before lifecycle dispatch.

`COMPUTER_MCP_HOST_CONTEXT` is JSON provenance, not authentication. Its fields
are:

| Field | Type and meaning |
| --- | --- |
| `formatVersion` | Integer `1` |
| `hostServiceContract` | String `"projects-v1"` |
| `runtimeID` | Host runtime UUID |
| `caller` | Host-established caller kind |
| `profileID`, `principalID` | Host-established profile and principal strings |
| `project` | `{ "id": "<project-id>", "rootPath": "/canonical/project/root" }` |
| `readOnly` | Boolean describing the bound channel's access; never an independent grant |
| `transportTrace` | Optional host transport provenance, unchanged from the transport model |
| `managedProjectRoot` | Optional host-selected storage root beside durable host storage; provenance only |

The host owns storage paths; `managedProjectRoot` is not permission for a plugin
to create, adopt or delete a checkout. Launch JSON is limited to 16 KiB. Clients
without the inherited endpoint cannot reconstruct authority from it. Host tools
and sandboxed programs enforce host-data protection and the
[provider container boundary](PluginPackages.md#provider-containers-and-discovery).

## Invocation inspection and action binding

The Gateway supplies its invocation UUID in downstream `tools/call` metadata
under `_meta["io.github.computer-mcp/host-invocation"]`. For a lifecycle mutation
it also supplies the host-reserved operation UUID under
`_meta["io.github.computer-mcp/host-operation"]`. Downstream arguments cannot
set or replace either value. The adapter records these IDs before requesting
an effect. They correlate host records; they are not bearer credentials.

Private tools are listed only on the inherited channel, never northbound.
Vendor-originated dynamic requests cannot target the private namespace.

| Private tool | Request fields | Result |
| --- | --- | --- |
| `host.invocations.describe` | Exactly one of `invocation_id`, `operation_id` | Invocation projection or durable operation projection described below |
| `host.projects.worktree_add` | `invocation_id`, `operation_id`, `name`; optional `branch`, `base` | Operation envelope with creation result |
| `host.projects.worktree_list` | `invocation_id` | `worktrees` inventory |
| `host.projects.worktree_remove` | `invocation_id`, `operation_id`; optional `force` | Operation envelope with removal result |
| `host.diagnostics.snapshot` | `limit` | Bounded diagnostic audits for the authenticated scope |

Requests are objects with no unknown fields. Invocation and operation IDs are
host UUID strings. Success uses `structuredContent.result`; a refusal without
an operation projection uses `isError: true` and `structuredContent.error` with
`code` and bounded `message`.
Identity, permission answers and arbitrary database operations are not inputs.
Durable lifecycle services require host persistence.

Inspection by `invocation_id` returns `format_version: 1`, `invocation_id`,
`generation_id`, `registration_id`, `plugin_id`, `contribution_id`,
`principal_id`, `profile_id`, `caller`, `project_id`, `request_id`,
`authorization_revision`, `capability_id`, `tool`, `risk`, `host_action`,
`arguments_digest`, `ticket_id`, and `operation`. The plugin/contribution fields
are null for a direct registration; `ticket_id` is null. Project write risk is
`project-write`. `arguments_digest` is SHA-256 over the host-recorded downstream
arguments encoded as sorted-key JSON. It is an invocation audit binding.
`operation` is null for non-lifecycle calls, or
the durable operation projection below. Inspection cannot override identity or
authorization revisions.

### Host actions

Tools using lifecycle services declare their semantic action in MCP metadata:

```json
{"_meta":{"io.github.computer-mcp/host-action":"projects.provision"}}
```

| Action | Host minimum | Downstream arguments bound before dispatch |
| --- | --- | --- |
| `projects.provision` | Source Project write; risk `project-write` | Required `name`, optional `branch`, `base`, with the creation rules below |
| `projects.remove` | Selected host worktree Project write; risk `destructive` | Optional `force`, default false, with the removal rules below |
| `projects.list` | Project read; risk `read-only` | No lifecycle arguments |
| `diagnostics.snapshot` | Read-only diagnostic access | Optional `limit`, default 100; the callback count cannot exceed it |

Domain arguments such as a plugin's plan ID or expected revision remain plugin
inputs. The host records the complete downstream argument digest, but only the
fields in this table select lifecycle effects. A plugin must expose those fields
in the dispatched call. Defaults are resolved and captured once by the host. The callback's
normalized arguments must equal that captured selection; it cannot strengthen
`force`, choose another branch or change the base after admission.

The metadata selects validation and additive host requirements; it cannot
replace manifest requirements or grant authority. The host checks the action
again before dispatch, records it in `host_action`, and rejects changed,
unknown or malformed actions. Callbacks use the captured action without
rediscovering a provider that may be waiting for the callback. Current caller
and provider permissions, project/source generation and admission revisions
are still rechecked. Configuration and builtin profiles need no persisted
profile; deletion of an originally persisted profile revokes its authority
rather than restoring configuration authority.

A mutation must name the exact live invocation on this channel, its reserved
operation and matching action/arguments. Ambiguous matches, completed requests,
lost leases, another provider or another client cannot authorize a mutation.
Validated background work can retain inspection context, including derived work
after the initial call returns; incomplete observations retain uncertainty.
That context does not extend the active mutation window. Cancellation delivery
alone does not prove local teardown.

## Project worktree operations

These methods call the same lifecycle library as the
[builtin Git worktree tools](Tools.md#git-worktree-lifecycle), with the same
permission, path, Git safety and retention rules. The host owns Git topology,
paths, IDs, publication, protection and physical cleanup. The plugin keeps its
domain plans/leases and host IDs; it never performs a local Git lifecycle fallback.
The following examples use illustrative host-selected IDs and paths and show
the complete JSON-RPC `tools/call` request and response envelopes.

### `host.projects.worktree_add`

Call in the source project, which must be a complete non-bare repository's top
level. `name` matches `[a-z0-9]+(-[a-z0-9]+)*`, at most 48 characters. `branch`
defaults to `worktree/<name>` and must be a new branch. `base` is a branch,
defaulting to the main checkout's current branch; detached HEAD requires it
explicitly. The captured source registration and repository identity must still
match when effects begin. A pathname, repository layout or worktree ID is never
an input.

The completed result contains `worktree_id` (host lifecycle UUID), `project_id`,
`path`, `branch`, `base` and `warnings` (string array). Its checkout has an
independent private repository and detached HEAD; `origin` names the source.
There are no alternates. Submodules remain uninitialized and LFS files remain
pointers, with corresponding warnings. Only verified storage is registered.
Runtime publication makes the returned project addressable on the next call;
its permissions are inherited, not copied or widened.

Request:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "host.projects.worktree_add",
    "arguments": {
      "invocation_id": "22222222-2222-4222-8222-222222222222",
      "operation_id": "33333333-3333-4333-8333-333333333333",
      "name": "example-change",
      "branch": "worktree/example-change",
      "base": "main"
    }
  }
}
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [],
    "structuredContent": {
      "result": {
        "operation_id": "33333333-3333-4333-8333-333333333333",
        "invocation_id": "22222222-2222-4222-8222-222222222222",
        "action": "projects.provision",
        "source_project_id": "example-source",
        "project_id": "example-source",
        "state": "completed",
        "result": {
          "worktree_id": "11111111-1111-4111-8111-111111111111",
          "project_id": "worktree-11111111-1111-4111-8111-111111111111",
          "path": "/var/example-host/worktrees/11111111-1111-4111-8111-111111111111/checkout",
          "branch": "worktree/example-change",
          "base": "main",
          "warnings": []
        },
        "error": null
      }
    },
    "isError": false
  }
}
```

### `host.projects.worktree_list`

Call in a source or derived project with a live `projects.list` invocation.
There are no operation arguments or mutation ID. It returns `worktrees`, each
with exactly `path`, `project_id`, `branch`, `base`, `ahead`, `behind`, `dirty`,
`unavailable`, `worktree_id` and `owner`. The builtin `git.worktree_list` entries
carry the same fields, including `worktree_id` and `owner`.
`worktree_id` is the host lifecycle UUID, null for foreign
checkouts; `owner` is `"host"` or `"foreign"`. Paths, project IDs and branches
are strings, counts are integers, and `dirty` is Boolean. Inaccessible fields
and unavailable foreign metrics are null. `unavailable` is null when state is
available, otherwise a reason string. Inventory combines host records with Git's
foreign checkouts; a path or name does not establish lifecycle ownership. Listing does
not repair, adopt, prune or delete anything.

Request:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "host.projects.worktree_list",
    "arguments": {
      "invocation_id": "44444444-4444-4444-8444-444444444444"
    }
  }
}
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [],
    "structuredContent": {
      "result": {
        "worktrees": [
          {
            "path": "/var/example-host/worktrees/11111111-1111-4111-8111-111111111111/checkout",
            "project_id": "worktree-11111111-1111-4111-8111-111111111111",
            "branch": "worktree/example-change",
            "base": "main",
            "ahead": 1,
            "behind": 0,
            "dirty": false,
            "unavailable": null,
            "worktree_id": "11111111-1111-4111-8111-111111111111",
            "owner": "host"
          },
          {
            "path": "/srv/example-foreign-checkout",
            "project_id": null,
            "branch": "main",
            "base": null,
            "ahead": null,
            "behind": null,
            "dirty": false,
            "unavailable": "No host-recorded base for this checkout.",
            "worktree_id": null,
            "owner": "foreign"
          }
        ]
      }
    },
    "isError": false
  }
}
```

### `host.projects.worktree_remove`

Call in the selected host worktree project. `force` is Boolean, default false.
The host resolves ownership from its ledger and the selected project. Supplied
paths, source/project replacements, foreign checkouts and independent
registrations cannot become removal targets.

Removal closes admission, drains host mutations and terminates/reaps sandboxed
writers across clients and providers before capture. Full access writers are
terminated best-effort and possible survivors are reported. It first durably
retains every private reference and reflog root with its complete closure in
the host recovery store, then publishes HEAD with an expected-value source-ref
update, then removes owned storage and unregisters the project last. The journal
records intent before and durable completion after each boundary: recovery-store
retention, source-ref update, storage removal and unregistration. Each completed
boundary is required before the next phase begins; a failed source comparison
may leave extra retention but cannot lose it. Publication without removal follows
the same retention-before-source-update order. Dirty tracked, staged,
untracked or ignored content blocks unless `force` was part of the admitted
call. Force discards only uncommitted content; it does not discard commits,
private roots, branch protection or recovery records.

The completed result contains `worktree_id`, `project_id`, `branch`, `oid` and
`termination_warnings` (string array). Branch and recovery records remain;
branch deletion and owner recovery release are separate operations. A failed
or uncertain removal stays bound to its host operation and journals.

Request:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "host.projects.worktree_remove",
    "arguments": {
      "invocation_id": "55555555-5555-4555-8555-555555555555",
      "operation_id": "66666666-6666-4666-8666-666666666666",
      "force": false
    }
  }
}
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [],
    "structuredContent": {
      "result": {
        "operation_id": "66666666-6666-4666-8666-666666666666",
        "invocation_id": "55555555-5555-4555-8555-555555555555",
        "action": "projects.remove",
        "source_project_id": "example-source",
        "project_id": "worktree-11111111-1111-4111-8111-111111111111",
        "state": "completed",
        "result": {
          "worktree_id": "11111111-1111-4111-8111-111111111111",
          "project_id": "worktree-11111111-1111-4111-8111-111111111111",
          "branch": "worktree/example-change",
          "oid": "0123456789abcdef0123456789abcdef01234567",
          "termination_warnings": []
        },
        "error": null
      }
    },
    "isError": false
  }
}
```

## Operation identity and lost responses

Before forwarding a lifecycle mutation, the host durably reserves an operation
ID, binding the originating invocation, verified client and provider identities,
contribution/registration, source and selected project generations, action,
normalized lifecycle arguments, full argument digest and authority basis.
Reservation performs no Git mutation. The adapter receives the reserved ID in
metadata before it can request an effect. It cannot choose a new operation ID.

Each mutation result is an operation envelope:

| Field | Meaning |
| --- | --- |
| `operation_id` | Host UUID; stable through retries, restart and reconciliation |
| `invocation_id` | Originating host invocation UUID |
| `action` | `projects.provision` or `projects.remove` |
| `source_project_id`, `project_id` | Captured source and original call scope; these coincide for creation |
| `state` | `reserved`, `running`, `completed`, `failed`, `recovery_required` |
| `result` | Completed creation/removal object above; otherwise null |
| `error` | Null or `{ "code": "...", "message": "..." }` describing refusal or required recovery |

`reserved` means no lifecycle effects have begun; `running` is not a success
claim. `failed` is terminal only when the host knows effects did not begin or
its owned rollback completed. An interrupted or uncertain effect is
`recovery_required` until host journal recovery establishes the outcome. A
completed result remains available even after removal deleted the project row.
Mutation replies with a recorded operation use `structuredContent.result` for
this envelope, including on failure; `isError` is true for `failed` and
`recovery_required`. A successful inspection of any recorded state has
`isError: false`, since it reports state rather than attempting the effect.

On a lost response, call `host.invocations.describe` with `operation_id` on a
currently authorized channel for the same source or surviving selected project.
It returns this envelope without replaying Git. The same verified client and
provider/contribution must match, and current authority for the original effect
is required. Reconnection changes neither ownership nor consent. The retained
source generation authorizes inspection after worktree removal; it cannot
recreate the removed project. Unknown IDs, a changed source or revoked authority
are refused. The original `invocation_id` can also locate its durable operation
when the live invocation has ended; only its operation projection, not expired
call authority, survives.

A repeated callback with the same operation ID and identical normalized arguments
returns the current state while the operation is `reserved` or `running`, without
starting a second execution. A `completed` or `failed` operation returns its
stored outcome. A `recovery_required` operation returns that state and its
recovery detail; the repeated call never starts or resumes work. Host recovery
resolves the operation. The first effect still requires the live invocation and an
atomic claim of the reservation. Changed arguments, identity or scope return
`host.operation_conflict`. An adapter with uncertain
outcome queries the recorded ID and reports pending/recovery-required state;
it never fabricates a replacement operation or runs Git itself. Host journal
recovery owns completion or rollback. An explicit new request after a confirmed
terminal failure is a new operation and is admitted afresh.

If admission returns `permission.required` after reservation, that reservation
ends refused: `state` is `failed`, `result` is null and `error.code` is
`permission.required`. No lifecycle effects begin. The host forwards the
permission request to the owner. The owner's answer cannot resume that
reservation: retrying requires a new northbound call after the answer, with a
new invocation and a new operation ID. Repeating the refused operation ID
only returns its stored refusal.

A representative sequence is: receive both metadata IDs, persist them in domain
state, inspect the invocation, call `worktree_add` with those IDs and the exact
captured arguments, then address the returned project. If the reply is lost,
query the stored operation ID, including after restart, and use its completed
result or report its recovery state. The same sequence applies to removal;
a missing checkout is not itself proof of success.

### Errors

| Code | Meaning and caller action |
| --- | --- |
| `host.unsupported_contract` | Update host and plugin together; no mutating dispatch occurred |
| `host.unknown_method` | Method is not in this contract; do not retry under another spelling |
| `host.service_denied` | Invalid schema, expired invocation, wrong channel/action or unavailable durable service; correct the request/scope |
| `permission.required` | Current permission is missing; follow the host request and explicit retry rules |
| `host.operation_conflict` | ID, arguments, ownership or captured scope do not match; inspect the original operation |
| `host.operation_not_found` | No operation visible under the current authorized scope; do not infer permission to replay |
| `worktree.invalid_request` | Invalid name, branch/base, call location or unsupported target; correct the input/state |
| `gateway.execution_failed` | Dirty removal without admitted `force`, matching the builtin `git.worktree_remove` mapping of the lifecycle busy error; preserve or commit the changes, or explicitly request force in a new call |
| `worktree.identity_changed` | Project, repository or owned path changed; retain state for reconciliation |
| `worktree.unsafe_configuration` | Repository configuration violates lifecycle safety; correct it without bypassing host checks |
| `worktree.unsupported_repository` | Repository format or topology is unsupported; use a supported source |
| `worktree.command_failed` | Host Git command failed; inspect the recorded outcome before retrying |
| `worktree.busy` | Concurrent writer, lock or incomplete capture; inspect the existing operation before any retry |
| `worktree.recovery_required` | Journal outcome is uncertain; retain IDs and let host recovery reconcile it |

Lifecycle errors retain the operation envelope whenever reservation succeeded;
its state distinguishes a terminal refusal from an uncertain effect. No error
implicitly permits Full access, a local fallback or automatic replay.

## Startup retirement reports

Startup removes plugin-registration-derived authority transactionally and keeps
a durable notice for every affected checkout. A notice contains exactly:

| Field | Meaning |
| --- | --- |
| `report_id` | Stable host UUID persisted with the retirement transaction |
| `code` | `host.plugin_worktree_retired` |
| `checkout_path` | Stored checkout path, safely escaped when rendered |
| `source_project_id` | Recorded source project ID |
| `source_registered_at` | Recorded source registration generation as an ISO 8601 timestamp |
| `source_repository` | Recorded canonical source repository path |

These are retirement facts, not proof of current filesystem identity. Startup
emits all notices to the App log or CLI stderr before provider activation and
acknowledges them durably. Output failure keeps the notice pending; a crash
between emission and acknowledgement can duplicate the same `report_id` but
cannot silently lose it. The output contains no credentials
and does not truncate away individual checkout notices.

The transaction leaves host-owned worktrees and independent explicit
registrations/grants unchanged and performs no Git or filesystem mutation.
Retired linked checkouts appear as foreign inventory. Plugin history referencing
them is unmanaged and excluded from managed deletion and expiry cleanup. There
is no historical adoption or reconciliation API. Older binaries refuse the
upgraded store before provider activation; rollback requires a compatible repair
build, not restoration of the retired authority. Rationale is retained in
[Coding Harness](../Decisions/CodingHarness.md#configuration-and-migration).

## Diagnostic and transport bounds

`host.diagnostics.snapshot` keeps its name and requires `limit` from 1 through
1000 within the active `diagnostics.snapshot` call's captured bound. It returns
`owner` and `recent_tool_audits`. The owner uses `project_id`, `profile_id`,
`caller`, transport tracking fields and `principal_id`; audit rows use
`project_id`. Verified subject, profile and project filtering occurs before the
limit. Records without a verified subject remain stored but are not exposed.
Results contain identities and digests, not command bodies or raw output.
Missing data is reported as unavailable. Private service audits retain the
originating invocation and permission authorization when present.

Messages are bounded to 1 MiB, queues to 32 messages and concurrent handlers
to 16. Private arguments are limited to 64 KiB and responses to 512 KiB;
oversized diagnostics require a smaller limit. Calls are bounded to 30 seconds.
Timeout or cancellation joins shutdown and leaves uncertain mutation outcomes
for operation inspection, without automatic replay. EOF/retirement closes the
descriptor, and confirmed cleanup participates in the managed process's
retirement barrier.
