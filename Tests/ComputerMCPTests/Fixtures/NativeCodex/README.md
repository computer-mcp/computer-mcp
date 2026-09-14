# Native Codex model fixture

`ModelServer.py` provides a loopback Responses endpoint and a token endpoint
for the opt-in native plugin acceptance suite. It never executes commands.
The selected native Codex executable receives one fixture-owned command per
phase and uses a non-login shell.

The Swift fixture owns `response.json`, the network token and all directories.
The model fixture records exact `function_call_output` messages by the call ID
it issued. Tests compare those native results with events and independent
filesystem/network observations. HTTP authentication is rejected.

The service terminates on stdin EOF. Its process and the Codex adapter/vendor
generations are owned independently; successful cleanup requires confirmed
process exit and stopped domain receipts.

With native acceptance enabled, `Scripts/verify-codex-plugin-host.sh` also runs
`Scripts/verify-codex-gateway-flow.py` against the built CLI, or the explicit
`COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE`. That independent stdio client discovers
the tool catalog before generic calls, checks declared argument fields, and
verifies execution, Goal preservation, release and process exit with two
manifest workspaces and a separate audit database. The same driver accepts a
signed App's embedded CLI for package acceptance. It retains only fixture-owned
state and protocol evidence under a newly created temporary directory.
