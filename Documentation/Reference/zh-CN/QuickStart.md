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
2. 复制 App 展示的 command 与 arguments 到本地 MCP 客户端。
3. Codex 用户选择 **Register with Codex**，核对预览后确认。注册命令使用 App-owned
   bridge，不读取 TOML。
4. 发起一次工具调用并刷新；出现匹配 `local-mcp` 的成功审计请求后状态为 Verified。

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
