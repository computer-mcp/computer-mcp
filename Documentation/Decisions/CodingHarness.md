# Coding Harness

## Status

Accepted. The mechanisms under Prerequisites are validated by prototypes
before the implementation depends on them.

## Context

Clients (ChatGPT, claude.ai, Claude Code, Codex) drive Computer MCP, and
plugins extend it. Authorization today is a profile with a set of tool IDs, a
set of workspace IDs, a risk ceiling, a Full Shell switch and a confirmation
policy, and every granted tool applies to every granted workspace. One list
mixes what a principal may access with how its actions are executed, so it
cannot express common needs:

- A client either edits files without being able to build or test, or
  receives Full Access, which is arbitrary execution as the user.
- There is no unit of isolated work. The host cannot create a Git worktree;
  `delivery.apply` creates one internally for a single scenario with its own
  edit language, path scopes and commit message format; the Codex plugin
  manages its own worktrees by adding grants to profiles.
- Safety relies on confirmation steps that only the local App can answer, so a
  client used from a phone stops at the first one, and an approved step is no
  more confined than any other.
- Plugin processes and local MCP servers run with the user's full authority,
  whatever the calling client was granted, and inherit the host's environment.
- Several tools execute code or write outside a workspace without Full Access:
  file tools can write inside `.git`, host Git runs repository hooks and
  configured programs, `sqlite.query` can call `edit()` and `writefile()`,
  `cli.help` runs a registered command, a revision such as `--output=<path>`
  becomes a Git option, and a workspace registered inside another can be
  written through the outer one.
- The product's vocabulary (workspace, controller, capability) is its own,
  while the clients it serves and the platform it runs on use other words for
  the same things.

The host cannot see a client's conversations: every ChatGPT call arrives
through the same tunnel credential, and MCP session lifetimes do not match
conversations. Permissions therefore attach to the verified principal and to
the objects a call names, never to a conversation.

## Decision

Computer MCP is an environment on the owner's Mac that clients (ChatGPT,
claude.ai, Claude Code, Codex) drive and plugins extend. It is a coding harness
without the agent loop: a client brings its loop and its model, and Computer
MCP provides the tools, the execution environment and the permissions. This
decision gives it one permission model for every principal and one vocabulary,
taken from proven designs rather than invented. Apple's platforms separate
what an app may access (privacy permissions granted by the user), whether it
runs in a sandbox, and what its sandbox allows; an app outside the sandbox can
attempt anything but is still stopped by privacy permissions. Claude Code and
Codex run an agent's work in a worktree inside an operating-system sandbox,
through the ordinary development flow. Here, permissions, execution mode and
sandbox settings are three separate layers with their own granularity; work
happens in worktrees derived from projects; and safety comes from that
structure rather than from confirmation steps.

### Agent architecture

The terms follow common use in coding agents:

| Term | Meaning | Examples |
| --- | --- | --- |
| Model | The language model that decides each next step. It is not part of a harness. | GPT, Claude |
| Agent loop | The cycle that assembles context, calls the model, runs the tool calls it chooses, returns their results and decides when to stop. | ChatGPT calling tools within a conversation; the loops of Claude Code and Codex |
| Harness | What turns a model into an agent: the agent loop, tools, the execution environment, permissions, and the state and interface around them. | Codex, Claude Code |
| Agent | A model working on a task in a harness. | |
| Orchestrator | An agent that divides work among other agents, gives each its own task and environment, and combines their results. | A ChatGPT conversation that delegates a change to Codex through its plugin; the Claude Code agent that delegates to subagents and combines their results |
| Connector | An MCP integration, as ChatGPT and Claude use the word. | Computer MCP as seen from ChatGPT; the MCP servers and plugins Computer MCP calls |

```text
Client: model + agent loop
    │ inbound connection: transport and authentication establish a principal
    ▼
Computer MCP: tools, execution environment, permissions, worktrees
    │ launches, within the plugin's permissions
    ▼
Plugin agent: its own agent loop, in the plugin's execution mode
            (shown here sandboxed, in a worktree)
    │ network access through the host's egress proxy
    ▼
External services: package registries, model providers
```

From a client's side Computer MCP is a connector, reached through an inbound
connection (the ChatGPT tunnel, the Cloudflare tunnel with OAuth for
claude.ai, the local bridge for Claude Code and Codex) that establishes the
principal. On the host's side, MCP servers and plugins are the connectors it
calls on a principal's behalf, under the MCP server and Plugin permissions.
Programs in the sandbox reach other external services only through the
sandbox's network access.

Because the loop belongs to the client, the host keeps every step
loop-friendly: results and errors are structured and actionable
(`permission.required` names what is missing and who can grant it), state can
be queried again from any conversation (`git.worktree_list`, execution
status), and long-running work such as a build starts in the background and
is read in later calls, so no single call has to outlast a client's time limit
for tool calls.

A plugin may carry a complete harness of its own, as the Codex and Claude
plugins do. When a client drives such a plugin, the client acts as an
orchestrator and the plugin's agent as a delegated agent: Computer MCP gives
the delegated task its own worktree, and the plugin's loop runs within the
plugin's permissions. The outer permission model bounds the inner harness.

A front end that adds an agent loop, such as a future agent SDK, would make
Computer MCP a complete harness by itself, reusing the permission, sandbox and
worktree libraries described under Implementation surface.

### Naming

Terms follow Apple's platforms for permissions and Claude Code and Codex for
the harness. They are used the same way in tools, configuration, the App and
documentation:

