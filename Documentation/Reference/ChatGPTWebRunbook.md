# ChatGPT Web Runbook

This runbook connects `Computer MCP.app` to ChatGPT Web through OpenAI Secure
MCP Tunnel. It does not expose a public port and does not require gateway-owned
OAuth.

Official references:

- [Secure MCP Tunnel][secure-tunnel]
- [Developer mode apps and full MCP connectors][developer-mode]
- [Platform tunnel settings][tunnels]

## 1. Confirm Account Access

In Platform tunnel settings:

1. Select the Platform organization that owns the Tunnel.
2. Create or open the Tunnel.
3. Associate the owning Platform organization.
4. Associate the exact target ChatGPT workspace.
5. Copy the `tunnel_id`.

The operator creating or editing a Tunnel needs `Tunnels Read + Manage`. The
runtime-key principal and the user selecting the Tunnel in ChatGPT need
`Tunnels Read + Use`. Organization roles can take time to propagate.

For personal use, associate the personal Platform organization and the
personal ChatGPT workspace. A Platform organization association alone does not
make the Tunnel appear in a ChatGPT workspace.

## 2. Install Prerequisites

Install the latest official `tunnel-client` from the download in Platform
tunnel settings or the [latest public release][tunnel-client].

Verify:

```sh
command -v tunnel-client
tunnel-client --version
```

Create a dedicated runtime API key with only Tunnel runtime permissions. Do not
reuse an administrator key.

## 3. Configure Computer MCP.app

Open the App:

1. On a fresh installation, open **Diagnostics**, select **Load Built-in
   Defaults**, review the generated manifest, validate it, and
   activate it. Loading the defaults into the editor does not activate them.
2. **Profiles**: activate `chatgpt-observe` for the initial connection.
3. **Workspaces**: add the folders ChatGPT may inspect or operate, then turn on
   **Enabled for chatgpt-observe** for each folder. Registration creates the
   persistent bookmark; the per-profile switch grants access. These are
   separate operations.
4. **Permissions**: review the enabled endpoint requirements. Grant
   Accessibility or Screen Recording to `Computer MCP.app` only when the
   corresponding Computer Use endpoints are intended to be available. A grant
   held by Terminal, Codex, or another app does not apply to Computer MCP.
5. **OpenAI Tunnel**: add a profile with:
   - local profile name;
   - Tunnel ID;
   - gateway profile `chatgpt-observe`;
   - optional absolute `tunnel-client` path;
   - optional HTTP proxy; leave blank to follow the fixed macOS HTTPS/HTTP
     proxy;
   - runtime API key.
6. Save the profile. The key is stored in Keychain.
7. Select **Provision**, then **Doctor**.
8. Do not start until Doctor succeeds.
9. Select **Start** and keep the App running.

When migrating from a standalone Tunnel, stop that Tunnel before activating
the App manifest or changing workspace grants. Each manifest/profile/workspace
change restarts the App-owned Gateway socket. Start only the App-managed Tunnel
after the final restart so its authenticated bridge and MCP session are
created against the current socket instance.

The App provisions `tunnel-client` with its embedded command:

```text
Computer MCP.app/Contents/Resources/computer-mcp bridge --socket <private-socket>
```

It does not launch a second standalone TOML gateway.

The App passes the resolved proxy to `tunnel-client` itself. This matters when
Safari can reach ChatGPT through the macOS proxy but an App-launched child
process would otherwise connect directly. Proxy URLs containing credentials
are intentionally unsupported.

## 4. Verify Local Runtime

The Tunnels view must report Running. Open the loopback admin UI reported by
`tunnel-client` and verify:

- health is live;
- readiness is ready;
- polling is connected;
- the MCP subprocess remains running.

Official diagnostic endpoints are `/ui`, `/healthz`, `/readyz`, and `/metrics`.
The admin UI is loopback-only by default.

Use the App's Tunnel Logs and Diagnostics views for failures. App logs are
under `~/Library/Logs/Computer MCP/`; the runtime key must not appear there.

## 5. Create The ChatGPT App

