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
It also requires the current Access Token principal or a live OAuth grant with
its selected profile. OAuth protocol events do not count as tool requests.
Replacing the Access Token or revoking a grant immediately removes that
credential's verification evidence.

## Consumer authentication

Header-capable consumers send the Computer MCP Access Token:

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

## OAuth client pairing

OAuth defaults off per connection. In the App, turn on **Allow sign-in with
OAuth** in the Cloudflare connection editor, where **Allowed client hosts** edits
the allowlist. The owner CLI on the Mac does the same:

```sh
computer-mcp tunnel cloudflare save partner --tunnel-name computer-mcp-release --public-hostname mcp.example.com --gateway-profile cloudflare-observe --oauth-enabled
computer-mcp clients authorizations
computer-mcp clients authorize <pairing-code> --profile cloudflare-observe
computer-mcp clients deny <pairing-code>
computer-mcp clients grants
computer-mcp clients revoke-grant <grant-id>
```

The save example updates an existing connection and preserves its stored tokens.
Creating one also requires `--tunnel-token-stdin`. Repeat `--oauth-client-host`
to replace the exact CIMD host allowlist; defaults are `claude.ai` and
`claude.com`. Omission preserves current settings on save. Use
`--no-oauth-enabled` to disable OAuth. Manifest keys are `oauth_enabled` and
`oauth_client_allowlist`; an empty manifest allowlist admits no new clients.
Enablement and allowlist changes apply to the running listener.

Point the client at `https://<hostname>/mcp`. Preserve the public Host and route
`/.well-known/…` and `/oauth/…` through the tunnel as well as `/mcp`. The client
must support CIMD and S256 PKCE. Its browser page displays client host, redirect
host and six-character code. Review the matching local request before approval.
In the App, **Client access** lists it under **Sign-in requests** with the same
code, client host, redirect host and connection. It offers the profiles that
allow `cloudflare-tunnel`, grouped by access level, and preselects a read-only
one, Cloudflare Observe first; without a read-only profile you choose one
explicitly, and approval stops if the chosen profile's access changes. Expired
requests cannot be approved. **Signed-in remote clients** lists live grants with
their connection, profile, approval time and last use; **Revoke** ends one.
Only the local owner control plane can approve or deny; the public page polls
an opaque handle. Pairing expires in ten minutes. The callback receives the
original `state`, issuer `iss` and a 60-second single-use code; denial or expiry
returns `access_denied`.

`authorizations` and `grants` accept `--id`, `--after-id`, `--limit` (default
100, maximum 200) and `--tunnel-id`. Approval and denial accept `--tunnel-id`
to disambiguate codes across connections. Approval defaults to
`cloudflare-observe` only while its effective mode is read-only; otherwise an
explicit `--profile` is required. The selected profile must allow
`cloudflare-tunnel` and cannot be `local-admin`. The grant acts as
`oauth:<grant ID>` with that profile. Full
Access still requires separate local session consent. `clients revoke-grant`
revokes OAuth access and ends that grant's active gateway sessions and open
streams; `clients revoke` manages saved Full Access trust.

Access tokens last one hour. Refresh tokens rotate on every use and expire
after 30 idle days. Reusing a rotated refresh token revokes the grant. The
gateway stores only SHA-256 digests of OAuth tokens and codes in GRDB. These
values never enter Keychain, logs or audit. Header clients keep using the
current Access Token, including after rotation without restarting. A separate
Cloudflare Access policy must permit the chosen client to reach the routes;
Computer MCP OAuth does not satisfy that independent policy.