| Term | Meaning | Source | Chinese label |
| --- | --- | --- | --- |
| Project | A registered folder, usually a repository | Claude Code, Codex | 项目 |
| Worktree | A Git worktree; here a project derived from another | Git, Claude Code, Codex | worktree |
| Client | An application that connects over MCP and drives Computer MCP; replaces "controller" | MCP | 客户端 |
| Plugin | An installed package that adds tools and may run processes | Claude Code, Codex | 插件 |
| Principal | A client or a plugin, as the subject of permissions | Apple (app as subject) | 主体 |
| Permissions | What a principal may access; replaces "capabilities" | Apple privacy permissions, Claude Code permissions | 权限 |
| Execution mode: Sandbox or Full access | Whether a principal's programs run in the sandbox | Apple App Sandbox, Codex sandbox modes and Full access | 执行方式：沙盒 / 完全访问 |
| Sandbox settings | What the sandbox allows: filesystem, Git and network access | Apple sandbox entitlements, Claude Code sandbox settings | 沙盒设置 |
| Network access: None, Trusted, Full, Custom | The sandbox's outbound connections | Claude Code environments | 网络访问：无 / 可信 / 完全 / 自定 |
| Permission request; Only this time, Always | A request for a missing permission and its answer | Apple privacy prompts, Codex and Claude Code approvals | 权限请求；仅这一次 / 始终 |
| Privacy & Security | Where permissions are reviewed and revoked | Apple System Settings | 隐私与安全性 |

Tools use the `project.*` namespace and the `project_id` parameter. The CLI
uses `project` commands, and worktree tools take Git's command names. Profiles
keep their name as the stored permissions of a client.

### Model

#### Correspondence with Apple's platforms

| Apple | Computer MCP |
| --- | --- |
| The user | The owner |
| macOS: enforces permissions, launches processes, provides system APIs | The Computer MCP host |
| System APIs and frameworks | Built-in tools |
| An app | A principal |
| An app the user works with, which initiates actions | A client (ChatGPT, Claude Code, Codex); its code, the model, runs elsewhere and acts on this machine by calling tools |
| An app or extension that provides services other apps drive | A plugin, which runs processes on this machine and provides tools |
| Code signature, bundle ID, notarization | A client's verified connection; a plugin's ID and official verification |
| Usage descriptions and entitlements an app declares | The permissions and sandbox settings a plugin manifest declares |
| Privacy permissions (TCC) | Permissions |
| Files and Folders: Desktop, Documents, Downloads and other categories | The Files and Folders permission, by the same categories |
| A user-selected folder kept with a security-scoped bookmark | A project |
| Screen Recording | Screen |
| Accessibility | Desktop control |
| Local Network | Local network |
| Automation (one app controlling another) | Plugin and MCP server permissions |
| Allow Once, Always | Only this time, Always |
| Sandboxed or unsandboxed app | Execution mode: Sandbox or Full access; like an unsandboxed app, Full access still meets privacy permissions and does not include Full Disk Access |
| Sandbox entitlements (network, file access exceptions) | Sandbox settings |
| MDM configuration profiles, where the stricter setting wins | Managed limits |
| Privacy & Security in System Settings | Privacy & Security in the App |
| The user's folders and documents | A project's main checkout |
| An app working in its own space, then saving to the user's document with permission | A principal working in a worktree derived from the project, then merging it back with `git.merge` |

Three differences shape the design:

- A client is not a local process. The sandbox confines what its tool calls
  run (shells, builds, Git), not the client itself.
- A worktree is not an app's private container. It is a working copy derived
  from a project for a piece of work, and every principal's access to it is its
  access to that project.
- Machine information and Skills have no privacy permission on Apple's
  platforms, where system information is open to apps. They are permissions
  here, granted to new principals by default, so the owner can still revoke
  them; unified logs, which can expose sensitive activity, are a separate
  permission that starts ungranted.

#### Layers

The model has an identity and three permission layers, above the operating
system's own permissions:

| Layer | Apple counterpart | Granularity | Set by | Enforced by |
| --- | --- | --- | --- | --- |
| Identity: which client or plugin | Code signature, bundle ID | per principal | connection verification, plugin ID | the host |
| Permissions: what it may access | Privacy permissions (TCC) | per principal and permission; projects, plugins and servers per object, Files and Folders per category | the owner, a permission request the owner answers, within managed limits | the host on every call, and the sandbox profile generated from them |
| Execution mode: Sandbox or Full access | Sandboxed or unsandboxed app | per principal | the owner; Full access needs local consent | the host, when it launches programs |
| Sandbox settings: what the sandbox allows | Sandbox entitlements | per principal and project, inherited by worktrees | the owner for network access and extra denied reads, a plugin's declarations; the rest is fixed | the operating-system sandbox, which also keeps programs from reaching the network except through the host's egress proxy, and the proxy, which applies network access |

Permissions apply in both execution modes. A sandboxed principal additionally
passes through its sandbox settings; a principal with Full access does not,
but its programs meet macOS privacy permissions under their own identity. The
worktree is the writable location its sandbox settings define.

#### Principals

A principal is a **client** or a **plugin**.

- A client is a profile bound to verified connection identities: its allowed
  callers and, where the transport provides one, a principal identity (each
  OAuth grant, the tunnel bridge credential, a local client identity). Calls
  from different conversations of one client share its permissions.
- A plugin is an installed package identified by its plugin ID. A local MCP
  server the owner registers directly is a plugin without a package: it is
  identified by its server ID, and the owner gives it permissions and sandbox
  settings at registration instead of a manifest declaring them.

#### Permissions

Permissions correspond to Apple's privacy permissions: what a principal may
access, granted by the owner and checked on every call in every execution
mode.

| Permission | Granularity | Values |
| --- | --- | --- |
| Project | per project | `read`, `write` or `deny` |
| Files and Folders | per category: Desktop, Documents, Downloads, iCloud Drive, network volumes, removable volumes | `read` or `deny`, for reading by host tools and sandboxed programs |
| Plugin | per plugin | `use` or `deny`: whether the principal may drive the plugin's contributions, as Automation lets one app control another |
| MCP server | per server registered directly by the owner | `read` (listing, resources, prompts, read-only tools), `all` or `deny` |
| Screen | per principal | screenshots, windows, displays, accessibility queries, pointer position, permission status |
| Desktop control | per principal | keyboard, pointer actions, scrolling, accessibility actions, opening and revealing files in apps |
| Local network | per principal | connections from the sandbox to devices on the local network: directly connected subnets, link-local addresses (including cloud metadata addresses) and multicast |
| Machine information | per principal | system, macOS, network diagnostics, environment, service status, the CLI and plugin catalogs |
| Unified logs | per principal | querying the macOS unified log |
| Skills | per principal | reading the skill library |

