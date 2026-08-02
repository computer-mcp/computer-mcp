# MCP Protocol Reference

## Transport

`computer-mcp serve` and the App's `computer-mcp bridge` use MCP stdio
transport. Each message is one UTF-8 JSON-RPC object followed by a newline:

```text
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"protocol-debugger","version":"1.0"}}}\n
```

For interactive debugging, do not use LSP-style `Content-Length` framing. This
gateway's stdio adapter expects one complete JSON-RPC object per line.

MCP protocol handling is provided by the official Swift MCP SDK. The examples
below document the wire shape for debugging; they are not a separate protocol
implementation in this repository.

## Initialize

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": {
      "name": "protocol-debugger",
      "version": "1.0"
    }
  }
}
```

The initialize response advertises tools support, the configured server name
and title, and bounded server instructions for using the gateway tools.

## Tool Discovery

```json
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
```

The result contains the active profile's policy-filtered provider tools plus
any configured reexports. Tools include standard MCP operational annotations such
as `readOnlyHint`, `destructiveHint`, `idempotentHint`, and `openWorldHint`.
Local gateway and Codex tools also include a human-readable `title` and an
`outputSchema`. Downstream reexports preserve these fields when the provider
advertises them.
CLI/process and downstream MCP gateway tools are listed only when at least one
matching provider is configured.

The client-facing surface preserves canonical registry names such as
`cli.exec`. `tools/call`, tool descriptions, and machine-readable follow-up
references use the same identifiers without client-specific rewriting.

## Tool Call

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "cli.exec",
    "arguments": {
      "id": "git",
      "argv": ["status", "--short"]
    }
  }
}
```

Local gateway and Codex tool results contain:

- `content`: a JSON text representation for clients that consume MCP content.
- `structuredContent.result`: the same JSON value in a schema-declared
  structure for machine-readable follow-up calls.
- `isError`: the standard MCP tool error flag.

Downstream MCP calls and reexports preserve provider content,
`structuredContent`, `_meta`, and error state through the official SDK.

In the App-owned runtime, the bridge forwards these messages to the private
current-user Unix socket. Each socket connection owns an official SDK MCP
server session; the bridge does not parse or reinterpret tool payloads.

## HTTP Transport

`computer-mcp serve http` exposes the same MCP server through the official MCP
Swift SDK HTTP server transport. The default endpoint is:

```text
http://127.0.0.1:8765/mcp
```

For ChatGPT Web and a private local gateway, use OpenAI Secure MCP Tunnel with
the stdio server. The HTTP transport is intended for loopback inspection,
temporary no-auth transport probes, and compatible clients that can provide the
configured fixed bearer token.

For a public HTTP probe, put an HTTPS forwarding service in front of the
endpoint and configure `[server.http].public_base_url` with that HTTPS origin.
The gateway does not serve OAuth discovery, authorization, registration, or
token endpoints. An authenticated public ChatGPT deployment must use an
established OAuth 2.1 identity provider in front of the MCP server; ChatGPT does
not accept the gateway's fixed bearer-token mode as app authentication.

Health check:

```sh
curl http://127.0.0.1:8765/health
```
