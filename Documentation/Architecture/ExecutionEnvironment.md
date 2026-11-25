# Execution Environment

The reusable execution components have no MCP or permission-store dependencies.
The caller authorizes the operation, provides canonical resolved paths and an
execution ID, and retains ownership through the complete process lifetime.
`ExecutionLauncher` in
`ComputerMCPProcess` constructs the child environment and calls an injected
`ExecutionPlatform`. Every host subprocess uses this entry point, including shell
sessions, registered processes, CLI and host commands, downstream MCP supervisors,
plugin archive workers and Cloudflare tunnels. The macOS composition root supplies the
Darwin backend; neutral modules never construct it. An authorized execution context
is required for every principal shell, process and CLI launch.

## Permission configuration

`GatewaySandboxCompiler` composes the durable permission ledger with neutral
sandbox and egress values. The ledger selects every read boundary through its
path resolver and saves the resulting evidence on the invocation. Project
precedence, projected nested projects, Files and Folders, developer locations,
directory-only ancestors and host-data exclusions share the host-tool resolver.
A complete classified path environment is required. The host supplies canonical
working paths and private scratch storage. Sandbox project programs require a
current host-worktree identity and private Git context. Full access project
programs run unconfined after permission admission and local consent. Plugin and
local stdio launches follow the launcher boundary below.

Screen opens capture and Desktop control opens accessibility independently.
Egress uses the effective project network and managed ceilings; a scoped Local
network grant opens only its named host. Direct Apple events and sandbox
extensions remain closed. `GatewayPathAccess` revalidates host file use against
durable invocation evidence. File mutation keeps its descriptor and inode guards
and checks permissions before and after effects, including each recursive entry.
The live gateway installs these services at the permission admission boundary.

## Durable execution authority

`ExecutionRevocationCoordinator` reserves a logical execution in the permission
store before a launch. `PreparedExecutionContext` supplies its compiled mode,
environment, complete authorization basis and limits through a neutral Process
protocol. Once installed, provider risk classifications cannot widen that mode.
Blocking command adapters and detached lifecycle tasks carry the same context;
stdin, retained-result and cancellation operations revalidate durable authority.
A continuation context permits access to existing work but cannot start programs.
The caller closes launch admission after its operation, including failure paths.
Child programs share the reservation; finishing it never restores a consumed retry.

The bootstrap records kernel ownership before releasing the target. An independent
ownership journal survives restoring a permission database backup. Keep that
journal outside the database backup/restore transaction: its active receipts and
same-boot completion receipts are recovery evidence, not permission state. A single
lifetime lease excludes simultaneous coordinators. On restart, recovery interrupts
running work without replay, closes proxies, confirms tracked processes have ended, and only then
releases marker files and port leases. Cleanup acknowledgements are idempotent.
Authorization epoch recovery is acknowledged after physical cleanup; suspended
permissions still require owner confirmation. Missing or unreadable ownership
proof refuses admission and keeps cleanup pending.

Darwin durable ownership requires the sandbox's inherited marker. After host death,
recovery scans the entire process table in a quiet identity-probe round, validates
each identity across classification, and retains ambiguous zombies or incomplete
snapshots as pending. The root birth identity excludes older processes but never
cuts off enumeration. Full access records the root's stable identity and isolated
process group; recovery terminates surviving members only when a stable identity
anchors that group. Unobserved detached descendants are outside ownership and
may survive. Shell/process snapshots and command results report
`process_group_best_effort`; sandboxed results report `durable_sandbox`.

