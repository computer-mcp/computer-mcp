# 隔离编辑交付

`delivery.scopes.list` 列出当前工作区的交付范围；`delivery.apply` 在隔离的 Git
worktree 内顺序编辑 UTF-8 文件，提交后快进合并到默认分支，或保留提交分支。
两者都需要 `workspace_id`，均不使用网络；列表为只读，编辑属于工作区写入。
授权与单次确认沿用现有 profile 权限。

## 配置

范围声明在 App 管理的清单或独立模式的 TOML 清单中，不读取仓库内的范围文件。
每个工作区只收到指向自己的范围。App 工作区通过书签解析路径；独立模式相对路径
从清单目录解析。App 暂不提供范围编辑界面。

```toml
[[workspaces]]
id = "journal"
path = "../journal" # 仅独立模式填写；App 管理的工作区省略此项。

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

ID 必须唯一，`workspace` 必须已注册。`repository` 默认为 `.`，`worktree_root`
默认为 `.claude/worktrees`；均为相对路径，不能包含 `..` 或 `.git`。worktree
根必须处于仓库内且被 Git 忽略。`paths` 不能为空，`*` 不跨 `/`，`**` 跨目录，
`**/` 也匹配零级目录；不支持其他 glob 操作符。`default_branch` 必填，`sparse`
默认为 false，`mode` 为 `land`（默认）或 `commit-only`。

还需在 `[builtin].enabled` 启用这两个工具，注册 ID 为 `git` 的 CLI 命令，并为
调用方 profile 授予对应工具与工作区权限。启用范围后，可用现有权限界面撤回
profile 的直接文件写入能力。

## 调用与结果

```json
{
  "scope": "training",
  "message": "docs: record training session",
  "slug": "training-session",
  "edits": [
    {"path": "training/month.md", "replace": {"old": "Sessions: 2", "new": "Sessions: 3"}},
    {"path": "exports/session.csv", "create": {"content": "exercise,reps\nsquat,5\n"}}
  ]
}
```

`message` 首行遵循 Conventional Commits，类型为 `feat fix docs style refactor
perf test build ci chore revert`，可带 `(scope)`、`!` 与正文。换行符在校验与提交前
统一；已注册的 Git 通过 `interpret-trailers --parse` 解析说明，有任何尾注输出即
拒绝，包括 `Key:value`、`Key : value`、空值及仓库配置的分隔符。`slug` 匹配
`[a-z0-9]+(-[a-z0-9]+)*`，最多
48 字符；分支为 `<type>/<slug>`，同名分支存在则放弃。

`edits` 为 1–64 项，按序应用。每项提供相对仓库根的 `path`，以及二选一的
`replace {old,new}` 或 `create {content}`。路径必须在范围内，使用正斜杠，不能
包含 `..`、`.git`、绝对路径或符号链接。替换要求已有 UTF-8 文件且非空 `old`
恰好出现一次；新建要求文件不存在，会创建缺少的父目录。每项内容最多 1 MiB（`old` 与 `new` 合计，或 `create.content`）。同一文件的后项作用于前项结果。
全部编辑先在内存中计算，每个文件从原始字节到最终内容只写一次。替换前紧挨着回读并
确认仍为原始字节；新建使用独占创建，保留此时已出现的文件。编辑后回读验证，再只暂存
指定路径。提交前紧挨着核对这些路径的索引 blob 恰好为最终内容的 Git 对象号，且
worktree 的 `HEAD` 仍是原基线。

结果通过可读 JSON 和 `structuredContent.result` 返回：`state` 为 `aborted`、
`merged`、`committed` 或 `cleanup_pending`；有提交时包含 `commit`，分支保留时
包含 `branch`，非 `merged` 时包含 `reason`；清理需要处理时，`message` 提供诊断详情。`files` 含每个文件的 `path` 与
`snippets`：替换处前后各 3 行，新文件前 20 行，每段最多 4 KiB，保持 UTF-8 完整。
`aborted` 设置 `isError=true`，并提供 `code=delivery.<reason>`、`message`；
Git 失败附退出码与截断 stderr。其余状态为成功工具结果。

## 执行与恢复

整个调用持有 `<git-common-dir>/computer-mcp/delivery.lock` 的 POSIX 文件锁，
App 与独立进程互斥，等待最多 60 秒。Git 使用已注册命令及其超时（未设置时使用
策略默认值）；移除继承环境和命令环境中的全部 `GIT_*`，设置
`GIT_TERMINAL_PROMPT=0`，仓库配置与钩子仍然生效。

预检要求路径合法、worktree 根被忽略、主检出目标文件没有未提交改动、分支可用，
且提交说明合法。预检与恢复的所有 Git 检查均带 `--no-optional-locks`，不会刷新或
写入主检出的索引。land 模式要求主检出处于默认分支。隔离 worktree 从默认分支当前
提交开始；稀疏模式使用精确路径的非 cone 检出。记录提交号后，先通过
`diff --no-renames --name-only <基线> <提交>` 核对实际改动路径集合恰好等于本次请求，
且全部在范围内。提交钩子另外暂存文件时返回 `committed` / `scope_changed`，保留分支，
停止合并。

每次合并前，紧挨着确认主检出的 `HEAD` 仍等于路径核对所用的基线。默认分支推进或
回退均视为已变化：在隔离 worktree 中 rebase 到当前默认分支，重新核对新基线到提交的
完整 diff，再重试一次；第二次基线变化时，以 `committed` / `not_fast_forward` 保留
分支，不再合并或 rebase。land 使用
`merge --ff-only --no-squash --no-edit <已核对的提交号>`，以不可变的提交号合并。
实时交付只有主检出的 `HEAD` 恰好等于交付提交时才报告 `merged`，命令失败、超时或
抛出异常时也按同一规则核对。合并后钩子产生后继提交时，结果为 `committed` 并保留分支。

每次 rebase 后都按同样规则核对新提交相对新基线的改动路径；不符则以
`committed` / `scope_changed` 保留分支，包括默认分支已含相同补丁而产生空 diff 的
情况。发起 rebase 前，日志记录原提交与目标提交。失败且仍在进行的 rebase 只有其
`orig-head` 与 `onto` 均与记录相同时才中止到保存的原提交；否则保留为
`cleanup_pending`。rebase 命令报错或超时但已无
进行中的 rebase 时，以交付分支实际顶端重新核对并记录提交号，命令失败后不再尝试合并。
commit-only 只提交并保留分支。

清理使用不带 `--force` 的 `worktree remove`，检查已跟踪、未跟踪和被忽略的改动。
`aborted` 先按持久化的撤销记录，识别仍为本次原始或最终字节的文件，只撤销本次记录的
暂存条目；其他改动使删除失败，留在 worktree 中。`committed` 始终保留分支，即使提交
已从默认分支可达；`cleanup_pending` 中有未落地提交时也保留分支。只有 `merged` 与
`aborted` 可删除分支。中止清理删除前，交付分支顶端必须可从当前默认分支顶端到达。
删除使用一个 `update-ref --stdin` 事务，验证默认分支引用的对象号仍等于刚核对的值，
再以预期值删除交付分支。所有 Git 版本都在事务前紧挨着核对主检出的 `HEAD`
仍为指向 `refs/heads/<默认分支>` 的符号引用。核对与事务之间符号 `HEAD` 的变化仍属于
剩余并发窗口；事务原子保护默认分支与交付分支的值。实时 `merged` 要求 `HEAD`
与默认分支均等于交付提交；恢复使用核对
可达性时保存的默认分支顶端。检测到干扰则以 `cleanup_pending` / `cleanup_failed`
保留分支并记录诊断详情，包括主检出已变化的情况。

仓库锁在 App 与 CLI 进程之间串行交付调用。用户和其他工具等外部 Git 写入者不受
此锁约束。对它们的保证是：不丢失已提交的工作（本次交付和此前已有的工作仍能从某个
引用到达，或在结果中给出）；不删除不属于本次操作的文件、未提交改动或 worktree；
每个守护 Git 改动的状态核对紧挨着该改动执行；Git 提供原子引用事务的地方使用事务；
检测到干扰时保留分支，以 `committed` 或 `cleanup_pending` 与原因收敛。唯一不在
保证内的是：没有原子原语覆盖核对与下一条 Git 命令时，两者之间极短窗口中的外部写入。
这些核对不提供该窗口内对外部 Git 写入者的隔离。

日志为 `<git-common-dir>/computer-mcp/delivery/<operation_id>.json`，schema 1
记录操作 ID、工作区、范围、仓库、默认分支、交付分支、worktree 路径、基线 `base`、
`phase`、可选 `commit`、`merged`、可选终态、原因、`message` 以及文件片段。
创建 worktree 后立即记录 `worktree_identity`：公共 Git 目录下的管理目录 `directory`
与其中 `gitdir` 文件的原始内容。可选 `changes` 在文件写入前保存原始与最终（`written`）
字节、其 Git blob 对象号（`originalDigest`、`finalDigest`）和原索引条目；新文件没有
原始字节与摘要。`staged` 保存暂存后已核对的索引条目。可选 `rebase` 在发起前保存
`original` 与 `onto` 提交号。日志写入顺序为同目录临时文件、文件 fsync、改名、目录 fsync。
首次创建 `computer-mcp` 与 `delivery` 目录时，在改动 Git 状态前还会同步每个新建
目录的父目录，包括先于日志写入创建的锁目录。

| 阶段 | 含义 |
| --- | --- |
| `started` | 创建 worktree 前已记录身份与基线 |
| `committed` | 尝试合并前已记录提交号 |
| `cleanup_pending` | 等待清理或终态日志持久化重试，保留提交与合并事实 |
| `finished` | 清理完成，`state` 记录最终分类 |

提交后日志写入失败返回 `committed` / `journal_failed`，保留分支并停止合并。
此时终态日志尽力写入，恢复可从 started 记录与保留分支重新分类。
清理失败返回 `cleanup_pending` / `cleanup_failed`。

provider 构造时在后台恢复已配置仓库，关闭时取消并等待后台任务；每次 apply 在持锁
后、预检前也先恢复。在记录目录内运行 Git 前，核对 worktree 登记路径、指向日志
所记管理目录的常规 `.git` 文件、管理目录中与记录完全一致的 `gitdir` 内容及其反向
路径、`HEAD` 所在的交付分支，以及 `rev-parse --show-toplevel` 返回的根路径。
rebase 期间使用保存的 `head-name` 确认中止将恢复的分支。确认后的每条 worktree 内
Git 命令（包括核对命令）都显式传入 `--git-dir` 与 `--work-tree`，`.git` 消失也不会
让 Git 转而发现外层的主检出。原 worktree 被移走或原路径出现替代 worktree 时不通过
所有权核对。未识别的空目录删除；非空目录保留，以 `cleanup_pending` /
`worktree_unrecognized` 记录，日志保留目录路径。工作目录已不存在时，仅删除本次记录的
管理目录：先核对 `gitdir` 内容与记录完全一致、反向路径仍指向该缺失目录，且登记未上锁。
删除未识别的空目录后也按此处理。不相关的 worktree 登记保留。所有权或锁检查失败则
保持 `cleanup_pending`。仅在已核对的 worktree 内，且日志表明本次发起了该 rebase、
当前 `orig-head` 与 `onto` 均与记录相同时，才中止进行中的 rebase；不属于本次操作的
rebase 及其索引与工作文件保留为 `cleanup_pending`。再按实际 Git 状态分类，包括提交
已生成但尚未写入日志的情况：无提交则清理为 `aborted`；提交从默认分支可达则清理
为 `merged`；未合并提交只删除 worktree，保留分支并归类为 `committed` /
`interrupted`。清理仍失败则保持 `cleanup_pending`，等待下次重试。

全部原因码：`scope_unknown`、`path_outside_scope`、`path_invalid`、
`match_missing`、`match_ambiguous`、`file_exists`、`file_missing`、`not_text`、
`main_checkout_dirty`、`main_checkout_branch`、`worktree_root_not_ignored`、
`branch_exists`、`message_invalid`、`busy`、`git_failed`、`commit_only`、
`not_fast_forward`、`rebase_conflict`、`scope_changed`、`journal_failed`、`interrupted`、
`worktree_unrecognized`、`cleanup_failed`。错误 ID 加 `delivery.` 前缀。完整字段和逐项原因释义见
[英文参考](../Delivery.md)。
