# Plugin Packages

A Plugin is an independently owned repository and distribution package. Its
root `computer-mcp-plugin.toml` describes a nonempty combination of MCP, CLI,
and Skills contributions. A declaration-only package needs neither
`Package.swift` nor an executable. An adapter or helper belongs to the package
that supplies its implementation.

This reference describes package declarations, host-owned source selection and
settings, and the gateway's internal composition contract. Parsing a declaration
does not establish publisher trust, artifact integrity, or user authorization.

## Identity and Compatibility

| Field | Meaning |
| --- | --- |
| `id` | Stable package identity |
| `name` | Nonempty display name |
| `version` | Semantic release version, including optional prerelease/build identifiers |
| `description` | Optional package description |
| `repository` | Optional HTTPS repository URL; a claim, not verified provenance |
| `compatibility.minimum_host` | Inclusive minimum host release |
| `compatibility.maximum_host` | Exclusive maximum host release |
| `compatibility.architectures` | Optional unique subset of `arm64` and `x86_64`; omitted means unrestricted |

Package, dependency, and contribution IDs contain lowercase ASCII letters,
digits, hyphens, or underscores, start with a letter or digit, and are at most
128 bytes. Contribution IDs are unique across all three kinds within a package;
dependency IDs have their own namespace. There are at most 1024 contributions.
Compatibility compares semantic precedence; build metadata does not change it.

## Executables and External Dependencies

An `executable` has exactly one of two fields:

- `path`: a normalized package-relative path to a package-owned executable.
- `dependency`: the ID of a declared, user/vendor-owned external dependency.

Each `[[dependencies]]` entry has `id`, ordered executable base names in
`commands`, optional ordered `applications` locators, human-readable
`instructions`, and an optional HTTPS `documentation` URL. At least one command
or application locator is required. Each application locator has
`bundle_identifier` and an `executable` path relative to the application bundle
root, such as `Contents/MacOS/vendor`. Paths are normalized and may not escape
the bundle through symlinks. There are at most 32 distinct application locators
per dependency. Instructions are text, not installation commands executed
by the loader. Loading a package does not search for, install, update, copy, or
run an external executable. Missing external executables do not make the
immutable declaration malformed.

Resolution uses an explicit host binding first, then ordered command names in
the host search path, then application locators. macOS chooses the installed
application for a bundle identifier; the host verifies that identifier and path
containment before inspecting the selected executable. It neither launches the
application nor recursively scans installation directories. A selected program
with a missing interpreter, missing executable or execution-access failure stays
selected for diagnostics; the host does not silently choose another installation.
When macOS cannot locate a vendor installation, use an explicit host binding.
Bundle identity is discovery metadata, not signature or publisher verification.

Enabled contribution resolution checks package-owned and externally bound
executables with the same non-executing inspection used by `cli.status` and
`mcp.servers.status`. It checks regular-file type, execution access and a bounded
script header, then resolves script interpreters against the child working
directory and environment. An explicit binding is retained on failure; it does
not silently switch to another installation. A known executable failure omits
the affected contribution and reports `dependencyUnavailable` or
`executableUnavailable`. Independent Skills remain available.

Plain `/usr/bin/env command` and unquoted, unescaped `env -S command` forms can
be inspected. Environment assignments, other env options and complex split
strings, unreadable headers and unsupported header encodings report
`executableUnverified`; uncertainty alone does not suppress a registration.
The App's registration diagnostics and management CLI's list/show
responses include the executable and interpreter inspection. Neither resolution
nor those read operations executes a plugin, installs a runtime or prompts for
system permissions. File checks do not establish binary compatibility,
signatures, protocol health or the caller's authority to perform an action.

### Explicit Package Checks

Use **Check package** in the App or `computer-mcp plugins doctor <id>` to inspect
an identity from `plugins list`, including disabled packages and contributions.
This reads the selected source, revalidates its declaration identity and package
paths, checks declared host compatibility, and inspects every declared external
dependency and MCP/CLI executable or tree helper. Checks use the same source
selection, dependency bindings and executable inspection as activation. A broken
selected source is reported; it does not silently switch to bundled fallback.

The JSON report includes `pluginID`, `revision`, `checkedAt`, `enabled`, `source`,
`version`, `dependencies`, `checks`, `status`, `scope`, and `notChecked`. Each
dependency retains its declaration and reports an executable path, if resolved,
and `resolutionSource`: `host_override`, `path`, `application_bundle`, or
`unresolved`. Executable
checks identify their contribution/dependency and child working directory, with
the file/interpreter observation. Human setup instructions are stored once in
the dependency declaration, shared by all checks referencing that ID. Skill checks
validate the declared directory, not the correctness of its guidance or scripts.

