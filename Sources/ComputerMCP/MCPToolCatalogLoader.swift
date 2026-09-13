import Foundation
import MCP

/// Builds a complete catalog before any caller can publish it or activate its routes.
enum MCPToolCatalogLoader {
  static func load(
    maxPages: Int = 1_024,
    maxTools: Int = 100_000,
    maxEncodedBytes: Int = 32 * 1_024 * 1_024,
    page: @Sendable (String?) async throws -> (tools: [Tool], nextCursor: String?)
  ) async throws -> [Tool] {
    guard maxPages > 0, maxTools > 0, maxEncodedBytes > 0 else {
      throw GatewayToolError.executionFailed("MCP catalog limits must be positive.")
    }
    var tools: [Tool] = []
    var names: Set<String> = []
    var cursors: Set<String> = []
    var cursor: String?
    var remainingBytes = maxEncodedBytes
    let encoder = JSONEncoder()

    for _ in 0..<maxPages {
      try Task.checkCancellation()
      let result = try await page(cursor)
      try Task.checkCancellation()
      guard result.tools.count <= maxTools - tools.count else {
        throw GatewayToolError.executionFailed("MCP tools/list exceeded the catalog tool limit.")
      }
      let pageBytes = try encoder.encode(result.tools).count
      guard pageBytes <= remainingBytes else {
        throw GatewayToolError.executionFailed("MCP tools/list exceeded the catalog byte limit.")
      }
      remainingBytes -= pageBytes

      for tool in result.tools {
        guard !tool.name.isEmpty, !tool.name.contains("\0") else {
          throw GatewayToolError.executionFailed("MCP tools/list returned an invalid tool name.")
        }
        guard names.insert(tool.name).inserted else {
          throw GatewayToolError.executionFailed("MCP tools/list returned duplicate tool names.")
        }
        guard case .object = tool.inputSchema else {
          throw GatewayToolError.executionFailed(
            "MCP tools/list returned a non-object input schema.")
        }
        if let outputSchema = tool.outputSchema {
          guard case .object = outputSchema else {
            throw GatewayToolError.executionFailed(
              "MCP tools/list returned a non-object output schema.")
          }
        }
      }
      tools.append(contentsOf: result.tools)

      // Cursors are opaque: even an empty string can identify a subsequent page.
      guard let nextCursor = result.nextCursor else { return tools }
      guard nextCursor.utf8.count <= remainingBytes else {
        throw GatewayToolError.executionFailed("MCP tools/list exceeded the catalog byte limit.")
      }
      remainingBytes -= nextCursor.utf8.count
      guard cursors.insert(nextCursor).inserted else {
        throw GatewayToolError.executionFailed(
          "MCP tools/list returned a repeated pagination cursor.")
      }
      cursor = nextCursor
    }
    throw GatewayToolError.executionFailed("MCP tools/list exceeded the catalog page limit.")
  }
}
