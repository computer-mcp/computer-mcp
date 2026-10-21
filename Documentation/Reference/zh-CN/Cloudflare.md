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
该请求还必须来自当前访问令牌或仍有效的 OAuth 授权，并匹配该凭据的配置档。
OAuth 配对和令牌端点的事件不会建立 Verified。

## OAuth 配对

每条连接默认关闭 OAuth。可在 App 的 Cloudflare 连接编辑器中打开「允许通过 OAuth
登录」，并在「允许的客户端主机」中编辑允许列表。已有连接也可通过所有者 CLI 开启；
省略令牌参数会保留已保存的凭据：

```sh
computer-mcp tunnel cloudflare save partner --tunnel-name computer-mcp-release --public-hostname mcp.example.com --gateway-profile cloudflare-observe --oauth-enabled
computer-mcp clients authorizations
computer-mcp clients authorize <pairing-code> --profile cloudflare-observe
computer-mcp clients deny <pairing-code>
computer-mcp clients grants
computer-mcp clients revoke-grant <grant-id>
```

重复 `--oauth-client-host <host>` 可替换 CIMD 客户端主机允许列表；默认允许
`claude.ai` 和 `claude.com`，按完整主机名匹配。`--no-oauth-enabled` 关闭 OAuth；
保存已有连接时，省略这些选项会保留原设置。清单键为 `oauth_enabled` 和
`oauth_client_allowlist`，更改可作用于运行中的监听器。

客户端连接 `https://<hostname>/mcp`，通过 CIMD、S256 PKCE 和本机批准获得授权。
隧道路由需保留公网 Host，并转发 `/.well-known/…`、`/oauth/…` 和 `/mcp`。
浏览器只显示客户端主机、回调主机和六位配对码；请在 Mac 上核对同码后批准。
App 的「客户端权限」页在「登录请求」中列出同一请求，只提供允许 `cloudflare-tunnel`
的配置方案，并默认选中 Cloudflare 观察；「已登录的远程客户端」列出仍有效的授权、
配置方案和最近使用时间，可直接撤销。
配对十分钟过期，公网页面不能批准。授权默认使用只读配置档；完全访问仍需本机
逐会话同意。批准或拒绝可加 `--tunnel-id` 区分不同连接的同码请求。

授权码单次使用、有效期六十秒；访问令牌有效一小时。刷新令牌每次使用都会轮换，
三十天未使用即过期；重用已轮换的刷新令牌会吊销整个授权。数据库只保存令牌和
授权码的 SHA-256 摘要，日志、审计和钥匙串都不保存 OAuth 原值。吊销授权立即
拒绝其令牌。替换 Computer MCP 访问令牌也会立即更新运行中的监听器。
独立的 Cloudflare Access 策略仍需允许该客户端访问相关路径。

## 恢复

- `cloudflared` 不兼容：通过官方安装渠道升级后 Retry。
- 替换 Computer MCP 访问令牌或吊销 OAuth 授权：对应的 Verified 证据立即失效；
  新凭据需重新完成成功的工具请求。
- Cloudflare 隧道令牌被撤销：编辑连接并保存新令牌，重新诊断和启动。
- 401：核对 Computer MCP 访问令牌或 OAuth 授权、刷新状态，而不是隧道令牌。
- Cloudflare 连接成功但无 MCP：核对 hostname 路由、origin 端口和 `/mcp` 路径。
- 停止连接会清理临时 `0600` Token 文件和 loopback origin，不会删除 Cloudflare 账号内的 Tunnel。

官方参考：[Tunnel Token][token]、[Run parameters][run]。

[token]: https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/
[run]: https://developers.cloudflare.com/tunnel/advanced/run-parameters/