The current scope is `configuration_and_files`. Aggregate `status` is `failed`
when any check fails, otherwise `unverified` when an observation is inconclusive,
otherwise `passed`. Read `notChecked` even after a passing report: runtime
version, binary compatibility, connections and system permissions are not
verified by these checks. No contribution, version probe, connection, installer
or permission prompt is started. Source selection, grants, enabled state and the
settings revision are unchanged; the owner control plane retains its normal
audit record.

The CLI returns the report as JSON, with exit status 1 for failed checks and 0
for passed or explicitly unverified observations. Control failures return the
normal JSON `error` object and exit status 1; parsing errors use CLI usage
diagnostics. The App keeps the previous dated observation visible if a refresh
fails, shows the failure, and cancels the read when the sheet closes.

## Contributions

### MCP

Each `[[mcp]]` has an `id` and `transport`. Stdio requires `executable` and may
include `args` and a package-relative `cwd`; HTTP requires `url` and rejects
process fields. Transport names use the host's existing `stdio`,
`streamable_http`, `http`, and `sse` values. URLs require HTTP(S), a host, and no
embedded user/password or fragment. A `prefix` can recommend tool names, and
`capabilities` declares a unique subset of `tools`, `resources`, `prompts`, and
`events` (default: `tools`). Neither field grants caller access.

The manifest does not copy MCP tool schemas. Tool selection, risk assignments,
environment/secret bindings, and exposure decisions belong to the host;
`allow_any_tool`, `allowed_tools`, `tool_risks`, and `env` are not manifest fields.

### CLI

Each `[[cli]]` has `id`, `executable`, optional `description`, and optional
package-relative `cwd`. An optional `tree` identifies a machine-readable source:

| `tree.kind` | Required fields | Meaning |
| --- | --- | --- |
| `file` | `path` | Package-relative command-tree document; no helper or args |
| `introspection` | Nonempty `args` | Exact arguments for the contribution's executable; no path or helper |
| `helper` | `helper` executable reference | Package helper or declared dependency, with optional args; no path |

These fields identify a source; parsing them does not execute introspection or
verify a command tree's contents. Omission does not imply structured command
coverage. Command-tree validation and argument encoding are separate from
package-directory validation.

Activation resolves these sources into the same CLI registration used by direct
integrations. The Gateway validates their [CLI Tree contract](CLITrees.md), then
publishes typed tools using the shared argv/stdin encoder and managed process
runtime. Tree-bearing registrations require `allowAnyArgs` to remain false;
generic execution cannot bypass their declared input constraints.

### Skills

Each `[[skills]]` entry has `id`, a package-relative directory `path`, and an
optional `description`. Directory validation does not execute Skill scripts or
grant their recommended tools. Skill content and resource reads retain their
own size and containment checks.

## Combined Declaration Example

This illustrative package refers to an external executable and a `skills/`
directory in its own repository:

```toml
id = "example-integration"
name = "Example Integration"
version = "1.2.3"

[[dependencies]]
id = "vendor"
commands = ["example-cli"]
instructions = "Install the vendor CLI separately and make it available to the host."

[[mcp]]
id = "native"
transport = "stdio"
executable = { dependency = "vendor" }
args = ["mcp"]

[[cli]]
id = "commands"
executable = { dependency = "vendor" }
tree = { kind = "introspection", args = ["schema", "--json"] }

[[skills]]
id = "guidance"
path = "skills"
```

The example's introspection arguments are illustrative, not a required command
for every CLI. A package must describe its actual executable's contract.

## Validation and File Safety

Unknown fields are rejected at every manifest level. The manifest must be UTF-8
and no larger than 1 MiB. Package-relative paths reject absolute paths, tilde
expansion, backslashes, NULs, empty components, and `.`/`..` components.

Package-directory validation checks referenced directories, regular files, and
helper executable bits. Contained symbolic links are resolved; dangling links
and links outside the package fail. After canonicalization, each component is
opened with no-follow semantics, and file type, size, and bounded contents are
checked through the opened descriptor. This anchors an individual read against
path replacement; it does not turn a writable development checkout into an
immutable installed artifact. Runtime activation must validate the exact
package revision it will use.

Loading never executes helpers, introspection, Skill scripts, or installation
instructions. It also does not infer official identity from a manifest's name
or repository URL.

### Archive Staging

