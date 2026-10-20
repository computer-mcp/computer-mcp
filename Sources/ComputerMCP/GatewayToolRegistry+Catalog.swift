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
      case "workspace.info":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.info",
              description:
                "Return a non-secret summary of the configured gateway workspace, policy, and providers.",
              inputSchema: objectSchema(),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.info", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.status":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.status",
              description:
                "Return read-only workspace root status, bounded top-level entry counts, and local VCS marker presence without reading file contents.",
              inputSchema: objectSchema(
                properties: [
                  "include_hidden": boolSchema("Whether to include hidden top-level entries."),
                  "max_entries": integerSchema(
                    "Maximum top-level entries to scan before truncating. Defaults to 5000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.status", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.manifests":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.manifests",
              description:
                "Return existence/type metadata for a fixed catalog of common workspace manifest and config markers without reading file contents or inferring project type.",
              inputSchema: objectSchema(
                properties: [
                  "include_missing": boolSchema(
                    "Whether to include catalog entries that do not exist. Defaults to false."),
                  "max_results": integerSchema(
                    "Maximum catalog entries to return before truncating. Defaults to the catalog size."
                  ),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.manifests", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.recent_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.recent_files",
              description:
                "Return a bounded list of recently modified regular files under the configured workspace using filesystem metadata only. This does not read file contents, run Git, or infer project semantics.",
              inputSchema: objectSchema(
                properties: [
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_results": integerSchema(
                    "Maximum recent files to return after sorting. Defaults to 25."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.recent_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.directory_stats":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.directory_stats",
              description:
                "Return bounded directory-level shape statistics grouped by the first child under a workspace-contained path. Counts files, directories, symlinks, bytes, and common workspace file categories using metadata only. This does not read file contents, infer architecture, or run tools.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative directory path. Defaults to workspace root."),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth per group. Defaults to 4."),
                  "max_results": integerSchema(
                    "Maximum directory groups to return after sorting. Defaults to 100."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.directory_stats", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.artifact_directories":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.artifact_directories",
              description:
                "Return a bounded metadata-only list of common generated, build output, cache, dependency install, coverage, and temporary directories under a workspace-contained path. This does not read contents, run cleanup commands, or delete anything.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative directory path. Defaults to workspace root."),
                  "include_hidden": boolSchema(
                    "Whether to include hidden artifact/cache directories such as .build and .cache. Defaults to true."
                  ),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum directories to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.artifact_directories", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.empty_directories":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.empty_directories",
              description:
                "Return a bounded list of actually empty directories under a workspace-contained path using filesystem metadata only. This does not delete directories, run cleanup commands, or treat directories containing hidden entries as empty.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative directory path. Defaults to workspace root."),
                  "include_hidden": boolSchema(
                    "Whether to include hidden directories in traversal/results. Defaults to false."
                  ),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum empty directories to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.empty_directories", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.git_changes":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.git_changes",
              description:
                "Return structured workspace-relative Git working tree change entries using fixed git status porcelain output through the registered git CLI provider. This does not read file contents, run diff, or infer tasks.",
              inputSchema: objectSchema(
                properties: [
                  "paths": stringArraySchema(
                    "Optional literal workspace-relative paths passed after --."),
                  "max_results": integerSchema(
                    "Maximum change entries to return after parsing. Defaults to 200."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.git_changes", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.file_types":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.file_types",
              description:
                "Return a bounded extension histogram for regular files under the configured workspace using filesystem metadata only. This does not read file contents or infer project semantics.",
              inputSchema: objectSchema(
                properties: [
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_groups": integerSchema(
                    "Maximum extension groups to return after sorting. Defaults to 50."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.file_types", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.large_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.large_files",
              description:
                "Return a bounded list of largest regular files under the configured workspace using filesystem metadata only. This does not read file contents, delete files, or run cleanup commands.",
              inputSchema: objectSchema(
                properties: [
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_results": integerSchema(
                    "Maximum files to return after sorting by size. Defaults to 25."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.large_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.symlinks":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.symlinks",
              description:
                "Return a bounded list of symbolic links under the configured workspace, including raw destinations and target containment metadata. This does not read target contents or follow links for execution.",
              inputSchema: objectSchema(
                properties: [
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_results": integerSchema(
                    "Maximum symlinks to return after sorting by workspace path. Defaults to 100."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.symlinks", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.executable_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.executable_files",
              description:
                "Return a bounded list of executable regular files under the configured workspace using filesystem metadata only. This does not read file contents, infer script language, or execute files.",
              inputSchema: objectSchema(
                properties: [
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_results": integerSchema(
                    "Maximum executable files to return after sorting by workspace path. Defaults to 100."
                  ),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.executable_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.todos":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.todos",
              description:
                "Search the configured workspace for common TODO-style marker tokens using bounded UTF-8 file reads. This returns mechanical line matches and does not summarize, infer priority, or execute commands.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "markers": stringArraySchema(
                    "Optional literal marker tokens to search for. Defaults to TODO, FIXME, HACK, and XXX."
                  ),
                  "case_sensitive": boolSchema(
                    "Whether marker matching is case-sensitive. Defaults to false."),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_files": integerSchema("Optional scanned file cap. Defaults to 500."),
                  "max_matches": integerSchema("Optional match cap. Defaults to 100."),
                  "max_bytes_per_file": integerSchema(
                    "Optional per-file read cap in bytes. Defaults to 1048576."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.todos", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.env_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.env_files",
              description:
                "Find workspace env files such as .env and .env.local and return only variable key metadata. Values are always redacted and never returned.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden_directories": boolSchema(
                    "Whether to recurse into hidden directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
                  "max_files": integerSchema("Optional env file cap. Defaults to 100."),
                  "max_keys_per_file": integerSchema(
                    "Optional key cap per env file. Defaults to 200."),
                  "max_bytes_per_file": integerSchema(
                    "Optional per-file read cap in bytes. Defaults to 262144."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.env_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.dependency_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.dependency_files",
              description:
                "Find common package manifest, dependency, lock, and checksum files under the workspace using filename metadata only. This does not read file contents, parse dependencies, or run package managers.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.dependency_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.project_roots":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.project_roots",
              description:
                "Group common dependency manifest, lock, requirements, and checksum files by containing directory to find candidate project roots using filename metadata only. This does not read manifests, infer build graphs, or run package managers.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
                  "max_results": integerSchema(
                    "Maximum candidate project roots to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.project_roots", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.documentation_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.documentation_files",
              description:
                "Find README, AGENTS, CONTRIBUTING, SECURITY, SUPPORT, changelog, license, and docs-directory documentation files under the workspace using filename metadata only. This does not read contents, summarize documents, or infer policy.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.documentation_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.agent_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.agent_files",
              description:
                "Find workspace agent instruction and skill entrypoint files such as AGENTS.md, CLAUDE.md, GEMINI.md, .github/copilot-instructions.md, Cursor/Windsurf rules, and skills/*/SKILL.md using path metadata only. This does not read instruction contents; use each row's file.read context to inspect selected files through the gateway.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to true because many agent instruction files live under hidden config directories."
                  ),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 100."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.agent_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.instructions":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.instructions",
              description:
                "Return the bounded agent instruction files that apply to a target workspace path by walking from the workspace root to that path's scope directory. This reads only fixed instruction filenames and rule directories, does not summarize or merge instructions, and returns apply_order for the MCP consumer.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root. The path may be a future file that does not exist yet."
                  ),
                  "path_is_directory": boolSchema(
                    "Whether to treat path as a directory. Defaults to filesystem metadata when the path exists, otherwise false unless path ends with '/'."
                  ),
                  "include_content": boolSchema(
                    "Whether to include bounded UTF-8 instruction content. Defaults to true."),
                  "max_bytes_per_file": integerSchema(
                    "Maximum instruction bytes to read per file. Defaults to 65536."),
                  "max_results": integerSchema(
                    "Maximum instruction files to return. Defaults to 50."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.instructions", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.test_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.test_files",
              description:
                "Find likely test/spec files under the workspace using path and filename metadata only. This does not read file contents, infer test frameworks, or run tests.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.test_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.ci_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.ci_files",
              description:
                "Find common CI/CD and hosted build pipeline configuration files under the workspace using path and filename metadata only. This does not read YAML or JSON contents, infer pipeline semantics, or run automation.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to true because many CI configs live under hidden config directories."
                  ),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.ci_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.infra_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.infra_files",
              description:
                "Find likely infrastructure, deployment, container, orchestration, and platform configuration files such as Dockerfile, docker-compose, devcontainer, Kubernetes manifests, Helm charts, Terraform, Packer, Nomad, Pulumi, Serverless, Cloudflare Wrangler, Vercel, Netlify, Fly, Render, Railway, and Procfile using filename, extension, and infra-directory metadata only. This does not read config contents, parse IaC, infer topology, validate manifests, or run deployment tools; use returned context objects for explicit follow-up inspection through the gateway.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false, but .devcontainer is scanned because it is a common infra directory."
                  ),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.infra_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.config_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.config_files",
              description:
                "Find common editor, formatter, linter, toolchain, and build-tool configuration files under the workspace using path and filename metadata only. This does not read config contents, infer rules, or run tools.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to true because many config files are dotfiles."
                  ),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.config_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.ignore_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.ignore_files",
              description:
                "Find common ignore-rule files such as .gitignore, .dockerignore, .rgignore, .prettierignore, deployment ignore files, and agent context ignore files using path metadata only. This does not parse ignore rules, decide whether a path is ignored, or read file contents; use each row's file.read context to inspect selected files through the gateway.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to true because ignore files are usually dotfiles."
                  ),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.ignore_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.asset_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.asset_files",
              description:
                "Find common project asset files such as images, icons, fonts, audio, video, PDFs, presentations, and design-source files under the workspace using extension and path metadata only. This does not read asset contents, generate previews, inspect dimensions, or infer usage.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 500."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.asset_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.archive_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.archive_files",
              description:
                "Find common archive, compressed stream, installer, disk image, and application package files under the workspace using extension and path metadata only. This does not list archive entries, extract files, inspect package manifests, or read contents; use returned archive.list context for supported formats.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 500."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.archive_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.log_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.log_files",
              description:
                "Find likely log, process output, trace, and crash-report files under the workspace using filename, extension, and logs-directory metadata only. This does not read log contents, infer severity, summarize events, or follow live streams; use returned file.tail or file.search context for explicit follow-up inspection.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 500."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.log_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.data_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.data_files",
              description:
                "Find common data artifacts such as CSV, TSV, JSONL, SQLite, DuckDB, Parquet, Arrow, Avro, ORC, Excel, and structured files in data-like directories using path and extension metadata only. This does not read data contents, infer schemas, count rows, sample values, or inspect databases; use returned context objects for explicit follow-up inspection through the gateway.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 500."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.data_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.schema_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.schema_files",
              description:
                "Find likely API, interface, data, and database schema/contract files such as OpenAPI, Swagger, AsyncAPI, GraphQL, Protocol Buffers, JSON Schema, Avro schema, Prisma, WSDL, XSD, Thrift, FlatBuffers, and SQL migrations using filename, extension, and schema-directory metadata only. This does not read schema contents, validate contracts, infer models, or inspect databases; use returned context objects for explicit follow-up inspection through the gateway.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 500."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.schema_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.source_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.source_files",
              description:
                "Find likely source, script, component, markup, style, header, and query files under the workspace using file extension and path metadata only. This does not read source contents, infer architecture, or run tools. Tests are excluded by default; use include_tests when needed.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "include_tests": boolSchema(
                    "Whether to include files that also match workspace.test_files. Defaults to false."
                  ),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema(
                    "Maximum matching files to return after sorting. Defaults to 500."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.source_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.outline":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.outline",
              description:
                "Return a bounded mechanical outline across outline-capable workspace files by extracting Markdown headings and common source declarations. This does not summarize, infer architecture, build a semantic graph, or run tools.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative directory or file path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "include_tests": boolSchema("Whether to include test files. Defaults to false."),
                  "include_imports": boolSchema(
                    "Whether to include import/use/require statements. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_files": integerSchema(
                    "Maximum outline-capable files to read. Defaults to 200."),
                  "max_items": integerSchema(
                    "Maximum outline items to return across files. Defaults to 1000."),
                  "max_bytes_per_file": integerSchema(
                    "Maximum bytes to scan per file. Defaults to 262144."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.outline", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.commands":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.commands",
              description:
                "Find deterministic project command entrypoints from common workspace manifests such as package.json scripts, Makefile targets, Justfile recipes, and standard SwiftPM/Cargo/Go commands. This reads only bounded manifest bytes, does not execute commands, and returns cli.exec context plus whether the suggested CLI provider is registered.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files and directories. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 4."),
                  "max_results": integerSchema(
                    "Maximum command entries to return after sorting. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
                  "max_bytes_per_file": integerSchema(
                    "Maximum manifest bytes to read per file. Defaults to 262144."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.commands", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

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

      case "file.exists":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.exists",
              description:
                "Check whether a workspace-contained path exists without treating absence as an error.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path.")
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.exists", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.list":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.list",
              description:
                "List entries under a workspace-contained directory with deterministic ordering and bounded output.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative or in-workspace absolute directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
                  "recursive_depth": integerSchema(
                    "Optional recursive depth. Defaults to 0 for direct children only."),
                  "max_entries": integerSchema("Optional entry cap. Defaults to 200."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.list", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.tree":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.tree",
              description:
                "Return a bounded hierarchical tree for a workspace-contained directory. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative or in-workspace absolute directory path. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema(
                    "Whether to include hidden files. Defaults to false."),
                  "max_depth": integerSchema("Maximum child depth to traverse. Defaults to 2."),
                  "max_entries": integerSchema("Maximum tree nodes to return. Defaults to 500."),
                  "directories_only": boolSchema(
                    "Whether to include only directories. Defaults to false."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.tree", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.stat":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.stat",
              description:
                "Return file metadata for a workspace-contained path without reading file content.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path.")
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.stat", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.permissions":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.permissions",
              description:
                "Return POSIX mode, owner/group, current-process access, and common macOS file flags for a workspace-contained path. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path.")
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.permissions", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.chmod":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.chmod",
              description:
                "Set the POSIX mode for a workspace-contained path without invoking chmod. This is non-recursive.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                  "mode": stringSchema(
                    "3- or 4-digit octal POSIX mode, for example 0644 or 0755."),
                  "expected_current_mode": stringSchema(
                    "Optional 3- or 4-digit octal mode assertion before changing permissions."),
                  "dry_run": boolSchema(
                    "Whether to validate the mode change without changing permissions. Defaults to false."
                  ),
                ],
                required: ["path", "mode"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.chmod", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.type":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.type",
              description:
                "Return MIME type and charset for a workspace-contained file using fixed /usr/bin/file -b --mime argv. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.type", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.count":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.count",
              description:
                "Return line, word, and byte counts for a workspace-contained file using fixed /usr/bin/wc -l -w -c argv. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.count", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.disk_usage":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.disk_usage",
              description:
                "Return disk usage for a workspace-contained file or directory using fixed /usr/bin/du -sk argv. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.disk_usage", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.volume_info":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.volume_info",
              description:
                "Return the mounted volume and filesystem capability metadata for a workspace-contained path using Foundation URL resource values. This is read-only and does not run shell commands.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative or in-workspace absolute path. Defaults to workspace root."
                  )
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.volume_info", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.find":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.find",
              description:
                "Find workspace-contained paths by file or directory name using bounded deterministic traversal.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative directory path. Defaults to workspace root."),
                  "query": stringSchema("Name query to match."),
                  "match": stringSchema("Match mode: contains, prefix, suffix, or exact."),
                  "case_sensitive": boolSchema("Whether name matching is case-sensitive."),
                  "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema("Optional result cap. Defaults to 200."),
                  "max_visited": integerSchema("Optional visited-entry cap. Defaults to 20000."),
                ],
                required: ["query"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.find", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.search":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.search",
              description:
                "Search UTF-8 text content under a workspace-contained path with bounded files, bytes, and matches.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative file or directory path. Defaults to workspace root."
                  ),
                  "query": stringSchema("Text query to search for."),
                  "case_sensitive": boolSchema("Whether text matching is case-sensitive."),
                  "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_files": integerSchema("Optional scanned file cap. Defaults to 500."),
                  "max_matches": integerSchema("Optional match cap. Defaults to 100."),
                  "max_bytes_per_file": integerSchema(
                    "Optional per-file read cap in bytes. Defaults to 1048576."),
                ],
                required: ["query"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.search", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.timeline":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.timeline",
              description:
                "List regular files under a workspace-contained directory by modification time with optional ISO8601 modified_after/modified_before filters. This is read-only, uses filesystem metadata only, and does not infer recency semantics.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative directory path. Defaults to workspace root."),
                  "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
                  "modified_after": stringSchema(
                    "Optional inclusive ISO8601 lower modification-time bound, such as 2026-07-09T00:00:00Z."
                  ),
                  "modified_before": stringSchema(
                    "Optional inclusive ISO8601 upper modification-time bound, such as 2026-07-10T00:00:00Z."
                  ),
                  "sort": stringSchema(
                    "Sort order: modified_desc, modified_asc, or path. Defaults to modified_desc."),
                  "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                  "max_results": integerSchema("Optional result cap. Defaults to 200."),
                  "max_scan_entries": integerSchema(
                    "Optional scanned-entry cap. Defaults to 20000."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.timeline", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.read":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.read",
              description: "Read a UTF-8 file under the configured workspace directory.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "max_bytes": integerSchema("Optional maximum bytes to return."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.read", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.read_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.read_files",
              description:
                "Read multiple explicitly named workspace-contained files in one call. This is read-only, supports uniform utf8 or base64 output, and does not search, infer, or follow references.",
              inputSchema: objectSchema(
                properties: [
                  "paths": stringArraySchema(
                    "Workspace-relative or in-workspace absolute file paths. Must contain 1 to 50 values."
                  ),
                  "max_bytes_per_file": integerSchema(
                    "Maximum bytes to read per file. Defaults to policy.max_output_bytes."),
                  "encoding": stringSchema("utf8 or base64. Defaults to utf8."),
                ],
                required: ["paths"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.read_files", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.read_window":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.read_window",
              description:
                "Read a UTF-8 text byte window from a workspace-contained file using offset_bytes and max_bytes. This is read-only and reports whether the selected byte window is valid UTF-8.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "offset_bytes": integerSchema(
                    "Zero-based byte offset where reading starts. Defaults to 0."),
                  "max_bytes": integerSchema(
                    "Maximum bytes to read from the offset. Defaults to policy.max_output_bytes."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.read_window", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.read_lines":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.read_lines",
              description:
                "Read a bounded UTF-8 line range from a workspace-contained file.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "start_line": integerSchema("One-based starting line. Defaults to 1."),
                  "max_lines": integerSchema("Maximum lines to return. Defaults to 200."),
                  "max_bytes": integerSchema(
                    "Maximum bytes to scan from the start of the file."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.read_lines", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.read_context":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.read_context",
              description:
                "Read bounded UTF-8 line context around a one-based target line in a workspace-contained file.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "line": integerSchema("One-based target line number."),
                  "before": integerSchema("Number of lines before the target line. Defaults to 5."),
                  "after": integerSchema("Number of lines after the target line. Defaults to 5."),
                  "max_bytes": integerSchema(
                    "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
                  ),
                ],
                required: ["path", "line"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.read_context", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.head":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.head",
              description:
                "Read the first lines from a workspace-contained UTF-8 file using a bounded byte window.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "max_lines": integerSchema("Maximum head lines to return. Defaults to 200."),
                  "max_bytes": integerSchema(
                    "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
                  ),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.head", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.outline":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.outline",
              description:
                "Return a bounded mechanical outline for a workspace-contained UTF-8 file by extracting Markdown headings and common source declaration lines. This does not summarize, infer architecture, or build a semantic graph.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative file path."),
                  "include_imports": boolSchema(
                    "Whether to include import/package/use/mod lines. Defaults to false."),
                  "max_results": integerSchema(
                    "Maximum outline items to return. Defaults to 200."),
                  "max_bytes": integerSchema(
                    "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
                  ),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.outline", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.tail":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.tail",
              description:
                "Read the last lines from a workspace-contained UTF-8 file using a bounded tail window.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "max_lines": integerSchema("Maximum tail lines to return. Defaults to 200."),
                  "max_bytes": integerSchema(
                    "Maximum bytes to scan from the end of the file."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.tail", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.hexdump":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.hexdump",
              description:
                "Read a bounded byte window from a workspace-contained file and return deterministic hex/ascii rows. This is read-only and useful for binary inspection.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "offset_bytes": integerSchema("Starting byte offset. Defaults to 0."),
                  "max_bytes": integerSchema("Maximum bytes to return. Defaults to 256."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.hexdump", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.xattrs":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.xattrs",
              description:
                "List extended attributes for a workspace-contained file or directory, with optional bounded value previews. This is read-only and useful for macOS metadata such as quarantine flags and Finder tags.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                  "include_values": boolSchema(
                    "Whether to include bounded attribute value previews. Defaults to false."),
                  "max_value_bytes": integerSchema(
                    "Maximum attribute value size to read when include_values is true. Larger values are reported as truncated without reading. Defaults to 1024."
                  ),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.xattrs", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.remove_xattr":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.remove_xattr",
              description:
                "Remove one extended attribute from a workspace-contained path using the macOS xattr API. This is non-recursive.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                  "name": stringSchema("Extended attribute name to remove."),
                  "dry_run": boolSchema(
                    "Whether to validate the removal without deleting the extended attribute. Defaults to false."
                  ),
                ],
                required: ["path", "name"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.remove_xattr", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.metadata":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.metadata",
              description:
                "Read Spotlight metadata for a workspace-contained file or directory using fixed /usr/bin/mdls -plist argv. This is read-only and macOS-specific.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                  "attributes": stringArraySchema(
                    "Optional Spotlight metadata attribute names to return after plist parsing."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.metadata", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.readlink":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.readlink",
              description:
                "Read the raw destination of a workspace-contained symbolic link without following the final link. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute symlink path.")
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.readlink", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.resolve":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.resolve",
              description:
                "Resolve a workspace-contained path mechanically, preserving the final symlink for inspection and reporting whether the resolved destination remains in the workspace.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute path.")
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.resolve", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.hash":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.hash",
              description:
                "Compute a SHA-256 hash for a workspace-contained file without returning content.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "algorithm": stringSchema("Hash algorithm. Only sha256 is currently supported."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.hash", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.diff":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.diff",
              description:
                "Return a bounded unified diff between two workspace-contained files using fixed /usr/bin/diff argv. This is read-only.",
              inputSchema: objectSchema(
                properties: [
                  "source": stringSchema(
                    "Workspace-relative or in-workspace absolute source file."),
                  "target": stringSchema(
                    "Workspace-relative or in-workspace absolute target file."),
                  "context_lines": integerSchema("Unified diff context lines. Defaults to 3."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ],
                required: ["source", "target"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.diff", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.compare_trees":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.compare_trees",
              description:
                "Compare two workspace-contained directory trees by relative path using bounded deterministic traversal. Defaults to metadata-only comparison; set compare_hashes=true to SHA-256 compare same-size files within explicit hash limits. This is read-only and does not run shell commands.",
              inputSchema: objectSchema(
                properties: [
                  "left": stringSchema(
                    "Workspace-relative or in-workspace absolute left directory."),
                  "right": stringSchema(
                    "Workspace-relative or in-workspace absolute right directory."),
                  "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
                  "max_depth": integerSchema("Maximum recursive depth. Defaults to 8."),
                  "max_entries": integerSchema(
                    "Maximum entries to scan per tree. Defaults to 20000."),
                  "max_results": integerSchema(
                    "Maximum difference rows to return. Defaults to 200."),
                  "compare_hashes": boolSchema(
                    "Whether to SHA-256 compare same-size files within hash limits. Defaults to false."
                  ),
                  "max_hash_files": integerSchema(
                    "Maximum files to hash when compare_hashes is true. Defaults to 1000."),
                  "max_hash_file_bytes": integerSchema(
                    "Maximum bytes per file eligible for hashing. Defaults to 10485760."),
                ],
                required: ["left", "right"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.compare_trees", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.duplicates":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.duplicates",
              description:
                "Find duplicate regular files under a workspace-contained directory by size bucket and bounded SHA-256 hashing. This is read-only, skips symlinks, does not delete files, and returns deterministic duplicate groups plus follow-up contexts.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Workspace-relative or in-workspace absolute directory. Defaults to workspace root."
                  ),
                  "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
                  "min_size_bytes": integerSchema(
                    "Minimum file size eligible for duplicate detection. Defaults to 1."),
                  "max_depth": integerSchema("Maximum recursive depth. Defaults to 8."),
                  "max_entries": integerSchema(
                    "Maximum filesystem entries to scan. Defaults to 20000."),
                  "max_hash_files": integerSchema(
                    "Maximum candidate files to hash. Defaults to 5000."),
                  "max_hash_file_bytes": integerSchema(
                    "Maximum bytes per file eligible for hashing. Defaults to 10485760."),
                  "max_groups": integerSchema(
                    "Maximum duplicate groups to return. Defaults to 100."),
                  "max_files_per_group": integerSchema(
                    "Maximum files to return per duplicate group. Defaults to 20."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.duplicates", risk: .readOnly,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "archive.list":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "archive.list",
              description:
                "List entries in a workspace-contained zip or tar archive using fixed read-only argv. This does not extract files.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute archive path."),
                  "max_entries": integerSchema("Maximum entries to return. Defaults to 1000."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "archive.list", risk: .readOnly,
              workspaceRequirement: .optional,
              localOnly: false, usesNetwork: false
            )
          ))

      case "archive.read_file":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "archive.read_file",
              description:
                "Read one file member from a workspace-contained zip or tar archive using fixed read-only argv, returning UTF-8 text or base64 bytes. This streams the selected member to stdout without extracting files or writing to disk. Entry paths are normalized and must not be directories, absolute paths, parent escapes, option-like names, or archive wildcard patterns.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute archive path."),
                  "entry": stringSchema("Archive member path to read."),
                  "encoding": stringSchema(
                    "utf8, base64, or auto. Defaults to utf8. Use base64 for binary members."),
                  "max_bytes": integerSchema(
                    "Maximum stdout bytes to capture from the member. Defaults to policy.max_output_bytes."
                  ),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                ],
                required: ["path", "entry"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "archive.read_file", risk: .readOnly,
              workspaceRequirement: .optional,
              localOnly: false, usesNetwork: false
            )
          ))

      case "archive.extract":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "archive.extract",
              description:
                "Extract a workspace-contained zip or tar archive into a workspace-contained destination using fixed argv. This defaults to dry-run, validates entry paths, refuses link entries, and requires confirm_extract=true when dry_run is false.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute archive path."),
                  "destination": stringSchema(
                    "Workspace-relative or in-workspace absolute destination directory."),
                  "create_directories": boolSchema(
                    "Whether to create the destination directory if missing. Defaults to false."),
                  "overwrite": boolSchema(
                    "Whether extraction may overwrite existing destination paths. Defaults to false."
                  ),
                  "dry_run": boolSchema(
                    "Whether to validate and preview extraction without writing files. Defaults to true."
                  ),
                  "confirm_extract": boolSchema(
                    "Required as true when dry_run is false to extract files."),
                  "max_entries": integerSchema(
                    "Maximum archive entries to validate, 1 through 100000. Defaults to 100000."),
                  "max_preview_entries": integerSchema(
                    "Maximum validated entries to return, 0 through 5000. Defaults to 100."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum list/extract stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                  ),
                ],
                required: ["path", "destination"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "archive.extract", risk: .destructive,
              workspaceRequirement: .optional,
              localOnly: false, usesNetwork: false
            )
          ))

      case "archive.create":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "archive.create",
              description:
                "Create a zip or tar archive from explicit workspace-contained sources using fixed argv. This defaults to dry-run, refuses symlink sources/entries, prevents output inside sources, and requires confirm_create=true when dry_run is false.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Workspace-relative or in-workspace absolute output archive path."),
                  "sources": stringArraySchema(
                    "Workspace-relative or in-workspace absolute source files/directories to archive."
                  ),
                  "format": stringSchema(
                    "Optional archive family, zip or tar. When omitted it is inferred from the path suffix."
                  ),
                  "create_directories": boolSchema(
                    "Whether to create the archive parent directory if missing. Defaults to false."),
                  "overwrite": boolSchema(
                    "Whether an existing archive file may be replaced. Defaults to false."),
                  "dry_run": boolSchema(
                    "Whether to validate and preview archive creation without writing files. Defaults to true."
                  ),
                  "confirm_create": boolSchema(
                    "Required as true when dry_run is false to create the archive."),
                  "max_entries": integerSchema(
                    "Maximum source entries to validate, 1 through 100000. Defaults to 100000."),
                  "max_preview_entries": integerSchema(
                    "Maximum source entries to return, 0 through 5000. Defaults to 100."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                  "max_output_bytes": integerSchema(
                    "Maximum create stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                  ),
                ],
                required: ["path", "sources"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "archive.create", risk: .destructive,
              workspaceRequirement: .optional,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.download":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.download",
              description:
                "Download an absolute HTTP or HTTPS URL to a workspace-contained file using fixed /usr/bin/curl argv. This defaults to dry-run, writes through a deterministic temp file, rejects credentials in URLs, sends no custom headers/cookies/request body, and requires confirm_download=true when dry_run is false.",
              inputSchema: objectSchema(
                properties: [
                  "url": stringSchema("Absolute http or https URL to download."),
                  "path": stringSchema(
                    "Workspace-relative or in-workspace absolute destination file path."),
                  "create_directories": boolSchema(
                    "Whether to create the destination parent directory if missing. Defaults to false."
                  ),
                  "overwrite": boolSchema(
                    "Whether an existing destination file may be replaced. Defaults to false."),
                  "dry_run": boolSchema(
                    "Whether to validate and preview download without writing files. Defaults to true."
                  ),
                  "confirm_download": boolSchema(
                    "Required as true when dry_run is false to write the downloaded file."),
                  "follow_redirects": boolSchema(
                    "Whether curl should follow redirects. Defaults to false."),
                  "max_redirects": integerSchema(
                    "Maximum redirects when following. Defaults to 5."),
                  "connect_timeout_seconds": integerSchema(
                    "Connection timeout in seconds. Defaults to 5; max 60."),
                  "timeout_ms": integerSchema(
                    "Process timeout in milliseconds. Defaults to 30000."),
                  "max_download_bytes": integerSchema(
                    "Maximum downloaded file size in bytes. Defaults to 10485760."),
                  "max_output_bytes": integerSchema(
                    "Maximum curl stdout/stderr bytes per stream. Defaults to a small metadata allowance."
                  ),
                ],
                required: ["url", "path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.download", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: true
            )
          ))

      case "file.write":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.write",
              description:
                "Write UTF-8 content to a file under the configured workspace directory.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "content": stringSchema("UTF-8 content to write."),
                  "overwrite": boolSchema(
                    "Whether to overwrite an existing file. Defaults to true."),
                  "create_directories": boolSchema(
                    "Whether to create missing parent directories. Defaults to false."),
                  "dry_run": boolSchema(
                    "Whether to validate the write without creating directories or writing content. Defaults to false."
                  ),
                  "include_preview": boolSchema(
                    "Whether to include a bounded content preview. Defaults to dry_run."),
                  "preview_max_bytes": integerSchema(
                    "Maximum UTF-8 bytes for the content preview. Defaults to 8192."),
                ],
                required: ["path", "content"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.write", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.write_files":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.write_files",
              description:
                "Write multiple explicitly named UTF-8 files under the configured workspace directory. Defaults to dry-run and requires confirm_write=true for real writes.",
              inputSchema: objectSchema(
                properties: [
                  "files": .object([
                    "type": .string("array"),
                    "description": .string(
                      "File entries to write. Each entry must be an object with path and content. Must contain 1 to 50 entries."
                    ),
                    "items": .object([
                      "type": .string("object"),
                      "additionalProperties": .bool(false),
                      "properties": .object([
                        "path": stringSchema(
                          "Workspace-relative or in-workspace absolute file path."),
                        "content": stringSchema("UTF-8 content to write."),
                      ]),
                      "required": .array([.string("path"), .string("content")]),
                    ]),
                  ]),
                  "overwrite": boolSchema(
                    "Whether existing files may be replaced. Defaults to false."),
                  "create_directories": boolSchema(
                    "Whether to create missing parent directories. Defaults to false."),
                  "dry_run": boolSchema(
                    "Whether to validate and preview without writing files. Defaults to true."),
                  "confirm_write": boolSchema(
                    "Required as true when dry_run is false to write files."),
                  "include_preview": boolSchema(
                    "Whether to include bounded content previews. Defaults to dry_run."),
                  "preview_max_bytes": integerSchema(
                    "Maximum UTF-8 bytes per content preview. Defaults to 8192."),
                ],
                required: ["files"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.write_files", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.append":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.append",
              description:
                "Append UTF-8 content to a workspace-contained file without rewriting existing content.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "content": stringSchema("UTF-8 content to append."),
                  "create_if_missing": boolSchema(
                    "Whether to create the file when it is missing. Defaults to true."),
                  "create_directories": boolSchema(
                    "Whether to create missing parent directories. Defaults to false."),
                  "append_newline": boolSchema(
                    "Whether to append a newline after content. Defaults to false."),
                  "dry_run": boolSchema(
                    "Whether to validate the append without creating the file/directories or writing content. Defaults to false."
                  ),
                  "include_preview": boolSchema(
                    "Whether to include a bounded content preview. Defaults to dry_run."),
                  "preview_max_bytes": integerSchema(
                    "Maximum UTF-8 bytes for the content preview. Defaults to 8192."),
                ],
                required: ["path", "content"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.append", risk: .workspaceWrite,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.replace_text":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.replace_text",
              description:
                "Perform exact UTF-8 text replacement in a workspace-contained file without semantic editing.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "search": stringSchema("Non-empty exact text to find."),
                  "replacement": stringSchema("Replacement text. May be empty."),
                  "replace_all": boolSchema(
                    "Whether to replace all non-overlapping matches. Defaults to false."),
                  "expected_replacements": integerSchema(
                    "Optional exact number of replacements that must be performed."),
                  "dry_run": boolSchema(
                    "Whether to validate match counts and preview the replacement without writing. Defaults to false."
                  ),
                  "include_preview": boolSchema(
                    "Whether to include bounded search/replacement text previews. Defaults to dry_run."
                  ),
                  "preview_max_bytes": integerSchema(
                    "Maximum UTF-8 bytes per preview string. Defaults to 8192."),
                  "max_bytes": integerSchema(
                    "Maximum file bytes to read and edit. Defaults to policy.max_output_bytes."),
                ],
                required: ["path", "search", "replacement"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.replace_text", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.insert_text":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.insert_text",
              description:
                "Insert exact UTF-8 text before or after a one-based line in a workspace-contained file.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "line": integerSchema("One-based target line number. Defaults to 1."),
                  "content": stringSchema("UTF-8 text to insert."),
                  "position": stringSchema("before or after. Defaults to before."),
                  "expected_line": stringSchema(
                    "Optional exact target line text assertion before inserting."),
                  "append_newline": boolSchema(
                    "Whether to append a newline to inserted content if missing. Defaults to true."),
                  "dry_run": boolSchema(
                    "Whether to validate and preview the insertion without writing. Defaults to false."
                  ),
                  "include_preview": boolSchema(
                    "Whether to include bounded target-line/inserted-content previews. Defaults to dry_run."
                  ),
                  "preview_max_bytes": integerSchema(
                    "Maximum UTF-8 bytes per preview string. Defaults to 8192."),
                  "max_bytes": integerSchema(
                    "Maximum file bytes to read and edit. Defaults to policy.max_output_bytes."),
                ],
                required: ["path", "content"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.insert_text", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.replace_lines":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.replace_lines",
              description:
                "Replace or delete an exact one-based line range in a workspace-contained UTF-8 file without semantic editing.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "start_line": integerSchema("One-based first line to replace."),
                  "end_line": integerSchema("One-based last line to replace, inclusive."),
                  "content": stringSchema("Replacement UTF-8 text. May be empty to delete lines."),
                  "expected_content": stringSchema(
                    "Optional exact selected-line text assertion before replacing."),
                  "append_newline": boolSchema(
                    "Whether to append a newline to non-empty replacement content if missing. Defaults to true."
                  ),
                  "dry_run": boolSchema(
                    "Whether to validate and preview the replacement without writing. Defaults to false."
                  ),
                  "include_preview": boolSchema(
                    "Whether to include bounded selected/replacement text previews. Defaults to dry_run."
                  ),
                  "preview_max_bytes": integerSchema(
                    "Maximum UTF-8 bytes per preview string. Defaults to 8192."),
                  "max_bytes": integerSchema(
                    "Maximum file bytes to read and edit. Defaults to policy.max_output_bytes."),
                ],
                required: ["path", "start_line", "end_line", "content"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.replace_lines", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.touch":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.touch",
              description:
                "Create an empty workspace-contained file if missing or update an existing file modification time.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                  "create_if_missing": boolSchema(
                    "Whether to create an empty file when the path is missing. Defaults to true."),
                  "create_directories": boolSchema(
                    "Whether to create missing parent directories. Defaults to false."),
                  "dry_run": boolSchema(
                    "Whether to validate the touch without creating the file/directories or updating timestamps. Defaults to false."
                  ),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.touch", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.mkdir":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.mkdir",
              description: "Create a directory under the configured workspace directory.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Workspace-relative or in-workspace absolute directory path."),
                  "intermediate_directories": boolSchema(
                    "Whether to create missing parent directories. Defaults to true."),
                  "dry_run": boolSchema(
                    "Whether to validate directory creation without creating directories. Defaults to false."
                  ),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.mkdir", risk: .workspaceWrite,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.copy":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.copy",
              description:
                "Copy a file or directory between two workspace-contained paths. Does not overwrite unless requested.",
              inputSchema: objectSchema(
                properties: [
                  "source": stringSchema(
                    "Workspace-relative or in-workspace absolute source path."),
                  "destination": stringSchema(
                    "Workspace-relative or in-workspace absolute destination path."),
                  "overwrite": boolSchema(
                    "Whether to overwrite an existing destination. Defaults to false."),
                  "create_directories": boolSchema(
                    "Whether to create missing destination parent directories. Defaults to false."),
                  "dry_run": boolSchema(
                    "Whether to validate the copy without creating directories, overwriting, or copying content. Defaults to false."
                  ),
                ],
                required: ["source", "destination"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.copy", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.move":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.move",
              description:
                "Move or rename a file or directory between two workspace-contained paths. Does not overwrite unless requested.",
              inputSchema: objectSchema(
                properties: [
                  "source": stringSchema(
                    "Workspace-relative or in-workspace absolute source path."),
                  "destination": stringSchema(
                    "Workspace-relative or in-workspace absolute destination path."),
                  "overwrite": boolSchema(
                    "Whether to overwrite an existing destination. Defaults to false."),
                  "create_directories": boolSchema(
                    "Whether to create missing destination parent directories. Defaults to false."),
                  "dry_run": boolSchema(
                    "Whether to validate the move without creating directories, overwriting, moving, or removing the source. Defaults to false."
                  ),
                ],
                required: ["source", "destination"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.move", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.symlink":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.symlink",
              description:
                "Create a symbolic link at a workspace-contained path. By default the destination must resolve inside the workspace.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Workspace-relative or in-workspace absolute path where the symlink will be created."
                  ),
                  "destination": stringSchema(
                    "Raw symlink destination string. Relative destinations are resolved from the link parent for containment checks."
                  ),
                  "overwrite": boolSchema(
                    "Whether to overwrite an existing destination path. Defaults to false."),
                  "create_directories": boolSchema(
                    "Whether to create missing link parent directories. Defaults to false."),
                  "allow_external_destination": boolSchema(
                    "Whether to allow the symlink destination to resolve outside the workspace. Defaults to false."
                  ),
                  "dry_run": boolSchema(
                    "Whether to validate symlink creation without creating directories, overwriting, or creating the link. Defaults to false."
                  ),
                ],
                required: ["path", "destination"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.symlink", risk: .workspaceWrite,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "file.trash":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "file.trash",
              description:
                "Move a workspace-contained file or directory to the macOS Trash. This is a write operation.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Workspace-relative or in-workspace absolute path to trash."),
                  "dry_run": boolSchema(
                    "Whether to validate the trash operation without moving the path to Trash. Defaults to false."
                  ),
                ],
                required: ["path"]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "file.trash", risk: .destructive,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.open":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.open",
              description: "Open the configured workspace or an in-workspace path with macOS open.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative path. Defaults to workspace root."),
                  "application": stringSchema("Optional macOS application name for open -a."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.open", risk: .workspaceWrite,
              workspaceRequirement: .required,
              localOnly: false, usesNetwork: false
            )
          ))

      case "workspace.reveal":
        definitions.append(
          ToolDefinition(
            tool: MCPTool(
              name: "workspace.reveal",
              description: "Reveal a workspace-contained path in Finder using macOS open -R.",
              inputSchema: objectSchema(
                properties: [
                  "path": stringSchema(
                    "Optional workspace-relative path. Defaults to workspace root."),
                  "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                ]
              ),
              meta: toolMeta
            ),
            capability: CapabilityDescriptor(
              id: "workspace.reveal", risk: .workspaceWrite,
              workspaceRequirement: .required,
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

  private static let mutatingBuiltinNames: Set<String> = [
    "archive.create",
    "archive.extract",
    "file.append",
    "file.chmod",
    "file.copy",
    "file.download",
    "file.insert_text",
    "file.mkdir",
    "file.move",
    "file.remove_xattr",
    "file.replace_lines",
    "file.replace_text",
    "file.symlink",
    "file.touch",
    "file.trash",
    "file.write",
    "file.write_files",
    "workspace.open",
    "workspace.reveal",
  ]

  private static let additiveBuiltinNames: Set<String> = [
    "file.append",
    "file.mkdir",
    "file.symlink",
    "workspace.open",
    "workspace.reveal",
  ]

  private static func toolAnnotations(
    for name: String,
    builtins: Set<String>
  ) -> MCPToolAnnotations {
    if builtins.contains(name) {
      let mutating = mutatingBuiltinNames.contains(name)
      let destructive = mutating && !additiveBuiltinNames.contains(name)
      let openWorld = name.hasPrefix("network.") || name == "file.download"
      return MCPToolAnnotations(
        readOnlyHint: !mutating,
        destructiveHint: destructive,
        idempotentHint: mutating ? false : nil,
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

    case "workspace.open":
      return MCPToolAnnotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
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
