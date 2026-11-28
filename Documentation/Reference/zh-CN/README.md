# 简体中文上手文档

- [快速开始](QuickStart.md)
- [连接 ChatGPT](ChatGPT.md)
- [连接 Cloudflare](Cloudflare.md)
- [常见故障](Troubleshooting.md)
- [执行工具](Executions.md)：游标续读、输入、取消、限额与重启恢复。
- [工作树](Worktrees.md)：创建、编辑、构建、提交、合并与清理。

这些文档镜像用户上手与故障恢复路径。完整 CLI、MCP 协议、工具 Schema、发行与
Validation 参考继续以英文文档为准；命令名、JSON key、配置 ID、错误码和路径不会
本地化。

通过 `git.worktree_add` 创建继承源项目权限的工作树，同一连接可立即使用返回的
`project_id`。在其中编辑、构建和提交，再用 `git.merge` 快进合并。