The internal `PluginArchiveExtractor` decodes ZIP (stored or compressed), TAR,
and gzip-compressed TAR with the macOS system library. It accepts ordinary
files and directories; links, device nodes, FIFOs, encrypted entries and sparse
maps are rejected. Archive paths must be UTF-8, relative, and free of control
characters, backslashes, colons and traversal components. TAR's leading `./`
and a directory's trailing slash are normalized. Duplicate entries, file versus
directory conflicts, and case/Unicode spelling collisions fail the whole
extraction. Implicit parent directories count toward the entry limit.

Default bounds are 512 MiB of archive input, 1 GiB of extracted file contents,
256 MiB per file, 20,000 entries including implicit parents, 32 path components,
4,096 path bytes and 255 bytes per component. Expanded stream accounting also
bounds header/padding overhead to 64 MiB beyond the payload budget. Limits can
be reduced for callers/tests, not raised above these ceilings.

The destination must be new, under a current-user-owned directory that is not
group/world-writable. Descriptor-relative, no-follow writes use exclusive file
creation. Directories and executables receive owner-only mode `0700`; other
files receive `0600`. Archive ownership, special permission bits, ACLs and
xattrs are not restored. File and parent-directory synchronization precede
success. Failure/cancellation reclaims only the newly owned staging directory;
a replaced root name or cleanup failure is reported instead of deleting a
different directory or claiming cleanup succeeded.

`PluginArchivePreparation` runs the host's own CLI through its hidden
`_plugin-archive --sha256 <digest>` entry point. This is an implementation
detail, not a Plugin runtime or a user-facing installation command. The host
opens a nonempty regular archive with read-only/no-follow semantics and passes
that descriptor as stdin. Each job receives a new private working directory,
bounded stdout/stderr, and only explicit system `PATH`, `LANG` and job-local
`TMPDIR` environment values. Host credentials and configuration are not
inherited. The worker executable must come from the host, never the package.

Before decoding, the worker copies stdin in 64 KiB chunks to a new owner-read-only
file and incrementally computes SHA-256. It requires an exact lowercase
64-character expected digest. Decoding reads that verified private copy, not a
second opening of the mutable source. A mismatch never reaches the parser.
Neither the digest nor the worker receipt proves publisher identity or grants
permissions. The original archive is never removed or changed.

The CLI worker lowers only its own CPU limit to 30 seconds, per-file limit to
512 MiB and core-dump limit to zero. The host cancels and reaps it after at most
60 seconds; a child alarm provides an independent 60-second deadline. Resident
memory is sampled every 20 milliseconds and the worker exits above 512 MiB or
if sampling fails. This is a sampled safeguard, **not a hard allocation cap**:
an allocation can overshoot before the next sample. Small macOS `RLIMIT_AS` and
`RLIMIT_DATA` values cannot reliably be established for Swift's reserved virtual
address space. Separate processes and cleared environments do not constitute an
OS security sandbox; no package code is executed during preparation.

The host validates the bounded JSON receipt, loads the package manifest and
referenced files, checks the selected identity/version and host compatibility,
then supplies the package to a scoped installation operation. Failure,
cancellation and normal scope exit reclaim only that job's staging root, after
the worker has exited. An installation transaction may move its payload into
an owned final directory before committing state. Preparation alone is not a
completed installation; the store commits source selection separately.

### Artifact Transactions and Recovery

`PluginStore.installArchive` prepares a local archive under a host-owned storage
root. Before starting the worker, it records the new installation directory's
device, inode and birth time in the local database. These ownership receipts
are separate from portable settings and must not be accepted from an imported
manifest or plugin. Each root admits one filesystem transaction at a time using
a nonblocking file lock. The worker inherits that lock reference, so losing the
parent reference does not permit another host to clean files while the worker
is writing. On normal completion the host explicitly unlocks and closes its
reference after joining the worker and all file operations. This also releases
lock copies briefly inherited by unrelated forked children before exec, without
waiting for their descriptor cleanup. Abnormal destruction only closes the host
reference, leaving the orphan worker protected. Contention returns a retryable
busy error; it never interrupts the other process.

After preparation, the actor rechecks the configuration revision, exclusively
renames the complete payload to its final `package` directory, synchronizes the
directories, validates the proposed composition and commits source selection
with a database revision comparison. Any pre-commit failure preserves the
previous selected version. Earlier installed versions remain available for
explicit selection/rollback. Host enabled state, grants, component settings and
external executable overrides survive updates. A new identity starts disabled.

