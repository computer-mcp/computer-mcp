# Security And Privacy

Computer MCP evaluates every tool call with the permission library before provider
dispatch. Profiles hold permissions, execution mode and sandbox settings. Verified
identity, managed limits, current profile state and the exact invocation determine
authority; tool names, client labels and risk annotations cannot supply it.

## Authority boundaries

- Project access is `read`, `write` or `deny`, independently of its network setting.
- Screen, Desktop control, Machine information, Unified logs, Skills and Local
  network are separate permissions. Files and Folders are per category; Plugin
  and MCP server permissions are per object.
- New principals receive Machine information and Skills. Missing permissions are
  requestable; explicit denies and managed exclusions refuse without a request.
- Tool listings include declared requirements. Project discovery without Project
  permission exposes only ID, display name and access status, never root paths.
- `local-admin` remains local-only. Unknown tools, routes and ownership claims
  fail closed. Every file operation resolves and rechecks its authorized path.
- Full access changes execution mode only. It does not grant Project, Screen or
  any other permission. The profile must allow it and the owner must consent
  locally. The static Shell facility stays off by default.

Downstream registrations own exact tool selection and classification. Aliases,
reexports and generic calls resolve to the same server/tool and plugin origin.
MCP `read` permits host-classified reads; `all` permits the selected surface.
Plugin contributions additionally require their owning Plugin permission. Remote
annotations cannot lower the host classification. Cached tool identity must be
resolved before admission; discovery that starts a process requires its own
admitted execution context.

## Principals, requests and consent

Verified local peer credentials, a registered tunnel bridge or an authenticated
HTTP credential establish the principal. A connection ID is tracing information.
Clients sharing a credential share principal permissions; their connections have
separate live consent scopes. Tool arguments cannot replace the verified identity.

A missing permission returns `permission.required` and a durable pending request.
Only the local owner answers it, using the reviewed control revision. **Only this
time** binds to the initiating principal, exact canonical invocation, requirement
set and retry chain. **Always** changes the profile shared by existing and future
clients. **Deny** rejects the request. Requests expire after one day. Answering
never dispatches the operation; the initiating caller explicitly retries, and
changed arguments, routes, principals or stale authority cannot reuse an answer.
`policy.probe` previews without consuming one-time authority.

The App gateway and standalone HTTP gateway bind admitted MCP sessions to a
host-created live authority object. Full access consent defaults to This Session;
Always Allow this Client is a separate local choice bound to the verified
principal, caller and reviewed profile. Consent never widens the permission table.
A changed reviewed profile or permission environment permanently invalidates saved
consent. Session limits may only narrow the profile and managed ceilings.
Disconnecting ends connection-scoped authority; saved consent and its standing
execution authority survive disconnect and reconnect only while their ledger
binding remains valid. Reconnect cannot replace a missing or invalidated binding:
fresh local owner approval is required. Restoring previous settings cannot revive
retired authority. Profile/trust revocation and retention apply even when no
connection is active.

The durable permission ledger reconciles profile edits, requests, running work and
result access. Revocation terminates affected executions and proxy streams. A
one-time execution retains authorized input, output and cancellation access for
its lifetime; it does not become a standing grant or authorize another launch.
The external Keychain epoch detects restored permission databases: transient
answers are discarded and standing authority stays suspended until local owner
confirmation. Unknown execution outcomes are evidence, never permission to replay.

## Execution admission

A launch requires an installed `PreparedExecutionContext`; there is no implicit
Full access default. The compiler uses the ledger's path decisions, effective
network and resource limits. Unsupported enforcement is refused before effects.
General sandboxed writes need a verified worktree/private Git context; plugin and
server launches need their project-bound context. These contexts remain future
integration work. Darwin prepared arbitrary Full access execution also remains
unavailable where durable ownership cannot be proved. Authorized sandboxed read
helpers can run for either principal mode. Trusted host administration uses an
explicit administrative execution scope, never a principal's implicit fallback.

## Transport And Secrets

The remote paths are:

```text
ChatGPT -> OpenAI Secure MCP Tunnel -> local stdio bridge -> private user socket
Remote MCP client -> Cloudflare named tunnel -> bearer-authenticated loopback HTTP
```

