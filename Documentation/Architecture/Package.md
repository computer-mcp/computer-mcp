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

| Package | Role |
| --- | --- |
| `computer-mcp/swift-sdk` compatibility fork | MCP server/client protocol, exact integer wire values, stdio framing with complete POSIX frame writes, and HTTP server session semantics |
| ArgumentParser | CLI parsing |
| swift-toml and Yams | TOML config and Skill YAML frontmatter |
| SwiftNIO | HTTP and Unix-socket transport adapters; shared lock primitives through `NIOConcurrencyHelpers` |
| swift-subprocess | Process, Shell, and streaming lifecycle |
| swift-system | `FilePath` for process launches where the System framework is unavailable |
| GRDB | Transactional App metadata and redacted audit; system SQLite on Linux |
| swift-log | Runtime logging integration |
| swift-crypto | SHA-256 in the platform-neutral `ComputerMCPCore` and `ComputerMCPToolsCLI` targets on macOS and Linux |
| macOS system `libarchive.2` | ZIP/TAR/gzip decoding for plugin staging; no downloaded library or decompressor process |

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
| `Sources/ComputerMCPCore/` | Platform-neutral models, policy, JSON values, tool descriptors and the session authority interface |
| `Sources/ComputerMCPPlatform/` | Platform-neutral protocols and values for secrets, workspaces, plugin archives, launch at login, file change monitoring and process inspection |
| `Sources/ComputerMCPConfiguration/` | Platform-neutral manifest model and defaults, MCP HTTP authentication values and CLI tree source values |
| `Sources/ComputerMCPPlatformPOSIX/` | POSIX implementations shared by macOS and Linux: executable inspection, workspace path resolution, process-table queries, shared/exclusive advisory file locks, file fingerprints, socket peer credentials and bounded package file reads |
| `Sources/ComputerMCPProcess/` | Platform-neutral bounded process execution, managed processes, shell sessions and executable discovery |
| `Sources/ComputerMCPTransport/` | Platform-neutral Unix-socket transport, inherited sockets, stdio bridging, HTTP response streams, SSE decoding and MCP framing and initialization normalization |
| `Sources/ComputerMCPDownstream/` | Platform-neutral downstream client contracts and authorization, child-process transport, catalog loading, value bridging, host launch metadata and session interfaces, and process ownership receipts |
| `Sources/ComputerMCPTunnels/` | Platform-neutral OpenAI tunnel launch planning and supervision, Cloudflare runtime values, the HTTP origin lifecycle contract and system proxy settings parsing |
| `Sources/ComputerMCPToolsCLI/` | Platform-neutral CLI provider, CLI tree catalogs, validation, parameter mapping and executable compatibility checks |
| `Sources/ComputerMCPToolsShell/` | Platform-neutral shell and managed-process provider with explicit definitions, annotations, descriptors and workspace runtime dispatch |
| `Sources/ComputerMCPToolsGit/` | Platform-neutral Git provider with explicit definitions, annotations, descriptors and registered-command dispatch |
| `Sources/ComputerMCPToolKit/` | Platform-neutral argument and result helpers, workspace path scope and file metadata, shared filesystem/outline/HTTP helpers, configured command resolution and execution, and workspace-owned tool environments |
| `Sources/ComputerMCPPersistence/` | Platform-neutral database connection with lifetime shared locks, initial schema, migration-ledger check, stored records and the exclusively locked, identity-based state import from installations created before 0.1.0 |
| `Sources/ComputerMCPPlatformDarwin/` | macOS implementations: Keychain, security-scoped bookmarks, `SMAppService`, Launch Services lookup, directory-event file change monitoring, archive extraction and staging, and system network proxy lookup |
| `Sources/ComputerMCP/` | Shared target for the gateway, providers, persistence, tunnel administration, and App Control Plane; see [Module Architecture](../Decisions/ModuleArchitecture.md) |
| `Sources/ComputerMCPMacOS/` | macOS composition root that supplies workspace grants, tool providers, executable search directories, file change monitors, tunnel proxy resolution and live App services to the shared target |
| `Sources/CSystemArchive/` | Internal declarations for the macOS system archive library |
| `Sources/computer-mcp/` | Thin CLI and stdio bridge entry point |
| `Sources/ComputerMCPApp/` | SwiftUI control center and menu-bar lifecycle |
| `Resources/ComputerMCPApp/` | Bundle metadata, entitlements and the imported App icon document |
| `Tests/` | Swift Testing component, policy, transport, App, and provider tests; an extracted target's tests are in `Tests/<Target>Tests/`, the shared target's in `Tests/ComputerMCPTests/` |
| `Tests/ComputerMCPTestSupport/` | Neutral helpers shared by test targets; package checks reject any non-test target that depends on it |
| `Tools/Validation/` | Independent Test Case catalog, probes, fixtures, evidence correlation, and reports |
| `Sources/ComputerMCP/ComputerMCP.docc/` | Internal target documentation |
| `Examples/` | Standalone development and dogfood manifests |
| `Scripts/` | App build, DMG, notarization, and distribution verification workflows |

`GatewayToolRegistry` retains configuration, runtime ownership and tool dispatch.
Its domain extensions contain the MCP, skills, workspace, file, structured-data
and platform implementations. Its catalog extension owns the definitions and
annotations for those domains. `ComputerMCPToolKit` owns shared
argument/result helpers, `WorkspaceScope` path checks and file metadata, and
`RegisteredCommands` resolution and execution with its CLI process lifecycle.
`ToolEnvironment` shares a workspace's configuration, scope, command execution,
environment and process/shell runtimes across providers; the host owns shutdown.
`MCPTool` and `DownstreamMCPClient` own their definitions
and client contract. `GitToolProvider`, `CLIToolProvider` and `ShellToolProvider`
own their definitions and dispatch using the shared tool environment. The
composition root registers them alongside the remaining registry providers, which
retain the shared runtime lifecycle. Each
catalog refresh loads CLI tree providers from the CLI module and publishes them
with their validated immutable definitions.

The release scripts assemble the SwiftPM App executable and embedded CLI into a
standard `.app`, sign both code objects, and package the bundle in a DMG. The
official candidate workflow builds an exact trusted-master commit through the
protected GitHub Actions `production` Environment. Installed acceptance binds
the signed and notarized artifacts before publication creates a signed `v*` tag
on that commit and publishes the same bytes. Local development signing verifies
distribution structure; it does not supply an official candidate. See
[Versioning and Release](VersioningAndRelease.md) for the evidence policy.

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
- Keep workspace path resolution errors in `ComputerMCPPlatform` and the
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
  retain precedence. The gateway validates bundle identity and workspace path
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
