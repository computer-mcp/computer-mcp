# Package

Computer MCP is a SwiftPM package that builds layered internal targets, the
`computer-mcp` CLI/bridge, and the native SwiftUI App on macOS. Only the App and
CLI are the declared package products. A private Darwin execution bootstrap ships
in the App's `Contents/Helpers`; a standalone CLI uses a sibling bootstrap binary.
On Linux the manifest declares the platform-neutral
targets, and CI builds and tests them there.

Neutral tool providers receive executable bindings from their host. Linux uses
GNU tar for tar extraction and an optional BSD tar binding named `bsdtar` for ZIP
extraction. ZIP creation uses `zip`; listing and member reads use `zipinfo` and
`unzip`. SQLite inspection requires a SQLite CLI binding independently of the
system SQLite library. Absent bindings return an unavailable-tool error before
executing that utility or creating destinations; neutral providers do not install utilities.

File and media readers share the descriptor-authorized reader in `ComputerMCPPlatformPOSIX`.
Tool domains depend on that lower-layer implementation so pathname swaps and live
permission changes are checked at the same read boundary. Darwin media inspection
uses in-memory image/PDF input and descriptor-backed AVFoundation resource loading.

The [execution environment](ExecutionEnvironment.md) describes the sandbox,
launch identity, outbound proxy and their validation entry points.

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
| swift-subprocess | `.upToNextMinor(from: "1.0.2")` | Darwin execution launcher backend |
| GRDB | `from: "7.11.1"` | Transactional App metadata and redacted audit; system SQLite on Linux |
| swift-log | `from: "1.14.0"` | Runtime logging integration |
| swift-crypto | `.upToNextMinor(from: "4.5.2")` | SHA-256 in the platform-neutral `ComputerMCPPermissions`, `ComputerMCPCore`, `ComputerMCPToolsCLI`, `ComputerMCPPlugins`, `ComputerMCPGateway`, `ComputerMCPControlPlane` and `ComputerMCPWorktrees` targets on macOS and Linux |
| System zlib | OS-provided | Bounded streaming decompression for private Git object validation through `CSystemZlib` |
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
| `Sources/ComputerMCPSandbox/` | Neutral execution configuration, explicit environments, launch and route-observation contracts |
| `Sources/ComputerMCPEgress/` | Execution-scoped proxy, destination policy, bounded relay and revocation |
| `Sources/ComputerMCPExecutionBootstrap/` | Private Darwin identity handshake before Foundation launches execute user commands |
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
| `Sources/ComputerMCPWorktrees/` | Neutral repository coordination, durable creation recovery, detached worktree topology and inventory, private object storage, Git safety policy, derived-project/provenance records and injected command/store contracts |
| `Sources/ComputerMCPAuthorization/` | Platform-neutral OAuth state machine, discovery metadata, injected CIMD identification, rate limits and transactional grant/token store contract; macOS URLSession CIMD transport |
| `Sources/ComputerMCPToolKit/` | Platform-neutral argument and result helpers, project path scope and file metadata, shared filesystem/outline/HTTP helpers, configured command resolution and execution, and project-owned tool environments |
| `Sources/ComputerMCPPlugins/` | Platform-neutral plugin manifests, bundled inventory and distribution, catalogs, installation/recovery, contribution resolution, archive preparation and the injected plugin state store contract |
| `Sources/ComputerMCPComputerUse/` | macOS Computer Use provider, observation and action service, native Accessibility and screen capture adapter, and permission readings |
| `Sources/ComputerMCPPersistence/` | Platform-neutral database connection, schema migrations, stored records, serialized permission ledger, generic derived-project store, branch protection and authority-epoch recovery |
| `Sources/ComputerMCPPlatformDarwin/` | macOS implementations: Keychain, security-scoped bookmarks, `SMAppService`, Launch Services lookup, directory-event file change monitoring, archive extraction, private staging, directory identities and exclusive rename, system network proxy lookup, ImageIO/PDFKit/AVFoundation media inspection, extended attributes, Trash, project opening and native system readings |
| `Sources/ComputerMCPGateway/` | Platform-neutral runtime, provider routing, admission, permission requests, receipts, continuations, host services, HTTP adapter, domain stores, owned work and audit; injected management and client-control contracts |
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
services across providers; the host owns shutdown. The gateway also uses
ToolKit's `AuthorizedFileReader` for operation-state digests, sharing descriptor
and live permission checks with tool readers.