OpenAI and Cloudflare tokens and the Computer MCP Access Token are stored in
the macOS Data Protection Keychain. Every operation sets
`kSecUseDataProtectionKeychain`, the provisioned private access group
`<TeamID>.<BundleID>`, and an environment-specific service ending in
`.secrets`. New items use `AfterFirstUnlockThisDeviceOnly` so desired tunnels
can restore in the logged-in user context without an interactive biometric or
password policy. The production Development and Developer ID builds use the
same Team ID and Bundle ID and therefore share the same private access group.
This group-based Data Protection Keychain contract does not attach credentials
to an individual App binary, so routine builds with the stable signed identity
do not require an owner prompt. The opt-in development App uses a different
Bundle ID, group, service, and Application Support directory.

The App fails closed when its signed Team metadata, environment, Bundle ID,
embedded provisioning profile, or private Keychain entitlement do not agree.
Ad-hoc artifacts therefore validate packaging in CI but cannot open the live
App control plane or its secrets. Data Protection Keychain with the provisioned
private access group is the sole App secret store.

The App materializes the Cloudflare token only as a temporary `0600` file for
`cloudflared`. Consumer-owned Cloudflare Access service tokens are not stored
by Computer MCP. Downstream CLI credentials, provider tokens, and Codex login
state stay in their existing local stores. Secrets are not copied into TOML,
audit records, examples, exports, or App logs.

The private socket validates current-user ownership and peer credentials. The
App is the sole service owner and cleans up its socket and owned processes on
normal termination.

Cloudflare release mode uses authenticated loopback HTTP and a remotely-managed
named tunnel. Quick Tunnel and anonymous HTTP are development Validation Test Cases
only. Header-capable consumers use the Computer MCP Access Token; replacing it
through the owner control plane immediately updates the running listener.

OAuth is enabled per Cloudflare connection and defaults off. The gateway is both
the protected resource and authorization server on that connection's public HTTPS
origin. Its OAuth routes require the public Host; loopback Host requests cannot
use them. Public clients identify through HTTPS Client ID Metadata Documents
(CIMD), with exact hosts on the owner-managed allowlist (default `claude.ai` and
`claude.com`). The credential-free fetch is bounded to 64 KiB and eight seconds,
does not follow redirects, and pins a checked public numeric destination while
URLSession performs TLS validation. Private, loopback and special-use destination
addresses are refused. The document must bind its own URL and the exact redirect
URI; registered loopback redirect ports are ignored during matching.

The browser displays client and redirect hosts and a six-character pairing code.
It can only poll a separate opaque status handle. Approval and denial require the
local App control plane or owner CLI. Pairing expires after ten minutes. Approval
creates a grant for the explicitly selected remote profile.
Its principal is `oauth:<grant ID>` and its caller is `cloudflare-tunnel`.
OAuth authenticates that identity; profile, project and local Full access
consent still apply. Client secrets and Dynamic Client Registration are not part
of this authorization surface.

Authorization codes and tokens contain 256 random bits; GRDB stores their SHA-256
digests and bindings, never their plaintext. Codes expire after 60 seconds and
bind client ID, exact redirect URI, S256 PKCE and resource. Access tokens last one
hour and bind `https://<hostname>/mcp`. Refresh tokens rotate on every use and
expire after 30 idle days. Reuse of a rotated refresh token revokes its grant.
Owner grant revocation invalidates all of its tokens immediately. RFC 7009 access
token revocation invalidates that token; refresh token revocation invalidates the
grant. Grant revocation from Client access, the owner CLI, refresh-token revocation
or refresh-token reuse also ends the grant's active gateway sessions and open
streams. Audit records `oauth.grant_revoked` and completion as
`oauth.sessions_ended`, bound to the grant principal. OAuth credentials never enter
Keychain. In-flight OAuth admissions retain principal revocation state until they
drain, so revocation during idle cleanup or initialization cannot publish a new
session. The service keeps one lock-protected Access Token digest per Cloudflare
profile across listener startup and shutdown; rotation and rollback publish the
digest synchronously after the corresponding Keychain write. Saves and deletion
serialize each profile's credential mutation from the initial secret reads
through activation and rollback.

