# Remote OAuth Authorization

## Status

Accepted.

## Context

Remote clients reach the gateway through the App-managed Cloudflare tunnel at
`https://<hostname>/mcp`. Today every remote request must carry the Computer MCP
Access Token as a Bearer header. Clients that can set request headers work;
claude.ai custom connectors cannot, because they authenticate with OAuth.

Claude's connector client follows the MCP authorization specification
(revision 2026-07-28) with these specifics:

- Sign-in starts only from an HTTP `401` whose `WWW-Authenticate` header points
  to protected resource metadata (RFC 9728). Claude uses only the first
  authorization server listed there.
- Claude identifies itself with a Client ID Metadata Document (CIMD) when the
  authorization server advertises `client_id_metadata_document_supported: true`
  and `"none"` in `token_endpoint_auth_methods_supported`; otherwise it falls
  back to Dynamic Client Registration, which the specification now deprecates.
- Every authorization request uses PKCE with `S256` and the `resource`
  parameter (RFC 8707). The hosted Claude apps redirect to
  `https://claude.ai/api/mcp/auth_callback`; Claude Code uses a loopback
  redirect on a varying port.
- Claude refreshes tokens on `401` and ahead of expiry, expects refresh tokens
  of public clients to rotate, and gives discovery and token endpoints 10
  seconds to respond.

## Decision

### Roles and endpoints

The gateway is both the protected resource and its authorization server, on the
tunnel's public origin. OAuth is enabled per Cloudflare tunnel profile and is
off until the owner turns it on in the App.

| Path | Purpose |
| --- | --- |
| `/.well-known/oauth-protected-resource/mcp` and `/.well-known/oauth-protected-resource` | RFC 9728 metadata: `resource` is `https://<hostname>/mcp`, `authorization_servers` is `["https://<hostname>"]`, `bearer_methods_supported` is `["header"]`, `scopes_supported` is `["mcp"]`. |
| `/.well-known/oauth-authorization-server` | RFC 8414 metadata: issuer `https://<hostname>`, authorization and token endpoints, `response_types_supported: ["code"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none"]`, `client_id_metadata_document_supported: true`, `authorization_response_iss_parameter_supported: true`, `scopes_supported: ["mcp"]`. |
| `/oauth/authorize` | Validates the request and shows the pairing page. |
| `/oauth/authorize/status` | Lets the pairing page learn the local decision. |
| `/oauth/token` | Authorization code and refresh token grants (`application/x-www-form-urlencoded`). |
| `/oauth/revoke` | RFC 7009 token revocation. |

An `/mcp` request without a valid credential, when OAuth is enabled, receives
`401` with `WWW-Authenticate: Bearer resource_metadata="https://<hostname>/.well-known/oauth-protected-resource/mcp", scope="mcp"`.
The OAuth paths answer only requests whose `Host` is the tunnel's public
hostname, so they are never served on the loopback origin directly.

### Client identification

Clients identify themselves only with Client ID Metadata Documents and are
public clients authenticated by PKCE. There is no client secret and no Dynamic
Client Registration endpoint, so the gateway keeps no client registry.

The authorization server accepts a `client_id` only from hosts on the tunnel
profile's client allowlist, which defaults to `claude.ai` and `claude.com`. The
owner edits the allowlist in the App, with the CLI or in the manifest; adding a
client that publishes a Client ID Metadata Document needs no code change. It
fetches the document over HTTPS with bounded size and time, without redirects
and without connecting to private or loopback addresses; requires the
document's `client_id` to equal the URL; and requires the `redirect_uri` to
match one of its `redirect_uris` exactly, comparing loopback redirects
(`127.0.0.1`, `[::1]`, `localhost`) with the port ignored.

Client identification is a separate step in front of the shared authorization,
grant and token flow. A client that supports only Dynamic Client Registration
can be added later as another identification method, restricted to redirect
hosts on the allowlist, without changing approval, grants or tokens.

### Local approval

The browser page served by `/oauth/authorize` never grants access itself. It
shows the client's host (from the `client_id` URL, not the self-asserted name),
the redirect host, and a six-character pairing code, and asks the user to
approve in Computer MCP. The App's Client access page lists the pending request
with the same code; only the local App or the owner CLI can approve or deny it.
On approval the page redirects to the client with the authorization code,
`state` and `iss`; on denial or after ten minutes it redirects with
`access_denied`.

### Grants, identity and permissions

