# Computer MCP

**面向 AI Agent、由策略控制且限定工作区的本地执行网关。**

Computer MCP 把 ChatGPT、Codex 和其他兼容 MCP 的客户端连接到已注册的工作区、
CLI、桌面应用、开发工具，以及可选的 Codex Runtime，同时不会把整台 Mac 变成一个
不受约束的远程 Shell。

当 Agent 需要在你的电脑上完成真实工作，而访问仍需明确所有者、范围、审批边界和
审计记录时，就适合使用 Computer MCP。

[快速开始](#快速开始) · [产品官网](https://computer-mcp.github.io/) ·
[文档](Documentation/README.md) ·
[最新版本](https://github.com/computer-mcp/computer-mcp/releases/latest) ·
[English](README.md)

Computer MCP 面向希望使用本地执行能力、但不愿把整台机器交给 AI 客户端的开发者和
技术团队。它提供：

- 以已注册文件夹替代无边界文件系统访问；
- 以能力范围明确的 Profile 替代一套共享权限；
- 类型化工具、已注册 CLI、下游 MCP、Skills、Computer Use、受治理 Git 和可选
  Codex 执行；
- 本地策略校验，以及对高风险操作的显式同意；
- 对请求和结果进行脱敏、关联的审计记录；
- 本地、ChatGPT 和经过审查的远程连接路径。

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
 Builtin · Skill · CLI · MCP · Computer Use · Git · Shell · Codex Adapter
                 │
                 ▼
        本地执行 → 有界结果 → 脱敏审计凭据
```

每次调用都绑定到调用方、Profile、能力和相关的已注册工作区。未知工具、未授权
工作区、不安全路径和无法验证的所有权声明都会 fail closed。

## 能做什么

- 让 ChatGPT 查看已注册项目、使用本地研究工具，并把实现任务交给 Codex，而不是
  暴露整个用户目录。
- 让 Agent 通过受审查的路径编辑、暂存、执行仓库 Hook、提交、检查结果并证明
  Worktree 干净，同时默认不授予宽泛 Shell。
- 让确定性的本地 CLI、下游 MCP Server 和可复用 Skill Package 共用同一套策略与
  审计平面。
- 通过有界 Computer Use 能力观察或控制桌面 UI，并在执行前检查相应 macOS 权限。
- 让 ChatGPT 通过 OpenAI Secure MCP Tunnel，或让经过审查的远程客户端通过
  Cloudflare Named Tunnel，访问同一个本地执行网关。
- 可选运行 Codex App Server、Exec 或 MCP 生命周期，并明确 Runtime、Thread、
  Approval、Goal 与 Worktree 所有权。

## 为什么比直接开放 Shell 更安全

Computer MCP 始终把两个决定分开：

1. **策略授权**：这个调用方是否可以在这个已注册工作区使用该能力？
2. **操作同意**：如果该能力已获准但本次操作风险较高，用户或被授权调用方现在是否
   同意？

审批不会扩张策略。被策略禁止的能力不会因为点击“批准”就变成允许。`shell.run`、
通用 CLI、进程启动、工作区写入、破坏性操作和 Full Shell 都保持关闭，除非当前
配置明确授予对应路径。凭据保存在签名 App 的 macOS Data Protection Keychain；
示例、诊断、日志和审计只保留占位符或脱敏摘要。

完整边界见[安全与隐私架构](Documentation/Architecture/SecurityAndPrivacy.md)，安全问题
请按 [SECURITY.md](SECURITY.md) 报告。

## 能力状态

| 状态 | 能力 | 说明 |
| --- | --- | --- |
| 稳定 | App-owned 本地网关、工作区注册、Profile、策略、Operation Ticket 和脱敏审计 | macOS 14+ 默认产品控制平面 |
| 稳定 | 本地 MCP、经 OpenAI Secure MCP Tunnel 连接 ChatGPT、Cloudflare Named Tunnel | 每条远程路径都有独立 Caller 与 Profile 边界 |
| 稳定 | Builtin、Skill、已注册 CLI、下游 MCP、Shell 与 Computer Use Adapter | 是否可用仍取决于 Profile、工作区、依赖和 macOS 权限 |
| 稳定 | 受治理的工作区与 Git 操作 | 写入需要策略授权；破坏性原子操作使用经审查的一次性 Ticket；不会隐式 Push |
| 实验性 | Codex App Server、Exec 与 MCP Provider | 选择性启用、默认关闭，并依赖已安装且完成认证的 Codex |
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

## Computer MCP 与 Codex Remote

普通的远程 Codex 工作，优先使用 **官方 Codex Remote**。它是 Codex 第一方的远程
控制体验；当完整流程就是 Codex 本身时，它是更合适的选择。

当流程需要通用且兼容 MCP 的本地执行平面时，使用 **Computer MCP**：多个 AI
客户端、已注册工具与应用、工作区/Profile 策略、自定义审批规则、关联审计，或与
其他本地能力组合的可选 Codex 编排。

以下所有权模式彼此独立：快速 Codex Thread/Turn、Computer MCP-owned Codex
Runtime、官方持久化 Codex Goal、单独的 Computer MCP 验收 Run、官方 Codex
Remote，以及外部 Codex Desktop、IDE 或 CLI 会话。

Computer MCP 只能释放或停止能够验证为自己所有的 Runtime。它可以显式尝试重新
接管一个持久化 Thread，也能解释可能的 Writer 冲突，但不会声称有权终止其他应用的
进程或订阅。

## 快速开始

Computer MCP 要求 macOS 14 或更高版本。

1. 从[最新版本](https://github.com/computer-mcp/computer-mcp/releases/latest)下载已
   公证的 Universal 2 DMG 和 `SHA256SUMS`。
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
- [生产级验收合同](Documentation/Reference/ProductizationAcceptance.md)
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

正式版本只来自受保护的签名 Tag Workflow。它负责构建、Developer ID 签名、公证、
Staple、验证并创建 Draft GitHub Release；发布仍是独立的人工验收步骤。完整流程见
[Release Reference](Documentation/Reference/Release.md)。

Computer MCP 按 [LICENSE](LICENSE) 中的条款提供。
