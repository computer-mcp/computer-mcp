# Computer MCP Examples

Normal `Computer MCP.app` users do not need any file in this directory. The App
owns its active configuration, workspace bookmarks, database, and Keychain
credentials.

These files support explicit standalone development, provider integration, and
tests. A standalone command uses exactly one TOML file passed with `--config`;
the files are alternatives, not fragments to merge.

| File | Purpose | Risk and intended use |
| --- | --- | --- |
| `computer-mcp.toml` | Default standalone development configuration | Local development; shell remains disabled |
| `computer-mcp-chatgpt-tunnel.toml` | ChatGPT observe surface | Read-only Secure MCP Tunnel development |
| `computer-mcp-chatgpt-operate.toml` | ChatGPT operate surface | Write and Computer Use review; grant only intended workspaces |
| `computer-mcp-codex-dogfood.toml` | Local Codex provider dogfood | High risk: enables shell and broad `local-admin` capabilities |
| `computer-mcp-local-providers.toml` | Local downstream provider integration | Requires separately installed provider CLIs |
| `mcp-inspector.json` | MCP Inspector fixture | Test/development data, not an App configuration |
| `sample.json`, `sample.plist`, `sample.toml` | Structured-data fixtures | Test data only |

Never paste a real API key, Tunnel Token, Computer MCP Access Token, Cloudflare
Access credential, or local CLI credential into an example. Use documented
environment variable names for standalone HTTP development and Keychain for
App-owned credentials.

Typical standalone validation:

```sh
swift run computer-mcp config validate --config Examples/computer-mcp.toml
swift run computer-mcp tools list --config Examples/computer-mcp.toml
swift run computer-mcp serve stdio --config Examples/computer-mcp.toml
```
