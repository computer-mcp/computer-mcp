# Support

Version 1.0 receives best-effort fixes for reproducible defects and security
issues. Only the most recent patch release in the 1.0 line is supported. There
is no guaranteed response time or paid support commitment.

Use the `computer-mcp/computer-mcp` issue tracker for reproducible bugs,
documentation gaps, and focused feature requests. Use GitHub private
vulnerability reporting, not a public issue, for security reports.

## Before Opening an Issue

Run:

```sh
/usr/bin/swift build --build-system native
/usr/bin/swift test --build-system native
swift run computer-mcp config validate --config Examples/computer-mcp.toml
swift run computer-mcp tools list --config Examples/computer-mcp.toml
swift run computer-mcp serve http --help
Scripts/build-app.sh
```

For MCP client integration problems, also verify that the client launches the
same executable path you tested in the terminal.

## Useful Details

Include:

- macOS version
- Swift version from `swift --version`
- Computer MCP App/CLI version
- active profile and workspace count
- command that failed
- MCP client name and configuration, if relevant
- ChatGPT app, Secure MCP Tunnel profile, or HTTP endpoint, if relevant
- TOML source configuration with secrets removed
- whether Codex or downstream provider executables are available locally
- App Diagnostics and redacted audit/error codes
- minimal JSON-RPC payload or tool call, if relevant

Do not include secrets, private tokens, or private tool output.
