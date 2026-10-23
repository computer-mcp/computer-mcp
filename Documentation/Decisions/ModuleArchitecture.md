# Module Architecture

## Status

Accepted.

## Decision

The gateway implementation is split into SwiftPM targets arranged in layers. A
target depends only on targets in lower layers, or on lower targets within its
own layer as listed below. Only the App and the CLI are package products, and
every target keeps `package` access; no declaration is `public`.

| Layer | Targets | Platform |
| --- | --- | --- |
| Front ends | `ComputerMCPApp`, `computer-mcp` | macOS |
| Composition root | `ComputerMCPMacOS` | macOS |
| Composition | `ComputerMCPControlPlane`, `ComputerMCPGateway` | neutral |
| Capabilities | `ComputerMCPToolKit`; tool domains `ComputerMCPToolsMCP`, `ComputerMCPToolsCLI`, `ComputerMCPToolsFiles`, `ComputerMCPToolsProject`, `ComputerMCPToolsStructured`, `ComputerMCPToolsGit`, `ComputerMCPToolsShell`, `ComputerMCPToolsSkills`, `ComputerMCPToolsSystem`; `ComputerMCPPlugins`, `ComputerMCPDelivery`, `ComputerMCPAuthorization`; `ComputerMCPComputerUse` | neutral; ComputerUse macOS |
| Services | `ComputerMCPConfiguration`, `ComputerMCPPersistence`, `ComputerMCPProcess`, `ComputerMCPTransport`, `ComputerMCPDownstream`, `ComputerMCPTunnels` | neutral |
| Platform | `ComputerMCPPlatform` (protocols and values), `ComputerMCPPlatformPOSIX`, `ComputerMCPPlatformDarwin`, `CSystemArchive` | neutral; POSIX; macOS |
| Base | `ComputerMCPCore`; lower `ComputerMCPPermissions` (Foundation only) | neutral |

Dependencies inside a layer are limited to these:

- Platform: `PlatformPOSIX` and `PlatformDarwin` use `Platform`;
  `PlatformDarwin` may use `PlatformPOSIX` and `CSystemArchive`.
- Services: `Process`, `Transport`, `Downstream` and `Tunnels` may use
  `Configuration`; `Downstream` and `Tunnels` may use `Process`; `Downstream` may use
  `Transport`.
- Capabilities: tool domains and `Delivery` may use `ToolKit`; `ToolsProject`,
  `ToolsStructured`, `ToolsSkills` and `ToolsSystem` may use `ToolsFiles`;
  `ToolsSkills` may use `ToolsStructured`; `Plugins` composes contributions and
  may use `ToolsCLI`.
- Composition: `ControlPlane` may use `Gateway`.

### Responsibilities

- `Core`: JSON values, gateway models, policy and capability descriptors, tool
  definitions and the provider protocol, workspace identity, product version
  metadata, invocation values and protocols, and the blocking executor.
- `Platform`: the platform service protocols listed below and their value types.
- `Configuration`: manifest model and defaults, including MCP HTTP
  authentication values.
- `Persistence`: the database connection, schema and transaction API. Each domain
  owns its own store on top of it.
- `Process`: bounded process execution, managed processes, shell sessions and
  executable discovery.
- `Transport`: socket and stream primitives and MCP framing.
- `Downstream`: downstream MCP clients, child-process transports, catalog
  loading and value bridging.
- `Tunnels`: OpenAI Secure MCP Tunnel and Cloudflare tunnel process lifecycles.
- Tool domains: each owns its tool definitions, explicit capability descriptors
  and implementation, and is registered as its own provider.
- `Plugins`: package manifests, catalogs, installation, resolution of plugin
  contributions into ordinary registrations, and archive preparation through the
  archive extractor interface.
- `Delivery`: governed edits in isolated worktrees that land on the default
  branch, within host-declared path scopes.
- `Authorization`: the OAuth authorization surface for remote clients, with
  grants approved locally.
- `ComputerUse`: the native Accessibility provider; macOS only, registered by
  the composition root.
- `Gateway`: runtime and routing, admission, approvals and operation tickets,
  receipts, continuations, host services, the HTTP server adapter, owned work
  and audit.
- `ControlPlane`: App and CLI administration, remote management, client control,
  plugin management, product readiness and client registration.
- `MacOS`: creates the Darwin implementations and wires them into the gateway
  and control plane; the only non-front-end target that depends on both neutral
  and Darwin targets.

### Providers and descriptors

Every tool domain is a provider with explicit tool definitions. Each definition
carries its complete MCP metadata and a `CapabilityDescriptor` (risk, workspace
requirement, network use, local-only). Risk is never inferred from a tool name
or a namespace prefix. Providers declare discovery that can fail and refresh;
the router replaces catalog snapshots atomically and keeps the previous
snapshot after a failed refresh. Remote management is a provider registered by
the control plane.

### Invocation context

Providers receive a `ToolInvocation` containing the tool name, arguments and
an `InvocationContext`. Downstream methods that authorize, discover, execute or
observe work receive that context explicitly. `Core` defines the
`InvocationAdmission` value and the `GatewaySessionAuthority` and
`ContinuationRoute` protocols carried by the context; `InvocationContext.empty`
has none of them. The session member is the live authority, so restriction,
revocation and revision checks read current state. Builtin tools have nil
admission. Gateway constructs downstream admission after authorization and
interprets its `MCPContinuationTarget` through the continuation protocol.
Transport tracing and execution-owner routing stay inside `Gateway`.
Blocking work uses `BlockingOperationExecutor` from `Core`, passing the invocation
as an argument. Exact continuation selection is captured before detached work
and cannot start a replacement connection.