HTTP admission precedes body accumulation. With OAuth enabled, `/mcp`
authentication pauses channel reads until the credential is checked; failure
returns 401 with the resource metadata challenge and closes the connection.
Without enabled OAuth, synchronous Bearer authentication runs at the request
head. OAuth routes consume their address rate allowance at the head. Headers are
limited to 16 KiB, OAuth bodies to 16 KiB and authenticated MCP bodies to 8 MiB;
both declared lengths and arriving bytes are checked, with 413 and close on
overflow. A request must complete its body within 15 seconds of its head (also
15 seconds to supply an initial head), or receive 408 and close. Each listener
admits at most 32 connections awaiting authentication; excess connections receive
503 and close. Public OAuth connections retain this reservation until MCP
authentication or disconnect, with the same 15-second idle deadline.

Each tunnel admits at most 128 pending or approved pairings, including at most
three per tunnel-reported client address. Admission is reserved before CIMD
identification: at most one fetch per address and four per tunnel may run at
once. Capacity rejection returns 429 `temporarily_unavailable` without fetching;
failure and cancellation release the reservation.

The token endpoint returns 400 `invalid_request` for missing, empty or duplicate
parameters and unsupported content types, `unsupported_grant_type` for an unknown
grant type, `invalid_scope` for scopes other than `mcp`, and `invalid_grant` for
invalid, expired, reused or mismatched codes, refresh tokens or their bindings
(client, redirect, PKCE or resource). Unsupported client authentication returns
401 `invalid_client`, with a `WWW-Authenticate` challenge matching an attempted
Authorization scheme (`Basic` for Basic requests). After validating a registered
callback, authorization errors redirect with `unsupported_response_type` or
`invalid_scope`. Appended callback parameters use percent encoding with only RFC
3986 unreserved characters left literal, preserving the registered URI's existing query.

OAuth endpoints and failed Bearer requests use address token buckets, with grant
buckets for grant-bound operations. OAuth audit records requests, local decisions,
expiry, token issuance, refresh, token and grant revocation, and refresh reuse.
Failed Bearer audit is limited to one summary event per minute per listener.
No credential values enter these events. Cloudflare Verified requires an allowed
tool audit event from the current Access Token or a live OAuth grant, bound to
that credential's profile and the current tunnel start. OAuth protocol events
cannot establish Verified; replacement or revocation removes the affected
credential's verification evidence.

## Local Client Configuration

Local registration writes the generated server command and arguments only.
Codex and Claude Code changes go through their own CLIs with a configuration
location bound at preview. Codex is queried with `mcp get --json`; Claude Code's
user-scope file is read directly because its health-query commands start
servers. Claude Desktop's configuration is changed only while its App is
closed. No manifest contents, tokens or credential values are registered.

The complete named entry is retained privately for comparison and Claude Code
recovery. Other fields in a JSON file are parsed to preserve the file and are
never retained in a plan. Displayable entries contain only type, command or URL
origin, argument count, and environment/header names. Argument values, URL
userinfo/path/query/fragment, environment/header values, client stdout/stderr
and `add-json` recovery payloads are never printed, logged or returned in errors.

An advisory writer lock serializes the App and CLI, and apply rechecks the
private plan's fingerprint. Other programs retain their client's own write
protections. Desktop rejects symlinks and nonregular files, compares bytes,
inode, mode and size immediately before rename, and uses exclusive rename to
create a missing file only inside an existing support directory. Temporary
files start at `0600` before content is written; replacement preserves the
existing mode and new files stay `0600`. Another program writing an existing
Desktop file after the final check can lose its update, so plans ask users to
close other configuration editors.

Client executables are selected from an explicit path or host search directories
and `~/.local/bin`. Their exact environment contains only basic user/locale/temp
variables, the bound client configuration variable and a constructed PATH.
Timeout kills the process group; recovery waits for confirmed exit. An uncertain
exit stops the sequence and is never reported as success. Unsupported Claude
Code entries cannot be replaced because they cannot be restored faithfully.

