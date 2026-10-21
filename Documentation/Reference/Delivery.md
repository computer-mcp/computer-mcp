# Isolated delivery

`delivery.scopes.list` and `delivery.apply` expose host-declared repository edits
within a selected `workspace_id`. Both require a workspace and use no network
operations. Listing is read-only; apply has `workspace-write` risk. Profile grants,
workspace access and action confirmation follow the ordinary gateway policy.
The provider ID and namespace are `delivery`.

## Configuration

Declare scopes in the App-managed manifest, or in the standalone TOML manifest.
The App uses its existing manifest read/write and validation path; repository files
do not define scopes. App workspace paths come from bookmarks; standalone paths
resolve from the manifest directory. Each workspace runtime receives only its own
scopes. Scope editing in the App is not yet available.

```toml
[[workspaces]]
id = "journal"
path = "../journal" # Standalone only; omit for an App-managed workspace.

[[delivery.scopes]]
id = "training"
workspace = "journal"
repository = "."
paths = ["training/**/*.md", "exports/*.csv"]
default_branch = "main"
worktree_root = ".claude/worktrees"
sparse = false
mode = "land"
```

Scope IDs are unique. `workspace` names a registered workspace. `repository`
defaults to `.` and `worktree_root` defaults to `.claude/worktrees`; both are
relative paths without traversal or `.git` components. The worktree root must be
inside the repository and ignored by Git. `paths` is a nonempty list of relative
globs: `*` stays within a path component; `**` crosses directories and `**/` also
matches zero directories. Other glob operators are unsupported. `default_branch`
is required. `sparse` defaults to false. `mode` is `land` (default) or `commit-only`.

Enable the two names in `[builtin].enabled`, register a CLI command with ID `git`,
and grant the tools and workspace to the calling profile. Once scopes are enabled,
users can withdraw a profile's direct file-writing capabilities through existing
profile permissions.

## Tools

`delivery.scopes.list` accepts no provider arguments. It returns `scopes`, each
with `id`, `repository`, `paths`, `default_branch`, `worktree_root`, `sparse`, `mode`.

`delivery.apply` requires these four arguments:

```json
{
  "scope": "training",
  "message": "docs: record training session",
  "slug": "training-session",
  "edits": [
    {"path": "training/2026-10.md", "replace": {"old": "Sessions: 2", "new": "Sessions: 3"}},
    {"path": "exports/session.csv", "create": {"content": "exercise,reps\nsquat,5\n"}}
  ]
}
```