Fixed host file mutations use live path authority in-process. Fixed Git helpers
bind the host executable, argument vector, directory and isolated environment;
they remain sandboxed even for a Full access principal. Write helpers open only
the admitted project and verified Git directory, preserve nested denials and
serialize repository writes. Caller arguments and decoded capability metadata
cannot select this strategy. Every host-worktree execution holds the same
worktree-use lease, including unconfined Full access programs. Preparation,
launch and in-process writes revalidate the pinned checkout, repository and
host-owned controls. Removal closes admission, drains synchronous mutations and
terminates writers across principals and generations. Sandboxed writers require
confirmed termination; Full access writers are terminated best-effort with
reported ownership limitations. Private Git writers do not acquire the shared
repository lock while holding this lease.
See [execution admission](SecurityAndPrivacy.md#execution-admission)
for the current Sandbox and Full access availability matrix.

Permission edits and periodic reconciliation revoke running descendants and proxy
streams. Standing work survives client disconnect; connection-scoped work ends
with its connection. A completed one-time execution retains result access until
its grant is revoked or retention ends. Time and memory tightening can terminate
work; output tightening drops oldest bytes across both streams, preserving cursor
history and arrival order across restoration. Completed authorized results use the
ledger's retention duration and aggregate byte ceiling, evicting oldest first.
The snapshot exposes applied limits and a limit termination reason.

Principal execution installs this context at its admitted call boundary. Trusted
host administration runs outside that boundary with an explicit host policy.
Registered CLI help, host Git, descriptor-backed file helpers and shell/process
adapters all reach the same launcher. Within host worktrees, local plugin/stdio
process preparation requires the plugin owner's verified execution context and
remains unavailable until that context is supplied. Ordinary projects retain
their admitted plugin invocation path. Neither a plugin receipt nor Full access
consent creates a host worktree context.
Housekeeping retains the original ownership handle for cleanup and cannot obtain
new launch authority by dropping the context.

## Tool executions

`ShellSessionRuntime` owns launches, stdin, output and completion through the
launcher. `ManagedProcessRegistry` adapts registered commands to the same session
store. `ProcessCommandRunner`, `ManagedCommandRunner` and `CLIProcessExecution`
share this lifecycle. Their synchronous adapters use the same input and output
ownership as background sessions.

Host Git inspection and file operations also use the injected launcher.
`runIsolated`, `runToFile` and `runInDirectory` receive a complete, explicit set of
caller-owned variables. They never merge process variables, runner base variables
or a managed runner's default host variables. Full access uses exactly that set.
Read-only execution combines it with the fixed sandbox environment. Sandbox home,
temporary, configuration and cache locations and proxy settings take precedence
because the profile opens only those locations and endpoints.

Callers select these sets at their operation boundary:

| Caller | Selected variables |
| --- | --- |
| Host Git operations and project Git layout checks | Private `HOME` and `XDG_CONFIG_HOME`, `LC_ALL=C`; `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`, `GIT_NO_LAZY_FETCH=1`, `GIT_ALLOW_PROTOCOL=`, `GIT_CONFIG_COUNT=0`, `GIT_CONFIG_PARAMETERS=`, `GIT_EXTERNAL_DIFF=/dev/null`, `GIT_ATTR_NOSYSTEM=1`, `GIT_PAGER=`, and `/dev/null` for `GIT_EDITOR`, `GIT_SEQUENCE_EDITOR`, `GIT_ASKPASS`, `GIT_SSH_COMMAND` |
| Git author identity lookup | A verified worktree reads the source repository’s author fields as data, without copying its configuration. Only selected configuration locations `HOME`, `XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, plus `LC_ALL=C`; author values are subsequently passed as explicit Git options |
| Registered SQLite inspection | Private `HOME`; arguments retain `-init /dev/null -safe` |
| File archive extraction | `LC_ALL=C` |
| File archive creation and download | Empty set |

Executable and interpreter resolution happens on the host before isolated Git or
SQLite execution. Host `PATH` can locate an executable, but only the resolved
absolute path and invocation arguments cross this boundary. Host variables are
never selected by copying an entire process or runner environment.

`runToFile` and `runInDirectory` stream stdout through a pipe into the host-owned
output descriptor, report write errors and bound stderr independently.
The pipe prevents sparse producers from seeking over holes in the output stream.
Descriptor working directories select the POSIX launch backend, which applies
`fchdir` before stdio remapping; Linux uses `LinuxSystemCalls` for that action.
Descriptor working directories are available for Full access and read-only
configurations; Linux continues to refuse sandbox execution.
The caller retains all borrowed descriptors until the synchronous operation
finishes. Timeouts cancel the owned process group and wait for confirmation before
joining output consumption.

Executions have stable UUIDs. Independent absolute stdout and stderr byte cursors
support incremental reads across transport reconnects. A shared ring budget keeps
the newest 8 MiB across both streams by default; reads report the discarded byte
count and whether a cursor precedes retained output. Waiting calls default to two
minutes and accept at most ten minutes. Background executions have no deadline
unless supplied. Snapshots report the applied limits, exit code or signal, and
an end reason. Cancellation delegates to `ExecutionOwnership` and completes only
after ownership confirms termination; the Full access membership limitations
described below still apply.

The admitted permission context determines process mode, paths, network and
limits. Semantic read helpers retain their read restrictions in either principal
mode. Trusted host compatibility checks and catalog exporters require an explicit
administrative scope; principal-triggered helpers use principal authority. Missing
contexts refuse launches rather than selecting a default policy.

`GatewayTerminalSessions` owns optional durable execution records separately from
runtime generations and transport connections. App listeners and standalone servers
select distinct journal directories and hold an exclusive lease. Records contain
scope, output, cursors, limits, boot session and kernel process identities; updates
are atomic. The initial root identity is persisted before the bootstrap acknowledges
the command. Periodic checkpoints follow while running. Reopening a journal verifies
saved identities from the same boot before cancelling surviving members, then marks
unfinished records
`interrupted`. Recovery exposes the last checkpoint, never restarts a command, and
retains principal/profile/project scope checks. Recovered outputs require the
same standing client trust ID and revision, or the same configured grant identity.
Connection-only consent permits crash cleanup but does not retain readable output
for another connection. Completed results remain subject to
the session store's retention limits. Explicit owner shutdown discards its results.

## Host infrastructure launches

[Execution admission](SecurityAndPrivacy.md#execution-admission) distinguishes
explicit local-owner host administration from principal tool execution, including
local stdio MCP and plugin processes. The mechanisms below preserve the selected
context; they do not classify every supervised process as host infrastructure.

- For an unprepared administration launch, `ManagedLineProcess` starts a
  supervisor with a child job-control group and an owner-death watchdog. The
  supervisor and watchdog inherit the ownership lock. For a prepared provider,
  the launcher starts the reviewed executable directly and tracks its execution.
  An adapter with scoped host services receives the host-service descriptor.
  Both launch paths use ordered nonblocking input and independent output drains.
  Teardown joins the I/O before releasing execution resources.
- `PluginArchivePreparation` uses launcher capture with a read-only archive input
  descriptor, an explicit inherited installation lock, private working directory,
  and only fixed `PATH`, `LANG` and job-owned `TMPDIR`. Capture limits are inclusive;
  overflow cancels the worker immediately. Timeout and cancellation wait for
  confirmed termination before releasing descriptors or discarding the job root.
- Cloudflare uses `ManagedServiceProcess` with the host infrastructure environment,
  null stdin and the existing stdout/stderr log files. The launcher owns startup,
  exit observation and termination. Stop confirms cleanup before the origin,
  token file and log handles are released, and unexpected exit still updates the
  control-plane lifecycle and audit.

Explicit inherited descriptors select the POSIX backend. It copies all sources
above the destination range before applying mappings, closes parent copies after
spawn, and exposes only the requested child descriptors. Sandbox launches refuse
extra inherited descriptors. The source gate in `Scripts/verify-execution-launches.py`,
run by the package boundary CI stage, rejects direct `Process`, `posix_spawn`,
`posix_spawnp` and `Subprocess.run` usage outside the launcher's OS backend,
sentinel and ownership implementation files. Those internal helpers establish
ownership before user commands can execute.

## Configuration and Seatbelt

`ComputerMCPSandbox` owns `SandboxConfiguration`, `ExecutionEnvironment`, launch
contracts and route-observation contracts. `SandboxPath` checks absolute lexical
form; the host's path resolver owns filesystem identity and symlink resolution.

`SeatbeltProfile` in `ComputerMCPPlatformDarwin` emits a deny-default profile:

- Writes are confined to the worktree and its private temporary, home and cache
  directories. Reads cover configured roots, subtract denied regions, reopen
  their explicit exceptions and always exclude forbidden paths. Ancestors can
  be listed without opening their other files.
- The source repository stays read-only. A host worktree has an independent
  private repository with cloned objects, references and operation state. Git
  uses its host-owned `.git` indirection and configuration. Control paths and
  their containing directory entries are immutable; only Git state names are
  admitted at the private root. Publication verifies a host-owned object copy.
  The layout and trust boundary are defined in [Coding Harness](../Decisions/CodingHarness.md#worktrees).
- Network access is limited to the execution's leased IPv4/IPv6 loopback proxy
  ports. Direct connections, UDP and child-side DNS are excluded.
- Screen capture and Accessibility have two independent switches. Screen capture
  allows global Mach lookups for `com.apple.windowserver.active`, `com.apple.replayd`
  and `com.apple.tccd.system`, plus the `IOSurfaceRootUserClient` IOKit user client.
  Accessibility allows only the local/per-process `com.apple.axserver` lookup;
  opening WindowServer would also expose capture. Their interaction with inherited
  TCC grants requires the explicit local acceptance fixture described below.
- Apple events are always blocked in the sandbox. Deny-default blocks
  `appleevent-send` and the `com.apple.coreservices.appleevents` lookup. macOS
  rejects a sandboxed sender without a target-scoped Apple-event entitlement
  (`errAEPrivilegeError`, -10004), regardless of profile allowances. Arbitrary
  sandboxed programs cannot carry that entitlement.

The sandbox environment is an explicit fixed set: selected search paths, private
HOME/TMPDIR/cache paths, locale, terminal, optional developer directory, Git
settings and proxy URLs. Host registration reads may additionally supply a canonical
`CODEX_HOME` so the CLI reads the selected configuration without writable access to
it. The sandbox
environment never merges host credentials. Sandboxed SwiftPM
builds use `ExecutionEnvironment.swiftBuildArguments()` with the native build
system and private caches, preserving TMPDIR in link tasks.
`UnsupportedExecutionPlatform` refuses execution when no backend is injected.
The Linux `POSIXExecutionPlatform` preserves Full access process-group execution;
its bootstrap stops before exec, and cancellation uses the unreaped process group
and identity-checked pidfds for observed descendants. It maps stdio and explicitly
inherited descriptors, closes unmapped descriptors below that range, and uses the
glibc spawn close-from action for all descriptors above it.
Host pipe writers and unrelated open files cannot leak across exec, so
closing the host's stdin writer delivers EOF to the command. Read-only, sandbox and durable
recovery calls fail closed until corresponding Linux backends are available.

## Launch and Cancellation

`DarwinExecutionPlatform` supports direct `posix_spawn`, swift-subprocess and
Foundation `Process`. Full access preflights the dynamic responsibility-disclaim
interfaces before launching; unavailable interfaces fail closed. Sandboxed
launches inherit responsibility and rely on Seatbelt's service rules.
The Subprocess adapter copies the opaque Quarantine policy payload immediately
after setting the disclaimer and retains it through the asynchronous spawn.
Darwin's [MAC policy attributes borrow their payload pointers](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/spawn/posix_spawn.c#L2184);
libquarantine's thread-local scratch cannot supply that asynchronous lifetime.

`ExecutionLauncher.start` returns an `ExecutionOwnership` handle for every launch
method. `members` lists known identities whose exit is unconfirmed, including unreaped
members. Running sandboxes return their known identities without starting classification;
after root exit or cancellation, the list reflects classification rounds. Launch does
not wait for a round: the bootstrap's identity is recorded before acknowledgement.
The host closes its copy of the child socket immediately after spawning, so an
early bootstrap exit produces EOF. The bootstrap confirms installation of the transferred
stdin and stderr descriptors before the host closes its endpoint and returns the
handle. The caller's descriptors stay alive through that confirmation. The host
uses one monotonic 30-second deadline from spawn through identity receipt,
ownership admission and confirmation. An independent timer closes the handshake
and fails startup even while an admission callback is blocked. A late callback
cannot release the target. Timeout leaves the process owned for bounded
termination attempts and background reaping; startup does not wait for that cleanup.
The bootstrap bounds its I/O waits at 30 seconds as well. Other handshake failures
include the collected bootstrap exit status and at most 4 KiB of its stderr;
target stderr goes directly to the caller.
`wait` returns the command's exit status after the execution's completion check;
`run` combines start and wait. Cancelling a waiter requests cancellation. `cancel`
sends SIGTERM and performs identity-checked KILL rounds after a 500 millisecond
grace interval. Full access cancellation returns as soon as
its members have exited; sandbox cancellation retains its strict confirmation rounds.

Sandboxed executions alone use sentinels, watermark probes, fully classified
machine-wide snapshots and per-PID sandbox checks. Classification starts only after
the root process exits or cancellation begins; running sandboxes do not periodically
scan the process table. Each classification round enumerates all process IDs with
one `proc_listallpids` call. Before each call the host launches `/usr/bin/true`
normally, reads the child's `p_uniqueid` as watermark W with
`proc_pidinfo(PROC_PIDUNIQIDENTIFIERINFO, argument 1)`, then waits for and reaps
that exact PID with `waitpid`. The child retains its identity until reaping;
argument 1 finds both live processes and unreaped zombies. Probe creation,
identity or reap failure invalidates the round. Failed identity reads and round
cancellation still reap the probe before returning. Before creating the execution's
first process, the host starts
an execution sentinel (`/usr/bin/true`), waits for its exit with `waitid(P_PID,
WEXITED | WNOWAIT)`, and records its PID and unique ID without reaping it. The
execution handle retains the sentinel and reaps that specific PID when released
after completion. Sentinel creation and its synchronous `waitid` run on a
per-execution worker outside the shared lifecycle executor. A snapshot is complete
only if it contains both PID 0 and this sentinel; otherwise enumeration retries with a larger buffer within the inspection
deadline. An absent or unconfirmable sentinel fails completion, retains the marker,
record and proxy leases, revokes egress, and continues background KILL rounds.
The initial buffer is four times the current process-count estimate. XNU
[`proc_info.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)
traverses `allproc` then `zombproc` under `proc_list_lock`, skipping exec shadow
processes and stopping early only at capacity. Its internal allocation uses
`nprocs + 20` before locking, so a short result alone does not prove completeness.
[`kern_proc.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_proc.c)
inserts new fork/exec process records at the head under that same lock;
[`bsd_init.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/bsd_init.c)
inserts immortal `kernproc` first. PID 0 therefore marks the end of `allproc`.
In [`kern_exit.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exit.c),
`proc_prepareexit` moves a process to the head of `zombproc` before terminating all
threads and setting `SZOMB`. Presence in `zombproc` therefore does not establish
quiescence: a thread may still be completing fork, with a child identity allocated
but not yet published. All execution members are created after the sentinel has
exited, so their zombie records precede it. Only the older records after the sentinel
can be truncated or omitted from classification. Host child reapers must specify
PIDs; `wait()`, `waitpid(-1, ...)` and SIGCHLD auto-reaping would invalidate this
boundary. The direct, Foundation and swift-subprocess launch paths leave unrelated
children unreaped. Held sentinel identities are registered as known unsandboxed
children, so simultaneous executions can classify each other's sentinels. A round
copies this registry once; the registry lock is never held during kernel calls
or acquired for each PID. On kernels
where `sandbox_check` reports denial for every path of an exiting process, negative
marker results in `zombproc` are unclassifiable, even before its state becomes
`SZOMB`. Negative marker classification also requires a successful non-zombie identity lookup
(`PROC_PIDUNIQIDENTIFIERINFO`, argument 0), since a process may enter `zombproc`
after enumeration and before state inspection. These records require independent
provenance or a verified live nonmember parent of a zombie with readable BSD flags
that confirm it is untraced; otherwise they block completion until reaped.

For each user-process PID, classification reads `(pid, p_uniqueid)` before and
after querying its sandbox marker. Both reads must agree and `p_uniqueid < W`.
XNU [`kern_fork.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_fork.c)
assigns the PID and monotonically increasing `p_uniqueid` in the same
`proc_list_lock` critical section in `forkproc`; exec preserves `p_uniqueid`.
A process replacing a snapshot PID after enumeration must have a unique ID above
W. Processes born between the probe and the list lock merely invalidate the round.
The identity reader uses `proc_pidinfo` flavor `PROC_PIDUNIQIDENTIFIERINFO` (17),
argument 1, and the 56-byte `proc_uniqidentifierinfo` from
[`bsd/sys/proc_info_private.h`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h).
This is kernel ABI not publicly exposed in the SDK. `proc_info.c` exempts this
flavor from the same-user check, and argument 1 includes zombie records.
Known launch identities also remain members:
the bootstrap can install its sandbox after enumeration, so its prior unmarked
state cannot establish the absence of members.
Every member signal (TERM or KILL) uses `proc_signal_with_audittoken` with the PID
and `p_idversion` read during classification. A positive marker query may send KILL
before the second identity read, but requires a successful first identity read.
XNU `kern_proc.c` (`proc_find_audit_token`) validates PID and pidversion while
retaining the target process for `psignal_by_audit_token`. A reused PID returns
ESRCH without signalling its replacement; a concurrent exec can also invalidate
the token and requires fresh classification. Stopped members receive the same
identity-bound KILL; peer signals cannot catch or ignore it. A failed classification does not prevent
killing other confirmed members, but makes the round ineligible to prove completion.