## TCC And Computer Use

Screen Recording and Accessibility permissions belong to the signed App.
Remote MCP calls never trigger a permission prompt. The App reports current
status; its local **Request Access** action invokes the public TCC request API,
opens the matching Privacy & Security page, anchors a noninteractive coach to
the System Settings window when its public window metadata is available, and
polls until the state changes. The coach omits its arrow when the window cannot
be located. Denied capabilities fail deterministically. ChatGPT's separate
**Lock Screen Operations** setting only
allows ChatGPT's own Computer Use principal to operate while the Mac is
locked; it does not grant or transfer TCC permissions to `Computer MCP.app`.
Application-specific automation remains in `apple-cli-mcp`.

Computer Use cannot perform Accessibility actions on the Computer MCP host
process. This prevents a remote caller from turning generic UI automation into
an implicit App administration channel and avoids re-entering AppKit menu
presentation from a non-main executor. App administration uses the local
SwiftUI adapter or owner-only `computer-mcp` control CLI.

## Plugin execution

The host authorizes plugin invocations through caller identity, profile and
registered project. Plugin runtime permissions and vendor configuration belong
to the plugin; see the [Codex plugin](https://github.com/computer-mcp/plugin-codex) for its execution model.

Callbacks into host tools require current permissions and a live call record
bound to permission-ledger admission. A plugin's native approval does not answer a
host permission request. Raw arguments and output stay out of redacted audit;
canonical invocation digests bind retries and private host-action validation.

## Stable Denials And Audit Decisions

Security-policy refusals return stable bracketed codes and are stored with the
GRDB audit decision `denied`, not the generic execution decision `failed`.
Representative codes include:

- `policy.project_denied` for traversal, symlink escape, and cross-project
  access;
- `permission.required` for a missing requestable permission;
- explicit permission and managed-policy denials for non-requestable access;
- `mcp.tool_not_approved` for downstream catalog drift.

Malformed arguments and provider/runtime failures remain `failed`. Acceptance
tests must correlate the client-visible code, Gateway request ID, and exact
audit row rather than inferring a denial from message text alone.

## Persistence And Logging

GRDB stores projects, profiles, provider health, manifest revisions,
permission requests, execution authority, OAuth requests/grants and credential digests, bounded MCP execution receipts and redacted audit metadata. The Data Protection Keychain
stores transport keys and access token values.
App logs are JSONL, mode `0600`, rotated, bounded, and redact secret-like
fields.

Execution receipts retain bounded downstream results for reconnect queries;
these can contain sensitive command output, file contents or provider data.
Their local storage is private user data, not a redacted audit log. Output
expires after 24 hours and is subject to per-result and aggregate budgets;
deduplication metadata remains when output expires. See the
[request result contract](../Reference/Tools.md#mcprequestsread).

## Main Risks

- A registered CLI or downstream MCP provider can act with its own local
  credentials.
- Full access programs, where supported, run with the user's operating-system authority.
- Computer Use can operate visible UI after local TCC grants.
- A leaked remote bearer or overly broad caller/profile grant can expose the
  configured remote surface.
- Provider output may itself contain secrets despite audit redaction.

Grant only the permissions a principal needs, keep Shell disabled unless needed,
review tool requirements and registration selection, and remove sensitive data
from diagnostics before sharing it.

## Host tool operations

File and structured-data writes walk path components through directory descriptors
with `O_NOFOLLOW`, checking protected names and refusing observed symlinks and
existing regular files with multiple hard links. Directory entry creation,
publication, rename and unlink check parent identity and containment before and
after successful syscalls, with an ancestor walk to the pinned project root.
Failed post-checks attempt rollback;
entry removal and rename during rollback compare device and inode immediately
before the syscall. An observed mismatch leaves the entry in place; rollback
failures are reported.
Metadata changes (`chmod`, `touch`, xattr removal) record mode, access/modification
times and affected xattr values on the opened inode. They recheck the parent chain,
path identity and link count afterward, restoring those values through the same
descriptor on failure. Checks do not lock out concurrent writers or detect changes
reversed between observations or made after the last check. Rollback is not an
atomic isolation guarantee: replacement can race the final identity comparison
and syscall, and restoring recorded metadata can overwrite intervening changes.

The hard-link rule protects existing files from writes through pre-existing aliases
to files outside the project. A file created by the operation can acquire a
concurrent hard link while it is being written. Creating that link outside the
project requires a process that can already create files there; a sandboxed
principal cannot do so, and a process with that access could read the archive
directly. After a created file is complete, `fstat` checks its descriptor's link
count. If multiple links persist, the operation fails and cleanup removes only
entries this operation created. This final check cannot retract bytes already
exposed through a concurrent link or detect a link removed before
the check.

Generated files are staged in the target directory before publication. macOS
copies use `fcopyfile(COPYFILE_ALL)` between anchored descriptors to preserve data,
xattrs, resource forks, ACLs, mode and access/modification times; source checks precede publication,
and failed copies clean staging with identity checks. Moves preserve metadata
through exclusive, no-follow rename on the same volume. Cross-volume moves fail
before changing either entry; callers must copy and then delete the source.

The neutral and POSIX targets also build on glibc Linux. Tool guards use these
platform equivalents; macOS-only platform services remain in `PlatformDarwin`.

| Operation | macOS | glibc Linux |
| --- | --- | --- |
| Component traversal and entry checks | `openat(O_NOFOLLOW)`, `fstatat(AT_SYMLINK_NOFOLLOW)`, `unlinkat(AT_REMOVEDIR)` | Same POSIX APIs and flags, walking one component at a time; `O_NOFOLLOW_ANY` is not needed |
| Exclusive publication and rollback | `renameatx_np(RENAME_EXCL \| RENAME_NOFOLLOW_ANY)` | `renameat2(RENAME_NOREPLACE)` through `CSystemPOSIX`; both names are single components of pinned directories and the leaf is not followed. Unsupported kernels or filesystems fail without a replacement fallback |
| Cleanup identity handles | Reopen with `O_EVTONLY` and no-follow flags; verify device and inode (and, off APFS, the retained descriptor) before changing directory permissions | Reopen with `O_PATH` and no-follow flags; compare the `name_to_handle_at` file handle through the handle and verify identity before restoring directory permissions through `/proc/self/fd/<fd>` |
| Retained staging path in errors | `fcntl(F_GETPATH)` | `readlink(/proc/self/fd/<fd>)`, used only for diagnostics; the original path is reported if procfs is unavailable |
| File data and metadata copy | `fcopyfile(COPYFILE_ALL / COPYFILE_METADATA)` | Descriptor reads/writes plus `flistxattr`, `fgetxattr`, `fsetxattr`, `fremovexattr`, `fchmod` and `futimens`; xattr signatures are bridged through C |
| Metadata rollback and file identity timestamps | Darwin descriptor xattr signatures and `stat.st_atimespec/st_mtimespec/st_ctimespec` | Linux descriptor xattr signatures and `stat.st_atim/st_mtim/st_ctim`, preserving nanosecond precision |
| Child working directory | `posix_spawn_file_actions_addfchdir_np`, `POSIX_SPAWN_CLOEXEC_DEFAULT` | The same fchdir action, available in glibc 2.29+, through C; host descriptors use `O_CLOEXEC` |
| Archive metadata and extraction options | BSD tar's `--format=mtree` conversion supplies exact times; extraction disables BSD flags with `--no-fflags` | GNU tar's `--numeric-owner --full-time -tvf` supplies times; extraction uses the shared no-owner, no-permissions, no-ACL and no-xattr options |

Linux copies preserve data, mode, access/modification times and visible xattrs,
including POSIX access/default ACLs. Destination-only inherited xattrs are removed;
listed attributes that cannot be read, written or removed fail the copy before
publication. A source filesystem without xattr support has no xattrs to copy.
Ownership stays with the created destination. Linux has no native macOS resource
fork, creation-time setter or BSD `st_flags` copy in this path. `getattrlist`/`fgetattrlist` and
Darwin resource-fork APIs belong to macOS-only services and are not called by the
Linux tool guards. The application-level concurrency limits above still apply.

SQLite uses a private empty home and `-init /dev/null -safe`, and CLI help returns
registered metadata without executing commands. Host Git operations isolate
system/global configuration, refuse repository configuration includes and disable
repository programs; `git.commit` commits only its
explicit `paths`, preserving other staged changes.

Path checks use `openat`/`fstatat`, `O_NOFOLLOW`, and directory descriptors.
Every `.git` path component is protected after Unicode normalization and
case-insensitive comparison. Writes, creation, moves, renames, deletion and archive
extraction refuse a target with such a component; moves and renames also refuse
such a source. This covers `.git` directories, gitfiles and paths beneath them.
When project file access is created, the host checks the Git layout once through
its isolated Git invocation: `rev-parse --git-dir --git-common-dir`, with
`core.worktree` resolved relative to the Git directory if set. All in-process
writes in the project fail with a layout error if the root's `.git` entry is a
symbolic link, or if the resolved Git directory or common directory is inside the
project at a path without a `.git` component. The error identifies the layout and
requires a standard Git layout for these tools. Git directories outside the
project cannot be reached by project writes; worktrees whose gitfile points
outside the project support ordinary writes while the `.git` name stays protected.
If the host cannot verify the Git layout, in-process writes fail.
Git configuration paths are also protected. Each host Git operation inspects local
configuration and refuses `include` or `includeIf` entries before running,
including entries added by the owner since the preceding call.
Recursive operations validate each member. Archive extraction lists once and
rejects absolute paths, `..`, Git metadata, links and special files before one
extraction in a fresh staging directory inside the destination. Tar starts with
`posix_spawn_file_actions_addfchdir_np` on its no-follow directory descriptor,
reads the archive on standard input, and streams contents to a host-opened
descriptor. The host creates entries from the validated relative names, checking
sizes and recording each entry's identity from its anchored descriptor
immediately after creation. The extracted tree must match
the listing's paths and types, including implicit parents, and pass identity and
link checks before files are published with anchored exclusive renames.
A separate read-only metadata pass supplies each member's modification time,
including nanoseconds. File times are restored through checked descriptors.
Staging and destination directories are created with owner read, write and search
permission so children can be written. Explicit directory members receive their
archive modes and modification times through checked descriptors after publication
and staging cleanup, deepest first. An existing destination keeps its own mode,
access time and modification time; a `.` member supplies destination metadata only
when extraction creates that directory.
Cleanup removes an entry only when its device and inode match a creation record
and the inode is provably the same one. APFS never reuses inode numbers within a
volume, so there the device and inode suffice; on Linux the kernel file handle
from `name_to_handle_at`, which encodes the inode generation, must match as well.
Writing descriptors close when the operation finishes using them. On other
filesystems, and Linux filesystems that cannot export handles, the operation
instead keeps a close-on-exec descriptor to each created entry, so its inode
cannot be reused while the operation runs. Each file operation keeps at most 64
such descriptors and reserves 16 additional slots plus one per retained
directory, releasing the reserve for cleanup, which holds one descriptor per
directory level. At the limit, creation stops, staging is cleaned and the error
names the 64-descriptor limit. Failure to read identity or allocate the reserve
also fails the operation. Processes that can write the directories an operation
works in are trusted not to race it: such a process can replace a new directory
or symbolic link between its creation and its first descriptor, and cleanup then
treats the replacement as created by the operation, restoring owner access to it
and removing it when empty.
Unknown entries are preserved without
descending into foreign directories. The staging directory is retained and named
in the error if cleanup cannot remove it. Earlier published entries remain if a
later publication fails. `file.trash` refuses the project root, recursively checks
members for protected paths and unsafe types, and allows multiply linked regular
files because moving entries does not write file content. The platform Trash call
uses a path, with no descriptor-based post-check or rollback.
Git revisions are resolved to object IDs before use in fixed argument shapes;
`--literal-pathspecs` applies to pathspec commands; `check-ignore` receives literal
paths after `--`, without that option;
merge checks reject assigned filter attributes in the working tree or either
commit. These boundaries do not change permission requirements.
