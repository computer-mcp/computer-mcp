# 执行工具

`shell.run` 等待命令结束，`shell.spawn` 返回稳定的 `session_id`。通过 `shell.read`
读取输出，将各流的 `next_cursor` 分别作为下一次 `stdout_cursor`、`stderr_cursor`。
`shell.write` 写入文本或 base64 字节，`close: true` 在先前写入完成后关闭标准输入；
`shell.cancel` 取消该执行拥有的进程树。

等待调用默认 `timeout_ms: 120000`，上限 `600000`。后台执行默认无时限。
stdout、stderr 共用默认 8388608 字节（8 MiB）预算，保留最近的输出。
结果中的 `limits` 表示实际限额，`dropped_bytes` 表示累计丢弃字节；游标早于保留范围时，
`missed_bytes` 为 true，`start_cursor` 给出实际起点。`truncated` 表示该流曾因保留限额而丢弃输出；`next_cursor < end_cursor` 表示还有保留数据可读。
`limits.timeout_ms` 缺省表示无期限。

结束原因 `end_reason` 为 `exited`、`signalled`、`timeout`、`cancelled`、`interrupted`、
`launch_failed` 或 `execution_failed`，并单独报告退出码或信号。
Full access 通过进程身份、进程组、会话和已观察到的后代跟踪进程；通过其他服务启动或
在观察间隙逃逸的后代仍有尽力清理的边界。

`process.spawn` 对已注册 CLI 使用同一执行生命周期。`process.read` 接受同样的游标及
`max_bytes`；`execution` 对象包含游标、限额、丢弃量与结束原因，原有顶层状态和文本
输出字段继续可用。`process.write` 使用 `process_id`，接受 `text` 或 `base64` 与可选的
`close`。`process.cancel` 通过统一所有权句柄取消进程树。

断线后使用相同主体、Profile 和项目权限续读。支持持久化的宿主保存周期性输出检查点；
重启后先核对系统启动周期与保存的内核进程身份并清理遗留进程，再将未完成记录标为 `interrupted`，
恢复输出要求原有长期信任版本或未变更的配置授权；仅连接有效的同意不会向新连接恢复输出。
保留最后检查点的输出，不自动重跑命令。记录受结果保留策略约束，显式停止所属服务会
清除该服务的结果。

任意 Shell、进程启动、`cli.exec` 仍要求 Full Shell，授权模型不变。
读取工具、无项目调用的宿主命令、CLI 兼容性检查与目录导出器使用只读沙盒，仅私有
临时目录可写；环境变量按允许列表重建。

完整字段以[英文工具参考](../Tools.md#shell-executions)为准。
