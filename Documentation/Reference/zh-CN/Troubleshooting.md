# 常见故障

## 先运行 Doctor

```sh
computer-mcp doctor --journey local
computer-mcp doctor --journey chatgpt
computer-mcp doctor --journey cloudflare
computer-mcp doctor --journey chatgpt --json
```

Ready/Verified 返回 0，其他状态返回 1。App 不可达时 JSON 仍符合 `schema_version: 1`。

## App 不可达

- 从 Finder 打开 `/Applications/Computer MCP.app`。
- 确认没有把 embedded CLI 或 App 可执行文件单独复制到别处运行。
- 回到 Home 选择 Retry；CLI 不会静默启动第二套数据库或 Gateway。

## 无法添加工作区

**工作区 > 添加** 在所有受支持系统上都会打开 macOS 原生文件夹面板。选择文件夹
本身并点 **添加**，原工作区页面会原位刷新；如果面板已经进入目标文件夹，先返回
上一级再选中它。面板未出现属于 App 界面呈现问题，不是网络安全、反爬、Shell 或
Keychain 拒绝。

## 依赖缺失

```sh
command -v codex
command -v tunnel-client
command -v cloudflared
cloudflared --version
```

App 只检测依赖，不会自动安装。使用任务页提供的官方入口安装后重试。

Computer MCP 的 `codex.exec.*` 会保留当前用户已有的 Codex 登录，但通过官方
`--ignore-user-config` 模式隔离全局 `config.toml`。因此交互式 Codex 中失效或缓慢的
MCP server、model、hook、profile 不会被 Gateway 的 Exec 调用启动；请在交互式
Codex 中单独修复这些用户配置，不要向 Computer MCP 复制凭据。

## 权限拒绝或撤销

1. 在 **Permissions** 重新预检。
2. 选择 Request Access；如系统没有打开正确页面，按 App 提供的手动路径进入
   “系统设置 > 隐私与安全性”。
3. 权限必须授予签名 `Computer MCP.app`。
4. 返回 App 后等待自动轮询；系统提示时重启 App。

权限撤销会立即影响需要该权限的能力，但不阻塞普通文件、系统和非 Computer Use 路径。

## Ready 但没有 Verified

- Ready 只表示 Transport 和本地组件健康。
- 必须由目标消费者在当前 Gateway/Tunnel 启动之后发起真实成功请求。
- 核对 Caller、Profile 和 Tunnel identity；被拒绝或失败的审计记录不会验证路径。
- 新建 ChatGPT 会话或重连公网消费者，再调用一个只读工具并刷新。

## 安全地收集诊断

在 **Diagnostics** 导出诊断包。包内日志和摘要会脱敏；不要手工粘贴 Keychain 内容、
API Key、Tunnel Token 或 Computer MCP Access Token。一次性 Access Token 关闭后无法
重新显示，遗失时请重新生成并更新消费者。
