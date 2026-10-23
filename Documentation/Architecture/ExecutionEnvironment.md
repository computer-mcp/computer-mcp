# Execution Environment

The reusable execution components have no MCP or permission-store dependencies.
The caller authorizes the operation, provides canonical resolved paths and an
execution ID, and retains ownership through the complete process lifetime.
`ExecutionLauncher` in
`ComputerMCPProcess` constructs the child environment and calls an injected
`ExecutionPlatform`. Shell sessions, registered processes, CLI execution and host
command runners use this entry point. The macOS composition root supplies the
Darwin backend; neutral modules never construct it. Full Shell authorization
continues to gate arbitrary shell, process and CLI execution.

## Tool executions

`ShellSessionRuntime` owns launches, stdin, output and completion through the
launcher. `ManagedProcessRegistry` adapts registered commands to the same session
store. `ProcessCommandRunner`, `ManagedCommandRunner` and `CLIProcessExecution`
share this lifecycle. Their synchronous adapters use the same input and output
ownership as background sessions.

Executions have stable UUIDs. Independent absolute stdout and stderr byte cursors
support incremental reads across transport reconnects. A shared ring budget keeps
the newest 8 MiB across both streams by default; reads report the discarded byte
count and whether a cursor precedes retained output. Waiting calls default to two
minutes and accept at most ten minutes. Background executions have no deadline
unless supplied. Snapshots report the applied limits, exit code or signal, and
an end reason. Cancellation delegates to `ExecutionOwnership` and completes only
after ownership confirms termination; the Full access membership limitations
described below still apply.

The host selects `HostExecutionPolicy` after authorization. Read-only and
project-independent command calls, CLI compatibility checks and catalog exporters
use the read-only sandbox variant: only a private temporary directory is writable,
and HOME and caches reside within it. The environment is rebuilt from the fixed
sandbox allowlist. Host network diagnostics use system read roots, a temporary
working directory and network access; they receive no project read root. Arbitrary
Full Shell execution retains its explicit caller environment and working directory.

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

## Configuration and Seatbelt

`ComputerMCPSandbox` owns `SandboxConfiguration`, `ExecutionEnvironment`, launch
contracts and route-observation contracts. `SandboxPath` checks absolute lexical
form; the host's path resolver owns filesystem identity and symlink resolution.

`SeatbeltProfile` in `ComputerMCPPlatformDarwin` emits a deny-default profile:

- Writes are confined to the worktree and its private temporary, home and cache
  directories. Reads cover configured roots, subtract denied regions, reopen
  their explicit exceptions and always exclude forbidden paths. Ancestors can
  be listed without opening their other files.
- Shared Git administration and existing objects remain read-only. The host
  prepares a detached HEAD and private object store; publication belongs to the
  worktree owner. The environment selects the private and alternate object stores.
- Network access is limited to the execution's leased IPv4/IPv6 loopback proxy
  ports. Direct connections, UDP and child-side DNS are excluded.
- Screen capture, Accessibility and Apple Events have independent switches.
  Their actual interaction with inherited TCC grants requires the explicit local
  acceptance fixture described below.

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
and identity-checked pidfds for observed descendants. Read-only, sandbox and durable
recovery calls fail closed until corresponding Linux backends are available.

## Launch and Cancellation

`DarwinExecutionPlatform` supports direct `posix_spawn`, swift-subprocess and
Foundation `Process`. Full access preflights the dynamic responsibility-disclaim
interfaces before launching; unavailable interfaces fail closed. Sandboxed
launches inherit responsibility and rely on Seatbelt's service rules.

`ExecutionLauncher.start` returns an `ExecutionOwnership` handle for every launch
method. `members` lists known identities whose exit is unconfirmed, including unreaped
members. Running sandboxes return their known identities without starting classification;
after root exit or cancellation, the list reflects classification rounds. Launch does
not wait for a round: the bootstrap's identity is recorded before acknowledgement.
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

`cancel(until:)` and `wait(until:)` accept absolute `ContinuousClock` deadlines.
Their convenience defaults are 5 seconds and 120 seconds respectively; cancellation
includes its grace, kill and confirmation stages in that total. Signal
retries and process enumeration also have bounded work. Kernel queries and signals
run on a serial worker without holding the ownership lock; a separate timer advances
deadlines even when libproc waits for exec. Concurrent callers share confirmation:
the earliest deadline fails all current waiters and invalidates in-flight inspection.
Late results cannot publish exit observations or release resources. A late sentinel
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
SCM_RIGHTS transfers the original input descriptor; output and error retain their
original descriptors. EOF or an acknowledgement deadline ends bootstrap without
executing the command. Missing bootstrap files refuse launches. The App packages
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

The policy admits `none`, `trusted`, `full`, or `custom` hosts. The trusted catalog
lives in `EgressPolicy.trustedHosts`. Hostnames and numeric forms are normalized,
the host system resolver supplies a bounded set of numeric addresses, and every
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
controlled fixture, tests all eight switch combinations, and fails if its
unsandboxed positive controls are unavailable. Its
[fixture instructions](../../Tests/ComputerMCPPlatformDarwinTests/Fixtures/README.md)
include the user-operated authorization command. Default Mach policy checks do
not replace this acceptance test. The network matrix includes 19 local negative
cases and six opt-in public HTTPS/Git/SwiftPM/npm/SOCKS/IPv6 cases.

Sandbox-runtime adaptations are identified in source headers and
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md); the Apache-2.0 text is
included in packaged notices.