### Injected interfaces

Lower targets reach higher-level state only through these interfaces, implemented
above them and supplied by the composition root:

| Interface | Defined in | Replaces |
| --- | --- | --- |
| Session authority | `Core` | `GatewayControlSession` in execution contexts and downstream clients |
| Continuation route | `Core` | `MCPContinuationTarget` reads in downstream clients |
| `MCPHostEnvironment`, `MCPHostLaunchMetadata` and `MCPHostSessionHandle` | `Downstream` | `MCPHostContext` and `MCPHostSession` in downstream clients and child transports |
| Domain stores | each owner | direct `GatewayDatabase` use by plugins, workspaces, receipts and the HTTP adapter |
| Package file reader | `PlatformPOSIX` | package file access in CLI tree loading and validation |
| CLI tree source value | `Configuration` | `CLITreeSource` stored in command configuration |
| CLI invocation layer | `ToolsCLI` | CLI checks inside bounded process execution |
| Owned work tracking | `Process` | `GatewayOwnedWork` in shell sessions |
| `MCPProcessOwnershipError` | `Downstream` | plugin store errors in process ownership; directory identity itself is a `Platform` value |
| `HTTPOriginLifecycle` | `Tunnels` | `GatewayHTTPRuntime` in Cloudflare runtime state |
| `OpenAITunnelHTTPProxyResolving` | `Tunnels` | system proxy lookup in tunnel supervision; `PlatformDarwin` reads system settings and `MacOS` supplies the conformance that parses them in `Tunnels` |
| `AuditErrorClassifying` | `Core` | concrete Computer Use error checks in gateway runtime audit classification; errors supply an optional audit decision and code |
| `ControlErrorClassifying` | `Gateway` | concrete control-plane error checks in control responses; errors supply an optional audit decision and code |
| `GatewayControlError` | `Gateway` | the HTTP Full Shell approval precondition, with localized messages and the existing audit and control-response defaults |
| `GatewayManagementProvider` | `Gateway` | control-plane management definitions, read capabilities, name lookup and asynchronous dispatch; `PlatformServices` reserves contract names independently of provider availability |
| `GatewayClientControlProvider` | `Gateway` | control-plane client-control contracts, argument validation and HTTP generation dispatch |
| `SecretStore` | `Platform` | `KeychainSecretStore` in configuration, tunnels, gateway and control plane |
| Workspace grant store | `Platform` | `WorkspaceBookmarkService` in gateway and control plane |
| Login item controller | `Platform` | the `SMAppService` controller in the control plane |
| Distribution identity and environment | `Platform` | Foundation values for signed App metadata, namespace selection and control-plane storage directories |
| Default manifest | supplied by `MacOS` | the macOS configuration extension; the neutral control-plane service receives the manifest as a constructor argument |
| `GatewayToolProvider` and `ComputerUsePermissionReading` | `Core`, `Platform` | the composition root registers the Computer Use provider and injects its service for control-plane permission snapshots |
| Archive extractor | `Platform` | the `libarchive`-based extractor, which moves to `PlatformDarwin`; archive limits, errors, staging directories and directory identity become `Platform` values |
| Directory identity capture and private staging | `Platform` | descriptor-anchored private directory creation/recovery, identity capture/matching and exclusive rename; implemented in `PlatformDarwin`, including birth time and volume UUID |
| Application locator | `Platform` | Launch Services application lookup in plugin dependency resolution |

## Rationale

The previous single implementation target held about 80,000 lines. Tool domains
were extensions of one registry type sharing its state, dispatch was a string
switch over tool names, capability risk was inferred from name prefixes, and
call context crossed dispatch hops through manually forwarded task-locals. None
of the intended boundaries was enforced by the compiler.

A symbol-level analysis of the type references between top-level declarations
showed that file-level allocation would create cycles across almost every
target, and that an acyclic graph needs shared records moved down, orchestration
kept with its owner, and the interfaces above. With them, the graph has no
cycles, no upward edges and no neutral target that depends on a Darwin target.

## Consequences

- Targets are extracted bottom-up from the shared implementation target. Each
  extracted set is closed under its dependencies, so every intermediate state
  builds. The base, platform, configuration, persistence and process targets come
  first; then transport, downstream, tunnels, the tool kit and the tool domains;
  then plugins, Computer Use, gateway and control plane. The shared target is
  removed when it is empty. `Delivery` and `Authorization` are new targets
  created with their capabilities; no existing declarations move into them.
- `Scripts/verify-module-graph.py package` checks the target dependencies declared
  in `Package.swift` against the layer rules and platform boundaries.
  `Scripts/module-graph.json` holds the layers, permitted same-layer dependencies,
  platform rules and test support targets.
- Neutral targets do not import macOS frameworks or reference macOS executable
  paths. As targets are extracted, `Scripts/verify-package-boundary.sh` is
  extended to reject both, and a Linux CI job builds and tests the extracted
  neutral targets.
- A builtin tool catalog snapshot (names, metadata, schemas and descriptors)
  guards extraction; it changes only for reviewed, intended differences.