Uninstall first revokes the exact artifact record and its selection, then
reclaims only its receipted directory. It retains settings, other versions,
development checkouts and external products. If another installation reference
points into the directory, uninstall refuses the change. A cleanup failure after
a successful database commit returns the committed state with a recovery issue;
it must not delete a successfully installed version as an apparent rollback.

Recovery holds the same lock. A receipted committed installation retains its
package and loses only reserved staging files. A missing package directory,
symlink, non-directory or non-private payload produces an issue without
revoking the installation record. An uncommitted directory can be
reclaimed only when its identity and direct-child location still match. Missing
uncommitted directories allow receipt cleanup. Replaced, out-of-root or
still-referenced directories are preserved and reported. Unrecorded files are
preserved, including a directory created immediately before a crash prevented
its ownership receipt from being committed. Recovery does not infer ownership
from a UUID-looking name, process ID or age.

These store APIs require the host to quiesce affected runtime tasks before
changing selected files. App and owner-only CLI mutations use the same idle
gateway admission reservation. They never interrupt connected clients.
Connections remain busy while session creation or downstream cleanup is in
progress, including after the client has disconnected. Stopping the socket
server waits for those owners to finish before reporting completion.
The host chooses its embedded archive worker and stores installations under
its Application Support `Plugins` directory; neither path is a plugin or
control-socket argument. An unavailable embedded worker fails without a PATH
fallback. App and CLI archive installation accepts a local file. The host's
GitHub release installer adds public provenance verification to this same
transaction; it does not grant additional runtime permissions.

After claiming its control socket, the App attempts owned-file recovery before
restoring gateway clients, including when the gateway is disabled. Recovery is
also attempted on a standalone gateway service's first start. Store-wide failure
is retained as `recovery_error`; per-plugin recovery warnings join `issues`.
Other integrations may start after a busy or damaged plugin store is reported.
`plugins recover` retries cleanup with the current revision, without changing
source selections or grants. Unknown directories are preserved. A stale recovery
request is rejected without falsely marking the store as damaged.

## Host Settings and Composition

`PluginSettings` belongs to the host, independently of a package version. A
package defaults to disabled. Enabling it permits its contributions to be
resolved; it does not grant MCP tools or unrestricted CLI arguments. Each
contribution can be disabled separately and can have a host-selected
registration ID. Absent an override, the registration ID is
`plugin-<package-id-byte-count>-<package-id>-<component-id>`; the length prefix
keeps distinct package/component pairs unambiguous.

MCP settings use the same exposure, prefix, all/allowlist selection, and
host-assigned tool risks as direct MCP registrations. An omitted or null `prefix`
follows the package recommendation or registration ID. An explicit `"prefix": ""`
preserves native downstream tool names; the App exposes **Preserve downstream
tool names**. This choice survives editing and does not modify the package.
Names that collide with another provider or a host management tool are rejected,
including during catalog refresh, rather than renamed or silently overwritten. All combined with a
nonempty allowlist is invalid. An empty allowlist grants no downstream tools.
Profile and workspace policy still apply to both generic calls and reexported
tools. A CLI with a declared command tree cannot also grant unrestricted raw
arguments. Skill roots retain their bounded read policy and do not grant the
tools described in their content.

`PluginResolver` consumes the selected package, host settings, and host-resolved
external executable bindings. An unavailable external binding produces a
component diagnostic and installation guidance; independent contributions such
as Skills can still resolve. Host incompatibility produces no registrations.
The executable checks establish file presence, regular-file type, and executable
permissions, not protocol connectivity, interpreter availability, or version
compatibility of the external product.

`GatewayPluginComposition` combines resolved contributions with direct
registrations into one runtime configuration. Duplicate selected package IDs,
registration conflicts, and invalid exposure prefixes fail validation. The
source configuration remains unchanged and exportable; expanded contributions
are not copied into the main TOML. Contribution origins retain package identity,
component identity, version, and host-owned source provenance.

For a trusted owned stdio contribution, `hostServices: true` enables the private
[scoped host-services connection](HostServices.md). The default is false; HTTP
rejects this choice. The App's **Allow scoped host services** toggle and the
owner CLI settings JSON persist the same value. It is a host override, never a
manifest field, and survives ordinary source updates without granting tools or
local-admin authority by itself.

## Source Selection and Persistent State

`PluginStore` persists installation references, selected sources, and host
settings in the gateway's existing database. Each mutation supplies the revision
it read. The database atomically compares that revision and saves the next
snapshot; a stale update must reload before retrying. Invalid or oversized state
leaves the previous snapshot intact. Serialized state is limited to 4 MiB.

