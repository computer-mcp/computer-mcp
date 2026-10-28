# Worktrees

`ComputerMCPWorktrees` owns repository identity, cross-process coordination,
private Git storage, publication and lifecycle recovery. Gateway adapters own
permission admission, execution leases and runtime publication. Persistence stores
derived project provenance and retained branch protection. See the accepted
[Coding Harness decision](../Decisions/CodingHarness.md#worktrees) for rationale
and [Worktree operations](../Reference/Worktrees.md) for the client sequence.

## Identity and storage

A host worktree has an external checkout and an independent private repository.
Its `.git` pointer names that repository; it is not a linked worktree registered
in the source repository. Creation copies the source object store with
copy-on-write cloning where supported and a bounded copy fallback, verifies the
base closure and checks out detached HEAD. Incomplete concurrent repacks fail
creation with a retryable result. There is no shared object alternate. `origin`
names the source repository so programs can fetch later source commits.

The ledger and journals bind source identity, directories, storage generation,
branch and base. A path, foreign checkout or plugin registration alone cannot
create a verified context. Private configuration, hooks, alternate/graft/shallow
controls and their protected containing directory entries are immutable to
sandboxed programs. Other private Git state remains writable for ordinary Git
operations. The source and other worktrees stay read-only to those programs.
Full access programs are unconfined and outside this integrity guarantee.

Storage derives from the App distribution or standalone database location;
content, private repositories, runtime scratch and journals occupy separate
regions. No lifecycle service exists for memory-only storage. Ordinary project
registration cannot engulf these regions.

## Authority and execution

Derived projects inherit the source's current permissions, nested boundaries and
sandbox settings. Creation adds no grant. The next call on the same session can
use the returned project ID; runtime generations retain existing execution owners.
Removing a source makes its children inaccessible while preserving their data
and provenance for recovery. See the authoritative
[execution admission matrix](SecurityAndPrivacy.md#execution-admission).

Both sandboxed and Full access programs launched in a host worktree reserve its
use lease. Destructive operations close admission first. Sandboxed writers must
terminate and be reaped; unconfined writers receive best-effort termination and
possible survivors are reported. Remote HTTP MCP services execute in their own
service context and do not acquire that worktree lease.

## Publication and recovery

Publication captures detached HEAD once, copies private objects into exclusive
host storage and verifies the copy. Programs keep running. Torn or substituted
input fails verification rather than authorizing publication. The host installs
the verified closure and updates shared refs using expected values under canonical
repository coordination. Captured/replaced commits and private references and
reflogs are retained as required by branch protection.

Host dirty checks reconstruct a fresh index from path, mode, object ID and stage;
program-set stat hints, validity flags and cache extensions cannot hide edits.
The private index is never rewritten by these reads.

Merge requires the recorded base to be the source checkout's current branch and
the candidate to fast-forward it. A prepared reference transaction locks HEAD
and its target; journaled two-tree checkout preserves unrelated local changes and
refuses overwrite hazards and Git filters. Recovery checks recorded before/after
state. Unknown interference is retained for reconciliation, never reset blindly.

Removal reconciles publication and merge journals, terminates writers, checks
dirty state, preserves committed roots, deletes owned storage and unregisters
last. `force` permits discarding uncommitted files only. Branch deletion is a
separate expected-value operation that protects live worktrees and retained
unmerged history. External Git does not honor the host's advisory lock, so
identity and expected-value checks remain necessary.
