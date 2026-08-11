# Cloudflare Named Tunnel Runbook

This transport exposes the App-owned Streamable HTTP MCP origin through a
remotely-managed Cloudflare named tunnel. It is independent from OpenAI Secure
MCP Tunnel.

## Cloudflare prerequisites

Create in the Cloudflare dashboard:

1. a remotely-managed named tunnel;
2. a public hostname routed to the App's loopback origin port;
3. a tunnel token for the connector;
4. optionally, a Cloudflare Access application and Service Auth policy.

Install `cloudflared` 2025.4.0 or newer. Cloudflare introduced
`tunnel run --token-file` for remotely managed tunnels in that release, and
Computer MCP fails closed when the installed version cannot support it.

Do not use a Quick Tunnel in production. Computer MCP does not persist an
account certificate or Cloudflare API token; it needs only the named-tunnel
run token.

## App onboarding

Open **Cloudflare** under Get Started and select **Add Connection**. Enter:

- a local profile id;
- the named tunnel name;
- the public hostname without scheme or path;
- `cloudflare-observe` or `cloudflare-operate`;
- distinct loopback origin and metrics ports;
- optional absolute `cloudflared` path;
- the named-tunnel token.

The App generates a separate Computer MCP Access Token. Copy it once into the
external consumer's secret store. Closing the one-time view permanently hides
the value; regenerate it if it is lost. Both values are stored in Keychain and
omitted from the schema 1 manifest and configuration export.

Run Diagnostics before Start. The diagnostic verifies `cloudflared`, both Keychain entries,
caller/profile alignment, named-tunnel mode, and—when running—the local
metrics endpoint.

The page reports Ready when the transport is healthy. Select **Check for
Request** after the public consumer calls a tool; Verified requires a matching
current tunnel, caller, profile, start boundary, and allowed audit decision.

## Consumer authentication

Every request requires the Computer MCP Access Token:

```text
Authorization: Bearer <computer-mcp-access-token>
```

When Cloudflare Access is also enabled, add the consumer-owned service token:

```text
CF-Access-Client-Id: <access-service-token-client-id>
CF-Access-Client-Secret: <access-service-token-client-secret>
```

An MCP client's conceptual configuration is:

```yaml
url: https://mcp.example.com/mcp
headers:
  Authorization: Bearer ${COMPUTER_MCP_ACCESS_TOKEN}
  CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}
  CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}
```

Omit the two `CF-Access-*` headers only when Access is not configured. Computer
MCP never saves those consumer credentials.

## Lifecycle and verification

```sh
computer-mcp tunnel cloudflare list
computer-mcp tunnel cloudflare doctor <profile-id>
computer-mcp tunnel cloudflare start <profile-id>
computer-mcp tunnel cloudflare logs <profile-id>
computer-mcp tunnel cloudflare stop <profile-id>
```

Verify the external consumer can initialize MCP, list the expected profile
surface, and call a read-only tool. Correlate its result with the Cloudflare
transport instance, gateway request id, caller/profile audit row, and
independent result evidence using the maintained Validation Test Case.

Stopping removes the temporary owner-only token file and stops both
`cloudflared` and the loopback origin. It does not delete the Cloudflare account
tunnel or the consumer's Access service token.

Official references:

- [Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)
- [Run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/)
- [Monitoring](https://developers.cloudflare.com/tunnel/monitoring/)
- [Service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)
