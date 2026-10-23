# Capability Ownership

A capability belongs in gateway core only when Computer MCP owns the stable
cross-provider contract and the wrapper adds containment, typed output,
bounded execution, or a deliberate safety gate.

## Ownership Map

| Owner | Responsibilities |
| --- | --- |
| Computer MCP core | MCP transports, App socket, profiles, project grants, audit, operation tickets, CLI/MCP bridges, Skills, typed project/file/Git/structured/system tools, Shell, and generic Computer Use |
| Plugins | Domain state, runtime configuration and vendor execution |
| `apple-cli` / `apple-cli-mcp` | Clipboard, notifications, Finder, application launching, URL opening, and Apple application/domain workflows |
| Browser provider | Browser engine, page lifecycle, selectors, and browser automation |
| Other downstream MCP providers | Their own business schemas, authentication, and side-effect contracts |

Skills are a first-class gateway plane, not a coding feature. Any authorized MCP
consumer can discover and read an entire registered Skill package without
escaping its root.

`project.open` and `project.reveal` remain project-contained navigation
primitives. They do not form a general Finder or application automation API.

## Plugin ownership

Plugins own their runtime configuration, domain state and vendor execution.
The host owns admission, project registrations, grants, operation tickets and
audit through the [host-service contract](../Reference/HostServices.md).
For coding runtime details, see the [Codex plugin](https://github.com/computer-mcp/plugin-codex).

## Project Identity

A project registration is identified by its symlink-resolved canonical root,
not by the spelling of the submitted path. Registering the same canonical root
again is idempotent and returns the existing project. A conflicting explicit
display name requires review rather than silently changing metadata.

Older duplicate rows are repaired by a digest-bound preview/apply operation.
The oldest registration remains canonical, profile references move to it, and
the retired IDs become durable aliases so historical audit and ownership
receipts continue to resolve. Deduplication never deletes the underlying
project and never treats equal-looking path text as sufficient ownership.

## Approval Ownership

Host capability authorization and human confirmation are separate decisions.
The host decides whether the authenticated caller may use a capability in a
registered project, then applies its confirmation policy to that operation.
Only the local control plane resolves pending host approval tickets.

Plugin execution approvals do not approve host operation tickets. Calls back
into host tools follow the host authorization and confirmation path.
MCP elicitation is interaction, not permission.

## External Provider Composition

For `apple-cli-mcp` or another local MCP provider:

1. Register it under `[[mcp.servers]]`.
2. Select exact `allowed_tools` or explicitly choose `allow_any_tool = true`.
   Grant the registration to the intended profile through `mcp_servers`, or
   grant particular tool capabilities. Registration policy remains host-owned.
3. Check `mcp.servers.status`.
4. Inspect `mcp.tools.list` and `mcp.tools.describe`.
5. Invoke through `mcp.tools.call`, or opt into a reviewed pinned/reexported
   surface.

Missing optional providers do not prevent Computer MCP from starting.

## Builtin Admission Gate

A new typed builtin must satisfy all of these:

1. No existing CLI or MCP provider clearly owns the domain.
2. The action is common and stable, not project-specific business behavior.
3. The wrapper adds real structure, containment, safety, or high-frequency
   ergonomics beyond `cli.exec` or `mcp.tools.call`.
4. Input maps directly to deterministic execution.
5. Traversal, time, output, and result limits are explicit.
6. Risk, profile, project, network, and TCC effects are classified.
7. Focused tests and real dogfood cover success and representative failure.

Wrappers that merely rename an existing command do not enter gateway core.
