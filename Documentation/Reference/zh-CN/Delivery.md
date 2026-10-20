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
perf test build ci chore revert`，可带 `(scope)`、`!` 与正文，不能带末段
`Key: value` 形式的 Git 尾注。`slug` 匹配 `[a-z0-9]+(-[a-z0-9]+)*`，最多
48 字符；分支为 `<type>/<slug>`，同名分支存在则放弃。

`edits` 为 1–64 项，按序应用。每项提供相对仓库根的 `path`，以及二选一的
`replace {old,new}` 或 `create {content}`。路径必须在范围内，使用正斜杠，不能
包含 `..`、`.git`、绝对路径或符号链接。替换要求已有 UTF-8 文件且非空 `old`
恰好出现一次；新建要求文件不存在，会创建缺少的父目录。每项内容最多 1 MiB（`old` 与 `new` 合计，或 `create.content`）。同一文件的后项作用于前项结果。编辑后回读验证，再只暂存指定路径并提交。

结果通过可读 JSON 和 `structuredContent.result` 返回：`state` 为 `aborted`、
`merged`、`committed` 或 `cleanup_pending`；有提交时包含 `commit`，分支保留时
包含 `branch`，非 `merged` 时包含 `reason`。`files` 含每个文件的 `path` 与
`snippets`：替换处前后各 3 行，新文件前 20 行，每段最多 4 KiB，保持 UTF-8 完整。
`aborted` 设置 `isError=true`，并提供 `code=delivery.<reason>`、`message`；
Git 失败附退出码与截断 stderr。其余状态为成功工具结果。

## 执行与恢复

整个调用持有 `<git-common-dir>/computer-mcp/delivery.lock` 的 POSIX 文件锁，
App 与独立进程互斥，等待最多 60 秒。Git 使用已注册命令及其超时（未设置时使用
策略默认值）；移除继承环境和命令环境中的全部 `GIT_*`，设置
`GIT_TERMINAL_PROMPT=0`，仓库配置与钩子仍然生效。

预检要求路径合法、worktree 根被忽略、主检出目标文件没有未提交改动、分支可用，
且提交说明合法。land 模式要求主检出处于默认分支。隔离 worktree 从默认分支当前
提交开始；稀疏模式使用精确路径的非 cone 检出。首先尝试主检出 `merge --ff-only`；
默认分支前进时在隔离 worktree 中 rebase，核对新提交相对新基线的改动路径集合恰好
等于本次请求且仍在范围内，才重试一次；不符则以 `rebase_scope_changed` 保留提交与
分支。冲突时中止 rebase 并保留
原提交。commit-only 只提交并保留分支。清理删除 worktree；没有交付提交或提交已从
默认分支可达时才删除分支。未落地提交的分支始终保留。

日志为 `<git-common-dir>/computer-mcp/delivery/<operation_id>.json`，schema 1
记录操作 ID、工作区、范围、仓库、默认分支、交付分支、worktree 路径、基线 `base`、
`phase`、可选 `commit`、`merged`、可选终态与原因以及文件片段。写入顺序为同目录
临时文件、文件 fsync、改名、目录 fsync。

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
后、预检前也先恢复。恢复先中止进行中的 rebase，再按实际 Git 状态分类，包括提交
已生成但尚未写入日志的情况：无提交则清理为 `aborted`；提交从默认分支可达则清理
为 `merged`；未合并提交只删除 worktree，保留分支并归类为 `committed` /
`interrupted`。清理仍失败则保持 `cleanup_pending`，等待下次重试。

全部原因码：`scope_unknown`、`path_outside_scope`、`path_invalid`、
`match_missing`、`match_ambiguous`、`file_exists`、`file_missing`、`not_text`、
`main_checkout_dirty`、`main_checkout_branch`、`worktree_root_not_ignored`、
`branch_exists`、`message_invalid`、`busy`、`git_failed`、`commit_only`、
`not_fast_forward`、`rebase_conflict`、`rebase_scope_changed`、`journal_failed`、`interrupted`、
`cleanup_failed`。错误 ID 加 `delivery.` 前缀。完整字段和逐项原因释义见
[英文参考](../Delivery.md)。