Sandbox completion requires a fully classified snapshot with no members (including every
zombie before the sentinel), confirmation that all known members have been reaped
or replaced, and collection of the root's exit. A member zombie or an unclassifiable
zombie prevents completion on every round; successful signalling or repeated zombie
observations do not prove exit completion. Reaping requires the exit path to finish.
Together with the watermark and matching identities before and after classification,
the snapshot proves that no member existed at t, the list-lock instant. Membership
is inherited through fork, only members can create members, and the launcher has
stopped creating processes for this execution; therefore none can appear after t.

Both Darwin and Linux POSIX ownership handles accept absolute `ContinuousClock`
deadlines through `cancel(until:)` and `wait(until:)`.
Each deadline ends only that caller's wait with `ExecutionWaitExpired`, retaining
its ownership handle. `cancel()` waits up to 5 seconds; `wait()` has no caller
deadline. Cancellation starts an independent 5-second termination attempt covering
grace, kill and confirmation; exhausting that budget reports
`ExecutionCompletionFailure` to all pending waiters, including those with later or
no deadlines. A termination failure takes priority over simultaneous caller expiry.
Caller expiry leaves other waiters and the termination budget unchanged. Both
platforms retain ownership and continue background cleanup after failure; a later
wait can confirm completion. POSIX retains its unreaped leader and observed
descendant identities, and continues process-group and pidfd signalling. Its
membership diagnostics are best effort.

