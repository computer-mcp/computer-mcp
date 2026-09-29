# App Control Plane

Computer MCP has one App-owned local administration domain with two presentation
adapters: SwiftUI and the embedded `computer-mcp` CLI. Neither adapter owns
business rules or runtime coordination.

```text
SwiftUI actions ─┐
                 ├─ AppControlPlaneOperations ─┬─ AppControlPlaneService
owner-only CLI ──┘                              └─ AppGatewayService
```

`AppControlPlaneOperations` owns lifecycle-aware use cases: gateway start,
stop, and restart; workspace registration/grants; profile activation and Full
Shell state; manifest activation/rollback; provider refresh; and Tunnel
configuration/lifecycle. It preserves desired state, validates compatible
Tunnel profiles, restarts an already-running gateway when required, reconnects
desired Tunnels, and rolls profile changes back when activation fails. Managed
manifest activation/rollback, manual MCP, plugin and workspace changes prepare
candidate runtimes before committing their state and synchronously publishing
routes. They preserve current connections and existing task owners; failed
candidates leave the admitted configuration active.

`AppControlPlaneService` owns durable state and direct domain mechanisms:
manifest revisions, GRDB records, security-scoped bookmarks, Keychain secrets,
provider discovery, Tunnel supervisors, and launch at login.
`AppGatewayService` owns the private gateway socket, App HTTP principal runtimes
and external manifest monitoring. Each HTTP listener has its own admission epoch
and current/retained runtime generations. Cloudflare origins use this shared
owner, so App control operations can inspect and limit their sessions and publish
configuration changes without replacing active HTTP connections. Stopping one
origin joins its own generations without stopping another origin's work.
Its bounded invalidation stream and one owned
consumer coalesce file saves and prepare the latest candidate through the same
publication boundary. Rejected edits remain on disk with a gateway diagnostic;
the admitted configuration and existing work remain active. The monitor remains
active while a gateway socket, App HTTP listener or owner control service is running.
Their lifecycle transitions join candidate cleanup and reconsider the latest file.
SwiftUI maps shared results into view models; the CLI maps the same results into
stable JSON over `ControlSocketService`.

## Local administration boundary

The control socket is mode `0600`, accepts only the embedded CLI's `local-cli`
identity, and binds it to `local-admin`. Control operations are audited. The
embedded CLI can read the version-matched contract offline through:

```sh
computer-mcp app capabilities
```

App-owned tool calls share retained local-admin runtimes in `AppGatewayService`.
Each CLI connection carries its own audit trace; disconnecting it does not stop
background work. Local-admin runtimes participate in the same prepared
configuration publication and exact continuation routing as gateway runtimes.
The control service and gateway listener have separate admission epochs and
shutdown ownership. Either can stop without discarding the other's work; App
shutdown stops and joins both. Local tool calls also work while the gateway
listener is stopped, with current authorization and operation approvals intact.

The `computer-mcp` control CLI is not a registered remote `cli.exec` provider.
Executing it from a Tunnel-originated gateway process would convert a remote
profile into the owner-only `local-admin` identity. Restricted MCP clients use
only their granted projects and capabilities. An explicitly approved Full Access
session can manage workspaces and verified official plugins through typed tools.
It retains its remote identity and never acquires the local-admin control socket.

`GatewayRuntime` owns discovery, capability classification, approval and audit for
these tools. `AppGatewayService` injects management dispatch bound to the admitted
runtime key and listener epoch; each request must also hold the actual registered
control-session reference. Calls delegate to existing App state and prepared
publication, retaining old execution generations. Read tools and monotonic session
limits are selectable in the Restricted editor. Configuration and installation
writes have a host-owned Full Access risk floor.

An asynchronous management operation captures the session revision and input
state. Its final non-suspending durable commit rechecks current consent under the
session lock. Revocation during download or preparation prevents publication and
joins candidate cleanup. Current-profile workspace grants also compare the full
SQLite input snapshot; changing profile authority invalidates earlier consent.
Persistent client trust is checked again inside the same SQLite transaction as
the configuration write, including revocations from another owner connection.
Official artifact installation reuses the existing source and byte verification.
Plugin summaries omit credential bindings and launch argument values and page
installations. Authentication, persistent client trust and TCC retain their local
owners. Exact request contracts are in the
[control-plane reference](../Reference/ControlPlaneCapabilities.md#remote-management).

Computer Use is not an administration adapter. Accessibility actions targeting
the Computer MCP host process fail with
`computer_use.self_target_forbidden`, and all allowed Accessibility actions use
main-thread dispatch before entering macOS AX/AppKit behavior.

## Adapter coverage

The App's Client access page presents connected socket/HTTP sessions separately
from saved client approvals. Its ObservableObject feature model captures the
reviewed session and trust revisions; refresh cannot rebase an open confirmation.
The menu shows current control status and directs the owner to that page. A failed
refresh remains unavailable while retaining the last visible records.

Restricted permission editing uses the host's current classified tool catalog,
registered projects and composed MCP integrations. The App presents readable
capability titles and explicit selections; arbitrary execution stays outside this
flow. Broad grants become explicit current choices when saved. An integration
selection includes its future host-allowed tools within the permission mode's
risk ceiling. Caller types require deliberate selection. Current session limits
can further restrict a profile, and Full Access remains a separate session consent.

The editor retains its reviewed profile and gateway inputs. After async discovery,
the service checks that snapshot again before saving the profile under the
manifest admission lock and exact authorization revision. A stale editor cannot
overwrite an external manifest edit or silently approve changed profile, workspace
or plugin state. Catalog discovery uses temporary non-persisting runtimes and
joins their shutdown. Saving changes affects subsequent requests for connections
sharing the profile and invalidates earlier approvals without stopping owned work.

Explicit owner Full Access consent can enable the Shell facility through prepared
manifest publication before granting the selected session. The admitted manifest
digest prevents overwriting external edits; session and trust checks still precede
the authority transaction. A failed consent grants no client authority even if a
facility update already committed. Profile authorization changes advance session
revisions before initial consent as well as after it.

The `clients` CLI family and App delegate to the same connection authority.
Standalone `serve http --control-socket` owns an optional current-user local
control listener exposing only the six client-access contracts. The listener
starts before HTTP admission; startup failure closes it, and runtime stop joins
its accepted connections. Every request retains its admitting HTTP generation;
closed or superseded generations cannot read or mutate current authority.
Standalone Full Access requires the fixed manifest's Shell facility to be enabled.
Persistent trust additionally requires durable storage and an authenticated
principal. Standalone control cannot mutate App state or publish configuration.
Shared schemas, exact session/trust revisions and structured replies keep both
owner adapters consistent. No owner command is re-exported as a remote tool.

Stable noninteractive App management should be exposed by the CLI. Operations
that inherently require local visual interaction, such as choosing a folder in
an open panel or presenting a macOS TCC prompt, remain UI interactions; their
noninteractive state and resulting resource operations still have CLI reads or
explicit path-based commands. Secrets enter Tunnel save commands only through
standard input and are stored in Keychain by the shared use case.

The machine-readable catalog is the source of truth for control capability ID,
CLI command, surface, read/write classification, destructive hint,
idempotence, and local-only ownership. The library exposes the same catalog on
the owner control socket, whose MCP schemas and tests must cover it exactly,
without publishing it to remote gateway profiles.
