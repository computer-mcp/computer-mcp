import ComputerMCPCore

extension CLIToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "cli.list",
          description: "List CLI executables registered in the local gateway configuration.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "cli.list", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "cli.describe",
          description:
            "Describe a registered CLI provider, its mechanical interface, and any declared CLI Tree source.",
          inputSchema: objectSchema(
            properties: ["id": stringSchema("Registered CLI id.")],
            required: ["id"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "cli.describe", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "cli.status",
          description:
            "Report whether registered CLI provider executables can be resolved without invoking their command trees.",
          inputSchema: objectSchema(
            properties: ["id": stringSchema("Optional registered CLI id. Omit to inspect all.")]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "cli.status", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "cli.help",
          description:
            "Return declared metadata for a file-backed CLI Tree path without executing it. For a CLI without a tree, return raw help and follow-up cli.exec context. Executable tree exporters are not run by this read-only tool.",
          inputSchema: objectSchema(
            properties: [
              "id": stringSchema("Registered CLI id."),
              "path": stringArraySchema("Command path before --help."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["id"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "cli.help", risk: .readOnly,
          workspaceRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "cli.exec",
          description:
            "Execute explicit argv for a registered CLI that grants unrestricted arguments. Tree-backed CLIs use their projected typed tools. Keep execution inside this gateway's authorization boundary.",
          inputSchema: objectSchema(
            properties: [
              "id": stringSchema("Registered CLI id."),
              "argv": stringArraySchema("Argument vector passed to the executable."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["id", "argv"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "cli.exec", risk: .fullShell,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
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

  private static func stringArraySchema(_ description: String) -> JSONValue {
    .object([
      "type": .string("array"),
      "items": .object(["type": .string("string")]),
      "description": .string(description),
    ])
  }
}