The first message line is a Conventional Commit: a type, optional `(scope)` and
`!`, then `: ` and a nonempty subject. Types are `feat`, `fix`, `docs`, `style`,
`refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. A body is allowed;
Line endings are normalized before validation and committing. The registered Git
command parses the message with `interpret-trailers --parse`; any trailer output
rejects the message, including `Key:value`, `Key : value`, empty values and
repository-configured trailer separators. The slug matches
`[a-z0-9]+(-[a-z0-9]+)*` and is at most 48 characters. The branch is `<type>/<slug>`;
an existing branch aborts the operation.

Edits contain 1–64 entries, applied in order, with exactly one `replace` or
`create`. Paths are normalized relative repository paths with forward slashes,
without `..`, absolute paths, `.git` components or symlinks. Every path must match
the scope. Replacement requires an existing UTF-8 file and a nonempty `old` string
occurring exactly once. `new` may be empty. Creation requires an absent file and
creates missing parents. Each edit is limited to 1 MiB of UTF-8 content: combined `old` and `new`, or
`create.content`.
Later edits see the results of earlier edits, including on the same file.
All edits are computed in memory before any file is written. Each file is written
once, from its original bytes to its final content. Immediately before replacing
a file, delivery rereads it and requires the original bytes; creation uses
exclusive creation so that a newly appeared file is preserved. Replacements write
a temporary file and rename it over the checked target. All files are read
back before staging only the requested paths. The journal records each successful
write immediately. Rejected writes never authorize rollback, even when another
writer's bytes equal the requested final content. Immediately before committing,
delivery verifies those index blobs against the final contents' Git object IDs
and requires the worktree `HEAD` to remain at the original baseline.

Results use the normal readable JSON and `structuredContent.result` envelope:

| Field | Meaning |
| --- | --- |
| `state` | `aborted`, `merged`, `committed`, or `cleanup_pending` |
| `commit` | Commit ID, when a commit exists |
| `branch` | Branch name, when retained |
| `reason` | Reason code, except for `merged` |
| `message` | Diagnostic detail when cleanup requires attention |
| `files` | Objects with `path` and `snippets` from the final edited content |

Replacement snippets include three lines before and after the changed text;
creation snippets include the first 20 lines. Each snippet is bounded to 4 KiB
without splitting a UTF-8 character. Aborted results set `isError = true` and
include `code = "delivery.<reason>"` and `message`; Git errors also include the
exit code and truncated stderr. Other states are successful tool results.

## Execution and recovery

The repository-wide POSIX lock is `<git-common-dir>/computer-mcp/delivery.lock`.
It is shared by App and standalone processes and held throughout recovery,
preflight, execution and cleanup. Lock acquisition waits up to 60 seconds, then
returns `busy`. Each Git command uses the registered executable/interpreter and
its configured timeout (or the policy default). Inherited and command-configured
`GIT_*` variables are removed. Delivery sets `GIT_TERMINAL_PROMPT=0`,
`GIT_NO_LAZY_FETCH=1` and an empty `GIT_ALLOW_PROTOCOL` to disable prompts,
implicit object fetching and all Git transports, including on older Git versions.
Missing local objects cause failure. Repository
configuration and hooks remain active. Every Git invocation supplies
`-c gc.auto=0 -c maintenance.auto=false` to prevent automatic object, reflog and
worktree-registration maintenance, and `-c submodule.recurse=false` to preserve
nested repositories' checkouts. Diff inspections use `--no-ext-diff --no-textconv`
to avoid external diff commands and text-conversion cache writes. Rebase note
copying is disabled with `-c notes.rewrite.rebase=false` so that other notes refs
remain unchanged. `-c rerere.enabled=false` preserves the shared conflict-resolution
cache. The runner also sets `rebase.updateRefs=false` and `rebase.autoStash=false`
for action modes such as `rebase --abort`, which reject start-only flags.

Preflight checks scopes, path containment, the ignored worktree root, a clean
main-checkout state for target files, branch availability and the message. Land
mode also requires the main checkout to be on the default branch.
Git inspections in preflight and recovery use `--no-optional-locks` so that
checking status does not refresh or write the main checkout's index. The isolated
worktree starts at the current default-branch commit. Sparse mode uses non-cone,
exact-path sparse checkout. Immediately after `worktree add -b` succeeds, delivery
persists creation evidence containing the initial branch commit and worktree
identity. A branch without that evidence is retained as `cleanup_pending` /
`branch_unproven`, including when creation fails or is interrupted before recording
success. Worktree identity and the expected `HEAD` are checked again before
file writes, sparse-checkout changes, checkout, staging, commit and rebase.

After recording the commit, delivery checks its actual paths with
`diff --no-renames --name-only <baseline> <commit>`. The changed paths must be
exactly the requested paths, all within scope. A hook that stages another file
therefore returns `committed` / `scope_changed`, retains the branch and stops
before landing.

Immediately before each landing attempt, delivery requires the main checkout's
`HEAD` to equal the baseline used for path validation. An advance or rewind
counts as a moved default branch: delivery rebases onto its current tip, checks
the entire new baseline-to-commit diff and retries once. A second baseline
change returns `committed` / `not_fast_forward` without another merge or rebase.
Land runs `merge --ff-only --no-squash --no-edit --no-overwrite-ignore --no-autostash <verified_commit>`
in the main checkout using the immutable, validated commit ID. An ignored file
that appears at a target path prevents landing rather than being overwritten.
Live delivery reports
`merged` only when that checkout's `HEAD` equals the delivery commit, including
after a command failure, timeout or exception. A post-merge hook that creates a
descendant leaves the result `committed` with its branch retained.

Rebase uses `--no-update-refs --no-autostash --no-rebase-merges` so that repository
configuration cannot rewrite other branches, temporarily stash user changes, or
write and delete label refs under `refs/rewritten/`. Merge also
uses `--no-autostash`. An existing main-checkout `MERGE_AUTOSTASH` prevents landing
and returns `committed` / `git_failed` with the branch retained, because Git would
otherwise apply that pending stash even with autostash creation disabled.
Immediately before each merge in the main checkout and each rebase in the
delivery worktree, `ORIG_HEAD` must be absent or a regular ref. Git follows a
symbolic `ORIG_HEAD` when updating it, which could overwrite another branch.
Delivery refuses the command and returns `committed` / `orig_head_symbolic`
with the delivery branch retained and the symbolic target unchanged.
Every rebase is followed by the same exact-path validation
against its new baseline. A mismatch, including an empty diff when the default branch already
contains the patch, returns `committed` / `scope_changed` with the branch retained.
Before starting a rebase, delivery journals its original and target commit IDs.
It then checks index visibility flags and requires a clean entire worktree,
including untracked and ignored files, because rebase's internal checkout can
overwrite ignored files. Before aborting its own rebase, delivery again checks
index visibility and refuses any untracked or ignored files; tracked conflict
files remain eligible for the recorded abort only while their working contents
match Git's `AUTO_MERGE` conflict snapshot and staged differences are limited to
still-unmerged paths. Conflict index modes, blob IDs and stages must exactly match
the recorded baseline, rebase target and original commit trees. `HEAD` must still
be the rebase target, the pending pick must be the saved original commit, and that
commit's first parent must be the recorded baseline. Resolve-undo records,
external tracked edits or staged resolutions prevent abort. A missing snapshot
or an unprovable complex rebase also prevents abort. Refusal retains the worktree
and branch as `cleanup_pending` / `rebase_in_progress` for user handling.
The running call immediately aborts its own failed rebase to the saved commit only
after actually invoking it and when its `orig-head` and `onto` match that record.
Immediately before abort, the delivery branch must still be a regular ref at the
saved original commit. An advanced, missing or symbolic ref prevents abort,
retains the rebase and worktree as `cleanup_pending` / `rebase_in_progress`, and
leaves existing refs unchanged.
If a rebase command
fails or times out with no rebase in progress, delivery reads the branch's actual
tip, validates it again and records that commit; it does not attempt landing
after the command failure. If validation fails before invocation, the saved commit
ID remains in the result; no rebase is aborted or attributed to delivery.
Commit-only mode retains the branch without landing.

Cleanup uses `worktree remove` without `--force` only on a verified, existing
worktree and checks for tracked, untracked and ignored changes. Private refs under
`refs/worktree/`, `refs/bisect/` or `refs/rewritten/`, or another Git operation
(`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_LOG` or `sequencer`),
prevent rollback and removal and retain the worktree as `cleanup_pending` /
`cleanup_failed`. Worktree-local `*.lock` files, including `index.lock`, also
prevent both operations so that pending external Git writes remain intact.
Other pseudoref state, including `FETCH_HEAD` and `BISECT_HEAD`, also prevents
removal. A regular `ORIG_HEAD` is accepted only when it names the recorded original commit
of delivery's rebase or a commit reachable from the retained delivery branch.
A symbolic `ORIG_HEAD` targeting a shared ref may be removed with the owned
worktree: removal unlinks the symbolic entry without updating its target ref.
`AUTO_MERGE` must equal the recorded commit's tree object, so removing it cannot
lose unique content. Index entries marked assume-unchanged prevent removal. Skip-worktree entries are
accepted only for delivery's recorded sparse checkout and only when the physical
path is absent; a clean status alone does not prove that hidden files are absent. For `aborted`, cleanup undoes only files durably
recorded as written by this operation and still matching its final bytes, and
unstages only its recorded index entries. Created-file rollback uses `unlink`,
which refuses a replacement directory without recursively deleting its contents.
Replaced-file rollback writes a temporary file and renames it over the checked
target. A rejected write is never undone. A
write interrupted before successful-write evidence was persisted is retained as
`cleanup_pending`; matching bytes alone do not establish ownership. Other changes
make removal fail and remain available in the worktree.
`committed` always retains its branch, even when the commit is reachable from the
default branch; `cleanup_pending` with an undelivered commit also retains it.
Branch deletion requires persisted creation evidence and is limited to `merged`
and `aborted`. Before an aborted deletion,
the branch tip must be reachable from the current default tip. One
`update-ref --stdin` transaction starts with `option no-deref`, verifies the
default ref's checked object ID, repeats `option no-deref` for the deletion, and
deletes the delivery branch with its expected value. Immediately before the
transaction, the delivery branch must be a regular ref, not a symbolic ref;
non-dereferencing deletion protects other branches even if it changes afterward.
On every Git version,
the check that the main checkout's `HEAD` is still the symbolic ref
`refs/heads/<default>` runs immediately before the transaction. A symbolic
`HEAD` change in that check-to-transaction interval remains a residual concurrency
window; the transaction atomically guards the default and delivery branch values.
For live `merged`,
both `HEAD` and the default tip must equal the delivery commit; recovery uses the
default tip captured for its reachability check. Detected interference returns
`cleanup_pending` / `cleanup_failed`, retains the branch and records diagnostic
detail, including a changed main checkout.

The repository lock serializes delivery calls across App and CLI processes.
Other Git writers, including users and other tools, do not take this lock.
Against those writers, delivery preserves committed work reachable from refs
under `refs/` or any checkout's `HEAD`: both newly delivered and previously
existing work remains reachable from those refs or is identified in the result.
Git's transient pseudorefs, such as `ORIG_HEAD` and `FETCH_HEAD`, are outside
this guarantee; merge and rebase may replace their direct values. Symbolic
`ORIG_HEAD` checks protect the refs they target. Delivery also preserves
files, uncommitted changes and worktrees it does not own,
checks state immediately before each guarded Git mutation, and uses Git's atomic
reference transactions where available. Detected interference converges to a
retained branch with `committed` or `cleanup_pending` and a reason. The only
state recovery and cleanup undo is state proven to belong to this operation:
durably recorded successful writes and worktrees and branches with matching
recorded identities. Unproven state is retained as `cleanup_pending` with its path
and reason for user handling. Within this scope, the remaining exception is an
external write in the short interval between a check and
the next filesystem or Git mutation where no atomic primitive covers both. These checks do not
provide isolation from external Git writers across that interval.

Journals live at `<git-common-dir>/computer-mcp/delivery/<operation_id>.json`.
Schema 1 records `operation_id`, `workspace`, `scope`, `repository`,
`default_branch`, `branch`, `worktree`, baseline `base`, `phase`, optional `commit`,
`merged`, optional terminal `state`, `reason` and `message`, and `files`. Immediately
after successful creation, optional `creation` records `branchCommit` (equal to
`base`), `sparse`, and `worktree`, containing the administrative `directory` under
`<git-common-dir>/worktrees/` and the exact contents of its `gitdir` file. This
record authorizes cleanup only after it has been persisted. Missing creation
evidence never authorizes branch deletion. Optional
`changes` record original and final (`written`) file bytes, their Git blob object
IDs (`originalDigest` and `finalDigest`), and original index entries before file
writes; a newly created file has no original bytes or digest. Each change's
`writeState` is `pending` before an attempt, `writing` before filesystem mutation,
`written` immediately after success, or `rejected` after a refused write. Missing
write evidence and `writing` both require conservative retention during rollback.
`staged` records
verified index entries after staging. Optional `rebase` records the `original`
and `onto` commit IDs before rebase starts and retains them after completion to
identify its `ORIG_HEAD`. Each journal write uses a same-directory, exclusively
created temporary file and file fsync. An absent target is published with
exclusive `link`, then the temporary entry is removed; a target that appeared
meanwhile is preserved and publication fails. An existing target must be a
regular journal with matching operation identity before replacement by rename.
Directory fsync follows publication. Temporary-file publication and `unlink`
cleanup check its inode against the exclusively opened file.
Creating the `computer-mcp` and `delivery` directories also fsyncs each directory's
parent before execution can mutate Git state, including when the lock directory
is created before journal writing.

| Phase | Durable meaning |
| --- | --- |
| `started` | Identity and baseline recorded before worktree creation |
| `committed` | Commit ID recorded before any landing attempt |
| `cleanup_pending` | Cleanup or final journal persistence needs retry; `commit` and `merged` preserve outcome facts |
| `finished` | Cleanup complete; `state` records `aborted`, `committed`, or `merged` |

A failed post-commit journal update returns `committed` / `journal_failed`, retains
the branch and never attempts landing. Final journal persistence is then best
effort; recovery can reconcile the retained branch from the started record.
Cleanup failures return `cleanup_pending`
with `cleanup_failed` and retain a retryable journal.

On provider construction, background recovery processes configured repositories;
provider shutdown cancels and joins that work. Every apply also recovers under
the repository lock before its preflight. Before running Git in a recorded
worktree, recovery requires its path in `worktree list --porcelain`, a regular
`.git` file selecting the recorded administrative directory, that directory's
unchanged recorded `gitdir` contents and backlink, the recorded delivery branch
in `HEAD`, and an exact `rev-parse --show-toplevel` match. During a rebase, the
saved `head-name` identifies the branch whose worktree is retained. Every Git command
inside a verified worktree, including verification commands, passes explicit
`--git-dir` and `--work-tree`; loss of `.git` cannot redirect discovery into the
main checkout. A moved original worktree or a replacement at its old path does
not pass ownership verification. An unrecognized empty directory is removed with
`rmdir`, which atomically refuses a directory that becomes nonempty;
a nonempty directory is
retained with `cleanup_pending` / `worktree_unrecognized` and its path in the
journal. If the working directory is missing but its registration or recorded
administrative directory remains, recovery preserves that administrative state
and returns `cleanup_pending` / `worktree_registration_retained`, identifying the
administrative path. Delivery never deletes administrative directories itself:
a matching `HEAD` cannot prove ownership of their index or private refs. This
also applies after removing an unrecognized empty directory. The user can
preserve the state and then use `git worktree prune` to remove stale registrations.
Unrelated worktree registrations are preserved. Failed ownership checks keep the
operation `cleanup_pending`. Recovery retains every in-progress rebase, its index and its
working files as `cleanup_pending` / `rebase_in_progress`, with the worktree path.
Even matching recorded commit IDs cannot establish ownership of subsequent user
resolutions or staged changes. Recovery then
reconciles actual refs, including a commit created before its journal
update. A saved commit must remain reachable from the delivery branch or default
branch before recovery can adopt another tip or clean up. Otherwise recovery
retains the saved commit ID, branch, worktree and reflogs as `cleanup_pending` /
`cleanup_failed`, with both commit IDs in its diagnostic. An unproven rewrite,
including an interrupted rebase without durable completion evidence, does not
authorize forgetting the saved commit. No commit means cleanup and `aborted`; a commit reachable from the default
branch means cleanup and `merged`; an unmerged commit means worktree removal,
branch retention and `committed` / `interrupted`. Failed cleanup remains pending
for the next recovery.

## Reason codes

Error IDs prefix these codes with `delivery.`:

| Code | Meaning |
| --- | --- |
| `scope_unknown` | Missing or unknown scope |
| `path_outside_scope` | Valid path does not match scope globs |
| `path_invalid` | Invalid path, symlink traversal, edit shape or edit size/count |
| `match_missing`, `match_ambiguous` | Replacement has zero or multiple matches |
| `file_exists`, `file_missing`, `not_text` | File precondition or UTF-8/readback failure |
| `main_checkout_dirty` | Target path has uncommitted main-checkout changes |
| `main_checkout_branch` | Land requires the main checkout on the default branch |
| `worktree_root_not_ignored` | Worktree root is not ignored by Git |
| `branch_exists` | Delivery branch already exists |
| `message_invalid` | Invalid commit message, trailer or slug |
| `busy` | Repository lock wait exceeded 60 seconds |
| `git_failed` | Git launch, timeout or command failure |
| `commit_only` | Commit retained under commit-only mode |
| `not_fast_forward` | Fast-forward attempt did not leave HEAD at the delivery commit |
| `rebase_conflict` | Rebase failed and was aborted to the saved commit |
| `rebase_in_progress` | Recovery or cleanup retained an in-progress rebase for user handling |
| `orig_head_symbolic` | Merge or rebase refused a symbolic `ORIG_HEAD`; delivery branch retained, target ref unchanged |
| `scope_changed` | Committed or rebased diff does not change exactly the requested in-scope paths; branch retained |
| `worktree_unrecognized` | Recorded worktree is not the repository's registered worktree; nonempty directory retained for inspection |
| `branch_unproven` | Branch exists without persisted creation evidence; retained for user handling |
| `worktree_registration_retained` | Working directory is missing; administrative state is retained for user handling |
| `journal_failed` | Journal could not be persisted; an existing commit remains on its branch |
| `interrupted` | Recovery classified an interrupted operation |
| `cleanup_failed` | Cleanup or final journal persistence requires retry |