A permission is not granted, granted at a value, or denied. A call that needs a
permission that is not granted produces a permission request; a denied one
produces none. For projects, plugins and MCP servers, `*` covers every entry
without an explicit one, and an explicit entry, including `deny`, takes
precedence. The host's own data and credentials are never readable and are
never offered in a request. Screen and desktop control act on the whole
desktop, outside any sandbox; granting them is the owner's judgment of that
principal. New principals have Machine information and Skills; every other
permission starts not granted.

#### Execution mode

The execution mode corresponds to whether an app is sandboxed. It is set per
principal.

- **Sandbox** (default). The principal's programs run in the execution
  sandbox, and it changes a project only inside worktrees derived from it.
- **Full access.** The principal's programs run without the sandbox, in any
  directory, including a project's main checkout, as the user. Granting it
  needs the owner's local consent: for one connection, or saved for the same
  principal, caller and unchanged profile (the existing client access flow) for
  clients, and at enablement for plugins. Remote clients have it off by default
  and can be given it the same way. Full access does not include Full Disk
  Access. Control-plane changes (plugin and project management) require it.

#### Sandbox settings

Sandbox settings correspond to sandbox entitlements: what the sandbox allows
when a principal works in a project. They are set per principal and project and
inherited by the project's worktrees.

| Setting | Value |
| --- | --- |
| Filesystem write | the worktree, its temporary directory and its home and cache directory |
| Filesystem read | the operating system and applications; in user data areas (home directories and external and network volumes) only the principal's readable projects and their worktrees, the Files and Folders categories it may read, and the developer locations the host maintains, with the directories above them readable as directories only; never the host's data or credentials; minus locations the owner denies |
| Git | recording commits on the worktree's own branch through a private object store; never the repository's configuration, hooks, other branches or existing objects |
| Network access | `none` (default), `trusted` (a host-maintained list of package registries, GitHub and toolchain downloads), `full` (any host) or `custom` (the owner's host list, optionally with the trusted list) |
| System services | screen capture, accessibility and Apple Events are blocked unless the principal has Screen or Desktop control, so sandboxed programs never use the App's own privacy permissions beyond the principal's |

The mechanism follows Anthropic's sandbox-runtime, which Claude Code uses:
reads are open except denied regions, which can be reopened, and writes are
closed except allowed paths. The default configuration follows Apple's
Files and Folders: user data is denied and reopened by permissions. Programs
in the sandbox reach the network only through an egress proxy the host runs
for that sandbox, offering HTTP CONNECT and SOCKS5 with host-side name
resolution: the sandbox may connect only to the proxy's loopback ports, with no
direct connections, UDP or DNS of its own. The proxy admits the hosts the
level allows, resolves them itself through the system resolver and connects to
the address it checked. As with Apple's Local Network permission, the address
the proxy connects to decides: an address on a directly connected subnet, a
link-local address or a multicast address needs Local network, judged with the
system's routing table. The judgement is made per connection when the proxy
connects: the connection is bound to the interface it was judged on, and the
proxy ends it when a routing or interface change alters that judgement.
Programs in the sandbox cannot change the host's routes, so they cannot use
the interval between the check and the kernel's send. An address the system
routes into a tunnel interface, such as the 198.18.0.0/15 range a fake-IP tool
like Surge returns and routes through its own interface, is an ordinary
internet destination; where the tool
sends the traffic afterwards is governed by the tool, as it is for any app on
Apple's platforms. Loopback addresses are never reachable from the sandbox
except the proxy itself, because they lead to the host's own services,
including Computer MCP's gateway. A connection to another host
fails with an error naming it and produces a permission request for that host
and project; allowing it always adds the host to the project's `custom` list,
keeping the trusted list when the level was `trusted`, and allowing it only
this time admits it for that execution. MCP servers and plugin tools are
called by the host, not from the calling client's sandbox, so the client's
network access does not limit those calls; its permissions do. A sandboxed
plugin's own processes reach the network only within the plugin's network
access. A permitted host is not an authority to push: pushing needs
credentials, which programs in the sandbox do not have.

#### How the layers combine

- **Permissions apply everywhere.** Every host tool checks the principal's
  permissions in both execution modes: reading a project needs `read`,
  changing it needs `write`, reading Downloads needs Files and Folders,
  taking a screenshot needs Screen. For sandboxed programs, the host turns
  the same permissions into the sandbox profile: readable paths, local network
  addresses, and the system services for screen capture, accessibility and
  Apple Events. Sandboxed programs are the App's child processes and keep the
  App's macOS privacy permissions, such as access to protected folders, only
  as far as the principal's permissions allow.
- **A sandboxed principal** needs the permission and must stay within its
  sandbox settings: with `write` on a project it adds worktrees, works in them
  and merges them back; the main checkout stays read-only to it.
- **A principal with Full access** is not confined by the sandbox, but host
  tools still check its permissions, and the programs it runs are launched so
  that they do not inherit the App's macOS privacy permissions (screen
  recording, accessibility, automation, protected folders): macOS evaluates
  them on their own, as it evaluates an unsandboxed app.
- **A plugin call** needs the client's Plugin permission for that plugin and
  the client's permission for what the tool does (Project for a project tool,
  Skills for a contributed skill). The plugin acts with its own execution mode
  and permissions, as an automated app does. A sandboxed plugin's process
  serving a project or worktree writes only that one, so a call about project
  A cannot change project B, and it reads by its own sandbox settings. A plugin
  with Full access is not confined in this way, which the App states when it is
  enabled and when a client is allowed to use it. When the owner lets a client
  use a plugin, the App states where the plugin sits (sandboxed, writing
  worktrees, with its network access, or with Full access).
