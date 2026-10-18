# 连接 Cloudflare

该路径通过 Cloudflare Remotely Managed Named Tunnel 暴露 App-owned、Bearer
保护的 loopback Streamable HTTP MCP origin。它与 OpenAI Secure MCP Tunnel 完全独立。

## 前置条件

1. 安装 `cloudflared` 2025.4.0 或更高版本；Computer MCP 依赖 `--token-file`，避免
   Tunnel Token 出现在进程参数中。
2. 在 Cloudflare 创建 Remotely Managed Named Tunnel。
3. 为 Tunnel 配置公网 hostname，使其指向 App 显示的 loopback origin。
4. 获取 Named Tunnel Token。持有该 Token 的人可以运行 Tunnel，应按真实凭据保护。

生产路径不支持 Quick Tunnel 或无鉴权 origin。

## App 内设置

1. 打开侧栏 **Cloudflare**，选择 **Add Connection**。
2. 填写 profile ID、Tunnel name、hostname、Gateway Profile、端口和 Tunnel Token。
3. 选择生成新的 Computer MCP Access Token 并保存。
4. 一次性窗口出现时，立即将 Access Token 复制到外部消费者的 Secret Store。关闭后
   App 不会重新显示原值；需要时只能重新生成。
5. 运行 Diagnostics，启动 Tunnel，等待 Ready。

## 消费者与验证

消费者连接 `https://<hostname>/mcp`，并发送：

```text
Authorization: Bearer <computer-mcp-access-token>
```

如果同时启用了 Cloudflare Access，消费者还需要自己管理 `CF-Access-Client-Id` 和
`CF-Access-Client-Secret`；Computer MCP 不存储这两个值。

发起一次只读工具调用，回到 Cloudflare 页面选择 **Check for Request**。只有当前
Named Tunnel、Profile、Caller 和启动时间均匹配的成功审计请求才会进入 Verified。

## 恢复

- `cloudflared` 不兼容：通过官方安装渠道升级后 Retry。
- Token 被撤销：编辑连接并保存新 Token；旧 Verified 状态会立即失效。
- 401：核对 Computer MCP Access Token，而不是 Tunnel Token。
- Cloudflare 连接成功但无 MCP：核对 hostname 路由、origin 端口和 `/mcp` 路径。
- 停止连接会清理临时 `0600` Token 文件和 loopback origin，不会删除 Cloudflare 账号内的 Tunnel。

官方参考：[Tunnel Token][token]、[Run parameters][run]。

[token]: https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/
[run]: https://developers.cloudflare.com/tunnel/advanced/run-parameters/
