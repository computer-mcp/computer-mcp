# App Control Plane

Computer MCP has one App-owned administration domain with two presentation
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
desired Tunnels, and rolls profile or manifest changes back when activation
fails.

`AppControlPlaneService` owns durable state and direct domain mechanisms:
manifest revisions, GRDB records, security-scoped bookmarks, Keychain secrets,
provider discovery, Tunnel supervisors, and launch at login.
`AppGatewayService` owns the current gateway runtime and private gateway socket.
SwiftUI maps shared results into view models; the CLI maps the same results into
stable JSON over `ControlSocketService`.

## Local administration boundary

The control socket is mode `0600`, accepts only the embedded CLI's `local-cli`
identity, and binds it to `local-admin`. Control operations are audited. The
embedded CLI can read the version-matched contract offline through:

```sh
computer-mcp app capabilities
```

The `computer-mcp` control CLI is not a registered remote `cli.exec` provider.
Executing it from a Tunnel-originated gateway process would convert a remote
profile into the owner-only `local-admin` identity. Remote MCP therefore lists
and uses only workspaces already granted to its profile. Registering a new
authorization root remains a deliberate local App or CLI operation.

Computer Use is not an administration adapter. Accessibility actions targeting
the Computer MCP host process fail with
`computer_use.self_target_forbidden`, and all allowed Accessibility actions use
main-thread dispatch before entering macOS AX/AppKit behavior.

## Adapter coverage

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