`GitToolProvider`, `CLIToolProvider`, `ShellToolProvider`, `ProcessToolProvider`,
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

Plugin permission and sandbox declaration parsing in `ComputerMCPPlugins` uses
`ComputerMCPPermissions` directly for `NetworkHost` validation and normalization.
This keeps declared network rules identical to permission and egress rules without
maintaining another host-name parser. Declarations and their canonical review
digest describe requested authority; parsing does not grant it.

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
  without a terminal. The launcher maps explicit inherited descriptors, including
  MCP ownership locks, through its Darwin and Linux POSIX backends. Parent-side
  copies close after spawn so they cannot delay pipe EOF.
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
  deadline and launcher-owned process cancellation/reaping. It uses Full access
  with disclaimed privacy responsibility and explicit input, lock and output
  descriptors. The worker performs bounded
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

Managed transport and execution use `DescriptorInputWriter` behind
`ChildProcessInput` to own admission, writes and descriptor close:

1. Writes enter one FIFO queue per child. Only one descriptor write is outstanding
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
   next waiter. Descriptor I/O errors propagate unchanged.
5. Close, cancellation and shutdown stop admission and fail queued waiters, while
   process termination proceeds independently of the input queue. Teardown joins
   the admitted operation before calling `finish()`, so a resumed write cannot use
   a descriptor that teardown has already closed.

Managed close delivers EOF first when input is idle. With an admitted operation
it signals the owned process group immediately after startup has published its
identity. SIGTERM escalates to SIGKILL after `terminationGraceMilliseconds`;
managed close then allows `killGraceMilliseconds` for exit and reports a
termination timeout if necessary. Startup identity has a separate 35-second
allowance, covering the 30-second bootstrap handshake deadline and five-second
supervisor PID wait. Idle close can use one additional termination grace for EOF delivery.
Shell cancellation delegates to `ExecutionOwnership`, whose termination and
confirmation do not wait for input to drain. The descriptor adapter uses
nonblocking writes, stops them on execution cancellation or exit, joins admitted
input, then closes the descriptor. The launcher tracks execution ownership on
both paths. An unprepared administration launch also uses a supervisor and
watchdog. `pendingWrites` counts queued and outstanding operations, including
explicit EOF.

Shell callers running in tasks use `writeAsync`, including the shell tool
provider, so their cancellation reaches admission. The synchronous `write`
bridge serves blocking callers and is unavailable from async code.

The descriptor writer serializes close and each nonblocking write under its lock.
An outstanding poll cannot write to a reused descriptor. The FIFO queue,
independent admitted task, short-write check and teardown join protect descriptor
lifetime and the child's frame boundaries.

## Execution ownership

`CDarwinExecution` bridges the variadic Darwin sandbox query SPI to Swift with
the platform C calling convention. `PlatformDarwin` creates existing, private
marker files and holds them until the execution has no live members. Its
Seatbelt profile denies the marker directory except for the execution's own
read marker. A process belongs to that sandbox when its own marker is readable
and the shared unsandboxed marker is denied.

### Tool requirement declarations

Every capability descriptor carries an explicit `ToolRequirement` in permission
library terms. Declarations distinguish canonical path operations, project writes,
execution continuations, forwarding targets, plugin registration provenance and
Full access. Inline structured data has no path requirement when no path is supplied.
The router publishes requirements with their provider and rejects a changed
descriptor at dispatch. The gateway resolves these declarations and evaluates
each invocation through the permission library before dispatch.

`ResolvedToolInvocation` represents host-resolved invocation conditions and typed
plugin origins. `InvocationContext` carries this host-resolved value alongside
admitted permission evidence. A declaration alone does not grant authority.

### Permission admission and execution evidence