A development registration records the canonical source directory, declared
identity and version, registration time, and a SHA-256 fingerprint of the parsed
manifest. That fingerprint is neither an archive digest nor a signature and
does not make development files immutable. Re-registering an unchanged source
reuses its record. A changed declaration requires an explicit refresh before
activation; selecting an older record cannot restore files changed in place.

A selected installation takes precedence over a bundled package of the same
identity. Clearing the selection restores bundled fallback while retaining the
host's enabled state and overrides. A broken selected source is diagnosed
instead of silently activating a different version. Duplicate bundled identities
are invalid. These source choices all feed the same resolver and policy path;
the source label does not grant privileges or establish verified provenance.

Removing a development registration removes its host reference and selected
pointer, not its checkout, external executables, or host overrides. If an enabled
identity has no selected or bundled source, resolution reports it unavailable.
Settings for temporarily absent components remain available when those
components return in a selected package.

## Bundled Inventory

`Scripts/build-app.sh` prepares the archives pinned in
`Resources/PluginArchives/index.json` before sealing the App. The index is a
build input: each entry contains an `id`, semantic `version`, archive basename
and SHA-256. The host's bounded archive worker checks the same integrity,
identity, compatibility and filesystem rules used by artifact installation.
All requested App architectures must be permitted. An invalid package fails
the build and removes only the newly created plugin resource directory.
Existing output is never overwritten by the collection command.

Archives are generated distribution inputs from independent plugin repositories,
not a second source checkout. Rebuild an archive in its owning repository,
review the input changes, and update its pinned digest when adopting a new
version. The build emits `ReleaseMetadata/BundledPlugins.json` describing the
input archives. These digests identify the inputs, not post-signing executable
bytes. Neither the index nor the receipt establishes a GitHub publisher.

Package files become ordinary readable App resources; package executables retain
executable permissions. Native code must contain both App architectures and is
signed before the outer App. Plugin scripts, external dependency installers and
contributed tools are not executed during collection. Host settings remain
outside the signed bundle.

The bundled `computer-use` package contains a native stdio MCP registration and
the `observe-act-verify` Skill. The vendor's `SkyComputerUseClient mcp` remains an
external dependency. Bind its actual executable in host settings when needed;
installation and caller compatibility remain vendor-owned. A catalog listing
does not establish working GUI observation or actions.

The App and its embedded CLI load package directories from
`Contents/Resources/Plugins` in their own App bundle. Discovery is tied to the
running executable, not the working directory, PATH, or a plugin-supplied path.
A standalone CLI has no implicit bundled packages. A missing resource directory
means an empty inventory.

Each immediate, non-hidden child is a package directory with the same
`computer-mcp-plugin.toml` and resource validation used by local packages.
Inventory scanning is limited to 128 entries. Links, non-directory entries,
unreadable directories and an exceeded inventory bound reject that inventory;
the host reports an issue and continues serving unrelated registrations.
Malformed package declarations are reported individually. Duplicate plugin IDs
exclude every bundled candidate with that ID; directory ordering never chooses
a winner. A bundled source label does not authenticate a GitHub publisher.

`plugins list` and `plugins show` include `bundled` descriptions and
`effective_settings`, which merge conservative host defaults with saved
overrides. `state` remains the exact database snapshot, and reads do not create
installation records, grant permissions, or advance its revision. A previously
unconfigured bundled plugin appears disabled and can be edited or enabled using
the same owner-only management operations as an installed plugin. New MCP
components start with an empty tool whitelist; raw CLI arguments remain denied.

The App's Sources section identifies the bundled version and path. Its settings
editor includes the bundled components even before the first saved settings.
Use the selected plugin's `effective_settings` object when preparing a CLI
configuration change. Saving or enabling writes host state in the database,
never the App bundle. An explicitly selected user installation overrides the
bundled source. **Use bundled fallback** or `plugins select ID --bundled`
restores the bundled choice without changing saved grants or enabled state.

## App Management

Open **Plugins** in the App's Configure group to register a local package,
inspect its recorded sources, select a source, enable or disable contributions,
or remove a development registration. New identities start disabled. Removing
a local registration retains its package files and host settings.

**Install archive** accepts a local ZIP/TAR/gzip file and an expected plugin ID,
version and SHA-256 from a trusted source. It installs a new identity or selects
an updated version while retaining earlier records. **Use this source** selects
a retained version for rollback. **Uninstall** confirms removal of one artifact
record and only its owned files; development checkouts, other versions and host
settings remain. **Retry file recovery** reports remaining cleanup issues, which
stay visible even when the affected identity has no installed source.

