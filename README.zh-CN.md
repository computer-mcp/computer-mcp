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
- **跨多台电脑工作。** 连接各台宿主，选择对应项目，在那台电脑的环境里使用工具。
- **开放什么，由你决定。** 配置工具、项目与确认策略，在本机批准需要确认的宿主操作。

Computer MCP 支持 macOS 14 或更新系统，可供 ChatGPT 和其他兼容 MCP 的客户端使用。
工具需按各插件的说明安装并配置。
Skills 提供说明和资源，实际执行使用已授权的工具。

## 30 秒理解工作方式

```text
ChatGPT · Codex · 其他 MCP 客户端
                 │
              已认证连接
                 ▼
          Computer MCP.app
                 │
 调用方 → Profile → 已注册项目 → 策略 → 必要时审批
                 │
                 ▼
 Builtin · Skills · CLI · MCP · AX 兜底 · Git · Shell
                 │
                 ▼
        本地执行 → 有界结果 → 脱敏审计凭据
```

每次调用都绑定到调用方、Profile、能力和相关的已注册项目。未知工具、未授权
项目、不安全路径和无法验证的所有权声明都会 fail closed。

每台宿主独立保有凭据、注册、审批和审计。项目 ID 只属于对应宿主；连接多台
电脑不会共享文件或迁移运行中的进程。完整模型见
[产品定位](Documentation/Architecture/ProductIdentity.md)。

## 插件与直接集成

Plugin 是可以组合 MCP、CLI 和 Skills 的分发包。原生 MCP、本地 CLI 与 Skill
也支持直接注册；两种来源共用宿主策略、项目范围和审计。

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

原生 Computer Use 还受厂商调用者认证限制，并非仅授予
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

1. **策略授权**：这个调用方是否可以在这个已注册项目使用该能力？
2. **操作同意**：如果该能力已获准但本次操作风险较高，用户或被授权调用方现在是否
   同意？

