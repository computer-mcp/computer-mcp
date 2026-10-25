# ``ComputerMCPGateway``

Build a deterministic, profile-bound MCP gateway for macOS.

## Overview

`ComputerMCPGateway` is the internal gateway runtime used by `Computer MCP.app`
and the embedded `computer-mcp` CLI. It is not a supported external Swift SDK.
Other internal targets supply execution, administration, transport, and platform
services. Together they provide:

- MCP Swift SDK server and client integration;
- a private current-user Unix socket and stdio bridge;
- registered projects and static capability profiles;
- policy, single-use operation tickets, and redacted audit persistence;
- bounded Builtin, Skill, CLI, Shell, process, downstream MCP, and Computer Use
  execution planes;
- Codex execution through an independent standard MCP adapter plugin;
- independent App-managed OpenAI and Cloudflare transport profiles and Keychain
  credentials;
- standalone stdio and HTTP development modes.

The runtime does not plan, select tools, infer grants, or rewrite provider
semantics.

## App Boundary

`Computer MCP.app` owns the service lifecycle and hosts the gateway behind its
private socket. `computer-mcp bridge` is a transport adapter; it does not start
a second gateway. Project bookmarks and secrets are App-managed state and do
not belong in TOML.

Tunnel profiles expose explicit capabilities only. Generic CLI execution,
process spawning, and Full Shell remain off by default; only
`chatgpt-operate` can receive them through an explicit local opt-in.

### Gateway Runtime

- ``GatewayToolRegistry``
- ``MCPRuntimeAdapter``

### MCP and OpenAI Secure MCP Tunnel

`ComputerMCPTunnels` owns tunnel launch planning, supervision, transport values
and the `HTTPOriginLifecycle` contract. `ComputerMCPControlPlane` constructs the
Cloudflare HTTP origin and audits gateway profiles. `DownstreamMCPClient` belongs
to `ComputerMCPDownstream`; its gateway implementation is ``MCPProxyClient``.
`ChatGPTProfileAuditor` belongs to `ComputerMCPControlPlane`.

The following types belong to `ComputerMCPTunnels`:

- `OpenAITunnelLauncher`
- `OpenAITunnelInvocation`
- `OpenAITunnelPlan`
- `OpenAITunnelConfiguration`
- `OpenAITunnelSupervisor`
- `OpenAITunnelStatus`
- `OpenAITunnelDoctorReport`
- `OpenAITunnelLogPage`
- `ChatGPTProfileAudit`
- `ChatGPTProfileAuditError`
- `OpenAITunnelLauncherError`

### Reverse Codex Integration

`ComputerMCPControlPlane` owns the independent adapter's installation workflow:

- `ClientRegistrationService`
- `ClientRegistrationPlan`
- `ClientRegistrationDisplayPlan`
- `ClientRegistrationResult`

## Host tool operation boundaries

File and structured-data writes walk directory handles with `O_NOFOLLOW` and reject
observed symlinks and existing regular files with multiple hard links. Entry
creation, publication, rename and unlink recheck parent identity and containment
before and after successful syscalls. On failed post-checks rollback compares device and inode
before removing or renaming an entry; an observed mismatch leaves it in place and
reports an error. `chmod`, `touch` and xattr removal record mode, access/modification
times and affected xattrs before mutation; they recheck the parent chain, path
identity and link count afterward, restoring recorded values through the same
descriptor on failure. These checks do not lock out concurrent processes, detect
changes reversed between checks, or cover changes after the last check. A
replacement can race an identity comparison and syscall; restoring metadata can
overwrite intervening metadata changes. Rollback failures are reported.

The hard-link rule protects existing files from writes through pre-existing aliases
to files outside the project. A file created by the operation can acquire a
concurrent hard link while it is being written. Creating that link outside the
project requires a process that can already create files there; a sandboxed
principal cannot do so, and a process with that access could read the archive
directly. After a created file is complete, `fstat` checks its descriptor's link
count. Persistent multiple links fail the operation; cleanup removes only entries
matching their recorded device and inode. The final check cannot retract bytes
already exposed through a concurrent link or detect a link removed before the
check.

Mutation targets and move sources refuse `.git` components after Unicode
normalization and case-insensitive comparison. At file-access creation, an
isolated Git layout check refuses all project writes if the root's `.git` is a
symlink or an in-project Git directory or common directory has no `.git` component
in its project-relative path. Gitfiles pointing outside the project allow ordinary
writes while `.git` remains protected. Git configuration paths are protected.

Generated files are staged before publication. macOS copies use anchored
`fcopyfile(COPYFILE_ALL)` to preserve data, xattrs, resource forks, ACLs, mode and
times, check the source again and clean staging with identity checks. glibc Linux
copies use descriptor reads/writes, `fchmod`, `futimens` and descriptor xattr calls
to preserve data, mode, nanosecond access/modification times and visible xattrs,
including POSIX ACLs; destination-only inherited xattrs are removed. Attribute
copy failures stop publication. Ownership remains with the created destination;
macOS resource forks, creation times and BSD flags have no Linux copy path.
Moves use
exclusive no-follow rename on one volume; cross-volume moves fail and callers must
copy and then delete the source. Linux uses `renameat2(RENAME_NOREPLACE)` through
the POSIX C bridge and fails if atomic exclusive rename is unsupported. Directory
components use `O_NOFOLLOW` individually. Archive extraction validates one listing for
paths and types, refusing absolute paths, `..`, Git metadata, links and special
files. Tar starts through `posix_spawn_file_actions_addfchdir_np` on the staging
directory descriptor (glibc 2.29+ on Linux), reads the archive on standard input and streams contents to
a host-opened descriptor. The host creates relative entries, records device and
inode at creation, compares the tree with the listing (including implicit
parents), checks sizes, identities and links, and publishes files with anchored
exclusive renames. A separate read-only metadata pass supplies exact member
modification times, restored through checked descriptors. Listing, metadata and
contents use the same selected archive reader.
On Linux tar formats use GNU tar with explicit compression options for standard
input; ZIP formats require a registered `bsdtar`. Missing archive or SQLite CLI
bindings fail as unavailable before executing those utilities or creating destinations.
Staging and destination
directories are created with owner read, write and search permission. Directory
archive modes and modification times are restored through checked descriptors,
deepest first after publication and staging cleanup. An existing destination
keeps its own mode, access time and modification time. An explicit `.` member
supplies destination metadata only when extraction creates that directory.
Created inodes stay pinned by close-on-exec descriptors until the file operation
ends, preventing inode reuse from assigning cleanup authority to a foreign entry.
Cleanup removes only recorded inodes, preserves foreign
entries without recursing into them, and retains staging with an error naming
its path. Earlier published entries remain after a later failure. `file.trash`
refuses the project root and checks every member first; multiply linked regular
files are allowed. Its platform path-based move to Trash has no descriptor-based
post-check or rollback.

SQLite uses a private
empty home and `-init /dev/null -safe`, and CLI help returns registered metadata
without executing commands. Host Git operations isolate system/global
configuration, refuse local `include` and `includeIf` entries on every operation,
and disable repository
programs; `git.commit` commits only its
explicit `paths`, preserving other staged changes.

Downloads stream into host-opened descriptors and recheck the destination before
publication. Recursive operations apply the same path
checks to each member. Delivery refuses merges when attributes assign filters.
These operation checks apply within each tool's existing authorization policy.
