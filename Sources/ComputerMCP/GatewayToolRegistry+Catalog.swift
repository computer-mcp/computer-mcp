import ComputerMCPCore
import Foundation

extension GatewayToolRegistry {
  internal static func gatewayDefinitions(
    builtins: Set<String>,
    hasMCPProviders: Bool,
    toolMeta: JSONValue?
  ) -> [ToolDefinition] {
    var definitions = [

      ToolDefinition(
        tool: MCPTool(
          name: "mcp.servers.list",
          description: "List downstream MCP servers registered in the local gateway.",
          inputSchema: objectSchema(),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.servers.list", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.servers.status",
          description:
            "Report deterministic downstream MCP provider readiness metadata without starting servers or calling tools.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Optional registered MCP server id. Omit to inspect all.")
            ]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.servers.status", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.tools.list",
          description: "List tools from one registered downstream MCP server.",
          inputSchema: objectSchema(
            properties: ["server": stringSchema("Registered MCP server id.")],
            required: ["server"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.tools.list", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.tools.describe",
          description:
            "Return the exact definition and input schema for one downstream MCP tool by name, plus call_context for mcp.tools.call. This is deterministic exact matching, not semantic tool selection.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "tool": stringSchema("Exact downstream tool name."),
            ],
            required: ["server", "tool"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.tools.describe", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.tools.find",
          description:
            "Filter tools from one registered downstream MCP server by deterministic string matching over name and description.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "query": stringSchema("String query to match."),
              "match": stringSchema("Match mode: contains, prefix, suffix, or exact."),
              "field": stringSchema("Field to match: name, description, or all."),
              "case_sensitive": boolSchema("Whether matching is case-sensitive."),
              "max_results": integerSchema("Optional result cap. Defaults to 50."),
            ],
            required: ["server", "query"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.tools.find", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.tools.call",
          description:
            "Call a tool on one registered downstream MCP server. A request_id deduplicates the exact input across synchronous and asynchronous calls. Set wait_for_result to false to return after dispatch; query the retained result with mcp.requests.read or request cancellation with mcp.requests.cancel.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "tool": stringSchema("Downstream tool name."),
              "workspace_id": stringSchema(
                "Stable workspace id returned by workspace.list. Required for host-service calls when multiple workspaces are registered."
              ),
              "request_id": stringSchema(
                "Optional caller-stable deduplication id, at most 256 UTF-8 bytes. Reuse only for identical inputs; query using mcp.requests.read. Required when wait_for_result is false."
              ),
              "wait_for_result": boolSchema(
                "Whether to wait for the downstream result. Defaults to true. When false, request_id is required and the call returns after the request starts."
              ),
              "arguments": .object([
                "type": .string("object"),
                "description": .string("Arguments passed to the downstream tool."),
                "additionalProperties": .bool(true),
              ]),
            ],
            required: ["server", "tool"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.tools.call", risk: .destructive,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.resources.list",
          description:
            "List resources from one registered downstream MCP server through resources/list. Returned resources include read_context for mcp.resources.read when a URI is present.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "cursor": stringSchema("Optional downstream pagination cursor."),
            ],
            required: ["server"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.resources.list", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.resources.templates.list",
          description:
            "List resource templates from one registered downstream MCP server through resources/templates/list. This does not expand URI templates.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "cursor": stringSchema("Optional downstream pagination cursor."),
            ],
            required: ["server"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.resources.templates.list", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.resources.read",
          description:
            "Read one resource URI from a registered downstream MCP server through resources/read. The gateway forwards the URI exactly and does not interpret it locally.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "uri": stringSchema("Exact downstream resource URI."),
            ],
            required: ["server", "uri"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.resources.read", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.prompts.list",
          description:
            "List prompts from one registered downstream MCP server through prompts/list. Returned prompts include get_context for mcp.prompts.get when a name is present.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "cursor": stringSchema("Optional downstream pagination cursor."),
            ],
            required: ["server"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.prompts.list", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.prompts.get",
          description:
            "Get one prompt from a registered downstream MCP server through prompts/get. Prompt arguments, when provided, must be string values and are forwarded exactly.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "name": stringSchema("Exact downstream prompt name."),
              "arguments": .object([
                "type": .string("object"),
                "description": .string(
                  "Optional downstream prompt arguments. Values must be strings."),
                "additionalProperties": .object(["type": .string("string")]),
              ]),
            ],
            required: ["server", "name"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.prompts.get", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.events.read",
          description:
            "Read cursor-paginated list-changed and connection events from one persistent downstream MCP session.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "session_id": stringSchema(
                "Session identity from a previous event page. Supply it when continuing a cursor so a replaced session cannot be mistaken for the original. Reading events never starts a server."
              ),
              "after_cursor": integerSchema(
                "Return events after this cursor. Defaults to 0."
              ),
              "max_results": integerSchema(
                "Maximum events to return from 1 through 500. Defaults to 100."
              ),
            ],
            required: ["server"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.events.read", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.requests.list",
          description:
            "List currently active tool requests on one persistent downstream MCP session.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id.")
            ],
            required: ["server"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.requests.list", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.requests.cancel",
          description:
            "Send the MCP cancellation notification for one active downstream tool request.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "request_id": stringSchema(
                "Caller-stable request id supplied to mcp.tools.call."
              ),
              "reason": stringSchema("Optional human-readable cancellation reason."),
            ],
            required: ["server", "request_id"]
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "mcp.requests.cancel", risk: .destructive,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.connections.close",
          description:
            "Close one exact retained MCP connection and join its managed-process teardown. This stops all work on that connection, not just the locating resource. Requires a live owner selected through runtime.owners.call; use that same owner for operations.prepare/commit when approval is required. Remote or detached work may remain uncertain; transport closure does not prove work stopped.",
          inputSchema: objectSchema(
            properties: ["server": stringSchema("Registered MCP server id of the selected owner.")],
            required: ["server"]),
          meta: toolMeta),
        capability: CapabilityDescriptor(
          id: "mcp.connections.close", risk: .destructive,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.requests.read",
          description:
            "Read a retained MCP execution result without starting a connection or replaying work. Continue with next_offset for bounded JSON output; expired, unavailable and unknown outcomes are explicit.",
          inputSchema: objectSchema(
            properties: [
              "server": stringSchema("Registered MCP server id."),
              "request_id": stringSchema("Caller-stable request id supplied to mcp.tools.call."),
              "offset": integerSchema(
                "UTF-8 byte offset returned as next_offset. Defaults to zero."),
              "max_bytes": integerSchema(
                "Maximum output bytes from 4 through 65536. Defaults to 32768."),
            ],
            required: ["server", "request_id"]),
          meta: toolMeta),
        capability: CapabilityDescriptor(
          id: "mcp.requests.read", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),

    ]

    if !hasMCPProviders {
      definitions.removeAll { $0.tool.name.hasPrefix("mcp.") }
    }

    for builtin in builtins.sorted() {
      switch builtin {
      case "system.info":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.info",
              description:
                "Return a non-secret read-only macOS system and current gateway process summary.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.info", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.kernel":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.kernel",
              description:
                "Return read-only macOS kernel and machine identity from uname, plus OS version and processor counts. This does not run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.kernel", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.software":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.software",
              description:
                "Return read-only macOS product name, version, and build version using fixed /usr/bin/sw_vers argv, plus ProcessInfo version fields. This does not run shell commands.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema("Optional timeout in milliseconds.")
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.software", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.locale":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.locale",
              description:
                "Return read-only current locale, preferred languages, calendar, and time-zone summary from Foundation. This does not run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.locale", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.memory":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.memory",
              description:
                "Return read-only macOS virtual-memory page counters and memory event counters using host_statistics64. This does not inspect processes or run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.memory", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.load":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.load",
              description:
                "Return read-only macOS load averages from getloadavg, with values normalized by active processor count. This does not inspect processes or run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.load", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.cpu":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.cpu",
              description:
                "Return read-only CPU and hardware identifier details from ProcessInfo, sysctlbyname, and uname. This does not inspect processes or run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.cpu", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.thermal":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.thermal",
              description:
                "Return read-only thermal state and low-power-mode status from ProcessInfo. This does not inspect processes or run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.thermal", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.time":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.time",
              description:
                "Return the current local time, Unix timestamp, time zone, and system uptime. This is read-only.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.time", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.uptime":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.uptime",
              description:
                "Return read-only system uptime and derived boot time from ProcessInfo.systemUptime. This does not run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.uptime", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.user":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.user",
              description:
                "Return read-only POSIX identity for the current gateway process using getuid/getgid/getpwuid/getgrgid. This does not enumerate users or run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.user", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.groups":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.groups",
              description:
                "Return read-only supplementary POSIX groups for the current gateway process using getgroups/getgrgid. This does not enumerate all system groups or run shell commands.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.groups", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.power":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.power",
              description:
                "Return raw macOS battery and power-source status using /usr/bin/pmset -g batt. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema("Optional timeout in milliseconds.")
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.power", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.volumes":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.volumes",
              description:
                "List mounted macOS volumes with non-secret capacity and mount metadata.",
              inputSchema: objectSchema(
                properties: [
                  "include_hidden": boolSchema(
                    "Whether to include hidden volumes. Defaults to false.")
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.volumes", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.processes":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.processes",
              description:
                "Return a bounded read-only macOS process snapshot using fixed /bin/ps argv. This reports executable command names, not full argument strings.",
              inputSchema: objectSchema(
                properties: [
                  "query": stringSchema(
                    "Optional case-insensitive filter over user, state, command, or raw line."),
                  "max_results": integerSchema("Maximum processes to return. Defaults to 200."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.processes", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.which":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.which",
              description:
                "Locate an executable basename on the gateway process PATH without running a shell or invoking the executable. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "name": stringSchema(
                    "Executable basename to find, for example cloudflared, tunnel-client, or codex."
                  ),
                  "all_matches": boolSchema(
                    "Whether to return every executable match on PATH. Defaults to false."),
                ],
                required: ["name"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.which", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "system.path":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "system.path",
              description:
                "Return structured gateway process PATH search directories without exposing other environment values and without running a shell.",
              inputSchema: objectSchema(
                properties: [
                  "include_missing": boolSchema(
                    "Whether to include PATH entries that do not currently exist. Defaults to true."
                  ),
                  "max_entries": integerSchema(
                    "Maximum entries to return. Defaults to 200; max 1000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "system.path", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "logs.query":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "logs.query",
              description:
                "Query a bounded recent window of the macOS unified log using fixed /usr/bin/log show --style ndjson argv. This is read-only but can expose sensitive local activity, so it belongs only in explicitly trusted profiles. It never starts a live stream or invokes a shell.",
              inputSchema: objectSchema(
                properties: [
                  "last_seconds": integerSchema(
                    "Required recent time window in seconds, from 1 through 604800."),
                  "max_entries": integerSchema(
                    "Required maximum captured log lines to return, from 1 through 10000."),
                  "predicate": stringSchema(
                    "Optional NSPredicate expression passed as one argv value to log show --predicate; max 4096 UTF-8 bytes."
                  ),
                  "include_info": boolSchema(
                    "Whether to include Info events. Defaults to false."),
                  "include_debug": boolSchema(
                    "Whether to include Debug events. Defaults to false."),
                  "timeout_ms": integerSchema(
                    "Optional execution timeout in milliseconds. Defaults to 30000."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                  ),
                ],
                required: ["last_seconds", "max_entries"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "logs.query", risk: .readOnly,
              workspaceRequirement: .optional,
              localOnly: false, usesNetwork: false
            )
          ))

      case "service.status":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "service.status",
              description:
                "Inspect one macOS launchd service with fixed /bin/launchctl print argv. The domain and label are explicit; user/gui domains are restricted to the current gateway uid. This returns an allowlisted status summary and never returns launchd environment blocks, raw output, or mutation controls.",
              inputSchema: objectSchema(
                properties: [
                  "domain": stringSchema(
                    "Required launchd domain: system, user, or gui. user/gui use the current gateway uid."
                  ),
                  "label": stringSchema(
                    "Required launch service label containing only letters, digits, dot, underscore, or hyphen."
                  ),
                  "timeout_ms": integerSchema(
                    "Optional execution timeout in milliseconds. Defaults to 10000."),
                  "max_output_bytes": integerSchema(
                    "Maximum captured stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                  ),
                ],
                required: ["domain", "label"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "service.status", risk: .readOnly,
              workspaceRequirement: .optional,
              localOnly: false, usesNetwork: false
            )
          ))

      case "network.interfaces":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.interfaces",
              description:
                "Return raw macOS network interface status using /sbin/ifconfig. This is read-only and runs fixed argv only.",
              inputSchema: objectSchema(
                properties: [
                  "interface": stringSchema(
                    "Optional interface name such as en0 or lo0. Omit to run ifconfig -a."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.interfaces", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.dns":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.dns",
              description:
                "Return raw macOS DNS resolver configuration using /usr/sbin/scutil --dns. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema("Optional timeout in milliseconds.")
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.dns", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.resolve":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.resolve",
              description:
                "Resolve a hostname or IP address through the system resolver using getaddrinfo. This is read-only and does not run shell commands.",
              inputSchema: objectSchema(
                properties: [
                  "host": stringSchema("Hostname or IP address to resolve."),
                  "family": stringSchema(
                    "Address family: any, all, ipv4, inet, ipv6, or inet6. Defaults to any."),
                  "max_results": integerSchema("Maximum addresses to return. Defaults to 50."),
                ],
                required: ["host"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.resolve", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.proxy":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.proxy",
              description:
                "Return raw macOS network proxy settings using /usr/sbin/scutil --proxy. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema("Optional timeout in milliseconds.")
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.proxy", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.services":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.services",
              description:
                "Return the raw macOS network service list using fixed /usr/sbin/networksetup -listallnetworkservices argv. This is read-only and does not make outbound network requests.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.services", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.hardware_ports":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.hardware_ports",
              description:
                "Return the raw macOS network hardware port list using fixed /usr/sbin/networksetup -listallhardwareports argv. This is read-only and may reveal local network hardware identifiers.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.hardware_ports", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.wifi":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.wifi",
              description:
                "Return read-only current macOS Wi-Fi interface status using fixed /usr/sbin/networksetup argv. The gateway discovers or accepts a Wi-Fi device, then queries power and current network association. This does not scan nearby networks, join networks, change settings, make outbound network requests, or expose full hardware-port raw output.",
              inputSchema: objectSchema(
                properties: [
                  "device": stringSchema(
                    "Optional network interface device such as en0. Omit to discover the first Wi-Fi/AirPort hardware port."
                  ),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.wifi", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.vpn":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.vpn",
              description:
                "Return read-only macOS Network Connection/VPN service list using fixed /usr/sbin/scutil --nc list argv. The gateway parses enabled state, connection status, service id, name, protocol, and type. This does not start, stop, select, trigger, enable, disable, or show detailed VPN configuration.",
              inputSchema: objectSchema(
                properties: [
                  "max_results": integerSchema("Maximum services to return. Defaults to 100."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.vpn", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.locations":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.locations",
              description:
                "Return the raw current and configured macOS network locations using fixed /usr/sbin/networksetup -getcurrentlocation and -listlocations argv. This is read-only and does not make outbound network requests.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.locations", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.routes":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.routes",
              description:
                "Return the raw macOS routing table using fixed /usr/sbin/netstat -rn argv. This is read-only and does not make outbound network requests.",
              inputSchema: objectSchema(
                properties: [
                  "family": stringSchema("Address family: all, inet, or inet6. Defaults to all."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.routes", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.connections":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.connections",
              description:
                "Return the raw local network connection table using fixed /usr/sbin/netstat -an argv. This is read-only and may reveal local and remote endpoints.",
              inputSchema: objectSchema(
                properties: [
                  "family": stringSchema("Address family: all, inet, or inet6. Defaults to all."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.connections", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.arp":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.arp",
              description:
                "Return the raw local IPv4 ARP neighbor cache using fixed /usr/sbin/arp -an argv. This is read-only and may reveal local network devices.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.arp", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.ping":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.ping",
              description:
                "Run a bounded ICMP ping to a hostname or IP address using fixed /sbin/ping -c argv. This performs network I/O.",
              inputSchema: objectSchema(
                properties: [
                  "host": stringSchema("Hostname or IP address to ping. URLs are rejected."),
                  "count": integerSchema("Number of echo requests. Defaults to 3; max 10."),
                  "timeout_ms": integerSchema(
                    "Process timeout in milliseconds. Defaults to 30000."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ],
                required: ["host"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.ping", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.tcp_check":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.tcp_check",
              description:
                "Check TCP connectivity to a host and port using fixed /usr/bin/nc -G <seconds> -zv argv. This performs network I/O.",
              inputSchema: objectSchema(
                properties: [
                  "host": stringSchema("Hostname or IP address to connect to. URLs are rejected."),
                  "port": integerSchema("TCP port number, 1 through 65535."),
                  "connect_timeout_seconds": integerSchema(
                    "nc connection timeout in seconds. Defaults to 5; max 60."),
                  "timeout_ms": integerSchema(
                    "Process timeout in milliseconds. Defaults to 30000."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ],
                required: ["host", "port"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.tcp_check", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.http_check":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.http_check",
              description:
                "Check an absolute HTTP or HTTPS URL using fixed /usr/bin/curl argv. This performs bounded network I/O, supports HEAD or GET, returns curl metadata such as HTTP status and effective URL, and optionally returns a bounded GET body prefix. It does not send custom headers, request bodies, cookies, or shell commands.",
              inputSchema: objectSchema(
                properties: [
                  "url": stringSchema("Absolute http or https URL to check."),
                  "method": stringSchema("HTTP method: HEAD or GET. Defaults to HEAD."),
                  "include_body": boolSchema(
                    "Whether to include a bounded GET response body prefix. Defaults to false and is ignored for HEAD."
                  ),
                  "follow_redirects": boolSchema(
                    "Whether curl should follow redirects. Defaults to false."),
                  "max_redirects": integerSchema(
                    "Maximum redirects when following. Defaults to 5."),
                  "connect_timeout_seconds": integerSchema(
                    "Connection timeout in seconds. Defaults to 5; max 60."),
                  "timeout_ms": integerSchema(
                    "Process timeout in milliseconds. Defaults to 30000."),
                  "max_body_bytes": integerSchema(
                    "Maximum GET body bytes to return when include_body is true. Defaults to 4096."
                  ),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to max_body_bytes plus metadata allowance."
                  ),
                ],
                required: ["url"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.http_check", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "network.listeners":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "network.listeners",
              description:
                "Return raw local TCP listening sockets using fixed /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN argv. This is read-only but may reveal local process names and ports.",
              inputSchema: objectSchema(
                properties: [
                  "timeout_ms": integerSchema(
                    "Optional timeout in milliseconds. Defaults to 10000."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "network.listeners", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: true
            )
          ))

      case "macos.user_directories":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "macos.user_directories",
              description:
                "Return a fixed read-only catalog of common macOS user and application directories such as Home, Desktop, Documents, Downloads, Movies, Music, Pictures, user Library, user Applications, /Applications, /System/Applications, and the current process temporary directory. This reports existence and filesystem metadata only; it does not list directory contents, read files, open Finder, or run shell commands.",
              inputSchema: objectSchema(
                properties: [
                  "include_missing": boolSchema(
                    "Whether to include catalog entries that do not exist on disk. Defaults to true."
                  ),
                  "include_system": boolSchema(
                    "Whether to include system-wide application directories. Defaults to true."
                  ),
                  "include_temporary": boolSchema(
                    "Whether to include the current process temporary directory. Defaults to true."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "macos.user_directories", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "macos.default_application":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "macos.default_application",
              description:
                "Return the default macOS application, and optionally candidate applications, that LaunchServices would use for a workspace-contained file path or an http, https, or mailto URL. This is read-only and does not open the file, launch an application, make network requests, or inspect UI content.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Existing workspace-relative or workspace-contained absolute file/directory path to query."
                  ),
                  "url": stringSchema(
                    "Absolute http, https, or mailto URL to query without opening."),
                  "include_candidates": boolSchema(
                    "Whether to include candidate applications returned by LaunchServices. Defaults to false."
                  ),
                  "max_candidates": integerSchema(
                    "Maximum candidate applications to return. Defaults to 20."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "macos.default_application", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "macos.applications":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "macos.applications",
              description:
                "List installed macOS application bundles from standard Applications directories.",
              inputSchema: objectSchema(
                properties: [
                  "include_system": boolSchema(
                    "Whether to include /Applications and /System/Applications. Defaults to true."),
                  "include_user": boolSchema(
                    "Whether to include ~/Applications. Defaults to true."),
                  "max_results": integerSchema("Optional application cap. Defaults to 500."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 3."),
                  "max_visited": integerSchema(
                    "Optional visited-entry cap. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "macos.applications", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "macos.screens":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "macos.screens",
              description:
                "List attached macOS screens with frame, visible frame, scale, and color-space metadata. This is read-only.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "macos.screens", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "macos.spotlight_search":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "macos.spotlight_search",
              description:
                "Search the macOS Spotlight index under a workspace-contained directory using fixed /usr/bin/mdfind -onlyin argv. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative directory path to constrain mdfind. Defaults to workspace root."
                  ),
                  "query": stringSchema("Raw Spotlight query string passed to mdfind."),
                  "max_results": integerSchema(
                    "Maximum contained results to return. Defaults to 100."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum raw stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                  ),
                ],
                required: ["query"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "macos.spotlight_search", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "macos.running_applications":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "macos.running_applications",
              description:
                "List running macOS applications visible to the current user session. This is read-only and does not inspect windows or UI content.",
              inputSchema: objectSchema(
                properties: [
                  "include_background": boolSchema(
                    "Whether to include accessory/background apps. Defaults to false."),
                  "query": stringSchema(
                    "Optional string matched against app name, bundle id, bundle path, or executable path."
                  ),
                  "match": stringSchema(
                    "contains, prefix, suffix, or exact. Defaults to contains."),
                  "case_sensitive": boolSchema("Whether query matching is case-sensitive."),
                  "max_results": integerSchema("Optional result cap. Defaults to 200."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "macos.running_applications", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "macos.frontmost_application":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "macos.frontmost_application",
              description:
                "Return the current frontmost macOS application visible to the user session. This is read-only.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "macos.frontmost_application", risk: .readOnly,
              workspaceRequirement: .none,
              localOnly: false, usesNetwork: false
            )
          ))

      case "env.describe":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "env.describe",
              description:
                "Describe only environment variable names declared by gateway config and whether they are present. Values are always redacted.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "env.describe", risk: .readOnly,
              workspaceRequirement: .optional,
              localOnly: false, usesNetwork: false
            )
          ))

      default:
        continue
      }
    }

    return definitions.map { definition in
      let tool = definition.tool
      guard tool.annotations == nil else { return definition }
      return ToolDefinition(
        tool: tool.withAnnotations(toolAnnotations(for: tool.name, builtins: builtins)),
        capability: definition.capability)
    }
  }

  private static func toolAnnotations(
    for name: String,
    builtins: Set<String>
  ) -> MCPToolAnnotations {
    if builtins.contains(name) {
      let openWorld = name.hasPrefix("network.")
      return MCPToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: openWorld
      )
    }

    switch name {
    case "mcp.servers.list", "mcp.servers.status", "mcp.tools.list", "mcp.tools.describe",
      "mcp.tools.find", "mcp.resources.list", "mcp.resources.templates.list",
      "mcp.resources.read", "mcp.prompts.list", "mcp.prompts.get", "mcp.events.read",
      "mcp.requests.list", "mcp.requests.read":
      return MCPToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: name.hasPrefix("mcp.")
      )

    default:
      return MCPToolAnnotations(
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      )
    }
  }

  private static func objectSchema(
    properties: [String: JSONValue] = [:],
    required: [String] = []
  ) -> JSONValue {
    var object: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
      object["required"] = .array(required.map { .string($0) })
    }
    return .object(object)
  }

  private static func stringSchema(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
  }

  private static func integerSchema(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
  }

  private static func boolSchema(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
  }

  private static func stringArraySchema(_ description: String) -> JSONValue {
    .object([
      "type": .string("array"),
      "items": .object(["type": .string("string")]),
      "description": .string(description),
    ])
  }
}