On Darwin, signal retries and process enumeration also have bounded work. Kernel queries and signals
run on a serial worker without holding the ownership lock; a separate timer advances
deadlines even when libproc waits for exec. Other waiters and in-flight inspection
continue when one caller's wait expires. Ownership failures reach all pending waiters.
Inspection and termination budgets invalidate late observations; caller wait deadlines
do not. Late results cannot publish exit observations or release resources. A late sentinel
failure still revokes egress and starts KILL cleanup because it only reduces authority. A blocked worker must return
before the next scan starts, bounding outstanding inspection work per execution.
`ExecutionCompletionFailure` reports remaining or unconfirmed identities, reasons,
and whether membership is best effort. Its `ownership` handle remains queryable even
when `run` or cancellation during `start` returns the failure. The monitor retains
the execution record and marker, continues background observation and, once cancelled,
keeps scanning by marker and killing members until a fresh fully classified snapshot
confirms completion. Programs that wake peers or replace themselves remain sandboxed and
without network access throughout cleanup.

Callers pass `{ proxy.attach(to: $0) }` as the launcher's `bindOwnership` callback.
The platform binds ownership before spawning, including cancellation during startup. Cancellation, including cancellation of a waiter, dispatches
revocation immediately: existing streams close and new connections are refused,
without waiting for process inspection or exit. Completion cannot retire ownership
until all concurrent revocation callbacks have been dispatched. Binding an already
cancelled handle also revokes immediately. The handle retains the proxy callback through cleanup.
`EgressProxy.releaseAfterExecutionEnds(_:until:)` also binds cancellation and waits
for successful confirmation before releasing either listener or port lease. Failed
confirmation keeps both loopback port leases reserved.

