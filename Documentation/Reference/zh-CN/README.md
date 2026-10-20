# 简体中文上手文档

- [快速开始](QuickStart.md)
- [连接 ChatGPT](ChatGPT.md)
- [连接 Cloudflare](Cloudflare.md)
- [常见故障](Troubleshooting.md)
- [隔离编辑交付](Delivery.md)：工具、范围配置与恢复。

这些文档镜像用户上手与故障恢复路径。完整 CLI、MCP 协议、工具 Schema、发行与
Validation 参考继续以英文文档为准；命令名、JSON key、配置 ID、错误码和路径不会
本地化。

通过 `delivery.scopes.list` 与 `delivery.apply` 可按宿主声明的 `[[delivery.scopes]]`
范围交付文本编辑；提交、合并与恢复均在仓库锁保护下执行。
