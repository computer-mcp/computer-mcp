import ComputerMCPCore

extension MCPToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "mcp.servers.list",
          description: "List downstream MCP servers registered in the local gateway.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: true),
          meta: toolMeta),
        capability: CapabilityDescriptor(
          id: "mcp.requests.read", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: true
        )
      ),
    ]
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