`ComputerMCPPermissions` is a platform-neutral value model using Foundation and
Swift Crypto for SHA-256 profile digests. `PermissionConnection` selects
host-issued consent and a connection ceiling alongside the stable `Principal`.
Full access consent never supplies a missing permission. Requests
keep stable permission and path evidence; each retry checks its calling
connection, while an admitted execution retains its exact consent and ceiling.
Closing a connection retires its connection-scoped Full access authority;
standing and sandbox work retain their independent lifetimes.

`NetworkHost` canonicalizes DNS names and numeric addresses and matches exact
hosts or explicit subdomain suffixes. Independent owner, machine-file and
managed-preference policies resolve per-object entries separately. Network
intersections retain only destinations admitted by every source and pin the
identities of the admitting rules. Execution evidence includes the connection's
network and denied-location ceiling, including implicit sandbox access.

`ExecutionLimitRequest` participates in complete invocation equality.
`EffectiveExecutionLimits` reports the strictest numeric ceilings and their
sources. Starting an execution refuses an unenforceable memory limit. Limit
reconciliation updates output and retention ceilings, records time or memory
termination reasons, and queues termination until the host acknowledges it.
The library performs no process, buffer, storage or operating-system operations.

`recordDiscoveredNeeds` accepts host-attributed path and host requirements for a
running execution. Discoveries accumulate per authorization in a durable retry
chain bound to the original principal, tool, project, arguments and requirements.
The chain carries prior Only this time answers from valid execution authority;
new requests expire after one day. Answers authorize a matching retry and its
new execution. The original execution's requirements remain fixed.

`GatewayRuntime` resolves every call's requirements and selects its authenticated
connection before permission admission. `ExecutionRevocationCoordinator` prepares
execution contexts, reconciles resource limits and joins revoked work. A launch
whose context or enforcement backend is unavailable fails before dispatch.

### Durable permission state

`ComputerMCPPersistence.SQLitePermissionStore` stores the complete permission ledger in
the additive `permission-ledger` schema migration. Every operation acquires SQLite's
immediate write lock and then the platform counter's namespace lock before loading state.
A mutation stages the complete candidate and advances the external counter before
committing the ledger; the counter lock remains held through SQLite COMMIT. SQLite uses
full synchronous writes and requests full filesystem synchronization where supported.
SQLite contention times out after five seconds; counter-lock acquisition uses the same
default. Lock, counter and database failures propagate without an older snapshot or
in-memory fallback. Transaction callbacks perform ledger and SQL work only; runtime
dispatch and other external effects follow a successful commit.

A missing counter or ledger, changed database identity, or unequal counter starts an
authorization epoch. The ledger discards transient authority and execution records,
suspends standing permissions, sandbox settings and owner policy, and preserves an
epoch-wide runtime termination handoff. Admission remains suspended until the owner
confirms the displayed snapshot and the runtime acknowledges that all work from other
epochs has stopped, including processes absent from a restored database. Confirmation
checks the epoch and ledger revision and allocates fresh grant identities. The owner can
apply reviewed restrictions in that same store transaction before any restored authority
becomes visible. Confirmation ends any connections opened while suspended. Cached
machine policies require fresh adapter reconciliation; Full access consent, request
answers and old execution access do not return.

The platform-neutral `AuthorizationEpochCounter` protocol owns the external watermark
contract. Darwin's `KeychainAuthorizationEpochCounter` uses a host-owned explicit
Keychain service/account and a stable namespace lock directory independent of the
database path. It disallows authentication UI while holding transaction locks.
`UnavailableAuthorizationEpochCounter` explicitly refuses durable permission storage on
a platform without that facility. The host must select the same namespace and lock
directory for every writer, including database replacement.

`GatewayDatabase.permissionStore(counter:)` shares its connection with the ledger store,
and `transactionWithDatabase` permits atomic project/profile SQL changes. The live gateway composes its authority through this store and epoch handoff.