The installation sheet retains its opening revision and disables duplicate
submissions while saving. A committed operation with cleanup warnings succeeds
and displays those warnings; it is not automatically repeated. Archive digest
verification does not establish an official publisher or artifact signature.

**Edit settings** provides component switches, MCP gateway/reexport exposure,
prefix and registration overrides, explicit tool whitelists or all current and
future tools, raw CLI argument permission, and external executable bindings.
An empty whitelist permits no tools. Existing host risk assignments are retained
when editing these fields. Enabling a package does not change caller profiles.

The editor saves against the revision at which it was opened. If the CLI or
another window changes plugin state, saving fails and refreshes the list; the
draft is not automatically retried or rebased. Reopen the editor to review the
current choices. Failed refreshes retain the displayed list and show an error.

The App and management CLI use the same host transactions. Source and dependency
diagnostics describe registration readiness, not verified connection health.
Selecting bundled fallback with no matching bundled package leaves the
contributions unavailable.

## Official Search

Use **Search official plugins** in the App's Plugins page or
`computer-mcp plugins search [query] [--kind mcp|cli|skills]`. Both call the same
App-owned public GitHub discovery service. A search never installs a package,
runs its code, changes registrations, or grants access. Search is owner-only
management, not a remotely exposed Gateway tool.

The official publisher is GitHub organization `computer-mcp`, pinned by numeric
account ID `315005910`. Repository ownership must match that identity; manifest
claims do not confer official status. The service scans public repositories
in name order, skips archived or disabled repositories, resolves the default
branch to an immutable commit, and reads `computer-mcp-plugin.toml` at that
commit. Git blob hashes and a SHA-256 digest bind the returned declaration to
the metadata. This identifies declaration provenance, not a downloaded
artifact's contents or signature. In particular, GitHub Contents can return a
symlink target as file content; discovery does not validate an installable
archive or execute the declaration.

Each repository page checks at most 10 repositories. Query words match the
repository, plugin ID, name and description; `--kind` filters by contribution.
An empty filtered page is not the end when `next_page` is present. Use `--page`
to continue. Results include the submitted criteria, checked repository count,
fetch time, cache status, source IDs and commits, component IDs, and individual
repository issues. Invalid declarations do not hide valid neighboring entries.

The host caches up to eight pages in memory for 60 seconds. `--refresh` or
**Refresh page** bypasses that cache. Only complete successful page reads are
cached. Concurrent uncached searches receive an explicit busy error. GitHub
unavailability, HTTP permission failures, rate limits, malformed responses and
timeouts are errors, not successful empty results. The App retains previous
results with an error label; it does not present them as freshly fetched.
Search can be cancelled. Paging and refresh retain the submitted search criteria
even while a new query is being edited.

The network client uses a separate ephemeral session, with no host cookies,
credentials, authentication prompts, or inherited authorization headers. It
does not read GitHub CLI credentials. Requests stay on `https://api.github.com`;
redirects are refused and pagination URLs are validated, never followed as
arbitrary destinations. Each request is bounded to 8 seconds idle/10 seconds
total, a page to 25 seconds, metadata to 2 MiB, and the decoded declaration to
1 MiB. Both declared and actual decompressed response sizes are bounded.

CLI success is a snake-case `PluginCatalogSearchResult` JSON object, including
`publisher_id`, `checked_repositories`, `fetched_at`, and optional `next_page`.
`fetched_at` follows the control plane's numeric Foundation reference-date
encoding (seconds since 2001-01-01 UTC). Runtime failure is
`{"error":{"code":"plugin.catalog.rate_limited","message":"..."}}` with
nonzero exit status; an unavailable App uses `control.unavailable`. Parser
errors use the normal command usage diagnostics. No token or raw HTTP error
body is included. A fixture catalog proves positive discovery behavior but is
not proof of a published official package. Live read-only verification can be
run separately without touching the production App:

```sh
COMPUTER_MCP_LIVE_CATALOG_TEST=1 /usr/bin/swift test --filter testOfficialPluginSearchAgainstPublicGitHubFromIsolatedCLI
```

That test creates a temporary control socket and database, invokes the built
CLI from its temporary working directory, and removes only its own fixture.
It requires GitHub connectivity and available public API quota; it does not
publish a repository or substitute fixture data for a real response.

### Release Artifacts