All execution launch methods use the private `computer-mcp-execution-bootstrap` executable. It
establishes an isolated session, sends its kernel process identity through a
socketpair, and waits for the host acknowledgement before executing the command.
SCM_RIGHTS transfers the original input and error descriptors; output retains its
original descriptor. A separate drained pipe captures only bootstrap diagnostics
until the error descriptor is installed before target exec. Both descriptors are
installed before confirmation. EOF or an acknowledgement deadline ends bootstrap
without executing the command. Host ownership-admission errors retain their
original type and do not enter the bootstrap diagnostic envelope. Missing bootstrap
files refuse launches. The App packages
and signs it in `Contents/Helpers`; the embedded CLI finds that location, and
standalone CLI builds use a sibling executable.

Sandbox membership uses existing marker files in a private host-owned directory.
Every profile denies reading that directory except for its own marker, and denies
all writes there. The host first checks that the shared marker is denied, then
that the execution's own marker is readable. This excludes unsandboxed processes,
unrelated sandboxes and other executions, including a process entering another
sandbox between queries. The host resolves marker paths with `realpath` and keeps
the files until confirmed completion. Disappearing PIDs, identity/query failures
and identities at or above the watermark make a scan incomplete. The watermark also
detects reuse before the first identity read. Zombie state comes from the cross-user
`PROC_PIDT_SHORTBSDINFO` query with argument 1. Parent-based nonmember classification
also requires readable zombie BSD info (`PROC_PIDTBSDINFO`, argument 1) with
`PROC_FLAG_TRACED` clear. An untraced zombie can be classified as a nonmember when its
live parent is neither launchd, this host nor an execution member: the parent's
`PROC_PIDUNIQIDENTIFIERINFO` unique ID must match the zombie's `p_puniqueid`, and
identity-checked sandbox queries must confirm the parent is a nonmember. Traced
zombies, unreadable BSD info and other unproven zombies retain member or
unclassifiable status until reaped.

