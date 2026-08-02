# Stdio MCP Transport

## Status

Accepted.

## Context

MCP clients commonly launch local servers as subprocesses and communicate over
stdio using newline-delimited JSON-RPC messages.

## Decision

Use stdio as the local transport in the current baseline. MCP request dispatch
is handled by the official Swift MCP SDK server/client. This package owns only
the local process transport adapters needed to connect stdin/stdout and
downstream child-process pipes to the SDK transport protocol.

## Consequences

- The server does not listen on a network port.
- MCP client configuration is a command plus arguments.
- Runtime behavior is tested at the gateway and downstream proxy layers without
  maintaining a separate MCP protocol implementation.

## Alternatives Considered

- HTTP transport: deferred because local stdio is the simplest MCP integration
  path for this package.
- Unix domain socket transport: deferred because it adds lifecycle and
  discovery concerns not needed by the baseline.

## Related Documentation

- [Runtime Architecture](../Architecture/Runtime.md)
- [MCP Protocol Reference](../Reference/MCPProtocol.md)