`PermissionProfileMigration` converts a versioned host snapshot without constructing
providers or querying downstream processes. `PermissionMigrationCatalog` freezes the
built-in classifications at migration version 1; the host supplies available tool IDs,
validated aliases and contribution origins, and the configuration digest. Revision-zero
profiles first resolve their manifest defaults. Missing or ineffective grants produce
bounded diagnostics rather than broader grants.
Every migrated project starts with network access `none`, including projects with
network-using tools such as `file.download`. Subsequent host requests allow the
owner to add individual destinations to that project's `custom` host list.

`PermissionMigrationStore.prepare` reads profiles, projects, aliases, derived receipts
and configuration identity together. Explicit activation recomputes that conversion
inside the permission-store transaction, verifies the expected input and catalog,
advances profile authorization revisions, clears saved consent, removes the obsolete
ticket table,
and records an idempotent receipt. Additive permission-profile and source-parent tables
preserve derived ownership and receipt provenance. Runtime composition activates the conversion before admitting calls and binds
converted profiles to the external authority epoch. The database opener alone
does not activate conversion.

`PermissionProfileManifest` is the codec for the
[permission-table format](../Reference/Config.md#callers-and-profiles). Missing entries remain requestable, `deny` is explicit, project
network entries support the custom host form, and revisions belong to the host.
Access and network settings are independent: a network-only project entry retains
the access fallback, an access-only entry retains the network fallback, and denying
access does not erase its saved network setting. Without a fallback, omitted network
settings mean none.
An empty custom host list is valid and denies network unless it includes trusted hosts.
Obsolete profile fields fail with replacement guidance, including empty and false
values. The public configuration parser uses this permission-table contract.

`GatewayPermissionService` provides admission, request answers, shared profile edits,
revocation, owner ceilings and machine-policy reconciliation on the same
`SQLitePermissionStore`. `PermissionControlService` accepts an in-process local-owner
proof for each action; `MacOSPermissionServices` constructs both adapters over one
connection and external epoch counter. The gateway and local owner controls use this shared authority.

Verified client identity, profile and caller form a stable subject. Only this time
answers remain bound to that subject's exact invocation and retry dependency chain.
Always changes the shared profile, including clients already bound to it and future
bindings; owner projections disclose that scope. Answers do not dispatch or replay a
call. Owner proof and a control revision are checked in the durable transaction.
Owner mutations and newly migrated profiles advance this revision; admissions and
projections do not make an open owner action stale. Profile edits also check their profile revision. Policy I/O
and canonical denied-path acquisition happen outside the writer; the transaction
compares the observed source projection and owner documents before applying the
snapshot, retrying at most three times on concurrent publication. Fresh limits are
reconciled before an answer or edit. Profile grants and
owner policies are also bound to the external authority epoch, so a restored database
cannot repopulate standing authority before local confirmation. Runtime termination
is delivered through the ledger's durable pending queue. Removing a caller retires
its requests and transient authorizations as well as standing rules. The control
service exposes confirmation with reviewed profile edits in the same transaction;
unadopted profiles remain visible and cannot admit calls. Subject bindings are capped
at 16,384 rather than evicting authority or revocation history.

The platform-neutral `ManagedPolicyReading` contract returns separate source status
and location. Darwin adapters read protected machine policy and forced preferences;
`GatewayPermissionService` reconciles their meaning and owner ceilings with ledger
authority. The [Managed limits reference](../Reference/Config.md#managed-limits)
owns locations, document syntax, source combination, failure behavior and the
connection-limit JSON shape. Resource-ceiling-only changes preserve permission
evidence while tightening running work and retained-output limits.

## Host call records

Callback-enabled, project-bound admissions journal immutable call identity before
provider dispatch when persistence is available. Declared host actions require
persistence; workspace mutations also require a verified client. `HostCallRecord`
binds client and acting plugin or local server, profile/caller, actual/source project,
route/action, canonical argument digest and admission revisions. It contains no raw
arguments. Its permission authorization ID links the call to live permission-ledger admission.
Control-session revision records admission evidence; callbacks consult the live session.

`HostCallRecordStore` uses the host database and retains at most one million records.
Completed records expire after 90 days and the oldest completed records are evicted at
capacity. Unfinished crash records remain as uncertain evidence and count toward the
cap; they cannot reconstruct authority or be presumed safe to replay. A store occupied
entirely by unfinished records refuses new admissions.

`MCPHostToolDirectory` owns separate request and retained-work lease identities.
Creation and retention commit before each lease is published; private host actions
compare the saved admission and exact lease sets with this directory. The directory's
mutex is scoped to one runtime, and durable lease changes use the host's serial writer
and bounded database lock wait. Downstream discovery and Git verification run outside
the commit boundary. Workspace mutations then lock session consent, the active-request
directory entry and the database, in that order, and compare the checked profile revision
and any persistent client-trust revision inside the writer. A profile revision conflict
rechecks current policy and retries once; continuing changes fail closed. Work-only
retention cannot pass a mutation check. Failed completion writes leave uncertain journal
evidence while retiring in-process authority. Runtime shutdown retires its directory;
another runtime cannot adopt its records.

The private protocol retains the same invocation/workspace fields, receipt identity
digest and confirmation arguments. Removal and unregister validate current authority.
Exact provisioning rollback requires its creating invocation and revision, even when
the grant has since been revoked; idempotent registration never transfers rollback
ownership. Permission-ledger admission remains authoritative. The version-1 `ticket_id`
compatibility field is null; callbacks validate the live call record and ledger.

## Repository coordination

Host Git mutations coordinate on the canonical common Git directory's
`computer-mcp/repository.lock`. The descriptor and stable inode own exclusion;
owner metadata is diagnostic. Cancellation and timeout never unlink the lock.
Directory and lock identity are checked before use. External Git processes do
not honor this advisory lock, so mutation owners also verify their expected Git
and checkout state. Upgrading from hosts using the earlier delivery lock requires
stopping those hosts before the new host opens the repository.

The lifecycle service derives four separate regions from durable composition:
content, private objects, runtime scratch, and host journals. App composition
uses `Worktrees`, `WorktreeObjects`, `WorktreeRuntime` and `WorktreeJournals`
under its distribution's Application Support root; standalone composition uses
`worktrees`, `worktree-objects`, `worktree-runtime` and `worktree-journals` beside
the database. Memory-only databases have no lifecycle storage. Ordinary project
roots cannot overlap these regions. Existing host content is recognized only
through matching active ledger, journal, storage generation and directory evidence.

Creation reserves a generic derived record, creates owned directories, verifies
the detached checkout and its independent private repository, creates an absent branch in a reference
transaction, then atomically activates topology and branch protection. Recovery
reconciles the recorded phases; changed or unproved state is retained for the
owner. The active ledger binds the topology and base captured by the journal.
Inventory verifies a host-owned copy of private HEAD and index entries and reports
unknown base or unavailable state explicitly. Foreign checkouts and plugin receipts
do not mint verified host topology. Topology evidence alone grants no execution
lease or sandbox authority; lifecycle tools are not registered by this service.

Worktree object verification uses system zlib through `CSystemZlib` for bounded
streaming decompression before invoking Git. Object and pack digests use the
existing swift-crypto dependency. Publication captures detached HEAD once and
validates an exclusive host copy; only its exact reachable closure is promoted.
Prepared reference transactions retain host recovery roots for replaced commits.
Explicit replacement acknowledgement releases an obsolete root with expected-value
checks; ordinary rebase and removal do not expire history by age.

Fast-forward integration prepares an expected-value update through dereferenced
HEAD, verifies its recorded base target under Git's reference locks, and reserves
the main index until reference commit. Two-tree checkout uses a host-owned index
copy; tracked, staged, untracked and ignored collisions are refused, and unrelated
dirty state is preserved. `HostGitCheckout` refuses attributes that select filters.
The adapter revalidates current permission for every destination, including nested
projects. Durable before/after fingerprints and an operation-specific reflog
receipt reconcile checkout, refs and the protected-branch ledger. Unknown partial
checkout and foreign or abandoned Git locks require reconciliation; recovery never
resets the main checkout. A merged OID is historical evidence, not authority to
delete a branch without checking its live base and reachability.
