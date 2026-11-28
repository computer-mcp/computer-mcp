# App Control Plane

Computer MCP has one App-owned local administration domain with two presentation
adapters: SwiftUI and the embedded `computer-mcp` CLI. Neither adapter owns
business rules or runtime coordination. `ComputerMCPControlPlane` owns the shared
administration implementation and builds on macOS and Linux. The macOS composition
root supplies the secret store, login item controller, Computer Use permission
reader and default manifest. Distribution identity and environment values belong
to `ComputerMCPPlatform`.

```text
SwiftUI actions ─┐
                 ├─ AppControlPlaneOperations ─┬─ AppControlPlaneService
owner-only CLI ──┘                              └─ AppGatewayService
```

`AppControlPlaneOperations` owns lifecycle-aware use cases: gateway start,
stop, and restart; project registration/grants; profile activation and execution
mode; manifest activation/rollback; provider refresh; and Tunnel
configuration/lifecycle. It preserves desired state, validates compatible
Tunnel profiles, restarts an already-running gateway when required, reconnects
desired Tunnels, and rolls profile changes back when activation fails. Managed
manifest activation/rollback, manual MCP, plugin and project changes prepare
candidate runtimes before committing their state and synchronously publishing
routes. They preserve current connections and existing task owners; failed
candidates leave the admitted configuration active.

`AppControlPlaneService` owns durable state and direct domain mechanisms:
manifest revisions, GRDB records, security-scoped bookmarks, Keychain secrets,
provider discovery, Tunnel supervisors, and launch at login.
When the manifest is absent, the macOS live factory activates
`DefaultGatewayConfiguration.manifest` before constructing the service. Secret
value reads explicitly permit Keychain interaction with `.allow`; metadata-only
presence checks explicitly use `.fail`. Codex discovery preserves the selected absolute executable
entry path, including symbolic links, so package-manager upgrades can replace
the target. Existing manifests remain user-owned configuration.
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
listener is stopped, with current permission authority intact.

The `computer-mcp` control CLI is not a registered remote `cli.exec` provider.
Executing it from a Tunnel-originated gateway process would convert a remote
profile into the owner-only `local-admin` identity. MCP clients use
the catalog with declared requirements and access only authorized objects. An explicitly approved Full Access
session can manage projects and verified official plugins through typed tools.
It retains its remote identity and never acquires the local-admin control socket.

`GatewayRuntime` owns discovery, requirement resolution, permission admission and audit for
these tools. `AppGatewayService` injects management dispatch bound to the admitted
runtime key and listener epoch; each request must also hold the actual registered
control-session reference. Calls delegate to existing App state and prepared
publication, retaining old execution generations. Read tools and monotonic session
limits use typed permission contracts. Configuration and installation
writes require host-authorized Full access.

An asynchronous management operation captures the session revision and input
state. Its final non-suspending durable commit rechecks current consent under the
session lock. Revocation during download or preparation prevents publication and
joins candidate cleanup. Current-profile project grants also compare the full
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
Pending OAuth sign-in requests and live grants appear on the same page. Approval
offers the profiles the authorization server accepts and requires an explicit
selection, submitting the profile and authorization digest the owner reviewed
before the request expires.
The menu shows current control status, or the number of waiting sign-in requests,
and directs the owner to that page. A failed refresh remains unavailable while
retaining the last visible records.

Profile editing presents permission values, projects, integrations, execution mode
and network settings for current registered objects. The editor retains the
reviewed profile, its authorization revision and the permission-store revision.
The service compares those inputs
under the manifest publication boundary before committing. A stale editor cannot
overwrite an external edit or approve changed profile, project or plugin state.
Saving updates the shared profile, invalidates stale Full access consent and
reconciles requests and executions against current authority.

Privacy & Security presents permissions by category and by client profile, with
project access, inherited grants, per-project network settings and managed-source
diagnostics. Ask, Allow and Deny edits use the same revision-bound permission
service as the CLI. Full access eligibility and per-connection local consent are
separate controls.

The request view shows the requesting principal, scope and whether Always changes
a shared profile. Ordinary requests offer Only this time, Always and Don't Allow;
project registration offers Allow and Don't Allow. Only the local owner answers.
The reviewed snapshot travels with the answer; a refresh cannot silently replace
it. Answers never replay the initiating call. The CLI exposes the same request
projection, managed-source diagnostics and revision-bound answer operation.

Full access consent requires `full_access` in the current profile and never
changes its permissions or enables `policy.shell_enabled`. Session limits are
`ManagedPolicy` values and may only narrow their effective predecessor.

The `clients` CLI family and App delegate to the same connection authority.
Standalone `serve http --control-socket` owns an optional current-user local
control listener exposing only the six client-access contracts. The listener
starts before HTTP admission; startup failure closes it, and runtime stop joins
its accepted connections. Every request retains its admitting HTTP generation;
closed or superseded generations cannot read or mutate current authority.
Standalone Full Access requires the fixed profile to allow that mode.
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

## OAuth approval consistency

`OAuthApprovalProfile` pairs each resolved remote grant with its
`authorization_digest`. The digest is the lowercase SHA-256 hex of compact UTF-8
JSON, with keys sorted and slashes unescaped. Its keys are `permissions`,
`networks`, `fullAccess` and `callers`. Permission entries and other
arrays are canonically sorted by their serialized values. Profile
identity and persistence revision are excluded. `profile.list` and
`profile.show` include the digest, and the App's Client access snapshot carries
it alongside each profile.

`AtomicManifestStore.publicationLock` serializes active-configuration reads
through publication across the control-plane and gateway actors. Writers read
their merge base under this lock and pass its admitted manifest digest to
preparation; file admission and database comparisons remain second guards.
Permission writers may prepare catalogs before acquiring the lock, then reread
and compare all configuration inputs under it before publishing.
The lock covers manifest activation, import, rollback, external reload,
OpenAI and Cloudflare tunnel saves and deletion, profile permission edits,
project changes and plugin publication. Secret I/O before a Cloudflare save
can suspend independently; omitted OAuth fields are resolved again from the
current configuration under the publication lock.

When both are needed, acquire the tunnel mutation slot before the configuration
publication lock. Approval holds both while resolving the effective profile,
checking the reviewed digest and committing the grant. Configuration publication
never acquires a tunnel slot. Gateway publications acquire their listener
lifecycle admission before entering the publication lock, and tunnel deletion
stops and joins the listener before acquiring the publication lock. This avoids
waiting for a listener publication while holding the lock it needs.

Deletion holds the tunnel slot while one OAuth store transaction revokes every
grant and removes every pairing request and unexchanged authorization code for
the tunnel. Revoked grants remain as audit-owned records. Session cleanup and
manifest removal follow that transaction, so a failed removal leaves the
configured tunnel with its authorizations ended. Recreating an ID and hostname
cannot resume any of those pairings or codes.