The host release service resolves the selected repository's published release,
using GitHub's latest release or an explicit tag, and reads the declaration at
the fully qualified `refs/tags/` commit. This declaration can differ from the
default-branch declaration shown by search. Selection records include publisher,
repository, release and asset IDs, the commit and declaration hashes, filename,
size and artifact SHA-256. ZIP, TAR and gzip-compressed TAR assets must be
uploaded and have a valid GitHub SHA-256 digest within the archive size limit.
Unsupported asset types are omitted; invalid archive candidates produce issues.
Asset pages contain at most 100 entries and retain explicit continuation.

Installation revalidates repository ownership and release membership before
download and again before commit. It checks membership through the release's
asset listing, not the repository-wide asset endpoint. Metadata work has a
30-second deadline, including pagination. The downloaded archive and its raw
manifest bytes must match the selected artifact and release declaration.
Moved tags, changed assets, transferred repositories and stale host revisions
fail before registration commits. Host state retains the verified selection in
`source.github_release`; local archives have no such receipt. The receipt is
host-owned installation provenance, not a plugin claim, importable grant or
code signature.

Downloads request the fixed GitHub asset API endpoint. A direct HTTP 200 or up
to three explicit HTTP 302 redirects to
`https://release-assets.githubusercontent.com` are accepted. Redirect requests
use fresh headers; host credentials, cookies and signed redirect URLs are not
stored or reported. Transfers have a 120-second total deadline and 15-second
idle timeout. Binary content is streamed through a 64 KiB write buffer into a
private receipted staging file, bounded by the selected size and checked with
SHA-256. Length mismatches, content encodings, unsupported content types,
unexpected origins and authentication challenges fail explicitly. Cancellation
joins the writer before the caller closes the output or reclaims its directory.
No download or package inspection executes plugin code or installs external
dependencies.

In the App, open **Plugins → Search official plugins → Choose release archive**.
Leave the tag blank for the latest stable release, or enter an exact published
tag (including a prerelease). Choose a ZIP/TAR/gzip archive appropriate for the
Mac; the host validates the package's architecture and version compatibility.
The displayed release may differ from the repository's default-branch version.
Asset pages stay on the displayed tag. Failed refreshes keep prior results
visible but disable installation until a successful request.

**Download and install** uses the same transaction as local archive installation.
New identities start disabled; updates preserve host settings and earlier
versions. An open selection keeps its original configuration revision; after a
conflict, close and reopen it to review the current state. **Cancel installation**
waits for the download/worker and cleanup to finish. If the transaction already
committed, its successful result remains authoritative. Source details retain
the verified release tag, release/asset IDs, commit and digest.

The CLI workflow is `plugins search` → `plugins artifacts <owner/repo>
--repository-id <id>` → `plugins install-release <selection.json>
--expected-revision <revision>`. The selection file contains one complete entry
from the `artifacts` array (at most 256 KiB), with the returned snake-case keys.
The listing itself neither downloads bytes nor changes plugin state. Use `--tag`
for an exact published release and follow `next_page`, including empty pages.
Both metadata and installation revalidate the official repository identity.
Neither command retries a failed write. The owner socket call waits for the
bounded host operation: losing that connection does not prove cancellation or
rollback. Read `list`/`show` before retrying an operation with an unknown outcome.

## Management CLI

The `plugins` command family uses the App's owner-only control socket and its
existing database and audit stream. It does not write a second standalone
configuration. `list` and `show` return JSON with `state`, `contributions`,
`diagnostics`, `issues`, and optional `recovery_error`. `state.revision` is the revision required by each
mutation; it is global to plugin state, including when `show` filters one ID.

| Command | Operation |
| --- | --- |
| `plugins list` | Read recorded source selections, settings, origins and resolution diagnostics |
| `plugins show <id>` | Read one recorded plugin identity |
| `plugins doctor <id>` | Check source, declared host compatibility, dependencies and files, including disabled contributions; report unverified runtime checks explicitly |
| `plugins search [query] [--kind mcp\|cli\|skills] [--page <number>] [--refresh]` | Read official GitHub declarations with source identity, pagination and explicit failure states |
| `plugins artifacts <repository> --repository-id <id> [--tag <tag>] [--page <number>]` | Read a published release's exact installable archive selections and pagination |
| `plugins install-release <selection.json> --expected-revision <revision>` | Revalidate, download and install one selected official release archive |
| `plugins register <path> --expected-revision <revision>` | Register or explicitly refresh a local development directory; new identities start disabled |
| `plugins install <archive> --id <id> --version <version> --sha256 <digest> --expected-revision <revision>` | Verify and install/update a local archive; retain settings and previous versions |
| `plugins uninstall <record> --expected-revision <revision>` | Revoke an artifact and remove only matching owned files; retain settings and other versions |
| `plugins recover --expected-revision <revision>` | Retry ledger-owned file recovery without changing the configuration revision |
| `plugins configure <id> --settings-file <file> --expected-revision <revision>` | Replace that identity's host settings with a bounded JSON document |
| `plugins enable <id> --expected-revision <revision>` | Enable using existing host choices; unavailable sources remain diagnosed |
| `plugins disable <id> --expected-revision <revision>` | Disable contributions and retain source, grants and overrides |
| `plugins select <id> --installation-id <record> --expected-revision <revision>` | Select an existing installation record |
| `plugins select <id> --bundled --expected-revision <revision>` | Clear the override and select bundled fallback when available |
| `plugins remove <record> --expected-revision <revision>` | Withdraw a development installation reference, retaining source files and host settings |