- **Path decisions.** One resolver decides every path for host tools and for
  the sandbox profile, in this order: the host's data and credentials are
  never readable; a location the owner or managed limits deny is denied; inside
  a registered project, the innermost project's permission decides, whatever
  folder category contains it, so a project in Downloads needs only its
  Project permission and a denied project stays denied when Downloads is
  readable; outside projects, a Files and Folders category decides for the
  paths it covers; then the developer locations the host maintains are
  readable; then each directory above a readable location can be opened and
  listed, without access to anything else inside it; then the operating system
  and applications are readable and every other user data area is denied.
- **Derivation.** A worktree is a project derived from its source. Every
  principal's permissions and sandbox settings for it are those for the
  source, resolved at each call; creating or removing a worktree changes no
  permission.
- **Nested projects.** A project registered inside another governs the paths
  inside it, including at its position inside a worktree of the outer
  project. A project tracked inside another project's Git repository shares
  that repository's history, so its permissions cannot be narrower than the
  outer project's for the same principal; the host rejects such a
  configuration.

#### Granting, requests and policy

The owner sets permissions in the App's Privacy & Security view, which lists
them by permission (which principals have desktop control) and by principal
(what ChatGPT can use), with revocation in both, or in a standalone manifest:

```toml
[[profiles]]
id = "chatgpt-operate"
allowed_callers = ["secure-tunnel"]
permissions = ["screen", "desktop-control", "machine", "skills"]
full_access = false

[profiles.projects]
"19591BE9-51BC-4709-B888-32B01D216E1F" = { access = "write", network = "none" }

[profiles.files_and_folders]
downloads = "read"

[profiles.plugins]
"*" = "use"

[profiles.mcp_servers]
"*" = "all"
```

When a call needs a permission the principal has not been granted, the host
refuses it with `permission.required`, naming the principal, the permission,
the object, the scope and, for a plugin, its declared purpose, and records a
pending request. The App shows it the way the system shows a privacy prompt.
The owner answers **Only this time** or **Always**, and the caller retries with
the request's ID. **Always** grants the permission until revoked. **Only this
time** is consumed by the first retry from the same principal whose tool,
project and arguments match the request; it covers that call and the execution
it starts for the execution's lifetime (reading its output, writing its input,
cancelling it), and no other call. Requests expire after a day. Revoking a
permission ends its use by running executions and proxy connections as well as
by later calls; revoking a client's Plugin or MCP server permission ends the
executions that client delegated to that plugin or server and no others.

A principal can ask for a folder that is not a project yet, as Claude Code
adds a directory to a session: `project.request` names a directory and the
access it needs. The owner verifies the folder's canonical path in the App and
answers Allow, which registers it as a project and grants that access until
revoked, or Don't Allow; registration does not take Only this time.
Registering a project, granting access to it and trusting configuration it
contains are separate: instruction files and skills in a project are given to
clients as data, and nothing a project declares runs because it was
registered.
Registering and removing projects directly stays a control-plane change.

Managed limits bound everything above, as configuration profiles do on Apple's
platforms, Claude Code's managed settings and Codex's requirements. They come
from a machine policy that an administrator installs (a system-wide policy
file or a configuration profile) and an owner policy kept by the App, and each
setting takes the stricter of the two. They set the most a principal may be
granted (for example no Full access for remote clients, no network access
beyond `trusted`, denied read locations) and the execution limits. The App
and manifests cannot grant beyond them, and the App shows the source of every
effective setting. A policy source that exists but cannot be read limits
everything it could limit until it can be read, and the App reports it.
Tightening a limit applies to running executions as well as to later calls.

Within a principal's permissions, calls execute without anyone's approval.
Tools carry accurate MCP annotations; whether a client's own interface asks
its user before a call is that client's behavior, which the host does not rely
on.

### Plugins

A plugin manifest declares what the plugin needs, each with a purpose shown to
the owner:

```toml
[[permissions]]
id = "project"
access = "write"
purpose = "Runs Codex in a worktree of the project you choose."

[sandbox]
network = { level = "custom", hosts = ["api.openai.com", "chatgpt.com"] }
purpose = "Codex contacts its model provider."
```

`[sandbox]` declares network access in the same levels, read exceptions inside
denied locations that the plugin needs for its own configuration, or instead
`full_access = true`, each with a purpose. The App shows the declarations when
a plugin is installed, updated or enabled. A declaration is a request, not a
grant or a signature: enabling grants it, with the owner choosing the objects
that a per-object permission (projects, MCP servers) covers, where `*` also
covers objects registered later, and a declaration added by an update waits
for the owner. A plugin is thus placed in the model like an app: sandboxed or
with Full access, with its permissions and sandbox settings, and usable by the
clients the owner allows through the Plugin permission.

A plugin process is bound to the project or worktree it serves and to the
plugin's permission revision at launch; when the plugin's permissions for that
project change, the host stops the process, and the next call starts one under
the new permissions. A plugin's tools declare their requirements like built-in
tools, by contribution type: MCP tools declare theirs, CLI contributions are
execution and Skills contributions need Skills. Plugins create and remove
worktrees through the same host service as `git.worktree_add` and
`git.worktree_remove`, so the Codex plugin's managed worktrees become ordinary
derived projects. These declarations are part of plugin API 1, which no plugin
has released yet.

### Tools

Every tool declares the permission and execution mode it needs in its
capability descriptor, and the built-in catalog snapshot records it.

