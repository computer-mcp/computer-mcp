# Quick Start

Install the signed release in `/Applications`, open it from Finder, and choose
a connection on Welcome. Normal App use does not require TOML.

For a local MCP client:

1. Start the Gateway on Home.
2. Under **Connect a local MCP client**, choose **Connect…** next to Codex,
   Claude Code or Claude Desktop. Review the settings file and command, then
   confirm. Quit Claude Desktop before confirming its change. **Update…**
   replaces a different entry with the same name and **Remove…** removes it,
   each after the same review.
3. Start a new Codex or Claude Code session, or reopen Claude Desktop.
4. Make one real tool request and refresh Home to reach Verified.

For any other client, **Other MCP clients** shows the stdio command to copy. The
same registrations are available from the embedded CLI with `computer-mcp
install <client> --app --dry-run` and `computer-mcp uninstall <client>`; see
[local client registration](CLI.md#local-client-registration).

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