This proof trusts processes outside the execution that hold debugging rights over its
members. Such a process can reparent a member to itself, and exec then rewrites the
member's `p_puniqueid`; after a detach the traced flag is clear again. A member cannot
arrange this itself: attaching needs task rights over a sandboxed process, which only
the owner's own tools hold, and a process with those rights already controls the
member completely.
Membership survives parent exit, reparenting, process-group/session changes and exec.

Full access uses the bootstrap's isolated process group, the exact root identity,
and known descendants. Lightweight observation reads only known PIDs and
`proc_listpids(PROC_PGRP_ONLY, ...)` members. A known identity, or a child whose
parent unique ID is known, anchors group ownership; a second read confirms the
anchor's identity, group and session before admitting other members. Known members
remain tracked if they leave the group. Cancellation signals known members and
enumerated group members individually with audit tokens, then confirms exit with
targeted identity reads and group enumeration. Repeated rounds reach new group
members born during cancellation.

Normal Full access completion is collection of the root's exit, confirmation that
known members have exited, and a non-blocking observation that the group is empty.
An exit or cancellation arriving during an observation requests a fresh round
immediately when that observation returns. Root exit always requests an immediate
observation; empty-group completion does not wait for a timer tick or machine-wide
classification. Background rounds continue while observed members remain alive or
ownership is unconfirmed. On macOS 15 and later, each lifecycle task uses its own
executor so synchronous file I/O does not monopolize a shared execution queue.
The swift-subprocess launch handshake runs on a per-execution worker.
This is best effort: descendants
that leave the group before being observed, or work started through another
service, may escape tracking. A nonempty group without a validated ownership
anchor remains unconfirmed; it cannot acquire unrelated work through identifier
reuse. Such uncertainty can reach the wait or cancellation deadline, and cleanup
continues until the group is observed empty.

