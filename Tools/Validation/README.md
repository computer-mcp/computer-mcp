# Computer MCP Validation Suite

This independent Swift package owns the canonical Validation Test Case catalog,
deterministic fixtures, auxiliary probes, Validation Evidence Bundle correlation,
Capability Coverage, and Production Readiness Report generation. It is not part
of the root package, `Computer MCP.app`, embedded CLI, or DMG.

```sh
swift build
swift test
swift run computer-mcp-validate --help
swift run computer-mcp-validate test-case validate
swift run computer-mcp-validate test-case list
swift run computer-mcp-validate runbook generate --output validation-runbook.md
```

Real App, Tunnel, external MCP client, ChatGPT, Safari, installation, and release
checks are Validation Runs. A PASS requires a verified Validation Evidence Bundle
that correlates the Test Case, transport, gateway request, local audit event, and
independently captured result. `probe` commands only collect auxiliary observations
and cannot independently produce PASS.

External consumers bind `consumer_result_id` to the Gateway request returned in
their result. `transport_request_id` is optional when an external UI does not
expose its MCP JSON-RPC identifier; it is never copied from local logs and
misrepresented as consumer evidence.

Store live evidence in an external archive or scratch directory. Do not commit
credentials, raw consumer content, runtime databases, or generated evidence.
See [Validation](../../Documentation/Reference/Validation.md).
