import ComputerMCPCore

extension SystemToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "system.info",
          description:
            "Return a non-secret read-only macOS system and current gateway process summary.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.info", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.kernel",
          description:
            "Return read-only macOS kernel and machine identity from uname, plus OS version and processor counts. This does not run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.kernel", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.software", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.locale",
          description:
            "Return read-only current locale, preferred languages, calendar, and time-zone summary from Foundation. This does not run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.locale", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.memory",
          description:
            "Return read-only macOS virtual-memory page counters and memory event counters using host_statistics64. This does not inspect processes or run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.memory", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.load",
          description:
            "Return read-only macOS load averages from getloadavg, with values normalized by active processor count. This does not inspect processes or run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.load", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.cpu",
          description:
            "Return read-only CPU and hardware identifier details from ProcessInfo, sysctlbyname, and uname. This does not inspect processes or run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.cpu", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.thermal",
          description:
            "Return read-only thermal state and low-power-mode status from ProcessInfo. This does not inspect processes or run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.thermal", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.time",
          description:
            "Return the current local time, Unix timestamp, time zone, and system uptime. This is read-only.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.time", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.uptime",
          description:
            "Return read-only system uptime and derived boot time from ProcessInfo.systemUptime. This does not run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.uptime", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.user",
          description:
            "Return read-only POSIX identity for the current gateway process using getuid/getgid/getpwuid/getgrgid. This does not enumerate users or run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.user", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "system.groups",
          description:
            "Return read-only supplementary POSIX groups for the current gateway process using getgroups/getgrgid. This does not enumerate all system groups or run shell commands.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.groups", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.power", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.volumes", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.processes", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.which", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "system.path", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "logs.query", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "service.status", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "env.describe",
          description:
            "Describe only environment variable names declared by gateway config and whether they are present. Values are always redacted.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "env.describe", risk: .readOnly,
          projectRequirement: .optional,
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

  private static func boolSchema(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
  }

}
