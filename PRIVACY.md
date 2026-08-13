# Privacy

Computer MCP is a local-first macOS App and CLI. It does not include analytics,
advertising, crash-reporting, or an updater, and it does not operate a
publisher-controlled cloud service. Data leaves the Mac only when a capability
or transport configured by the user requires it.

## Local data

The App stores product state under:

- `~/Library/Application Support/Computer MCP` for the active TOML manifest,
  GRDB database, tunnel-client profiles, runtime sockets, and other App state;
- `~/Library/Logs/Computer MCP` for bounded, rotated JSONL App and tunnel logs;
- the macOS Data Protection Keychain service
  `com.showxu.computer-mcp.secrets`, restricted to access group
  `TEAM_ID.com.showxu.computer-mcp`, for OpenAI Tunnel, Cloudflare Tunnel,
  and Computer MCP access tokens (development builds use the separate
  `com.showxu.computer-mcp.development.secrets` service and matching access
  group); and
- security-scoped bookmarks in the GRDB database for workspaces selected by
  the user.

The GRDB database records workspace and profile state, provider health,
manifest revisions, single-use operation tickets, desired transport state,
and redacted audit metadata. It does not intentionally store complete tool
arguments, file contents, screenshots, command output, or credential values.

App logs use owner-only permissions, rotate at 1 MiB, retain at most three
rotated files plus the active file, bound individual fields, and redact field
names that look like authorization, credential, key, password, secret, or
token data. Provider output can still contain sensitive information, so users
should review diagnostics before sharing them.

Audit records and configuration revisions currently remain until the user
removes the App data; there is no time-based automatic deletion policy in
version 1.0.4.

## Keychain and temporary credentials

Keychain values use `AfterFirstUnlockThisDeviceOnly` accessibility and do not
sync through iCloud Keychain. Removing an OpenAI or Cloudflare profile through
the App deletes its Computer MCP-managed Keychain values. Uninstalling only
the App bundle does not automatically remove product state or Keychain items.

For a remotely managed Cloudflare tunnel, the App writes the Cloudflare token
to an owner-only temporary file only while starting `cloudflared`, then removes
that file. Consumer-owned Cloudflare Access service tokens are not stored by
Computer MCP.

## Data sent to other systems

Computer MCP sends data only through user-enabled boundaries:

- MCP tool results and protocol metadata go to the connected local or remote
  MCP client;
- OpenAI Secure MCP Tunnel and a user-created ChatGPT Connector send selected
  MCP traffic through OpenAI's service;
- Cloudflare named tunnels send selected MCP traffic through the user's
  Cloudflare account and public hostname;
- configured downstream MCP, CLI, Codex, network, or Computer Use providers
  receive the arguments required for the invoked capability; and
- external commands may use credentials already owned by those tools.

Computer MCP does not control the retention or use of data by those clients,
providers, OpenAI, Cloudflare, Codex, or other configured services. Review
their privacy terms and enable the narrowest profile that meets the need.

## Permissions

Screen Recording and Accessibility access are requested only through local App
actions. Remote clients cannot grant those permissions. Revoking access in
System Settings stops the associated Computer Use capabilities.

## Access and deletion

The App can remove individual workspace grants and tunnel profiles. Removing a
workspace grant does not delete files in that workspace. To remove remaining
local state, quit Computer MCP, remove the two directories listed above, and
delete Computer MCP items from Keychain. This is destructive and cannot be
undone; preserve any configuration or audit material you need first.

Questions about this policy should use the support channel in `SUPPORT.md`.
Security-sensitive reports should use GitHub private vulnerability reporting
as described in `SECURITY.md`.
