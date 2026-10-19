/// `_meta` keys a provider declares for its own connection; they are removed before a
/// tool is exported to any other client.
package enum MCPProviderMetadataKey {
  package static let work = "io.github.computer-mcp/work"
  package static let continuation = "io.github.computer-mcp/continuation"
}

extension MCPTool {
  /// A downstream resource URI is meaningful only on that provider's connection.
  package var exportedMetadata: JSONValue? {
    guard mcpReference != nil, var fields = meta?.objectValue else { return meta }
    fields.removeValue(forKey: MCPProviderMetadataKey.work)
    fields.removeValue(forKey: MCPProviderMetadataKey.continuation)
    return fields.isEmpty ? nil : .object(fields)
  }
}