| Method and path | Behavior and security checks |
| --- | --- |
| `GET /.well-known/oauth-protected-resource/mcp`, `GET /.well-known/oauth-protected-resource` | RFC 9728 resource `https://<hostname>/mcp`, one authorization server at the public origin, header Bearer and scope `mcp`. |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata advertises code/refresh grants, S256, public authentication `none`, CIMD and authorization response `iss`. |
| `GET /oauth/authorize` | Requires code response, state, exact resource, `mcp` scope and S256 challenge. HTTPS CIMD fetch is limited to eight seconds/64 KiB, with no redirects or ambient credentials and a pinned public destination. Binds document client ID and registered redirect; loopback ports are ignored only during registration matching. |
| `GET /oauth/authorize/status` | Requires the opaque polling handle. Returns pending or a callback after local decision/expiry. Approval cannot be submitted here. |
| `POST /oauth/token` | Form encoding, public `client_id` and exact resource. Code exchange binds exact authorized redirect and PKCE verifier, atomically consuming the unexpired code. Refresh binds client/grant/resource, rotates atomically and detects reuse. |
| `POST /oauth/revoke` | RFC 7009 form encoding with `client_id` and `token`. Unknown or foreign-client tokens return 200. Access-token revocation invalidates that token; refresh-token revocation invalidates the grant. |

Every OAuth route requires enabled OAuth and the exact public Host; other Hosts
receive 404. Pairing and status responses are `no-store` with CSP
`frame-ancestors 'none'`; token and revocation responses are also `no-store`.
An unauthenticated public `/mcp` request receives 401 with
`WWW-Authenticate: Bearer resource_metadata="https://<hostname>/.well-known/oauth-protected-resource/mcp", scope="mcp"`.
At the request head, `/mcp` authentication pauses body reads and OAuth routes
consume the address rate allowance. A failed credential gets the 401 challenge
and a closed connection. OAuth-disabled listeners use synchronous Bearer
authentication at the head. Headers and OAuth bodies are limited to 16 KiB;
authenticated MCP bodies to 8 MiB. Declared or streamed overflow returns 413 and
closes. The body deadline is 15 seconds from the head; the initial head has the
same deadline. Timeout returns 408 and closes. Each listener caps connections
awaiting authentication at 32, returning 503 and closing excess sockets. Public
OAuth connections keep their slot until MCP authentication or disconnect and
have a 15-second idle deadline.

Each tunnel allows 128 pending or approved pairings, at most three per client
address. CIMD admission is reserved before fetching: one fetch per address, four
per tunnel. Exceeding either quota returns 429 `temporarily_unavailable` without
a fetch; failures and cancellations free the reservation.

Token errors return 400: `invalid_request` for missing, empty or duplicate
parameters or unsupported content types; `unsupported_grant_type` for an unknown
grant; `invalid_scope` for scopes other than `mcp`; `invalid_grant` for wrong,
expired, reused or mismatched codes, refresh tokens, client IDs, redirect URIs,
PKCE verifiers or resources. Unsupported client authentication returns 401
`invalid_client`, with a `WWW-Authenticate` challenge matching the attempted
Authorization scheme (`Basic` for Basic requests). Authorization redirects with
`unsupported_response_type` or `invalid_scope` only after validating the registered
callback. Callback values preserve literal `+` as `%2B` and spaces as `%20`,
retaining the existing query.

Address buckets allow burst 60, refill one/second; grant buckets allow burst
30, refill one/two seconds. Rate rejection returns 429 with `Retry-After`.
At most 4,096 limiter keys are retained per listener. Failed Bearer audit emits
at most one summary per minute. Audit also records authorization requests,
approvals, denials, expiry, token issuance/refresh/revocation, refresh reuse and
grant revocation and completion of session/stream termination
(`oauth.sessions_ended`). Refresh-token reuse and refresh-token revocation also
terminate the grant's sessions and streams.

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
independent result evidence. This is a deployment acceptance check for the
user-owned account, domain, hostname, and runtime token. It is supported and
recommended before relying on a named deployment, but it is not a publisher
release gate and never requires Computer MCP CI to own a Cloudflare domain or
production credential.

The canonical release suite separately verifies the development-only Quick
Tunnel isolation boundary and the named-tunnel lifecycle, bearer
authentication, temporary-token cleanup, and caller/profile separation with
automated tests. Quick Tunnel remains prohibited for production deployment.

Stopping removes the temporary owner-only token file and stops both
`cloudflared` and the loopback origin. It does not delete the Cloudflare account
tunnel or the consumer's Access service token.

Official references:

- [Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)
- [Run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/)
- [Monitoring](https://developers.cloudflare.com/tunnel/monitoring/)
- [Service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)