All commands accept `--control-socket <path>` for an explicitly selected isolated
App instance. Without it they use the production App control socket. Paths passed
to `register` and `install` are resolved relative to the CLI caller's working directory before
being sent to the App. `remove` takes a record ID, never a filesystem deletion
target.

`install`, `uninstall`, and `recover` return the committed host snapshot as JSON.
Nonempty `issues` can accompany exit status zero: inspect them before retrying
cleanup, rather than repeating a successful installation. Runtime failures return
a JSON `error` with `code` and `message` and a nonzero exit status. Codes distinguish
`plugin.stale_revision`, `plugin.installation_busy`, `plugin.connected_clients`,
`plugin.worker_unavailable`, and `plugin.archive.<reason>` failures. Parser errors
use standard CLI usage diagnostics. If the control connection is lost, inspect
list/show before retrying a change whose outcome is unknown.

Settings JSON uses the model field names `enabled`, `mcp`, `cli`, `skills`, and
`dependencyExecutables`. MCP choices have `enabled`, `registrationID`, `exposure`,
`prefix`, `allowAnyTool`, `allowedTools`, `toolRisks`, `hostServices`, and `args`; CLI choices have
`enabled`, `registrationID`, and `allowAnyArgs`; Skill choices have `enabled` and
`registrationID`. Unknown fields fail. Omitted settings use the defaults described
above. `configure` replaces rather than merges settings: start from the current
`state.settings[<id>]` object to preserve other choices. The file is limited to
4 MiB and must not contain secrets.

For stdio MCP contributions, omitted or null `args` follows the package's default
arguments. An array replaces the complete argument list; `[]` explicitly passes
none. Values are passed as exact argv elements, including empty strings, spaces,
Unicode, and newlines, without shell interpretation. The host permits up to 1024
arguments and 256 KiB of argument text, with no NUL bytes. HTTP contributions
reject argument overrides. These settings survive updates and source selection;
they do not modify package files, executable bindings, or grants. In the App,
**Override process arguments** edits one argument per row. Leave it off to follow
package defaults. Store credential references using the integration's documented
secret mechanism, never as launch arguments.

`dependencyExecutables` maps declared dependency IDs to absolute user-owned
executable paths. Otherwise the host searches absolute entries in its own launch
`PATH` for the manifest's command names. This does not alter `PATH`, search a
shell's startup files, install a product, or establish interpreter/version/
connection health. Contributions and resolution diagnostics describe file and
configuration readiness, not a successful MCP handshake or tool invocation.

The host validates a proposed composition before committing its revision. Main
manifest loading and import validation also check the enabled plugin composition.
Conflicts leave the previous plugin snapshot intact. MCP grant references remain
valid for identities recorded in host settings when a contribution is disabled
or unavailable; such references do not create a runtime or authorize another
registration. Expanded registrations and this host reference context are not
serialized into the main TOML.

Registration changes require the gateway to have no connected, connecting or
cleaning-up clients. The listener temporarily pauses admission during a change and resumes
on success or failure. A busy gateway rejects the mutation without disconnecting
clients or interrupting their tasks. This control-plane check is separate from
downstream MCP catalog-change notifications. A successful settings commit is
configuration validation, not a claim that a downstream executable is healthy.

For an HTTP contribution, host `mcp.<component>.authentication` settings may
contain `endpoint` and `keychain_account`. The endpoint must exactly match the
package's URL; a package update cannot retarget a saved credential. The manifest
cannot declare this binding or contain the token. The App's MCP list and
`mcp credential` commands manage its Keychain value independently of package
versions. Disabling or uninstalling a package retains the user's credential.
See [HTTP credentials](Config.md#http-credentials).
