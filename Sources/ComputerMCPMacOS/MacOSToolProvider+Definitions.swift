import ComputerMCPCore

extension MacOSToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "macos.user_directories", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "macos.default_application",
          description:
            "Return the default macOS application, and optionally candidate applications, that LaunchServices would use for a project-contained file path or an http, https, or mailto URL. This is read-only and does not open the file, launch an application, make network requests, or inspect UI content.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Existing project-relative or project-contained absolute file/directory path to query."
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "macos.default_application", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "macos.applications", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "macos.screens",
          description:
            "List attached macOS screens with frame, visible frame, scale, and color-space metadata. This is read-only.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "macos.screens", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "macos.spotlight_search",
          description:
            "Search the macOS Spotlight index under a project-contained directory using fixed /usr/bin/mdfind -onlyin argv. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional project-relative directory path to constrain mdfind. Defaults to project root."
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "macos.spotlight_search", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "macos.running_applications", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "macos.frontmost_application",
          description:
            "Return the current frontmost macOS application visible to the user session. This is read-only.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "macos.frontmost_application", risk: .readOnly,
          projectRequirement: .none,
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