在 App 的**客户端权限**页面查看已连接的客户端，并明确授予完全访问权限，默认
**仅此会话**。完全访问允许以您的 macOS 用户身份执行任意命令；项目提供项目
上下文，不是沙箱。**始终允许此客户端**是独立的选择。您可以降级或结束某个连接
的访问，也可以单独撤销已保存的客户端授权。权限变更立即适用于新请求，不会取消
已开始的工作。本地 `computer-mcp clients` 命令提供相同的权限控制，明确授权和
独立 HTTP 用法见[客户端权限](Documentation/Reference/CLI.md#client-access)。

通过**选择受限权限**按名称勾选能力、项目和集成，并明确允许哪些连接类型使用它们。
这些默认权限适用于共享该配置的客户端，每个会话仍可限制为更低的访问级别。
保存新的选择会使该配置之前的完全访问授权失效。

在 App 管理的连接中，已批准的完全访问还可使用类型明确的工具管理项目，以及
安装、配置和更新经过验证的官方插件。配置变化会保留已有任务，具体参数见
[远程管理](Documentation/Reference/ControlPlaneCapabilities.md#remote-management)。

单次操作审批不会扩大客户端的当前权限。受限访问只能使用所选工具和项目，
禁止任意执行。凭据保存在签名 App 的 macOS Data Protection Keychain；示例、
诊断、日志和审计只保留占位符或脱敏摘要。

文件与结构化工具逐级检查目录句柄，拒绝检查时发现的符号链接和已有多硬链接文件，
保护 Git 元数据与配置。新建文件完成后通过描述符检查链接数；并发链接可能在检查前
读到内容，具体边界见[工具参考](Documentation/Reference/Tools.md#file-mutation-boundaries)。
元数据修改后重查路径、父目录与链接数，失败时通过原句柄
恢复模式、时间和受影响的扩展属性。解压只列举一次，通过暂存目录描述符启动 tar，
将单次提取的内容流写入宿主创建的文件，核对后通过锚定重命名发布。
解压保留归档成员的修改时间；目录模式与时间在内容发布和暂存清理完成后，从深到浅恢复。
已有的目标目录保留自身的模式与时间。
清理要求设备号、inode 和纳秒级出生时间均与创建记录一致；没有出生时间的文件系统
使用保留描述符回退，每次操作最多 64 个，并预留清理容量。
外来条目保留在暂存目录中，错误会列出保留路径。
废纸篓操作拒绝项目根目录、先检查所有成员，允许
多硬链接普通文件。这些检查不构成并发事务隔离；检查时点和回滚限制见工具参考。
SQLite 查询使用安全模式，CLI 帮助只返回登记的元数据。
Linux 的 tar 格式解压使用 GNU tar，ZIP 格式解压需要登记 `bsdtar` 可执行文件。
未提供归档工具或 SQLite CLI 绑定时，工具在创建目标或启动相应命令前返回不可用错误。
文件移动仅限同卷；
macOS 复制保留数据、扩展属性、资源叉、ACL、模式和时间，跨卷请先复制，再删除源文件。
glibc Linux 复制保留数据、模式、访问与修改时间、可见扩展属性（含 POSIX ACL），
所有权沿用新建目标；macOS 资源叉、创建时间和 BSD 文件标志不在 Linux 复制范围内。
写入保护各层级的 `.git` 路径分量，比较前做 Unicode 规范化并忽略大小写。
文件访问创建时检查布局：根目录 `.git` 为符号链接，或项目内的 Git 目录、公共目录
不在含 `.git` 的路径下时，拒绝该项目的全部写入。宿主 Git 在每次调用前拒绝
含 `include` 或 `includeIf` 条目的本地配置。
宿主 Git 操作禁用仓库配置指定的程序，`git.commit` 只提交
明确的 `paths`，保留其他已暂存改动。

完整边界见[安全与隐私架构](Documentation/Architecture/SecurityAndPrivacy.md)，安全问题
请按 [SECURITY.md](SECURITY.md) 报告。

## 能力状态

| 状态 | 能力 | 说明 |
| --- | --- | --- |
| 稳定 | App-owned 本地网关、项目注册、Profile、策略、Operation Ticket 和脱敏审计 | macOS 14+ 默认产品控制平面 |
| 稳定 | 本地 MCP、经 OpenAI Secure MCP Tunnel 连接 ChatGPT、Cloudflare Named Tunnel | 每条远程路径都有独立 Caller 与 Profile 边界 |
| 稳定 | Builtin、Skill、已注册 CLI、下游 MCP、Shell 与原生 AX 兜底 | 是否可用仍取决于 Profile、项目、依赖和 macOS 权限 |
| 稳定 | 受治理的项目与 Git 操作 | 写入需要策略授权；破坏性原子操作使用经审查的一次性 Ticket；不会隐式 Push |
| 稳定 | 插件包生命周期、直接／插件 MCP 注册、经过验证的 CLI Tree 与 Skills | 宿主授权独立，不自动安装外部依赖 |
| 规划中 | 更广的平台支持和更完整的高级编排 UI | 暂无承诺日期；当前签名 App 仅支持 macOS |

## ChatGPT 编排，Codex 执行

ChatGPT 可以查看已注册项目，并通过独立的 [Codex 插件](https://github.com/computer-mcp/plugin-codex)
执行编程任务。宿主管理工具授权、项目、审批与审计；插件负责执行与运行时生命周期。

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
4. 在 Home 中点 Codex、Claude Code 或 Claude Desktop 旁的 **连接…**，核对更改后确认；
   确认 Claude Desktop 的更改前先退出 Claude Desktop。终端中可使用
   [注册命令](Documentation/Reference/CLI.md#local-client-registration)完成同样的操作。
5. 发起第一个只读工具调用：

   ```text
   project.list
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

App 统一拥有 Gateway、私有 Control Socket、项目 Bookmark、Profile、Provider
与 Tunnel 生命周期、Keychain 凭据和审计数据库。本地客户端使用当前用户独占的
Unix-domain Socket；ChatGPT 使用 OpenAI Secure MCP Tunnel；经审查的公网 MCP
消费者可使用 Cloudflare Remotely Managed Named Tunnel 背后的 loopback-only、
Bearer-protected Origin。

Cloudflare 连接支持可选的 OAuth，可供 claude.ai 等使用 CIMD 的公开客户端接入。
在 App 的 Cloudflare 连接编辑器中打开「允许通过 OAuth 登录」（也可用所有者 CLI
或清单）后，客户端登录时在「客户端权限」页核对六位配对码、选择配置方案并批准；
终端中对应 `computer-mcp clients authorizations` 与
`computer-mcp clients authorize <code>`。授权默认使用只读配置档，完全访问仍需
本机逐会话同意。设置与吊销步骤见 [Cloudflare 参考](Documentation/Reference/zh-CN/Cloudflare.md)。
Verified 只接受当前访问令牌或仍有效 OAuth 授权的成功工具请求；替换或吊销凭据后，
对应证据失效，新凭据需要重新验证。

Gateway 解析精确工具名，绑定 Caller/Profile/Project，检查策略和 Operation
Ticket，在需要时获得操作同意，分发一个有界 Adapter，并记录脱敏结果。Standalone
TOML 模式只用于开发和诊断，不共享 App 的 Bookmark 或 Keychain 状态。

当前架构见 [Gateway](Documentation/Architecture/Gateway.md)、
[Runtime](Documentation/Architecture/Runtime.md)和
[能力所有权](Documentation/Architecture/Ownership.md)；完整命令与 Schema 见
[Reference](Documentation/Reference/README.md)。

## 当前限制

- 签名产品目前仅支持 macOS 14 或更高版本。
- 远程连接依赖用户自己的 OpenAI 或 Cloudflare 服务，以及相应账号、管理员、网络
  和可用性条件。
- 需要 Accessibility 或 Screen Recording 的能力必须把权限授予已安装的签名 App；
  其他能力不受影响。
- 多个合格项目存在时不会静默选择一个；不会隐式 Push Git Commit。
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
- [版本规则](VERSIONING.md)
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
