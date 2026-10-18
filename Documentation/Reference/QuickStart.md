# Quick Start

Install the signed release in `/Applications`, open it from Finder, and choose
a connection on Welcome. Normal App use does not require TOML.

For a local MCP client:

1. Start the Gateway on Home.
2. Copy the displayed command and arguments into the client.
3. For Codex, preview and confirm **Register with Codex**.
4. Make one real tool request and refresh Home to reach Verified.

The App remembers only the onboarding version. Readiness and completion are
derived from live App, Gateway, dependency, transport, Keychain, and audit
state. Reopen Welcome from the sidebar whenever you want to choose another
path.

Use Doctor for a scriptable readiness result:

```sh
computer-mcp doctor --journey local
computer-mcp doctor --journey local --json
```

Doctor returns 0 only for Ready or Verified. Its schema-1 JSON remains
parseable when the App is unavailable and contains no credential values.

Continue with the [ChatGPT](ChatGPTWebRunbook.md) or
[Cloudflare](CloudflareRunbook.md) journey, or see
[Troubleshooting](Troubleshooting.md).
