# Capability Ownership

A capability belongs in gateway core only when Computer MCP owns the stable
cross-provider contract and the wrapper adds containment, typed output,
bounded execution, or a deliberate safety gate.

## Ownership Map

| Owner | Responsibilities |
| --- | --- |
| Computer MCP core | MCP transports, App socket, profiles, workspace grants, audit, operation tickets, CLI/MCP bridges, Skills, typed workspace/file/Git/structured/system tools, Shell, and generic Computer Use |
| Codex provider | App Server, Exec, and MCP session lifecycles through `swift-codex` |
| `apple-cli` / `apple-cli-mcp` | Clipboard, notifications, Finder, application launching, URL opening, and Apple application/domain workflows |
| Browser provider | Browser engine, page lifecycle, selectors, and browser automation |
| Other downstream MCP providers | Their own business schemas, authentication, and side-effect contracts |

Skills are a first-class gateway plane, not a coding feature. Any authorized MCP
consumer can discover and read an entire registered Skill package without
escaping its root.

`workspace.open` and `workspace.reveal` remain workspace-contained navigation
primitives. They do not form a general Finder or application automation API.

## Codex Boundaries

Computer MCP does not maintain a hand-written coding agent or shell-based
`coding.*` provider. It integrates the installed Codex through:

- App Server for stateful threads and turns;
- Exec for isolated JSONL jobs;
- MCP for the upstream `codex` and `codex-reply` tools.

The gateway fixes cwd, sandbox, approval policy, output limits, and session
ownership. Authentication mutation, config writes, marketplace mutation, and
remote-control pairing remain local Codex/App control-plane operations.

## External Provider Composition

For `apple-cli-mcp` or another local MCP provider:

1. Register it under `[[mcp.servers]]`.
2. Declare the exact `allowed_tools` for remote profiles. Use
   `allow_any_tool = true` only in a trusted local-admin manifest.
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
6. Risk, profile, workspace, network, and TCC effects are classified.
7. Focused tests and real dogfood cover success and representative failure.

Wrappers that merely rename an existing command do not enter gateway core.