| Tool | Needs |
| --- | --- |
| Reading `file`, `git` and `project` tools, structured formats, `archive.list`, `archive.read_file`, `process.list`, `process.read`, `shell.list`, `shell.read`, `runtime.owners.list`, `git.worktree_list`, `project.instructions` | Read access to each path, as the path resolver decides |
| Writing `file` tools, `git.add`, `git.unstage`, `git.commit`, `git.restore_worktree`, `git.clean`, `json.write`, `plist.write`, `archive.create`, `archive.extract`, `process.cancel`, `git.worktree_remove` | Project `write`; in a worktree unless Full access |
| `git.branch_create`, `git.branch_rename`, `git.branch_switch`, `git.tag_create`, `git.tag_delete`, `git.stash_push` | Project `write` and Full access, because they change references shared by every checkout |
| `shell.run`, `shell.spawn`, `shell.write`, `shell.cancel`, `process.spawn`, `cli.exec`, CLI command-tree tools | Project `write`; in a worktree inside the sandbox unless Full access |
| `file.download` | Project `write`; in a worktree whose network access admits the URL's host unless Full access |
| `git.worktree_add`, `git.merge`, `git.branch_delete` | Project `write`, called in the source project |
| `computer.*` reads; `computer.*` actions, `project.open`, `project.reveal` | Screen; Desktop control |
| `system.*`, `macos.*`, `network.*`, `env.describe`, `service.status`, `cli.list`, `cli.status`, `cli.describe`, `cli.help`, `plugin.list`, `describe`, `search`, `artifacts` | Machine information |
| `logs.query` | Unified logs |
| `skills.*` | Skills |
| `mcp.*` and tools re-exported from directly registered servers | MCP server, at the level the call needs, and the tool's own requirement (Project for a tool that names a project); for a remote server, a tool the host classifies as execution also needs Full access |
| Plugin contributions | Plugin `use` and the contribution's own requirement |
| `plugin.install`, `update`, `configure`, `enable`, `disable`, `uninstall`, `project.add`, `grant`, `remove`, `repair` | Full access |
| `project.list`, `project.describe`, `project.request`, `profile.show`, `profile.limit`, `policy.probe` | Nothing |

Forwarding tools (`runtime.owners.call`, `mcp.tools.call`) check their target
as if it were called directly. `profile.limit` lowers the calling connection's
permissions and never raises them. `git.commit` accepts `paths` and commits
exactly those paths (`git commit --only`), leaving other staged changes
staged.

`project.instructions` lists a project's instruction files (`AGENTS.md`,
`CLAUDE.md` and their nested copies, each with the paths it applies to) and its
skills (`SKILL.md` packages), with their sources, and returns their content
unchanged. Clients interpret them, as Claude Code and Codex interpret their
own.

### Execution

#### Worktrees

Host-created worktrees live outside every registered project, in
`Worktrees/<worktree-id>/<repository-name>` under the App's Application
Support directory or a `worktrees` directory beside a standalone host's
database file; hosts with an in-memory database have no worktree tools. Each is
registered as a derived project with its own project ID and appears under its
source in the App. A worktree outlives the connection and conversation that
created it, so a client can continue it from another conversation; it is
cleaned up by its state (merged, removed), not by session end. Gateway
runtimes rebuild when the registered project set changes, so a connected
client can address a new worktree on its next call. If the source is removed,
its worktrees become inaccessible and the App lists them for cleanup.
Worktrees created by other tools are Git state, listed by `git.worktree_list`,
and ordinary files of a project if they lie inside one.

The tools follow Git's commands:

| Tool | Git | Behavior |
| --- | --- | --- |
| `git.worktree_add` | `git worktree add` | In a project whose root is a non-bare repository's top level. Inputs: `name` (`[a-z0-9]+(-[a-z0-9]+)*`, at most 48 characters), optional `branch` (default `worktree/<name>`), optional `base` branch (default: the branch checked out in the main checkout; required when it is detached). Returns the worktree's `project_id`, path, branch and base. |
| `git.worktree_list` | `git worktree list` | Every worktree of the repository, with its `project_id` if derived, branch, base, commits ahead of and behind the base, and uncommitted changes. |
| `git.worktree_remove` | `git worktree remove` | Called in the worktree. Publishes the worktree's commits to its branch, then removes the worktree and its registration; uncommitted changes stop it unless `force` is true, which discards them but never commits. The branch is kept. |
| `git.merge` | `git merge --ff-only` | Merges a branch into the main checkout's current branch. A sandboxed principal may merge only a worktree branch into that worktree's base and only as a fast-forward; local changes the merge would overwrite stop it. Never creates merge commits, forces or pushes. |
| `git.branch_delete` | `git branch -d` | A sandboxed principal never forces, cannot delete the branch of a worktree that still exists, and cannot delete a worktree branch whose tip is not reachable from its base. |

Work in a worktree is the ordinary flow: edit, build, test, `git commit`,
`git rebase` onto the base when it has advanced, then `git.merge`,
`git.worktree_remove` and `git.branch_delete`.