## Outbound Connections

`ComputerMCPEgress` owns a CONNECT/SOCKS5 listener pair on a per-execution port,
leased on both loopback families. The listener determines identity independently
of request headers and SOCKS fields. The host retains the leases until the entire
sandbox process tree ends, even after revocation; an old profile cannot acquire
another execution's identity through port reuse.

The policy admits `none`, `trusted`, `full`, or `custom` hosts. The `trusted`
catalog contains these exact hosts and explicit subdomain suffixes:

```text
github.com, api.github.com, codeload.github.com, *.githubusercontent.com, ghcr.io
registry.npmjs.org, registry.yarnpkg.com, pypi.org, files.pythonhosted.org
crates.io, index.crates.io, static.crates.io, rubygems.org, *.rubygems.org
repo.maven.apache.org, repo1.maven.org, plugins.gradle.org, services.gradle.org
downloads.gradle.org, proxy.golang.org, sum.golang.org, dl.google.com
api.nuget.org, *.nuget.org, repo.packagist.org, packagist.org
swift.org, download.swift.org, download.developer.apple.com, developer.apple.com
swcdn.apple.com, swdownload.apple.com
```

Wildcards match subdomains, not the suffix's siblings. Hostnames and numeric forms
are normalized. The host system resolver supplies a bounded set of numeric addresses, and every
answer is checked before numeric dialing. A new connection resolves again;
established streams retain their checked address.

Local-network classification is made at connection time using the destination
and selected system route. Direct subnets, link-local destinations (including
metadata addresses) and multicast require Local network. Tunnel routes count as
internet destinations; loopback remains forbidden. Darwin sockets bind the
selected interface with IP_BOUND_IF or IPV6_BOUND_IF before connecting.

`DarwinEgressRouting` obtains selected routes through silent route queries and
observes PF_ROUTE events. The proxy coalesces events and compares each active
connection's route, interface index and interface addresses. Changed decisions
produce a denial event and close the affected stream; unchanged streams remain
open. Failure of observation closes streams and refuses new connections. This is
connection-time enforcement with event-driven invalidation, not an atomic promise
across host routing changes; sandboxed programs cannot change the host routes.

The proxy bounds admitted connections, DNS work, handshake and relay buffers,
connect time and idle time. Read scheduling applies backpressure, half-closes
wait for queued writes, and revocation closes admitted streams. Denial events
carry execution ID, normalized host, port and reason; CONNECT errors and SOCKS
replies name the denied host.

