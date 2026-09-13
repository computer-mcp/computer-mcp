# Package

Computer MCP is a SwiftPM macOS package that builds an internal gateway
implementation target, the `computer-mcp` CLI/bridge, and the native SwiftUI
App executable. Only the App and CLI are package products.

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
| official MCP Swift SDK 0.12.1 | MCP server/client protocol, stdio framing, and HTTP server session semantics |
| ArgumentParser | CLI parsing |
| swift-toml and Yams | TOML config and Skill YAML frontmatter |
| SwiftNIO | HTTP and Unix-socket transport adapters |
| swift-subprocess | Process, Shell, and streaming lifecycle |
| GRDB | Transactional App metadata and redacted audit |
| swift-log | Runtime logging integration |
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
| `Sources/ComputerMCP/` | Gateway core, transports, providers, policy, persistence, tunnel, and App Control Plane |
| `Sources/CSystemArchive/` | Internal declarations for the macOS system archive library |
| `Sources/computer-mcp/` | Thin CLI and stdio bridge entry point |
| `Sources/ComputerMCPApp/` | SwiftUI control center and menu-bar lifecycle |
| `Resources/ComputerMCPApp/` | Bundle metadata and entitlements |
| `Tests/` | Swift Testing component, policy, transport, App, and provider tests |
| `Tools/Validation/` | Independent Test Case catalog, probes, fixtures, evidence correlation, and reports |
| `Sources/ComputerMCP/ComputerMCP.docc/` | Internal target documentation |
| `Examples/` | Standalone development and dogfood manifests |
| `Scripts/` | App build, DMG, notarization, and distribution verification workflows |

The release scripts assemble the SwiftPM App executable and embedded CLI into a
standard `.app`, sign both code objects, and package the bundle in a DMG. The
only supported official release topology is a signed `v*` tag processed by the
protected GitHub Actions `production` Environment. Local invocations exercise
development signing and distribution structure but do not publish releases.

The GitHub release job imports a password-protected Developer ID PKCS#12 file
and provisioning profile into an ephemeral runner Keychain, authenticates
notarization with an App Store Connect Team API key, and deletes decoded assets
in an unconditional cleanup step. The no-secret verification job must pass
before the protected job can start.

`Tools/Validation` is not a root target and is not included in the App or DMG.
Real external consumers and tunnels are Validation Runs, never automated tests.

## Principles

- Keep executable targets thin; shared product behavior belongs in the internal
  `ComputerMCP` implementation target.
- Keep side effects behind provider and transport adapters.
- Share executable inspection across CLI/MCP status and plugin contribution
  resolution. The inspector reads regular-file metadata and at most 512 header
  bytes per interpreter, with bounded interpreter traversal. It does not run
  code or establish launch-time trust. Shebang handling follows the macOS
  [XNU interpreter rules](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c)
  and distinguishes supported plain
  [env invocations](https://github.com/apple-oss-distributions/shell_cmds/blob/main/env/env.c)
  from invocations needing further verification. Transport and process owners
  remain responsible for actual launch, cancellation, policy and runtime health.
- Keep explicit package checks in the App-owned control plane, shared by SwiftUI
  and the owner-only management CLI. `PluginDoctorReport` reuses activation's
  source selection, declaration identity, dependency binding and file inspection
  while including disabled contributions. Its dated, revision-bound report
  distinguishes observed file/configuration failures from runtime checks not
  performed. Reading a report does not activate or authorize a contribution.
- Delegate MCP JSON-RPC semantics to the official SDK. The shared owned-process
  primitive handles bounded newline-delimited stdio, supervisor/group lifetime
  and byte flow for downstream MCP without a domain dependency.
  The host-owned HTTP client transport uses Foundation URLSession and a bounded
  SSE decoder. Each POST response and the standalone GET event channel own
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