Inside the sandbox, the repository's shared object store and references are
read-only. Git in the worktree writes new objects to a private object store
for that worktree and keeps its position on a detached `HEAD`; the host
maintains the named branch. When the host updates the branch (on `git.merge`,
on `git.worktree_remove`, or when asked to publish the worktree's commits), it
pauses the worktree's processes, copies the private objects into a host-owned
staging area, verifies them (`git fsck`, then `git index-pack --strict` on a
pack built from them), adds them to the shared store, and updates the branch
with a reference transaction that verifies its previous value. Recovery,
locking and journaling follow the worktree rules below.

The host keeps each worktree branch's base after its worktree is removed,
until the branch reaches the base or is deleted with Full access. Worktree
operations are journaled under a lock identified by the repository's
canonical common Git directory, shared by the App and CLI and taken by every
host operation that changes references; each mutation re-verifies the state it
depends on, and recovery undoes only state the journal proves the operation
created. The delivery implementation's lock, journal, recovery and Git
side-effect controls are the starting point.

#### Sandbox

The execution sandbox applies a principal's sandbox settings to every program
the host runs for it in a worktree: shells, processes, CLI tools, Git, plugin
processes and local MCP servers, and whatever they start, such as hooks,
filters and build scripts. It uses Seatbelt on macOS and bubblewrap on Linux,
following sandbox-runtime. Programs the host runs to answer a `read` call,
such as Git queries and format readers, and programs for calls that name no
project, such as skill validation, run in a read-only variant with no writable
location except a temporary directory. Network diagnostics under Machine
information are host services that run fixed programs with the network and no
project access.

Local MCP servers that the owner registers directly are launched through the
same sandbox with the permissions and sandbox settings the owner gives them at
registration, as plugins are, and follow the plugin rules: a call to one of
their tools needs the client's MCP server permission and the tool's own
requirement, a server process is bound to the project or worktree it serves,
and a call that names no project is served by a process with no writable
project. Remote MCP servers are outside the host's confinement and are trusted
as external services.

Every sandboxed program starts with an environment the host constructs: a
fixed set of variables (`PATH`, `HOME` and `TMPDIR` pointing at the worktree's
own directories, locale and terminal settings, and the proxy variables), and
none of the host's tokens or credentials. Keeping credentials out of the
sandbox and attaching them in the proxy to requests for named hosts, as
Claude Code's network secrets do, is a later decision that fits this model.

The host's in-process tools apply the same boundaries: they write only inside
the worktree a call addresses (or, with Full access, inside the project with
`write`), never write Git metadata, check each path at the moment of the
operation anchored on directory handles, refuse writes to files with more than
one hard link, and cover every member of a recursive operation and every
archive entry. `file.trash`, which moves files into the user's Trash, is the
one write outside the worktree.

Host subprocesses keep a fixed argument shape: caller values never become
options, and Git revisions are resolved to object IDs first. `cli.help`
returns the registered command tree's metadata; running a command's own help is
execution.

#### Executions

Every program a call starts is an execution with a stable ID, bound to the
principal, project, execution mode and grants it started under. A call can
start it in the background and return; later calls read its output from a
cursor, read its exit status, write to its input where it has one, and cancel
it. Only the same principal can do so. While the execution runs, the grants it
started under must still hold. After it ends, its output, exit status or
interruption stay readable by the same principal for the retention period,
including when it ran under Only this time, unless a grant it started under
was revoked or it ran under a grant limited to a connection that has ended;
otherwise the call is refused and the output stays unreadable.

An execution lasts as long as the grants it started under. One started under
standing permissions continues when the client disconnects, and its output
stays available for its retention period. One started under a grant limited to
a connection (Full access for that connection) or to the execution (Only this
time) ends when that grant ends or is revoked. When the host restarts, running
executions end and are reported as interrupted; cancelling ends the execution
and everything it started.

Execution limits follow Claude Code's defaults unless managed limits set
others: a call that waits for its program has a time limit of 2 minutes by
default and 10 minutes at most; a background execution has no time limit; the
host keeps the most recent 8 MiB of each execution's output and reports how
much it dropped, without stopping the program; memory is limited only where a
managed limit sets it and the sandbox backend can enforce it. The result states
which limits applied and which one ended the execution. The existing
`shell.spawn` and `process.spawn` executions take these semantics.

#### Host operations on the main repository

`git.worktree_add`, `git.merge`, `git.worktree_remove`, `git.branch_delete`
and the promotion of a worktree's objects change the main repository, so the
host runs them itself rather than in a principal's sandbox. For a sandboxed
principal they run with hooks and fsmonitor disabled and every configuration
key that names a program (editors, pagers, credential and SSH helpers, signing
programs, diff and merge drivers, filters) overridden to its inert value, and
`git.merge` refuses a repository whose attributes assign a filter. A hook,
driver or filter that a merged change introduces therefore runs only when the
owner or a principal with Full access next runs Git.

#### Full access

Programs a principal with Full access runs start in the requested directory
without the sandbox and without the App's responsibility for macOS privacy
permissions, so they receive their own privacy prompts or refusals. Every
launch path goes through one launcher that disclaims responsibility before
the program starts: direct `posix_spawn` with
`responsibility_spawnattrs_setdisclaim`, swift-subprocess through its Darwin
spawn-attribute hook, and Foundation `Process` through its private
`setSpawnedProcessDisclaimed:`. These interfaces are not public; each macOS
release is checked against them, and if one stops working the launcher refuses
Full access launches and reports why, rather than inheriting the App's
permissions. Host tools still check the principal's permissions.

#### Execution records and audit

Host services that need proof of the executing call, such as a plugin removing
a worktree, receive the record the host creates for each call to a tool that
declares such a host action. The record is bound to the call's identity, tool,
project and arguments and has no approval state.

The audit log records, for every call and execution, the client and the
principal that acted, the project, the policy and permission revisions, the
decision with any denial reason or permission request, and the outcome.
Arguments are kept as digests and output is not stored, so the log carries no
file content or secrets; entries are kept for a bounded period.

### Implementation surface

The permission model, the execution sandbox and the worktree lifecycle are
libraries with no MCP, tool-definition or gateway types, so a front end other
than the MCP gateway, such as a future agent SDK that adds the agent loop, can
reuse them. They live in this package as separate targets, enforced by the
module graph, and move to a separate package when a second consumer exists.

- `ComputerMCPPermissions` (base layer, below `ComputerMCPCore`): principals,
  permissions, execution modes, sandbox settings, managed limits, evaluation
  and permission requests, with protocols for their storage and for resolving
  a principal's permissions at a path.
- The sandbox: a neutral profile model, with Seatbelt in
  `ComputerMCPPlatformDarwin` and bubblewrap in a Linux platform
  implementation, the egress proxy, and one launcher in `ComputerMCPProcess`
  through which every host subprocess starts, either in the sandbox or with
  Full access without inherited privacy responsibility, with execution IDs,
  output cursors and limits.
- `ComputerMCPWorktrees` (services layer): the Git worktree lifecycle, object
  promotion, repository lock, journal and recovery, with the derived-project
  store as a protocol.
- Adapters: `ComputerMCPCore` capability descriptors declare requirements in
  permission-model terms; `ComputerMCPToolsGit` exposes the worktree tools;
  `ComputerMCPToolKit` applies operation-level path checks for in-process
  tools; `ComputerMCPPlugins` reads manifest declarations, records enablement
  grants, launches plugins through the sandbox and provides the worktree host
  service; `ComputerMCPDownstream` launches local MCP servers through the
  sandbox; `ComputerMCPGateway` and `ComputerMCPPersistence` evaluate each
  call, store permissions, requests, managed limits, the derived-project
  ledger, execution records and audit, and migrate existing data.
- `ComputerMCPApp`: the Privacy & Security view, permission requests with
  Only this time and Always, plugin declarations, Full access consent, managed
  limit sources and worktrees under their source; the approval views are
  removed.
- The rename from workspace to project across tools, parameters, CLI, App,
  database and documentation is its own change.
- Documentation: architecture (including the module layers and the agent
  architecture), references and the plugin package format in both languages,
  DocC, localizations and the module graph.

## Consequences

### Behavior

- Sandboxed clients that edited main checkouts directly now work in worktrees
  and merge back.
- Calls a confirmation policy held for local approval now execute within the
  principal's permissions.
- Remote clients complete a whole change, including merging it, from the
  device the user is holding.
- Conversations of one client are not isolated from each other.
- Plugins and local MCP servers run confined to their declared and granted
  permissions.
- Permission requests are answered in the App; answering them away from the
  Mac is outside this decision.

### Configuration and migration

Profiles store `permissions`, `projects` (access and network access per
project), `files_and_folders`, `plugins`, `mcp_servers`, `full_access`,
`allowed_callers` and the authorization revision. Old fields (`capabilities`,
`workspaces`, `mode`, `full_shell_enabled`, `confirmation_policy`) fail
validation with an error naming the replacements.

A database migration converts stored profiles from their effective
authorization (wildcards expanded against registered tools, projects and
servers):

| Old | New |
| --- | --- |
| `local-full-access` with Full Shell | `full_access = true` (consent still per connection or saved trust); projects at `write` |
| `local-full-access` without Full Shell, or `workspace-operations` | sandbox; each project at `write` if the profile held any project write tool, else `read` |
| Workspace `*` | project `*` at the same access, so projects registered later stay covered |
| `read-only` | sandbox; each project at `read`; only Screen, Machine information, Unified logs and Skills can be granted |
| Any tool of a per-principal permission | that permission, subject to the row above; `logs.query` maps to Unified logs |
| Network-using project tools | network access `full` for each of its projects |
| `mcp.tools.call` | `"*"` at `all`, or at `read` for a `read-only` profile; downstream tools classified as execution need Full access, as they needed Full Shell |
| MCP listing, resource, prompt, event and request-reading tools without `mcp.tools.call` | `"*"` at `read`, the servers they applied to; `mcp.requests.cancel` and `mcp.connections.close` held without `mcp.tools.call` are dropped and reported |
| `mcpServerIDs` | each server at `all`, or at `read` for a `read-only` profile |
| Individual downstream tools or aliases | each tool's current server, at `read` if every granted tool of that server is read-only and the profile allowed no more, else at `all`; unresolvable grants are dropped and reported |
| Plugins | Plugin `*` at `use` for profiles that held any plugin contribution, else not granted |
| `confirmation_policy` | removed |

Files and Folders, Local network and managed limits are new and start not
granted or empty. Widened: profiles that held some tools of a permission
receive the whole permission, and calls a confirmation policy held now
execute. Narrowed: sandboxed principals write only in worktrees, so projects
whose root is not a Git repository's top level become read-only to them; their
programs run in the sandbox; `git.branch_create`, `rename`, `switch`,
`git.tag_*` and `git.stash_push` need Full access.

The migration advances every authorization revision, which invalidates saved
Full access trust bound to the old snapshot, removes pending approval tickets,
renames workspace records to projects, and moves `pluginDerivedWorkspaces`
rows to the derived-project ledger without the grants they added. Installed
plugins receive their declared permissions when next enabled or updated. For the
owner's current database, `chatgpt-operate` becomes a sandboxed client with
`write` on its seven projects and network access `none`, Screen, Desktop control,
Machine information, Unified logs and Skills, and every MCP server at `all`.

### Retirement

`delivery.apply`, `delivery.scopes.list`, `[[delivery.scopes]]` and the
`ComputerMCPDelivery` module are removed with their tests, reference pages,
localizations, catalog entries, validation fixtures and examples; the worktree
module takes over their lock, journal and recovery. `git.worktrees` is replaced
by `git.worktree_list`. `operations.prepare`, `operations.commit`, the
confirmation policy and approval tickets are removed.

### Later decisions

These fit the model and are left for later, some for the agent SDK to settle
first: proxy-injected network secrets; lifecycle hooks on tool calls,
executions and worktrees; project setup scripts and environment caches; file
checkpoints beyond Git; answering permission requests away from the Mac.

### Prerequisites

Prototypes on macOS 27 with ad-hoc signing and the hardened runtime settled
the Git object store, the launch paths for Full access and the egress proxy
described above, against public DNS; the proxy is checked again on the
owner's Mac with Surge's fake-IP mode; the proxy reuses the port rules,
connection handling and violation records of sandbox-runtime under Apache-2.0,
with attribution, and its own address rules. These remain:

- **SwiftPM's default build system.** It drops `TMPDIR` when it starts link
  tasks, so they write to the shared system temporary directory and the sandbox
  refuses them. Until SwiftBuild passes the sandbox's temporary directory to its
  tasks, builds in the sandbox use SwiftPM's native build system on a pinned
  toolchain; the sandbox does not open the system temporary directory. The fix
  belongs in SwiftBuild.
- **Production proxy.** Unforgeable attribution of each connection to its
  execution, host and address normalization, DNS and interface changes,
  concurrency and buffer limits, timeouts and half-closed connections, and
  revocation of a running execution's connections.
- **Linux backend.** The bubblewrap backend lands with the Linux host; until
  then a Linux build of the host refuses sandboxed execution and says why. Its
  layout for the private object store and the network relay is validated on
  Linux then.
- **Release signing.** The Full access launch paths and the sandbox are checked
  again in the Developer ID signed App.

### Acceptance

- A remote client with `write` adds a worktree, edits, builds, tests and
  commits in it with the sandboxed shell, rebases it onto an advanced base,
  merges it, removes it and deletes its branch, through the HTTP transport,
  without reconnecting and without any approval step; a background build is
  read through its execution ID across calls and survives a reconnection.
- In the sandbox, writes outside the worktree, to the repository's
  configuration, hooks, other branches or existing objects, connections to
  hosts the network access level does not admit, to local network addresses
  without Local network and to loopback addresses other than the proxy, and
  reads of user data outside readable projects, granted
  Files and Folders categories and developer locations, and of the host's data
  and credentials fail, while reads of the system and of readable projects
  succeed; the directories above a readable location can be listed while
  their other contents stay unreadable, and an explicit denial still wins over
  them; a denied host or folder produces a permission request, and after the
  owner allows it, only this time or always, the retried operation succeeds;
  hooks and filters planted in the worktree run only inside the sandbox; the
  sandbox environment contains none of the host's credentials; a sandboxed
  program cannot capture the screen, use accessibility or send Apple Events
  without the principal's Screen or Desktop control permission, even when the
  App has the matching macOS permission.
- A sandboxed principal cannot write a main checkout; a principal with Full
  access and `write` can; a Full access program does not inherit the App's
  screen recording or accessibility permission; host tools still refuse a
  principal with Full access a permission it lacks.
- A permission that is not granted produces `permission.required` and a
  pending request, a denied one produces none, and managed limits cap what the
  App can grant; an unreadable policy source limits everything it could limit;
  revoking a permission ends its use by a running execution.
- An Only this time grant is consumed by one matching retry and covers only the
  execution it starts, whose result stays readable for its retention period; a
  Full access execution for one connection ends with that connection, and no
  later connection can read its output or write its input; a project request
  offers only Allow and Don't Allow.
- The path resolver gives a project inside Downloads its Project permission
  without Files and Folders, keeps a denied project unreadable when Downloads
  is readable, and keeps the host's data unreadable everywhere.
- A sandboxed plugin's process and a local MCP server cannot exceed their
  permissions or write a project other than the one a call names; a plugin
  with Full access is described as unconfined when it is enabled and when a
  client is allowed to use it; a call to any plugin's tool needs the client's
  Plugin permission and the tool's own requirement; and the Codex plugin's
  managed worktrees are derived projects created through the host service.
- A `deny` entry overrides `*`; a nested project in the same repository with
  narrower permissions than the outer project is rejected; `git.merge` of a
  change that adds a hook or filter runs neither.
- Changing a project's permissions applies to its worktrees on the next call,
  and a nested project keeps its own permissions inside a worktree.
- `git.merge` refuses non-fast-forward merges, merges into another branch and
  local changes it would overwrite; object promotion rejects corrupt or
  unexpected objects; `git.branch_delete` refuses the branch of an existing
  worktree; no tool used by a sandboxed principal loses an unmerged worktree
  commit, including after its worktree is removed.
- In-process tools refuse Git metadata, multiply linked files and writes
  outside a worktree, including through recursive operations, archive
  extraction and a symbolic link swapped during the operation; `sqlite.query`
  and `cli.help` execute nothing outside the sandbox; a revision such as
  `--output=<path>` is treated as a revision.
- `project.instructions` returns a project's instruction files and skills with
  their sources and scopes.
- The audit log records every call's principal, project, decision and outcome
  without arguments or output in clear.
- The migration converts a copy of the owner's database and fixtures for each
  table row to the stated result.

## Alternatives Considered

- **One permission list (the current model).** It mixes access with execution
  and can neither describe nor confine what a principal does.
- **Confirmation steps in the flow.** They stop remote work and do not confine
  an approved step; the environment does.
- **Per-conversation permissions.** The host cannot observe conversations.
- **One setting per project for all principals.** A project commonly needs
  different access for a local agent, ChatGPT and a plugin.
- **Path rules inside projects.** Local harnesses do not use them; worktrees
  and the sandbox bound writes.
- **Reads open everywhere, as sandbox-runtime does with no configuration.**
  Programs in the sandbox would read user folders no permission covers; the
  same mechanism with Apple's Files and Folders defaults keeps them readable on
  request.
- **Direct writes to main checkouts by sandboxed principals.** They would
  escape the environment that confines the work; Full access covers them.
- **Special rules for who created a worktree.** Derived projects inherit
  without exceptions.
- **Worktrees bound to a session or thread, as in Claude Code and Codex.** A
  principal here continues across connections and clients, so worktrees end by
  their own state.
- **Escape hatches by command pattern or unsandboxed retry, as in Claude
  Code.** They bypass the boundaries the sandbox establishes; a missing
  permission is requested, and unconfined work uses Full access.
- **Credential injection that also opens network access.** Network access
  stays the only outbound policy.
- **File checkpoints.** Neither Claude Code's nor Codex's give a complete
  rollback (Codex removed its snapshots); Git is the recovery mechanism.
- **Delivery's single-call edit, commit and land.** It couples a generic need
  to one scenario.
- **Plugins outside the model.** A plugin would carry more authority than the
  principal calling it.
- **Product-specific terms.** Workspace, controller and capability named the
  same things clients and the platform already name.

## Related Documentation

- Current model this decision changes:
  [Security and Privacy](../Architecture/SecurityAndPrivacy.md),
  [Gateway](../Architecture/Gateway.md), [Runtime](../Architecture/Runtime.md),
  [Capability Ownership](../Architecture/Ownership.md) and
  [Naming](../Architecture/Naming.md).
- Reference pages it changes: [Tools](../Reference/Tools.md),
  [Configuration](../Reference/Config.md),
  [Plugin Packages](../Reference/PluginPackages.md),
  [Scoped host services](../Reference/HostServices.md),
  [CLI](../Reference/CLI.md) and [Isolated delivery](../Reference/Delivery.md),
  which it retires.
- [Plugin API Version](../Decisions/PluginAPI.md) for plugin API 1, which gains
  permission declarations.
- [Remote OAuth Authorization](../Decisions/RemoteOAuth.md) for the identities
  remote clients carry.

As the implementation lands, the resulting model is stated in the
architecture documents above and the tool, configuration and plugin contracts
in their reference pages; this record keeps the rationale.
