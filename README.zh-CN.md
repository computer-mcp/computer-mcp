<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Documentation/Brand/header-zh-CN-dark.png">
  <img alt="Computer MCP — 聊天在哪，你的电脑就在哪。" src="Documentation/Brand/header-zh-CN-light.png">
</picture>

# Computer MCP

**聊天在哪，你的电脑就在哪。**

让 ChatGPT 或其他兼容 MCP 的客户端直接使用本机能力。组合类型明确的工具、CLI、
MCP、Skills 与 Computer Use，跨多台电脑推进工作，每台宿主独立管理访问权限。
Codex 是可选集成。

[快速开始](#快速开始) · [产品官网](https://computer-mcp.github.io/) ·
[文档](Documentation/README.md) ·
[最新版本](https://github.com/computer-mcp/computer-mcp/releases/latest) ·
[English](README.md)

- **接上你的 CLI 工具。** 注册命令或安装 CLI 插件，让 ChatGPT 调用已开放的工具、
  读取执行结果。
- **在对话里调用 Codex 写代码。** 使用独立 Codex 插件启动任务、跟进进度、查看结果。
- **用 MCP 和 Skills 扩展工作方式。** 直接接入 MCP 服务与可复用说明，或通过插件组合。
- **跨多台电脑工作。** 连接各台宿主，选择对应工作区，在那台电脑的环境里使用工具。
- **开放什么，由你决定。** 配置工具、工作区与确认策略，在本机批准需要确认的宿主操作。

Computer MCP 支持 macOS 14 或更新系统，可供 ChatGPT 和其他兼容 MCP 的客户端使用。
工具需安装并配置。Codex 需要对应插件与本机 Codex，高级编排为实验能力。
Skills 提供说明和资源，实际执行使用已授权的工具。

## 30 秒理解工作方式

```text
ChatGPT · Codex · 其他 MCP 客户端
                 │
              已认证连接
                 ▼
          Computer MCP.app
                 │
 调用方 → Profile → 已注册工作区 → 策略 → 必要时审批
                 │
                 ▼
 Builtin · Skills · CLI · MCP · AX 兜底 · Git · Shell
                 │
                 ▼
        本地执行 → 有界结果 → 脱敏审计凭据
```

每次调用都绑定到调用方、Profile、能力和相关的已注册工作区。未知工具、未授权
工作区、不安全路径和无法验证的所有权声明都会 fail closed。

每台宿主独立保有凭据、注册、审批和审计。工作区 ID 只属于对应宿主；连接多台
电脑不会共享文件或迁移运行中的进程。完整模型见
[产品定位](Documentation/Architecture/ProductIdentity.md)。

## 插件与直接集成

Plugin 是可以组合 MCP、CLI 和 Skills 的分发包。原生 MCP、本地 CLI 与 Skill
也支持直接注册；两种来源共用宿主策略、工作区范围和审计。

可以使用 App 的插件管理页面，或本机管理 CLI：

```sh
computer-mcp plugins search --refresh
computer-mcp plugins list
```

官方包包括 [Codex](https://github.com/computer-mcp/plugin-codex)、
[Computer Use](https://github.com/computer-mcp/plugin-computer-use)、
[Claude Code](https://github.com/computer-mcp/plugin-claude)、
[Cursor](https://github.com/computer-mcp/plugin-cursor)、
[Swift Format](https://github.com/computer-mcp/plugin-swift-format) 和
[TRAE](https://github.com/computer-mcp/plugin-trae)（需要仓库访问权限）。选择发布附件安装，
检查依赖和工具暴露范围后再启用。新安装默认停用，不自动授予权限。Bundled 包
走相同生命周期，外部工具仍由用户或厂商管理。

Codex 执行位于独立 MCP adapter。升级已有内置 Codex 配置时，需要执行显式的
[配置与离线状态迁移](Documentation/Reference/CodexMigration.md)，不能热替换正在
执行迁移任务的后端。原生 Computer Use 还受厂商调用者认证限制，并非仅授予
macOS 隐私权限即可保证可用；原生 AX 工具继续作为兜底路径。

安装、升级与恢复见[插件包](Documentation/Reference/PluginPackages.md)；经过验证的
命令投影和结构化覆盖范围见 [CLI Trees](Documentation/Reference/CLITrees.md)。

## 能做什么

- 让 ChatGPT 查看本地项目、调用已接入的资料工具，再把实现任务交给 Codex。
- 运行已注册的格式化工具、检查 Git diff，或通过已授权的本机命令处理文件，
  根据结果继续下一步。
- 围绕一个任务，组合 CLI 命令、下游 MCP 服务与可复用 Skills。
- 通过 Secure MCP Tunnel 从 ChatGPT 接入，或通过 Cloudflare Named Tunnel
  接入经过审查的远程客户端，具体取决于客户端及账号支持。
- 通过 Computer Use 插件或原生 AX 工具接入桌面操作，实际可用性受相应 macOS
  权限和厂商调用者认证约束。

## 决定 Agent 能使用什么

Computer MCP 始终把两个决定分开：

1. **策略授权**：这个调用方是否可以在这个已注册工作区使用该能力？
2. **操作同意**：如果该能力已获准但本次操作风险较高，用户或被授权调用方现在是否
   同意？

在 App 的**客户端权限**页面查看已连接的客户端，并明确授予完全访问权限，默认
**仅此会话**。完全访问允许以您的 macOS 用户身份执行任意命令；工作区提供项目
上下文，不是沙箱。**始终允许此客户端**是独立的选择。您可以降级或结束某个连接
的访问，也可以单独撤销已保存的客户端授权。权限变更立即适用于新请求，不会取消
已开始的工作。本地 `computer-mcp clients` 命令提供相同的权限控制，明确授权和
独立 HTTP 用法见[客户端权限](Documentation/Reference/CLI.md#client-access)。

通过**选择受限权限**按名称勾选能力、项目和集成，并明确允许哪些连接类型使用它们。
这些默认权限适用于共享该配置的客户端，每个会话仍可限制为更低的访问级别。
保存新的选择会使该配置之前的完全访问授权失效。

在 App 管理的连接中，已批准的完全访问还可使用类型明确的工具管理工作区，以及
安装、配置和更新经过验证的官方插件。配置变化会保留已有任务，具体参数见
[远程管理](Documentation/Reference/ControlPlaneCapabilities.md#remote-management)。

单次操作审批不会扩大客户端的当前权限。受限访问只能使用所选工具和工作区，
禁止任意执行。凭据保存在签名 App 的 macOS Data Protection Keychain；示例、
诊断、日志和审计只保留占位符或脱敏摘要。

完整边界见[安全与隐私架构](Documentation/Architecture/SecurityAndPrivacy.md)，安全问题
请按 [SECURITY.md](SECURITY.md) 报告。

## 能力状态

| 状态 | 能力 | 说明 |
| --- | --- | --- |
| 稳定 | App-owned 本地网关、工作区注册、Profile、策略、Operation Ticket 和脱敏审计 | macOS 14+ 默认产品控制平面 |
| 稳定 | 本地 MCP、经 OpenAI Secure MCP Tunnel 连接 ChatGPT、Cloudflare Named Tunnel | 每条远程路径都有独立 Caller 与 Profile 边界 |
| 稳定 | Builtin、Skill、已注册 CLI、下游 MCP、Shell 与原生 AX 兜底 | 是否可用仍取决于 Profile、工作区、依赖和 macOS 权限 |
| 稳定 | 受治理的工作区与 Git 操作 | 写入需要策略授权；破坏性原子操作使用经审查的一次性 Ticket；不会隐式 Push |
| 稳定 | 插件包生命周期、直接／插件 MCP 注册、经过验证的 CLI Tree 与 Skills | 宿主授权独立，不自动安装外部依赖 |
| 实验性 | Codex 插件的 App Server、Exec 与 MCP Provider | 选择性启用、默认关闭，并依赖已安装且完成认证的 Codex |
| 实验性 | 原生 Codex Goal 透传、Computer MCP 验收 Run、线程占用诊断和受管子 Worktree | 官方 Goal、Computer MCP 验收与外部客户端所有权始终分开 |
| 规划中 | 更广的平台支持和更完整的高级编排 UI | 暂无承诺日期；当前签名 App 仅支持 macOS |

“实验性”不等于无边界；这些路径仍遵守与稳定能力相同的工作区、策略、审批、
生命周期、资源上限和审计规则。

## ChatGPT 编排，Codex 执行

一个典型流程如下：

1. ChatGPT 通过 Computer MCP 检查已注册仓库并收集本地上下文。
2. Computer MCP 把请求绑定到 ChatGPT Profile 和工作区，由策略决定可用的读取、
   Git、CLI 与 Codex 能力。
3. ChatGPT 为该工作区启动或 Steer 一个独立 Codex 任务。
4. Codex 请求受治理的写操作；Computer MCP 持久化脱敏审批记录，由用户或被授权
   调用方批准或拒绝。
5. Codex 通过受治理路径修改并提交；Computer MCP 关联 Codex 请求、审批、
   Operation Ticket、网关调用、Git 结果和审计记录。
6. Computer MCP 验收 Run 会一直保持活动，直到必须的 Build、Test 和干净 Worktree
   证据被显式接受；仅仅结束一个 Turn 不等于完成。

这是一种可选编排能力，不是在声称 Computer MCP 就是 Codex Remote。

## Computer MCP、Dots 与 Codex Remote

| 选择 | 适合的工作 |
| --- | --- |
| **Computer MCP** | 跨电脑、跨兼容 MCP 客户端，直接组合使用受治理的通用本机能力 |
| **OpenAI Dots** | 带记忆、应用和主动跟进的常驻云端 Agent；同时连接一台个人电脑 |
| **Codex Remote** | 跨已连接电脑启动、跟进、审批和审查 Codex 编程任务 |

Computer MCP 调用普通已注册工具不要求启动 Codex 任务，每台宿主执行自己的能力。
Dots 还有独立的云端电脑；Codex Remote 在选定的已连接宿主上执行编程任务。
账号和服务用量条款仍然适用。
[完整对比](https://computer-mcp.github.io/#comparison)说明接口、执行和权限边界，
OpenAI 官方来源于 2026-10-01 核实。

以下所有权模式彼此独立：快速 Codex Thread/Turn、Computer MCP-owned Codex
Runtime、官方持久化 Codex Goal、单独的 Computer MCP 验收 Run、官方 Codex
Remote，以及外部 Codex Desktop、IDE 或 CLI 会话。

Computer MCP 只能释放或停止能够验证为自己所有的 Runtime。它可以显式尝试重新
接管一个持久化 Thread，也能解释可能的 Writer 冲突，但不会声称有权终止其他应用的
进程或订阅。

## 快速开始

Computer MCP 要求 macOS 14 或更高版本。

1. 从[最新版本](https://github.com/computer-mcp/computer-mcp/releases/latest)下载已
   公证的 Universal 2 DMG 和 `SHA256SUMS`；也可以用 Homebrew 安装，然后直接打开 App：

   ```sh
   brew install --cask computer-mcp/tap/computer-mcp
   ```

2. 校验摘要，将 **Computer MCP** 拖入“应用程序”，并从 Finder 打开安装后的 App。
   macOS 隐私授权绑定的是这个签名 App 身份。
3. 在欢迎页选择 **连接本地 MCP 客户端**，然后启动 Gateway。
4. 把页面显示的 stdio 命令复制到客户端。Codex 用户也可以预览并确认
   **Register with Codex**。
5. 发起第一个只读工具调用：

   ```text
   workspace.list
   ```

6. 刷新 Home。只有观察到匹配且成功的审计事件，连接才会进入 Verified。

也可以在 Home 安装随 App 提供的 CLI；它无需 `sudo`，会创建
`~/.local/bin/computer-mcp`。在终端检查同一套实时状态：

```sh
computer-mcp doctor --journey local
computer-mcp doctor --journey local --json
```

只有 Ready 或 Verified 才返回退出码 0。即使 App 不可用，schema-1 JSON 仍可解析，
并且不会包含凭据值。

后续可阅读[快速开始](Documentation/Reference/QuickStart.md)、
[ChatGPT Runbook](Documentation/Reference/ChatGPTWebRunbook.md)或
[Cloudflare Runbook](Documentation/Reference/CloudflareRunbook.md)。普通 App 用户不
需要 TOML。

## 架构

App 统一拥有 Gateway、私有 Control Socket、工作区 Bookmark、Profile、Provider
与 Tunnel 生命周期、Keychain 凭据和审计数据库。本地客户端使用当前用户独占的
Unix-domain Socket；ChatGPT 使用 OpenAI Secure MCP Tunnel；经审查的公网 MCP
消费者可使用 Cloudflare Remotely Managed Named Tunnel 背后的 loopback-only、
Bearer-protected Origin。

Gateway 解析精确工具名，绑定 Caller/Profile/Workspace，检查策略和 Operation
Ticket，在需要时获得操作同意，分发一个有界 Adapter，并记录脱敏结果。Standalone
TOML 模式只用于开发和诊断，不共享 App 的 Bookmark 或 Keychain 状态。

当前架构见 [Gateway](Documentation/Architecture/Gateway.md)、
[Runtime](Documentation/Architecture/Runtime.md)和
[能力所有权](Documentation/Architecture/Ownership.md)；完整命令与 Schema 见
[Reference](Documentation/Reference/README.md)。

## Codex 运维与诊断

可选 Codex Provider 会记录自己拥有的 Runtime ID、Process Group、连接代次、已加载
Thread、活动 Turn、Approval、Shutdown Reason 和终止升级。持久化所有权凭据使后续
Computer MCP 代次能在尝试 Resume 前验证 Thread 所属工作区。

无需手工检查进程和打开文件即可读取同一份证据：

```sh
computer-mcp codex diagnose-thread <thread-id> --workspace-id <workspace-id>
computer-mcp codex diagnostics --workspace-id <workspace-id>
```

诊断会区分可验证的 Computer MCP 所有权与推断出的外部冲突，并且只提供安全动作，
例如释放自有 Thread、停止精确的自有 Runtime、审查过期凭据，或尝试重新接管持久化
Thread。

## 当前限制

- 签名产品目前仅支持 macOS 14 或更高版本。
- 远程连接依赖用户自己的 OpenAI 或 Cloudflare 服务，以及相应账号、管理员、网络
  和可用性条件。
- 需要 Accessibility 或 Screen Recording 的能力必须把权限授予已安装的签名 App；
  其他能力不受影响。
- 高级 Codex Provider 需要显式启用，并依赖已安装的官方 Codex 版本、认证与稳定
  协议支持。
- Computer MCP 无法检查、取消订阅或终止不属于自己的外部 Codex Desktop、IDE、
  CLI 或 Remote 连接。
- 多个合格工作区存在时不会静默选择一个；不会隐式 Push Git Commit，也不会把普通
  Turn 完成冒充为 Goal 已验收。
- 开发构建或 ad-hoc 签名 App 不是正式版本，也不会继承已安装正式版的 macOS 隐私
  与 Keychain 身份。

## 文档导航

- [文档首页](Documentation/README.md)
- [快速开始](Documentation/Reference/QuickStart.md)
- [CLI Reference](Documentation/Reference/CLI.md)
- [配置 Reference](Documentation/Reference/Config.md)
- [工具 Reference](Documentation/Reference/Tools.md)
- [常见故障](Documentation/Reference/Troubleshooting.md)
- [架构](Documentation/Architecture/README.md)
- [安全与隐私](Documentation/Architecture/SecurityAndPrivacy.md)
- [发布流程](Documentation/Reference/Release.md)

## 开发与贡献

修改 Product 或 Target 前先检查 [Package.swift](Package.swift)。在仓库根目录构建与
测试：

```sh
swift-format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
/usr/bin/swift build
/usr/bin/swift test
```

Standalone 开发模式每个进程只使用一个显式 TOML：

```sh
swift run computer-mcp serve stdio --config Examples/computer-mcp.toml
swift run computer-mcp config validate --config Examples/computer-mcp.toml
swift run computer-mcp tools list --config Examples/computer-mcp.toml
```

Standalone 不使用 App-owned Bookmark、数据库状态或 Keychain Tunnel 凭据，也不能
作为第二个 App 状态所有者同时运行。提交修改前请阅读
[Examples](Examples/README.md)和 [CONTRIBUTING.md](CONTRIBUTING.md)。

正式版本来自 canonical master 的受保护发布 Workflow。源码检查、构建、Developer ID
签名、公证、Staple、签名 Tag、附件上传和正式发布均在 GitHub Actions 完成，官网自动
同步公开发布记录。完整流程见
[Release Reference](Documentation/Reference/Release.md)。

Computer MCP 采用 [Functional Source License 1.1，Apache 2.0 Future License](LICENSE)
（FSL-1.1-ALv2）：除做竞争产品或服务外，任何用途都可以；每个版本发布两年后转为
Apache-2.0。官方可执行版本另附[最终用户许可协议](EULA.md)。
