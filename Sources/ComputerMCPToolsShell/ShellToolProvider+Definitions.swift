import ComputerMCPCore

extension ShellToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "process.spawn",
          description: "Spawn a registered CLI command for long-running work.",
          inputSchema: objectSchema(
            properties: [
              "id": stringSchema("Registered CLI id."),
              "argv": stringArraySchema("Argument vector passed to the executable."),
            ],
            required: ["id", "argv"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "process.spawn", risk: .fullShell,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "process.list",
          description:
            "List gateway-managed process sessions spawned through process.spawn. Does not inspect the OS process table.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "process.list", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "process.read",
          description: "Read buffered stdout/stderr and status for a spawned process.",
          inputSchema: objectSchema(
            properties: ["process_id": stringSchema("Process id returned by process.spawn.")],
            required: ["process_id"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "process.read", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "process.cancel",
          description: "Terminate a spawned process.",
          inputSchema: objectSchema(
            properties: ["process_id": stringSchema("Process id returned by process.spawn.")],
            required: ["process_id"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "process.cancel", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "shell.run",
          description:
            "Run one Full Shell command synchronously through this MCP gateway. Supports shell-script or explicit argv mode, cwd, environment, bounded stdout/stderr, timeout, and process-group cancellation. This grants the caller the effective authority of the current macOS user and is exposed only when the active profile enables Full Shell.",
          inputSchema: shellLaunchSchema(includeTimeout: true, includeStandardInput: true),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "shell.run", risk: .fullShell,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "shell.spawn",
          description:
            "Start a long-lived Full Shell session through this MCP gateway. Continue interacting only through shell.write, shell.read, and shell.cancel using the returned session_id.",
          inputSchema: shellLaunchSchema(includeTimeout: true, includeStandardInput: false),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "shell.spawn", risk: .fullShell,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "shell.list",
          description:
            "List gateway-owned Full Shell sessions and their lifecycle state. This does not inspect unrelated operating-system processes.",
          inputSchema: objectSchema(
            properties: [
              "max_bytes": integerSchema(
                "Optional output bytes per stream. Defaults to 0 for metadata only."
              ),
              "encoding": stringSchema("utf8 or base64. Defaults to utf8."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        // Shell output can contain secrets, so reading sessions needs shell authority.
        capability: CapabilityDescriptor(
          id: "shell.list", risk: .fullShell,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "shell.read",
          description:
            "Read incremental stdout and stderr from a gateway-owned Full Shell session using absolute byte cursors. Use returned next_cursor values for the next MCP call.",
          inputSchema: objectSchema(
            properties: [
              "session_id": stringSchema("Session id returned by shell.spawn."),
              "stdout_cursor": integerSchema("Absolute stdout byte cursor. Defaults to 0."),
              "stderr_cursor": integerSchema("Absolute stderr byte cursor. Defaults to 0."),
              "max_bytes": integerSchema(
                "Maximum bytes returned per stream. Defaults to policy.max_output_bytes."
              ),
              "encoding": stringSchema("utf8 or base64. Defaults to utf8."),
            ],
            required: ["session_id"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        // Shell output can contain secrets, so reading sessions needs shell authority.
        capability: CapabilityDescriptor(
          id: "shell.read", risk: .fullShell,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "shell.write",
          description:
            "Write UTF-8 text or Base64 bytes to a gateway-owned Full Shell session stdin and optionally close stdin. All interaction remains inside this MCP gateway.",
          inputSchema: objectSchema(
            properties: [
              "session_id": stringSchema("Session id returned by shell.spawn."),
              "text": stringSchema("Optional UTF-8 input."),
              "base64": stringSchema("Optional Base64-encoded binary input."),
              "close": boolSchema("Close stdin after writing. Defaults to false."),
            ],
            required: ["session_id"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "shell.write", risk: .fullShell,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "shell.cancel",
          description:
            "Terminate a gateway-owned Full Shell process group, escalating from SIGTERM to SIGKILL after the configured grace period.",
          inputSchema: objectSchema(
            properties: [
              "session_id": stringSchema("Session id returned by shell.spawn.")
            ],
            required: ["session_id"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "shell.cancel", risk: .fullShell,
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

  private static func shellLaunchSchema(
    includeTimeout: Bool,
    includeStandardInput: Bool
  ) -> JSONValue {
    var properties: [String: JSONValue] = [
      "mode": stringSchema(
        "shell or argv. Shell mode runs command through the configured shell; argv mode runs executable with argv directly. Defaults to shell."
      ),
      "command": stringSchema("Command string required by shell mode."),
      "executable": stringSchema("Executable name or absolute path required by argv mode."),
      "argv": stringArraySchema("Argument vector used by argv mode."),
      "shell": stringSchema(
        "Optional absolute shell executable override for shell mode."
      ),
      "cwd": stringSchema(
        "Optional absolute or gateway-workspace-relative working directory."
      ),
      "env": .object([
        "type": .string("object"),
        "description": .string(
          "Optional environment overrides merged with the gateway process environment."
        ),
        "additionalProperties": .object(["type": .string("string")]),
      ]),
    ]
    if includeTimeout {
      properties["timeout_ms"] = integerSchema(
        "Optional positive timeout in milliseconds. For shell.spawn, omit for no timeout."
      )
    }
    if includeStandardInput {
      properties["stdin_text"] = stringSchema(
        "Optional UTF-8 stdin written before stdin is closed."
      )
      properties["stdin_base64"] = stringSchema(
        "Optional Base64 stdin written before stdin is closed."
      )
    }
    return objectSchema(properties: properties)
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
