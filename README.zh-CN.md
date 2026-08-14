# Computer MCP

[English](README.md)

Computer MCP 是面向 macOS 的策略化 MCP 网关。App 统一拥有网关、Profile、
工作区授权、Provider 与 Tunnel 生命周期、Keychain 凭据和脱敏审计记录。本地
MCP 客户端、ChatGPT 和公网 MCP 消费者连接的都是同一个 App-owned Gateway。

> 普通 App 用户不需要 TOML。TOML 只用于明确的 standalone 开发和高级配置。

## 安装发行版

Computer MCP 要求 macOS 14 或更高版本。

1. 从提供当前构建的 Release 下载 `Computer-MCP-1.0.6-universal.dmg` 和
   `SHA256SUMS`。
2. 校验 DMG 摘要，打开后将 **Computer MCP** 拖入“应用程序”。
3. 从 Finder 启动安装后的 App。不要脱离 App bundle 单独运行可执行文件；macOS
   隐私权限绑定的是签名 App 身份。
4. 如需 CLI，可在 Home 选择 **Install Command Line Tool**，无需 `sudo`，会创建
   `~/.local/bin/computer-mcp`。

正式发行产物会经过 Developer ID 签名和 Apple 公证，并随校验和发布到 GitHub
Releases；源码构建或 ad-hoc 签名产物属于开发版，不是正式发行版。

## 首次启动

欢迎页提供四条入口：连接 ChatGPT、通过 Cloudflare 连接、连接本地 MCP 客户端，
以及浏览控制台。App 只保存 `onboarding_version = 1`；所有进度都从当前 App、
Gateway、依赖、Keychain、Transport 和审计记录推导。欢迎页可随时从侧栏重新打开。

状态含义：未配置、已阻塞、需要处理、已就绪、已验证。只有当前 Gateway/Tunnel
启动后出现匹配 Caller、Profile、Tunnel 身份的成功审计请求，才会进入“已验证”。

## 三种连接方式

- **本地 MCP**：在 Home 启动 Gateway，复制 stdio command/arguments；Codex 用户可
  预览并确认 App-owned `bridge --client-identity local-mcp` 注册命令。
- **ChatGPT**：在独立 ChatGPT 页面完成账号前置条件、Secure MCP Tunnel、
  `tunnel-client`、Keychain API Key、诊断、启动、ChatGPT App 创建和真实请求验证。
- **Cloudflare**：在独立 Cloudflare 页面完成 `cloudflared`、Remotely Managed
  Named Tunnel、hostname、Tunnel Token、一次性 Computer MCP Access Token、诊断、
  启动和公网消费者验证。

详细中文步骤：

- [快速开始](Documentation/Reference/zh-CN/QuickStart.md)
- [连接 ChatGPT](Documentation/Reference/zh-CN/ChatGPT.md)
- [连接 Cloudflare](Documentation/Reference/zh-CN/Cloudflare.md)
- [常见故障](Documentation/Reference/zh-CN/Troubleshooting.md)

## Doctor

```sh
computer-mcp doctor
computer-mcp doctor --journey local|chatgpt|cloudflare
computer-mcp doctor --journey cloudflare --json
```

仅 Ready 或 Verified 返回退出码 0。即使 App 不可达，schema 1 JSON 仍可解析；其中
不会包含 API Key、Tunnel Token 或 Access Token。

## 权限与安全

Accessibility 和 Screen Recording 只阻塞真正使用相应 Computer Use 能力的步骤，
不会阻塞普通只读或非 Computer Use 路径。权限必须授予实际执行操作的签名
`Computer MCP.app`；Terminal 或 Codex 已有的授权不会自动转移。

App Control Socket 与 Gateway Socket 均为当前用户独占的本地端点。远程 Profile
不会继承本地管理权限；`shell.run`、通用 CLI、进程启动、写操作和 Full Shell 默认
关闭。真实凭据只进入签名 App 私有 access group 下的 macOS Data Protection
Keychain；示例、Doctor、日志、诊断包、配置导出和审计记录只保留 placeholder 或
脱敏摘要。

## 高级开发

standalone 每个进程只读取一个 TOML：

```sh
swift run computer-mcp serve stdio --config Examples/computer-mcp.toml
swift run computer-mcp config validate --config Examples/computer-mcp.toml
```

本地产物只用于开发、测试和发布预演。正式 DMG 仅由受保护的 GitHub Actions
`production` Environment 处理 SSH 签名的 `vMAJOR.MINOR.PATCH` annotated tag 后
生成；CI 会完成 Developer ID 签名、App/DMG 公证、staple、Gatekeeper 校验并创建
Draft GitHub Release。完整配置和验收边界见
[发布参考](Documentation/Reference/Release.md)。

standalone 不使用 App 的 bookmark、数据库或 Keychain Tunnel 凭据，不应作为第二个
App 状态所有者同时运行。示例用途见 [Examples/README.md](Examples/README.md)；完整
CLI、协议和工具参考继续以英文文档为准。
