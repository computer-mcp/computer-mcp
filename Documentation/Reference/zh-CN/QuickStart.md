# 快速开始

## 安装与首次启动

1. 校验 Release 提供的 DMG SHA-256，将 **Computer MCP** 拖入“应用程序”。
2. 从 Finder 打开签名 App。普通 App 用户不需要 TOML。
3. 在欢迎页选择本地 MCP、ChatGPT、Cloudflare 或直接浏览 Home。
4. 在 Home 启动 Gateway。Home 只显示一个明确的下一步。

App 只记录 onboarding 版本；“已完成”从真实依赖、配置、进程、Keychain 和审计
状态推导。

## 本地 MCP 客户端

1. 在 Home 查看 App、Gateway 和 CLI 状态。
2. 在 **Connect a local MCP client** 中，点 Codex、Claude Code 或 Claude Desktop
   旁的 **连接…**，核对设置文件与命令后确认。确认 Claude Desktop 的更改前先退出
   Claude Desktop。**更新…** 替换同名的不同条目，**移除…** 删除它，两者都先经过同样的核对。
3. 新建 Codex 或 Claude Code 会话，或重新打开 Claude Desktop。
4. 发起一次工具调用并刷新；出现匹配 `local-mcp` 的成功审计请求后状态为 Verified。

其他客户端可在 **其他 MCP 客户端** 中复制 stdio 命令。内嵌 CLI 也提供同样的注册：
`computer-mcp install <client> --app --dry-run` 与 `computer-mcp uninstall <client>`，
见[CLI 参考](../CLI.md#local-client-registration)。

可选安装 CLI：

```sh
"/Applications/Computer MCP.app/Contents/Resources/computer-mcp" install cli
computer-mcp doctor --journey local
```

## 状态

- `not_configured`：还没有该路径的配置。
- `blocked`：依赖、凭据或必要组件缺失。
- `needs_attention`：已有配置，但运行步骤尚未完成。
- `ready`：本地组件、依赖、配置和 Transport 均健康。
- `verified`：当前启动边界之后出现匹配身份的真实成功请求。

## 权限

只有相应 Computer Use 能力真正启用时，Accessibility 或 Screen Recording 才是阻塞
项。拒绝后仍可返回 App 重试、手动打开正确的系统设置页或进入高级诊断。

## 项目配置升级

App 先在一个数据库事务中升级项目表、列、索引和现行授权，再打开 App 管理的
TOML 清单。清单中的旧配置字段、工具 ID 和模式值通过原子文件事务升级，验证成功
后新增一条配置修订。项目 ID、路径和插件参数保持原值；历史修订、审计和已完成
操作的记录不改写，派生登记的持久化内容和摘要保持稳定。

数据库与清单升级各自原子。清单验证或提交失败会报告错误并保留原文件；数据库
即使已经升级，下次启动仍会重试清单升级。已升级的清单再次打开不会新增修订。
独立模式的 `--config` 文件由用户维护：旧名称会使校验失败，错误信息提示新名称，
程序不会改写文件。
