# 连接 ChatGPT

ChatGPT 通过 OpenAI Secure MCP Tunnel 连接本地 Computer MCP Gateway，不要求把
本地端口直接暴露到公网。

## 前置条件

1. 按 OpenAI 当前的[开发者模式与 MCP Apps 文档][developer-mode]确认目标账号、
   Workspace、管理员权限和可用能力。
2. 在 OpenAI Platform 创建或选择 Secure MCP Tunnel，并关联准确的 ChatGPT
   Workspace。
3. 安装官方 [`tunnel-client`][tunnel-client]，准备仅有运行所需权限的 API Key。

Computer MCP 只检测依赖，不自动下载，也不会自动操作 OpenAI 账号。

## App 内设置

1. 打开侧栏 **ChatGPT**，选择 **Add Connection**。
2. 填写 Tunnel ID、tunnel-client profile 和 Gateway Profile。第一次建议使用
   `chatgpt-observe`。
3. 输入 API Key 并保存；Key 只进入 Keychain。
4. 如需工作区内容，在 **Workspaces** 添加文件夹并授权给相同 Profile。
5. 运行 Diagnostics，修复必要检查后启动 Tunnel，等待状态进入 Ready。

## ChatGPT 端与验证

1. 在 ChatGPT Web 启用 Developer mode，创建或更新自定义 MCP App。
2. 选择正确的 Secure MCP Tunnel，扫描工具并保存。
3. 新建 Chat，启用该 App，调用一个只读 Computer MCP 工具。
4. 回到 Computer MCP 的 ChatGPT 页面选择 **Check for Request**。

只有 Caller、Gateway Profile、Tunnel identity 和当前 Tunnel 启动时间全部匹配的成功
审计请求才会使状态进入 Verified。历史请求不会验证一次新的启动。

## 恢复

- 依赖缺失：安装官方 tunnel-client 后选择 Retry。
- App 或 Gateway 未运行：返回 Home 启动 Gateway。
- ChatGPT 找不到 Tunnel：核对 Platform Organization、ChatGPT Workspace 关联与账号权限。
- Ready 但未 Verified：新建 Chat、确认启用了正确 App，并实际调用工具。
- 更详细日志：选择 **Open Advanced Diagnostics**；诊断不会导出 API Key。

[developer-mode]: https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt
[tunnel-client]: https://github.com/openai/tunnel-client/releases/latest
