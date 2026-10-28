# Worktree operations

A host worktree is an isolated coding project that inherits its source project's
permissions. With standing Project write permission, creation, editing,
integration and cleanup use ordinary tool calls on one connection. There is no
separate approval step for creating a derived project.

## Before starting

Use a registered, complete non-bare Git repository and durable host storage.
Lifecycle tools are absent from memory-only hosts. The source checkout's current
branch is the default base; a detached source requires an explicit base. Branch
reuse is refused. Shell tools must be enabled and admitted separately; Full
access does not grant Project write. The
[execution matrix](../Architecture/SecurityAndPrivacy.md#execution-admission)
defines available program and plugin paths.

The host places the checkout outside registered projects and supplies a private
repository with detached HEAD, private objects and `origin` pointing to the
source. Its path is selected by the host. Use the returned project ID rather than
registering the path again. Do not edit `.git` or the private control files.
Submodules stay uninitialized and LFS files stay pointers; creation reports these
conditions as warnings.

## One-session sequence

1. In the source project, call `git.worktree_add` with a short lowercase `name`,
   and optional new `branch` and `base`. Keep `project_id`, `path`, `branch` and
   `base` from the result. `git.worktree_list` shows host and foreign checkouts;
   unavailable foreign metrics are null.
2. On the same session, use the returned `project_id` with `project.describe`,
   file tools and programs. Edit with `file.write`, stage with `git.add`, and
   commit with `git.commit`. Its `paths` argument commits only the selected paths
   while preserving other staged work. Raw Git in an admitted sandbox program
   also operates on the private repository.
3. Run builds and tests there. Use the native SwiftPM build system for Swift
   packages. Long-running shell/process calls return execution IDs; read output
   with the corresponding read tool and cursor while making other calls. Source
   permission changes and execution limits still apply. See [Execution owners](Tools.md#execution-owners).
4. If the base advanced, use an admitted shell to run `git fetch origin` and
   `git rebase origin/<base>`. Resolve conflicts explicitly, then continue or
   abort. The host never automatically rebases your work. Private commits do not
   advance the source's managed branch until publication.
5. In the source project, call `git.merge` with the returned `branch`. It publishes
   the worktree's committed HEAD to the managed branch, then fast-forwards the
   recorded base in the source checkout. Divergence, a different checked-out
   branch or local overwrite hazards are refused. For divergence, run
   `git fetch origin`, rebase onto `origin/<base>`, then retry. Unrelated local
   edits are preserved.
6. In the worktree project, call `git.worktree_remove`. It stops admitted writers,
   publishes the worktree's committed HEAD to the managed branch, preserves
   committed history, removes owned storage and unregisters the project. Inspect
   `terminationWarnings` for unconfined processes whose exit could not be confirmed
   or whose detached descendants may survive.
7. In the source project, delete the merged branch with `git.branch_delete`,
   `name`, `dry_run: false` and `confirm_delete: true`. These are fields in the
   same call. The branch tip must be reachable from its recorded base. Other
   recovery objects, including pre-rebase commits, stay retained independently
   after the branch is deleted. Live worktree branches are protected; sandbox
   callers cannot request force deletion.

Committing after `git.merge` and then removing the worktree advances the managed
branch to those new commits. `git.branch_delete` is refused until they are merged
into the recorded base.

### Abandoning work

A sandboxed caller cannot delete an unmerged worktree branch. Removing the
worktree keeps the branch and its recovery records. Only Full access `force` on
`git.branch_delete` discards that generation's remaining recovery records.

Exact arguments, bounds and result fields are in the
[Git lifecycle schemas](Tools.md#git-worktree-lifecycle) and
[branch deletion](Tools.md#gitbranch_delete).

## Dirty state, interruption and ownership

Removal without `force` refuses uncommitted tracked, staged, untracked or ignored
content. `force: true` discards that content only; committed objects, private
references/reflogs and protected history are preserved. Index hints such as
assume-unchanged or skip-worktree do not make a dirty worktree safe to delete.

A busy or interrupted operation may retain a journal and storage. Retry through
the lifecycle tools after resolving the reported interference; do not manually
delete journals, protected refs or lock files. The host verifies expected values
before recovery and preserves ambiguous state. Worktree registrations persist
across restart. Running programs follow execution interruption rules and are not
automatically replayed. Reconnecting does not grant another principal access to
an existing execution ID.

Host worktrees and plugin-managed worktrees have distinct lifecycle owners.
Plugin worktrees retain their existing receipt and host-service contract; these
tools do not convert their layout or take over their deletion protocol.

For installed-manifest upgrades and legacy configuration handling, see
[Worktree availability](Config.md#worktree-availability).