## Validation Entry Points

Default tests cover configuration, generated SBPL, actual Seatbelt filesystem
and Git boundaries, offline native SwiftPM building, proxy policy, network bypass
denials, routing and resource lifecycle. Ownership tests cover parent retirement,
double-fork and setsid, PID-1 adoption, exec, ignored TERM, members born during
cancellation, waiting for all members, concurrent isolation and simulated PID reuse.
A deterministic Full access regression runs 128 short commands across eight lanes
through `ManagedCommandRunner` and independently counts full snapshots, watermark
probes, sentinel spawns and sandbox membership checks, asserting zero for each.
A sandboxed control verifies that all counters observe their actual operations.
The informational timing printout separates worker execution from wall time, which
also includes scheduling the async test's resumption. A gated observation with a
long timer interval verifies that a concurrent exit or cancellation triggers
immediate completion.
An executor test stalls one lifecycle task while another continues. Injected process
tables also verify lazy sandbox classification, cancellation completing during
grace, nonempty unanchored groups and group anchors that leave during confirmation.
Native integration functions reserve their process and I/O budget before case
deadlines start. Parameterized functions reserve a batch while retaining their
existing case parallelism. Independent hosts run concurrently, each retaining its
own sentinel while both executions complete.
Injected process tables exercise fork-after-enumeration/exit races, descendants born
during classification, signal and enumeration failures, pending KILL, zombies, deadlines,
recoverable startup cancellation and resource retention. Additional regressions cover
mutual SIGCONT/self-stop, unique-ID changes, watermark equality/ordering, probe failure,
repeated probe reaping through live and zombie reads, identity failures and cancellation,
missing PID 0 or execution sentinel, lost-sentinel fail-closed cleanup, nonmember
system-process exit, continuous fork/exit, blocked kernel
queries/signals, discarded late empty scans and eventual background cleanup. Port
tests verify cancellation closes active streams and rejects new admissions before a
blocked query returns, while retaining IPv4/IPv6 leases through failed confirmation.
Real-kernel tests keep the last member unreaped to verify that completion waits for
reaping, check newest-first sentinel ordering and stale tokens against an actually
reused PID, and run zombie classification,
continuous exec and rapid fork through all three launch methods, plus PID 0 at the
end of the live-process list. Darwin-specific tests require macOS.
Route changes are simulated through injected routing sources; a route-socket
smoke test uses a read-only RTM_GET notification, without modifying host routes.

Local and public-network suites are explicit:

```sh
COMPUTER_MCP_PID_REUSE_TESTS=1 swift test --filter kernelRejectsStaleTokensAfterActualPIDReuse
COMPUTER_MCP_LOCAL_RESPONSIBILITY_TESTS=1 swift test --filter ResponsibilityAppTests
COMPUTER_MCP_LOCAL_SERVICE_TESTS=1 swift test --filter SeatbeltSystemServiceTests
COMPUTER_MCP_EGRESS_NETWORK_TESTS=1 swift test --filter EgressNetworkTests
```

The PID-reuse stress test keeps one child at a time and may cycle the kernel PID
allocator for several minutes. It verifies stale TERM and KILL tokens return ESRCH
while the replacement exits normally.
The responsibility suite launches an ad-hoc signed hardened App with `open`.
The service suite requires a graphical login and existing TCC grants for its
controlled fixture, tests all four switch combinations, and fails if its
unsandboxed positive controls are unavailable. Its
[fixture instructions](../../Tests/ComputerMCPPlatformDarwinTests/Fixtures/README.md)
include the user-operated authorization command. Default Mach policy checks do
not replace this acceptance test. The network matrix includes 19 local negative
cases and six opt-in public HTTPS/Git/SwiftPM/npm/SOCKS/IPv6 cases.

Sandbox-runtime adaptations are identified in source headers and
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md); the Apache-2.0 text is
included in packaged notices.

Fixed network diagnostics that launch `ping`, `nc`, or `curl` currently return
`execution.unavailable`: their prepared service-specific network context belongs
to Host 5 execution integration. Machine information still permits the fixed
read-only network inspection tools and the host resolver. A networked helper
cannot borrow administrative execution authority or a project network setting.

Remote MCP transport uses a prepared service context that cannot launch host
programs. Its retained requests keep their exact ledger execution authority
through completion and cancellation. Local stdio servers require their own
project/plugin execution context; catalog discovery cannot borrow the remote
service context or a read-only host helper context.
