import ComputerMCPCore

extension DeliveryToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "delivery.scopes.list",
          description:
            "List the host-declared delivery scopes for the current project, including repository, path globs, default branch, worktree root, sparse checkout and delivery mode.",
          inputSchema: objectSchema(properties: [:]),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta),
        capability: CapabilityDescriptor(
          id: "delivery.scopes.list", risk: .readOnly,
          projectRequirement: .required, localOnly: false, usesNetwork: false)),
      ToolDefinition(
        tool: MCPTool(
          name: "delivery.apply",
          description:
            "Apply ordered UTF-8 text edits within a host-declared scope in an isolated Git worktree, commit with a Conventional Commit message without trailers, and land by fast-forward or retain the committed branch. Returns state, commit, retained branch, reason and bounded file snippets; aborted results are tool errors. Uses the registered git command without network operations.",
          inputSchema: objectSchema(
            properties: [
              "scope": stringSchema("Delivery scope id from delivery.scopes.list."),
              "message": stringSchema(
                "Conventional Commit message using feat, fix, docs, style, refactor, perf, test, build, ci, chore or revert; optional body, no Git trailers."
              ),
              "slug": .object([
                "type": .string("string"),
                "description": .string(
                  "Branch suffix; the commit type supplies the branch prefix."),
                "pattern": .string("^[a-z0-9]+(-[a-z0-9]+)*$"), "maxLength": .integer(48),
              ]),
              "edits": .object([
                "type": .string("array"), "minItems": .integer(1), "maxItems": .integer(64),
                "items": .object([
                  "type": .string("object"),
                  "properties": .object([
                    "path": stringSchema(
                      "Relative repository path with forward slashes; no traversal, .git or symlinks."
                    ),
                    "replace": objectSchema(
                      properties: [
                        "old": .object([
                          "type": .string("string"), "minLength": .integer(1),
                          "description": .string(
                            "Text occurring exactly once; old and new together are at most 1 MiB of UTF-8."
                          ),
                        ]),
                        "new": stringSchema(
                          "Replacement text within the edit's combined 1 MiB UTF-8 limit."),
                      ], required: ["old", "new"]),
                    "create": objectSchema(
                      properties: [
                        "content": stringSchema(
                          "New file content, at most 1 MiB of UTF-8; creates missing parent directories."
                        )
                      ], required: ["content"]),
                  ]),
                  "required": .array([.string("path")]),
                  "oneOf": .array([
                    .object([
                      "required": .array([.string("replace")]),
                      "not": .object(["required": .array([.string("create")])]),
                    ]),
                    .object([
                      "required": .array([.string("create")]),
                      "not": .object(["required": .array([.string("replace")])]),
                    ]),
                  ]),
                  "additionalProperties": .bool(false),
                ]),
              ]),
            ], required: ["scope", "message", "slug", "edits"]),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, openWorldHint: false),
          meta: toolMeta),
        capability: CapabilityDescriptor(
          id: "delivery.apply", risk: .projectWrite,
          projectRequirement: .required, localOnly: false, usesNetwork: false)),
    ]
  }
  private static func objectSchema(properties: [String: JSONValue], required: [String] = [])
    -> JSONValue
  {
    .object([
      "type": .string("object"), "properties": .object(properties),
      "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false),
    ])
  }

  private static func stringSchema(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
  }

}
