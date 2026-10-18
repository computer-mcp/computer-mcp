import Foundation

/// Standard MCP hints describing a tool's operational behavior.
package struct MCPToolAnnotations: Equatable, Sendable {
  package let readOnlyHint: Bool?
  package let destructiveHint: Bool?
  package let idempotentHint: Bool?
  package let openWorldHint: Bool?

  package init(
    readOnlyHint: Bool? = nil,
    destructiveHint: Bool? = nil,
    idempotentHint: Bool? = nil,
    openWorldHint: Bool? = nil
  ) {
    self.readOnlyHint = readOnlyHint
    self.destructiveHint = destructiveHint
    self.idempotentHint = idempotentHint
    self.openWorldHint = openWorldHint
  }

  package var json: JSONValue {
    var object: [String: JSONValue] = [:]
    if let readOnlyHint {
      object["readOnlyHint"] = .bool(readOnlyHint)
    }
    if let destructiveHint {
      object["destructiveHint"] = .bool(destructiveHint)
    }
    if let idempotentHint {
      object["idempotentHint"] = .bool(idempotentHint)
    }
    if let openWorldHint {
      object["openWorldHint"] = .bool(openWorldHint)
    }
    return .object(object)
  }
}

/// MCP tool definition exposed by `tools/list`.
package struct MCPTool: Equatable, Sendable {
  /// Stable MCP tool name.
  package let name: String

  /// Human-readable display title.
  package let title: String

  /// Reader-facing tool description.
  package let description: String

  /// JSON Schema input schema.
  package let inputSchema: JSONValue

  /// JSON Schema for structured tool results.
  package let outputSchema: JSONValue?

  /// Standard MCP operational hints.
  package let annotations: MCPToolAnnotations?

  /// Optional MCP tool metadata.
  package let meta: JSONValue?

  /// Assigned by registration; never decoded from MCP annotations or `_meta`.
  package let mcpReference: MCPToolReference?

  /// Creates an MCP tool definition.
  package init(
    name: String,
    title: String? = nil,
    description: String,
    inputSchema: JSONValue,
    outputSchema: JSONValue? = MCPTool.resultEnvelopeSchema,
    annotations: MCPToolAnnotations? = nil,
    meta: JSONValue? = nil,
    mcpReference: MCPToolReference? = nil
  ) {
    self.name = name
    self.title = title ?? MCPTool.defaultTitle(for: name)
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.annotations = annotations
    self.meta = meta
    self.mcpReference = mcpReference
  }

  /// JSON representation used in MCP `tools/list` responses.
  package var json: JSONValue {
    var object: [String: JSONValue] = [
      "name": .string(name),
      "title": .string(title),
      "description": .string(description),
      "inputSchema": inputSchema,
    ]
    if let outputSchema {
      object["outputSchema"] = outputSchema
    }
    if let annotations {
      object["annotations"] = annotations.json
    }
    if let meta = exportedMetadata {
      object["_meta"] = meta
    }
    return .object(object)
  }

  internal func prefixed(_ prefix: String, serverID: String) -> MCPTool {
    MCPTool(
      name: prefix.isEmpty ? name : "\(prefix).\(name)",
      title: title,
      description: description,
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      annotations: annotations,
      meta: meta,
      mcpReference: MCPToolReference(serverID: serverID, toolName: name)
    )
  }

  internal func withAnnotations(_ annotations: MCPToolAnnotations) -> MCPTool {
    MCPTool(
      name: name,
      title: title,
      description: description,
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      annotations: annotations,
      meta: meta,
      mcpReference: mcpReference
    )
  }

  internal static let resultEnvelopeSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "result": .object([:])
    ]),
    "required": .array([.string("result")]),
    "additionalProperties": .bool(false),
  ])

  private static func defaultTitle(for name: String) -> String {
    name
      .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
      .map { part in
        guard let first = part.first else {
          return ""
        }
        return String(first).uppercased() + part.dropFirst()
      }
      .joined(separator: " ")
  }
}
