/// Host-assigned routing identity, kept separate from downstream wire metadata.
package struct MCPToolReference: Codable, Equatable, Sendable {
  package let serverID: String
  package let toolName: String

  package init(serverID: String, toolName: String) {
    self.serverID = serverID
    self.toolName = toolName
  }
}
