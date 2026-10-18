# Naming

Computer MCP freezes public names before its first release. Names describe a
stable responsibility or protocol concept, never a temporary delivery phase.

## Product names

| Surface | Name |
| --- | --- |
| Human-readable name | Computer MCP |
| Swift module | `ComputerMCP` |
| App | `Computer MCP.app` |
| Embedded CLI | `computer-mcp` |
| Validation package | Computer MCP Validation Suite |
| Validation directory | `Tools/Validation` |
| Validation module | `ComputerMCPValidation` |
| Validation executable | `computer-mcp-validate` |

## Runtime names

- **App Control Plane** owns configuration, database, bookmarks, secrets,
  providers, transports, and audit.
- **Gateway Socket** carries MCP data calls.
- **Control Socket** carries App and CLI administration.
- **OpenAI Secure MCP Tunnel** is the ChatGPT Connector transport.
- **Cloudflare Tunnel** uses the **Remotely Managed** mode.
- **Cloudflare Tunnel Token** authenticates `cloudflared`.
- **Computer MCP Access Token** authenticates the loopback HTTP gateway.
- **Cloudflare Access Service Token** is an optional consumer-owned credential.

## Validation names

- Validation Test Case
- Validation Run
- Validation Evidence Bundle
- Capability Coverage
- Production Readiness Report

`probe` means auxiliary observation and cannot independently produce PASS.

## Conventions

- MCP tool and error IDs use a lowercase namespace and snake-case action.
- JSON and TOML keys use `snake_case`.
- CLI commands and options use lowercase kebab-case.
- Swift names use UpperCamelCase and preserve `ID`, `URL`, `HTTP`, `MCP`, and
  `CLI` initialisms.
- Upstream protocol values retain their standardized spelling.
- The public configuration and evidence contracts begin at schema 1 and accept
  only their current shape.

`Scripts/verify-naming.sh` enforces the frozen contract in CI.
