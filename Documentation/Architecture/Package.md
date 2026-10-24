# Package

Computer MCP is a SwiftPM package that builds layered internal targets, the
`computer-mcp` CLI/bridge, and the native SwiftUI App on macOS. Only the App and
CLI are package products. On Linux the manifest declares the platform-neutral
targets, and CI builds and tests them there.

## Constraints

- Swift tools 6.2 and macOS 14 or newer.
- SwiftPM is the build and test entry point.
- Build, test, and release scripts consistently use SwiftPM's default build
  system so one cache layout is produced without relying on a deprecated flag.
- The release is a current-user App with Hardened Runtime and no App Sandbox.
- Generated `.doccarchive` output is not committed.

## Dependencies

Requirements follow the organization's
[Versioning rules](https://github.com/computer-mcp/.github/blob/master/VERSIONING.md).
The [Release Reference](../Reference/Release.md#dependencies-and-verified-combinations)
owns dependency verification and the combinations exercised by release checks.

| Package | Requirement | Role |
| --- | --- | --- |
| `computer-mcp/swift-sdk` compatibility fork | `exact: "0.13.2-computer-mcp.1"` | MCP server/client protocol, exact integer wire values, decoding errors answered under the request they belong to, stdio framing with complete POSIX frame writes, and HTTP server session semantics |
| ArgumentParser | `from: "1.8.2"` | CLI parsing |
| swift-toml | `from: "2.0.0"` | TOML config |
| Yams | `from: "6.2.2"` | Skill YAML frontmatter |
| SwiftNIO | `.upToNextMinor(from: "2.101.2")` | HTTP and Unix-socket transport adapters; shared lock primitives through `NIOConcurrencyHelpers` |
| swift-subprocess | `.upToNextMinor(from: "1.0.2")` | Process, Shell, and streaming lifecycle |
| swift-system | `from: "1.7.2"` | `FilePath` for process launches where the System framework is unavailable |
| GRDB | `from: "7.11.1"` | Transactional App metadata and redacted audit; system SQLite on Linux |
| swift-log | `from: "1.14.0"` | Runtime logging integration |
| swift-crypto | `.upToNextMinor(from: "4.5.2")` | SHA-256 in the platform-neutral `ComputerMCPCore`, `ComputerMCPToolsCLI`, `ComputerMCPPlugins`, `ComputerMCPGateway` and `ComputerMCPControlPlane` targets on macOS and Linux |
| macOS system `libarchive.2` | OS-provided | ZIP/TAR/gzip decoding for plugin staging; no downloaded library or decompressor process |

`Tools/Validation` uses `from: "1.8.2"` for ArgumentParser and deliberately keeps
the unmodified upstream `modelcontextprotocol/swift-sdk` at `exact: "0.12.1"`.
Its [README](../../Tools/Validation/README.md) owns this independent-client
exception for gateway interoperability checks.

`CSystemArchive` is an internal system-library module with the minimal C ABI
declarations used by the archive reader. macOS SDKs provide `libarchive.2.tbd`
without its headers. The declarations match Apple's
[archive interface](https://github.com/apple-oss-distributions/libarchive/blob/main/libarchive/libarchive/archive.h)
and [entry interface](https://github.com/apple-oss-distributions/libarchive/blob/main/libarchive/libarchive/archive_entry.h).
The OS owns parser updates; the gateway owns path/type checks, output files,
resource limits, and staging cleanup. This avoids maintaining a ZIP/TAR parser
or executing a command-line extractor with filesystem authority. It adds no
package product and does not install or bundle vendor binaries.

## Structure

| Path | Role |
| --- | --- |
| `Package.swift` | App/CLI products, internal targets, tests, and dependency graph |
| `Sources/ComputerMCPCore/` | Platform-neutral models, policy, JSON values, tool descriptors, audit error classification and the session authority interface |
| `Sources/ComputerMCPPlatform/` | Platform-neutral protocols and values for distribution identity and environment, secrets, projects, plugin archives, Computer Use permission readings, launch at login, file change monitoring, process inspection, bounded media inspection, extended attributes, Trash, project opening and native system readings |
| `Sources/ComputerMCPConfiguration/` | Platform-neutral manifest model and defaults, MCP HTTP authentication values and CLI tree source values |
| `Sources/ComputerMCPPlatformPOSIX/` | POSIX implementations shared by macOS and Linux: executable inspection, project path resolution, process-table queries, child-input signal handling, shared/exclusive advisory file locks, file fingerprints, socket peer credentials and bounded package file reads; Linux descriptor metadata and libc adapters |
| `Sources/CSystemPOSIX/` | Internal C bridge for Linux GNU spawn and exclusive rename declarations and descriptor xattr signatures; uses the system libc without an external dependency |
| `Sources/ComputerMCPProcess/` | Platform-neutral bounded process execution, managed processes, shell sessions and executable discovery |
| `Sources/ComputerMCPTransport/` | Platform-neutral Unix-socket transport, inherited sockets, stdio bridging, HTTP response streams, SSE decoding and MCP framing and initialization normalization |
| `Sources/ComputerMCPDownstream/` | Platform-neutral downstream client contracts and authorization, child-process transport, catalog loading, value bridging, host launch metadata and session interfaces, and process ownership receipts |
| `Sources/ComputerMCPTunnels/` | Platform-neutral OpenAI tunnel launch planning and supervision, Cloudflare runtime values, the HTTP origin lifecycle contract and system proxy settings parsing |
| `Sources/ComputerMCPToolsCLI/` | Platform-neutral CLI provider, CLI tree catalogs, validation, parameter mapping and executable compatibility checks |
| `Sources/ComputerMCPToolsShell/` | Platform-neutral shell and managed-process providers with explicit definitions, annotations, descriptors and project runtime dispatch |
| `Sources/ComputerMCPToolsSkills/` | Platform-neutral skill package provider with explicit definitions, bounded inventory and reads, and Markdown/structured parsing through the Structured domain |
| `Sources/ComputerMCPToolsProject/` | Platform-neutral project provider with explicit definitions, bounded inventories, configuration-change values, deduplication values and injected desktop opening |
| `Sources/ComputerMCPToolsFiles/` | Platform-neutral file and archive provider with explicit definitions, scoped filesystem operations, injected commands, extended attributes and Trash |
| `Sources/ComputerMCPToolsStructured/` | Platform-neutral Markdown and structured-data provider with explicit definitions, bounded parsing helpers, registered SQLite commands and injected media inspection |
| `Sources/ComputerMCPToolsSystem/` | Platform-neutral System and Network providers with explicit definitions, bounded command execution, POSIX observation and injected native memory, CPU and thermal readings |
| `Sources/ComputerMCPToolsMCP/` | Platform-neutral MCP builtin and configured providers, downstream discovery, validated catalogs, host risk descriptors and context-preserving calls |
| `Sources/ComputerMCPToolsGit/` | Platform-neutral Git provider with explicit definitions, annotations, descriptors and registered-command dispatch |
| `Sources/ComputerMCPDelivery/` | Platform-neutral delivery provider, scoped worktree edits, repository locks, atomic file journals, landing and recovery |
| `Sources/ComputerMCPAuthorization/` | Platform-neutral OAuth state machine, discovery metadata, injected CIMD identification, rate limits and transactional grant/token store contract; macOS URLSession CIMD transport |
| `Sources/ComputerMCPToolKit/` | Platform-neutral argument and result helpers, project path scope and file metadata, shared filesystem/outline/HTTP helpers, configured command resolution and execution, and project-owned tool environments |
| `Sources/ComputerMCPPlugins/` | Platform-neutral plugin manifests, bundled inventory and distribution, catalogs, installation/recovery, contribution resolution, archive preparation and the injected plugin state store contract |
| `Sources/ComputerMCPComputerUse/` | macOS Computer Use provider, observation and action service, native Accessibility and screen capture adapter, and permission readings |
| `Sources/ComputerMCPPersistence/` | Platform-neutral database connection with initial schema, migration-ledger check, stored records and transactions |
| `Sources/ComputerMCPPlatformDarwin/` | macOS implementations: Keychain, security-scoped bookmarks, `SMAppService`, Launch Services lookup, directory-event file change monitoring, archive extraction, private staging, directory identities and exclusive rename, system network proxy lookup, ImageIO/PDFKit/AVFoundation media inspection, extended attributes, Trash, project opening and native system readings |
| `Sources/ComputerMCPGateway/` | Platform-neutral runtime, provider routing, admission, approvals, receipts, continuations, host services, HTTP adapter, domain stores, owned work and audit; injected management and client-control contracts |
| `Sources/ComputerMCPControlPlane/` | Platform-neutral App and CLI administration, client control, remote management, manifest transactions, plugin and tunnel administration, product readiness and client registration |
| `Sources/ComputerMCPMacOS/` | macOS composition root that supplies project grants, tool providers, Computer Use permission readings, the Git executable, executable search directories, file change monitors, plugin directory and application lookup services, tunnel proxy resolution, native macOS tool definitions and dispatch, the secret store, login item controller, default manifest and live App services |
| `Sources/CSystemArchive/` | Internal declarations for the macOS system archive library |
| `Sources/computer-mcp/` | Thin CLI and stdio bridge entry point |
| `Sources/ComputerMCPApp/` | SwiftUI control center and menu-bar lifecycle |
| `Resources/ComputerMCPApp/` | Bundle metadata, entitlements and the imported App icon document |
| `Tests/` | Swift Testing component, policy, transport, App, and provider tests in `Tests/<Target>Tests/` |
| `Tests/ComputerMCPTestSupport/` | Neutral helpers shared by test targets; package checks reject any non-test target that depends on it |
| `Tools/Validation/` | Independent Test Case catalog, probes, fixtures, evidence correlation, and reports |
| `Sources/ComputerMCPGateway/ComputerMCPGateway.docc/` | Internal target documentation |
| `Examples/` | Standalone development and dogfood manifests |
| `Scripts/` | App build, DMG, notarization, and distribution verification workflows |

`GatewayToolRegistry` carries the project provider source, catalog invalidations,
refresh policy, downstream admission resolver and runtime shutdown. The macOS
composition root creates the shared `ToolEnvironment`, scopes the downstream client
and assembles the domain providers in catalog order. The router publishes definitions,
capabilities and provider ownership together, preserving its validated generation
when discovery fails.

`ComputerMCPGateway` builds on macOS and Linux without Darwin service implementations.
`GatewayManagementProvider` supplies the control plane's management definitions,
read capabilities and asynchronous dispatch. `GatewayClientControlProvider` supplies
local HTTP client-control contracts and validated calls for the admitted generation.
The control plane implements these with `GatewayRemoteManagement` and
`GatewayHTTPClientControl`, which dispatches through `GatewayClientControl.http`.
OAuth administration is exposed by the App control socket. Gateway implements
Authorization's store on GRDB; the `remote-oauth` migration follows
`gateway-initial` and creates `oauthAuthorizationRequests`, `oauthGrants`,
`oauthAuthorizationCodes` and `oauthTokens`. The existing Crypto
dependency supplies SHA-256; the existing NIO dependency pins public CIMD
destinations for URLSession through a bounded per-request CONNECT transport.
Proxy clients accept Platform's `SecretStore`; MCP HTTP authentication keeps its
explicit noninteractive `.fail` reads. Bound host services receive their Git
executable through `PlatformServices`.

`ComputerMCPGatewayTests` covers neutral gateway behavior. `ComputerMCPMacOSTests`
covers the macOS composition root and assembled runtimes, including the CLI crash
recovery driver. `ComputerMCPGatewayDarwinTests` covers macOS artifact-provenance
scripts. `ComputerMCPControlPlaneTests` covers neutral control-plane behavior;
`ComputerMCPControlPlaneDarwinTests` covers native control sockets and Computer Use
control-error integration. Control-plane tests assembled through the macOS
composition root, the builtin catalog snapshot and verification-script dependency
checks run in `ComputerMCPMacOSTests`, alongside their fixtures.

`ComputerMCPControlPlane` depends on the gateway and lower neutral targets.
Its service accepts Platform's `SecretStore`, login item controller and Computer
Use permission reader, plus the default manifest supplied by `ComputerMCPMacOS`.
Value reads pass `.allow` and presence checks pass `.fail` explicitly to preserve
the Keychain interaction contract. Distribution identity and environment are
Foundation values in `ComputerMCPPlatform`. Cloudflare access tokens use
`SystemRandomNumberGenerator`, and control-plane SHA-256 uses Swift Crypto.

`ComputerMCPToolKit` owns shared argument/result helpers, `ProjectScope` path
checks and file metadata, and `RegisteredCommands` resolution and execution with
its CLI process lifecycle. `ToolEnvironment` shares a project's configuration,
scope, command execution, environment, process/shell runtimes and injected platform
services across providers; the host owns shutdown.

`ComputerMCPDelivery` is a neutral capabilities target using Core, Configuration,
Process, PlatformPOSIX and ToolKit. It owns scoped edit/commit/land execution,
repository locks and durable file journals in the Git common directory. Its
registered Git executable is injected through the project environment. Neutral
`ComputerMCPDeliveryTests` uses real Git in temporary repositories and exercises
execution, fault injection, concurrent calls and interrupted-state recovery.

`DeliveryToolProvider`, `GitToolProvider`, `CLIToolProvider`, `ShellToolProvider`, `ProcessToolProvider`,
`StructuredToolProvider`, `SkillsToolProvider`, `FilesToolProvider`,
`ProjectToolProvider`, `SystemToolProvider`, `NetworkToolProvider` and
`MCPToolProvider` own explicit builtin definitions, annotations, descriptors and
invocation dispatch. `MacOSToolProvider` in the composition root owns the seven
native macOS tools. Each catalog generation creates a `ConfiguredMCPToolProvider`
with validated configured and reexported downstream bindings, and loads CLI tree
providers from their immutable definitions. `MCPTool` and `DownstreamMCPClient`
own the downstream definition values and client contract.

`ComputerMCPComputerUse` depends only on `ComputerMCPCore` and
`ComputerMCPPlatform`. `MacOSToolProviders` registers its `ComputerUseGatewayProvider`
through Core's `GatewayToolProvider` contract. Its errors implement
`AuditErrorClassifying` in Core: permission failures classify as denied, other
provider failures as failed, and each classification uses the error's own code.
The protocol permits nil for errors whose classification belongs to the caller.

`ComputerUseService` implements Platform's `ComputerUsePermissionReading` protocol.
The live control-plane factory injects the service into `AppControlPlaneService`
for non-prompting permission snapshots. The App reads tool counts directly from
`SkillsToolProvider` and `ComputerUseGatewayProvider`.
`ComputerMCPComputerUseTests` covers the service and provider on macOS; audit
integration with `GatewayRuntime` runs in `ComputerMCPMacOSTests`.

`StructuredToolProvider` owns the shared Markdown and structured parsing operations
used by Skills. `MediaInspector` returns neutral, bounded metadata and PDF text;
`DarwinMediaInspector` owns ImageIO, PDFKit and AVFoundation loading, including
per-property timeouts and cancellation. The composition root supplies that inspector
and the fixed SQLite command to the project environment.

`FilesToolProvider` owns file and archive dispatch. The composition root supplies
fixed command paths through `RegisteredCommands`; file hashing uses the existing
Swift Crypto dependency. `ExtendedAttributes` and `FileTrashing` operate on scoped
paths, with their native implementations in `ComputerMCPPlatformDarwin`.
`ComputerMCPToolsFilesDarwinTests` exercises the native extended attributes and Trash.

`ProjectToolProvider` owns project inventory and uses the shared path and command
helpers with the Files dependency. `ProjectOpener` isolates desktop open/reveal;
`DarwinProjectOpener` retains the bounded command execution contract.
`ComputerMCPToolsProjectDarwinTests` verifies its fixed native argv. Project
configuration changes and deduplication values belong to the Project domain;
prepared changes carry opaque host snapshots, while the gateway database owns
SQL transactions and commit validation.

`SystemProbe` returns neutral memory statistics, CPU hardware values and thermal
conditions. `DarwinSystemProbe` owns Mach, sysctl and native power/thermal reads;
the composition root supplies it and the fixed system/network command paths.
`ComputerMCPToolsSystemDarwinTests` verifies the real probe-backed tools, while
`ComputerMCPMacOSTests` exercises native application, directory, screen and Spotlight
tools. Portable tests inject command paths and native readings.

The neutral domain test targets are included on macOS and Linux; `ComputerMCPToolsStructuredDarwinTests` exercises the real media
frameworks and their native fixtures on macOS.

`ComputerMCPPlugins` owns `PluginStateStore`, which reads plugin snapshots, commits
validated revisions and maintains the local directory ownership ledger.
`GatewayPluginStateStore` in `ComputerMCPGateway` binds those commits to the expected
gateway configuration and optional runtime publication; `GatewayDatabase` retains
its transactions and configuration snapshot. The store validates the next snapshot
and the host's preflight checks before handing it to that adapter.

`PluginArchiveExtracting`, `PluginArchiveDirectoryFactory`,
`PluginArchiveStagingDirectory` and `ApplicationBundleLocating` are defined in
`ComputerMCPPlatform`. Darwin supplies the extractor, descriptor-anchored private
directories, directory identity capture/matching, exclusive rename and Launch
Services lookup. `MacOSPlatform.services` injects the directory factory and
application locator, and the CLI's internal archive command selects the Darwin
extractor. Archive worker lock-descriptor inheritance is implemented on Darwin;
the Linux branch fails with `PluginArchiveError.workerFailed` when inheritance is
requested.

`ComputerMCPPluginsTests` runs neutral catalog, HTTP, manifest and package tests on
macOS and Linux. `ComputerMCPPluginsDarwinTests` covers native archive handling,
application lookup and current macOS package activation/compatibility. Plugin tests
that exercise macOS runtime assembly and control-plane workflows run in
`ComputerMCPMacOSTests`.
Their shared fixtures in `ComputerMCPTestSupport` use injected directory services
and application lookup substitutes.

The release scripts assemble the SwiftPM App executable and embedded CLI into a
standard `.app`, sign both code objects, and package the bundle in a DMG.
The [Release Reference](../Reference/Release.md) owns protected candidate
construction, publication, optional installed diagnostics, and evidence reuse.
Local development signing verifies distribution structure; it does not supply
an official candidate.

The GitHub release job imports a password-protected Developer ID PKCS#12 file
and provisioning profile into an ephemeral runner Keychain, authenticates
notarization with an App Store Connect Team API key, and deletes decoded assets
in an unconditional cleanup step. The no-secret verification job must pass
before the protected job can start.

`Tools/Validation` is not a root target and is not included in the App or DMG.
Real external consumers and tunnels are Validation Runs, never automated tests.

`Scripts/build-app.sh` compiles `Resources/ComputerMCPApp/AppIcon.icon` with
`actool` into the bundle's `Assets.car` and a legacy `AppIcon.icns` for macOS 14
and 15. The organization `.github` repository renders that Icon Composer
document; see [Product Identity](ProductIdentity.md) for brand ownership.

## Principles

- Keep executable targets thin; shared product behavior belongs in the internal
  library targets.
- Keep side effects behind provider and transport adapters.
- Share executable inspection across CLI/MCP status and plugin contribution
  resolution. The inspector reads regular-file metadata and at most 512 header
  bytes per interpreter, with bounded interpreter traversal. It does not run
  code or establish launch-time trust. On every platform, shebang handling follows the macOS
  [XNU interpreter rules](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c)
  and distinguishes supported plain
  [env invocations](https://github.com/apple-oss-distributions/shell_cmds/blob/main/env/env.c)
  from invocations needing further verification. Transport and process owners
  remain responsible for actual launch, cancellation, policy and runtime health.
- Keep the executable observation result independent of gateway JSON and macOS
  frameworks. `ComputerMCPPlatform` owns the result, `ComputerMCPPlatformPOSIX`
  the native inspection, and `ComputerMCPProcess` the JSON projection.
- Keep finite command inputs and results in `ComputerMCPPlatform`. The command
  runners in `ComputerMCPProcess` own process lifecycle and bounded output
  capture; CLI compatibility checks run on top of its bounded execution.
- Keep project path resolution errors in `ComputerMCPPlatform` and the
  resolution in `ComputerMCPPlatformPOSIX`, which uses `lstat`/`realpath`
  ancestor checks; mutation owners retain responsibility for containment and
  replacement checks.
- Share declared platform/architecture matching between package preparation,
  retained source activation, diagnostics, static discovery and selected-asset
  provenance checks. Per-archive targets come from the exact tagged manifest;
  the installer retains the selected archive name and rechecks that target.
  Legacy macOS declarations retain their stored fingerprints. Catalog schema 2
  materializes per-asset targets; schema 1 remains readable, and a schema upgrade
  cannot alter the implied target or any immutable package identity.
- Keep Apple application-bundle discovery in `ComputerMCPPlatformDarwin`, which
  observes Launch Services without launching an application. Explicit executable and PATH bindings
  retain precedence. The gateway validates bundle identity and project path
  containment before binding a located executable.
- Keep the `SecretStore` protocol, the byte-level Keychain adapter protocol and
  secret-reference validation in `ComputerMCPPlatform`. `ComputerMCPPlatformDarwin`
  owns the Security calls and `KeychainSecretStore`, which implements
  `SecretStore` and handles UTF-8 values and blocking operation scheduling. macOS uses the private Data Protection Keychain access group and
  preserves noninteractive metadata-only existence checks.
- Keep explicit package checks in the App-owned control plane, shared by SwiftUI
  and the owner-only management CLI. `PluginDoctorReport` reuses activation's
  source selection, declaration identity, dependency binding and file inspection
  while including disabled contributions. Its dated, revision-bound report
  distinguishes observed file/configuration failures from runtime checks not
  performed. Reading a report does not activate or authorize a contribution.
- Delegate MCP JSON-RPC semantics to the upstream-aligned SDK. The shared owned-process
  primitive handles bounded newline-delimited stdio, supervisor/group lifetime
  and byte flow for downstream MCP without a domain dependency.
  Its supervisor uses `/bin/sh` on macOS and `/bin/bash` on Linux for job control
  without a terminal. Descriptor inheritance, including MCP ownership locks,
  uses Darwin spawn file actions; Linux rejects configurations that require
  inherited descriptors.
  Child-input owners install a process-wide no-op SIGPIPE handler once when the
  disposition is default, preserving an embedder's existing handler or SIG_IGN.
  The host reports broken child-input pipes as write errors. A caught handler
  resets to default on exec; SIG_IGN would survive exec and leak into children
  launched by Foundation Process on Linux.
  `ManagedLineProcess` and `ShellSession` share the child-input contract below.
  The HTTP client transport uses Foundation URLSession and a bounded SSE decoder.
  macOS reads native asynchronous bytes; Linux bridges data-delegate callbacks
  into the response byte stream. Each POST response and the standalone GET event channel own
  independent resume cursors and cancellation lifetimes. Response recovery uses
  GET; it does not repeat a possibly executed POST.
- Connect the independent Codex adapter through the ordinary MCP registration
  path. The adapter package owns its `swift-codex` dependency and domain state.
- Keep App bookmarks, Keychain secrets, and runtime state out of TOML.
- Keep Plugin declarations in their package and host source selection/settings
  in the existing transactional database. Runtime composition adds ordinary
  MCP, CLI, and Skill registrations with provenance; it does not copy expanded
  contributions into the source configuration or create another runtime.
- Resolve CLI Tree sources into ordinary CLI registrations. Immutable command
  descriptors own schema and ordered argv/stdin mapping; the shared process
  runtime owns byte streams, timeout, cancellation, and process-group cleanup.
  Descriptor-declared compatibility checks share that ownership and guard each
  target invocation; external CLI version knowledge remains in the plugin/tree.
  The Gateway owns grants and routing, independently of publisher risk hints.
- Load bundled declarations from the running App's `Contents/Resources/Plugins`.
  The embedded CLI uses that same directory; a standalone CLI has no implicit
  bundle. The read-only inventory remains separate from database installation
  records. Host defaults, user overrides, source precedence, configuration
  validation and runtime resolution share the ordinary plugin composition path.
  The bundle is not a writable settings store or an authorization source.
- Prepare bundled resources from digest-pinned distribution archives produced
  by independent plugin repositories. App packaging reuses the artifact worker,
  manifest validation and compatibility rules, then signs package-owned native
  code before sealing the App. This build input does not establish publisher
  identity or execute plugin contributions and external installers.
- Keep official GitHub discovery in the App-owned plugin management service,
  shared by SwiftUI and the owner-only CLI. Its isolated Foundation HTTP client
  reads public metadata without host credentials or arbitrary redirects.
  Publisher and declaration provenance are distinct from artifact verification
  and host permission grants.
- Bind release artifacts to GitHub's publisher, repository, tag commit and
  release-owned asset listing. Public downloads use a separate credential-free
  session and bounded, explicit GitHub CDN redirects. The installation ledger
  owns download staging before bytes arrive; archive and raw declaration hashes
  are checked, and release metadata is revalidated before the existing source
  selection transaction commits. A stored GitHub receipt is provenance, not a
  signature or an authorization grant.
- Keep untrusted archive decoding in the host CLI's short-lived internal
  worker. The host owns its read-only input descriptor, private job directory,
  deadline and process cancellation/reaping. The worker performs bounded
  private copying and SHA-256 verification before using the system parser;
  host-side package compatibility checks precede the installation transaction.
  CPU/file/time limits and sampled resident-memory termination are resource
  safeguards, not an OS sandbox or publisher authentication.
- Keep artifact selection in the plugin database transaction and local directory
  ownership in a separate recovery ledger. Files are prepared before selection;
  uninstall revokes selection before cleanup. A cross-process installation lock
  remains held by an orphan archive worker until it exits. Cleanup after a
  committed change can report a recovery issue without undoing that commit.
- Keep public behavior aligned across README, reference docs, DocC, and tests.

The independent `plugin-codex` repository pins and verifies `swift-codex` in
its own build and release checks. Host builds verify their own linked package
graph; bundled plugin archives retain their separate dependency notices.

## Child input lifecycle

Every owner of a child's `StandardInputWriter` uses `ChildProcessInput` to own
admission, writes and descriptor close:

1. Writes enter one FIFO queue per child. Only one library write is outstanding
   at a time. Explicit EOF, including a shell write with `close: true` and an
   empty close-only call, takes its turn after earlier operations.
2. Cancelling a caller before admission promptly removes its waiter and throws
   `CancellationError`, without writing. A caller cancelled while receiving the
   turn passes it on. Already-cancelled callers never write.
3. Once admitted, the input owner's task completes the whole write independently
   of caller cancellation. The caller awaits that result. Only the process's I/O
   cancellation or closure as it ends can cut the write short.
4. A short write fails as a closed managed transport or a shell session that is
   no longer running. If some bytes were written, the owner retires input before
   handing off the turn; queued and later data or EOF operations fail closed.
   A zero-byte result fails that operation but leaves input available for the
   next waiter. Library errors propagate unchanged.
5. Close, cancellation and shutdown stop admission and fail queued waiters, while
   process termination proceeds independently of the input queue. Teardown joins
   the admitted operation before calling `finish()`. Every `run` body also joins
   input before returning, since swift-subprocess automatically closes it then.
   Thus a resumed write cannot use a descriptor that teardown has already closed.

Managed close delivers EOF first when input is idle. With an admitted operation
it signals the owned process group immediately after startup has published its
identity. SIGTERM escalates to SIGKILL after `terminationGraceMilliseconds`;
managed close then allows `killGraceMilliseconds` for exit and reports a
termination timeout if necessary. Startup identity has a separate five-second
bound. Idle close can use one additional termination grace for EOF delivery.
Shell cancellation sends SIGTERM immediately and escalates after its configured
termination grace. These signal paths never wait for input to drain. When the
owned process exits, swift-subprocess cancels its I/O and releases the outstanding
write even if a descendant still holds stdin open; joining input adds no pipe
drain timeout to termination escalation. `pendingWrites` counts queued plus
outstanding operations, including explicit EOF.

Shell callers running in tasks use `writeAsync`, including the shell tool
provider, so their cancellation reaches admission. The synchronous `write`
bridge serves blocking callers and is unavailable from async code.

With swift-subprocess 1.0.2, each write registers its descriptor again, and a
second registration ends the first write's wait. Calling-task or process I/O
cancellation can return a short count. `finish()` immediately unregisters and
closes the descriptor, while a resumed write may still hold its descriptor
number. The FIFO queue, independent admitted task, short-write check and teardown
join together protect that descriptor's lifetime and the child's frame boundaries.