Custom MCP configuration is performed in ChatGPT Web, not in the local desktop
Codex MCP settings.

1. Enable Developer mode in the applicable ChatGPT Apps or workspace settings.
2. Open the available **Apps > Create** developer flow. OpenAI's Secure MCP
   Tunnel guide also links the current [ChatGPT developer app page][apps].
3. Enter a name such as `Computer MCP`.
4. Choose **Tunnel**, not Server URL.
5. Select the running Tunnel or paste its exact `tunnel_id`.
6. Choose no additional app-level authentication for the inner MCP server.
7. Select **Scan Tools**.
8. Review tool schemas, annotations, and risk.
9. Create the draft App.

For ChatGPT Pro, start with `chatgpt-observe`. Current OpenAI policy limits Pro
custom MCP use to read/fetch tools. Write/modify MCP is available only on
eligible Business, Enterprise, or Edu workspaces and can be further restricted
by workspace policy.

## 6. Test In A New Chat

Start a new chat, select Computer MCP, and test:

```text
Use Computer MCP to return the current local time and time zone.
```

```text
Use Computer MCP to call workspace.list, then describe one returned workspace.
```

```text
Use Computer MCP to list available Skill roots and describe one Skill.
```

Require visible Computer MCP tool calls. A prose answer without a tool call is
not an end-to-end test.

For an operate profile, add one narrowly authorized test only after observe
passes. Confirm the App audit records the exact profile, capability, and
workspace.

## 7. Metadata Refresh

ChatGPT stores the reviewed tool/action snapshot. After changing names,
descriptions, input/output schemas, annotations, or authentication:

1. restart or reconnect the Tunnel;
2. verify local readiness;
3. refresh or recreate the draft App;
4. review the new scan;
5. start a new conversation.

Do not diagnose a stale ChatGPT snapshot by renaming canonical MCP tools.

## 8. Stop And Recover

Stop the Tunnel from the App. Normal App Quit stops owned Tunnel processes and
the private gateway socket. Reopening the App restores profiles marked as
desired-running after validating state. A Gateway restart reconnects compatible
desired-running Tunnels immediately. The maintenance loop retains exponential
backoff for later provider or network failures.

Use `computer-mcp tunnel openai doctor <profile-id>` and the App's OpenAI
Tunnel logs for diagnosis. The CLI reaches the App-owned lifecycle; it does not
start a standalone control plane.

## Failure Isolation

### Tunnel is absent

Check, in order:

1. exact target ChatGPT workspace association;
2. owning Platform organization association;
3. `Tunnels Read + Use` for the runtime-key principal and app creator;
4. Tunnel runtime ready and polling;
5. role propagation delay.

### Create or refresh fails

Keep the Tunnel running, rerun Doctor, inspect `/readyz`, and verify the MCP
bridge still initializes and lists tools. Then retry Scan Tools.

### ChatGPT asks for OAuth

For the private stdio bridge, select Tunnel and no app-level authentication.
Do not paste the OpenAI-hosted Tunnel MCP endpoint as a Server URL; that route
causes ChatGPT to probe it as an OAuth-capable public MCP server.

### App connects but calls fail

Read Tunnel logs and the Computer MCP Audit view. Distinguish:

- Tunnel transport failure;
- policy denial;
- missing workspace id;
- TCC denial;
- missing provider executable;
- downstream provider error.

### Tool surface is stale

Refresh or recreate the ChatGPT App after local metadata changes. Verify the
local surface first:

```sh
swift run computer-mcp tools list \
  --config Examples/computer-mcp-chatgpt-tunnel.toml \
  --caller secure-tunnel \
  --profile chatgpt-observe
```

[apps]: https://chatgpt.com/plugins
[developer-mode]: https://help.openai.com/en/articles/12584461-developer-mode-apps-and-full-mcp-connectors-in-chatgpt-beta
[secure-tunnel]: https://developers.openai.com/api/docs/guides/secure-mcp-tunnels
[tunnel-client]: https://github.com/openai/tunnel-client/releases/latest
[tunnels]: https://platform.openai.com/settings/organization/tunnels