An approval creates a grant: the client ID URL, the redirect host, the profile
chosen at approval (default `cloudflare-observe`), creation and last-use times.
Requests authorized by the grant act as principal `oauth:<grant ID>` with caller
`cloudflare-tunnel`. OAuth only authenticates; it never raises permissions.
Workspace operations require the grant's profile to allow them, and Full Access
still requires the existing per-session local consent. The owner revokes a
grant from Client access or with the owner CLI, which invalidates its tokens
immediately.

### Consistency

Approval binds a client to exactly the authorization the owner reviewed, and
no approval survives the deletion of its tunnel:

- A profile's authorization digest is the SHA-256 of the canonical encoding of
  its effective grant (mode, capabilities, workspaces, callers, Full Access,
  MCP servers and confirmation policy) as resolved from the active
  configuration and persisted overrides, whether or not the profile has an
  override. The App shows remote profiles with their digest and approves with
  the digest it displayed; the owner CLI may pass one.
- Every path that changes the active configuration (App and CLI saves, tunnel
  saves, profile permission changes, import, rollback and external manifest
  reload) publishes under one configuration publication lock, from a
  configuration read under that lock. Approval holds the same lock while it
  resolves the chosen profile, compares the reviewed digest and commits the
  grant, so no configuration change can take effect between the comparison and
  the grant.
- Approval, start, save and deletion of a tunnel are serialized by that
  tunnel's mutation slot. Deletion, within its slot, revokes every grant and
  ends every pending request and unexchanged code for the tunnel in one store
  transaction, so a tunnel recreated with the same ID and hostname starts with
  no requests or grants.

### Tokens

Access tokens, refresh tokens and authorization codes are opaque 256-bit random
values. The gateway database stores only their SHA-256 digests with the grant,
`resource`, scope and expiry, so no plaintext token is stored anywhere and the
Keychain is not involved.

- Authorization codes are single-use, expire after 60 seconds and are bound to
  the client ID, redirect URI, PKCE challenge and `resource`.
- Access tokens expire after one hour and are accepted only for the
  `resource` they were issued for.
- Refresh tokens rotate on every use and expire after 30 days without use.
  Presenting an already-rotated refresh token revokes the grant.
- The token endpoint returns RFC 6749 error codes (`invalid_grant`,
  `invalid_client`, `invalid_request`).

### Coexistence with the Access Token

The Computer MCP Access Token keeps working for header-capable clients. A Bearer
credential is accepted if it matches the current Access Token or a live OAuth
access token for this resource. Replacing the Access Token in the App takes
effect for the running listener immediately.

### Limits and audit

The OAuth endpoints and failed Bearer authentication are rate-limited per
client address, as reported by the tunnel, and per grant. Audit records
authorization requested, approved, denied and expired; tokens issued, refreshed
and revoked; refresh token reuse; and grant revocation. Token values never
appear in logs or audit records.

### Module ownership

`ComputerMCPAuthorization` owns the OAuth state machine, metadata documents,
CIMD validation and the grant and token store protocol. `ComputerMCPGateway`
routes the OAuth paths to it, authenticates Bearer credentials through it, and
implements the store on the gateway database (one new migration).
`ComputerMCPControlPlane` exposes pending requests and grants to the App and
CLI. The App's approval interface is part of Client access.

## Consequences

- The Cloudflare tunnel becomes usable from claude.ai without a static header;
  the owner still approves every new client locally.
- Validation requires a live run with the owner's Cloudflare hostname and a real
  claude.ai custom connector: connect, approve in the App, call
  `workspace.list`, see Home show Verified, revoke, and see the next request
  refused.
- `SecurityAndPrivacy.md`, `CloudflareRunbook.md`, the README and the Chinese
  references describe the OAuth path once it ships, replacing the statement that
  the gateway does not implement an OAuth authorization server.
- Readiness verification for Cloudflare takes the credential into account, so a
  revoked Access Token or grant clears Verified.

## Alternatives Considered

- An App-generated client ID and secret entered in claude.ai's advanced
  settings: works, but adds a manual step and a long-lived secret; CIMD needs
  neither.
- Dynamic Client Registration as the default: deprecated by the MCP
  specification and creates a client per connection; it stays available as a
  later identification method for clients that need it.
- Storing tokens in the Keychain: unnecessary, because the gateway only needs to
  recognize tokens, which their digests allow.
- Approval directly on the browser page: the page is reachable from the
  internet, so a click there cannot prove the owner's consent.
