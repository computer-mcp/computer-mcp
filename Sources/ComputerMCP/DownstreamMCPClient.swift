import Foundation

package protocol DownstreamMCPClient: Sendable {
  /// Creates a client whose connections and shutdown belong to one workspace owner.
  /// Launch context is host-owned and must not be inferred from a plugin manifest's identity.
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  )
    -> any DownstreamMCPClient
  func toolChanges() -> AsyncStream<Void>
  func shutdown() async
  func isServerVisible(_ server: MCPServerConfig) -> Bool
  func listTools(server: MCPServerConfig) throws -> [MCPTool]
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue
  func callTool(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String?
  ) throws -> JSONValue
  func startToolCall(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String
  ) throws -> JSONValue
  func callToolAsync(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?
  ) async throws -> JSONValue
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  func connectionStatus(server: MCPServerConfig) throws -> JSONValue
  func closeConnection(server: MCPServerConfig) throws -> JSONValue
  func readEvents(server: MCPServerConfig, afterCursor: Int, maxResults: Int) throws -> JSONValue
  func readEvents(
    server: MCPServerConfig, afterCursor: Int, maxResults: Int, sessionID: String?
  ) throws -> JSONValue
  func activeRequests(server: MCPServerConfig) throws -> JSONValue
  func readRequest(server: MCPServerConfig, requestID: String, offset: Int, maxBytes: Int) throws
    -> JSONValue
  func cancelRequest(server: MCPServerConfig, requestID: String, reason: String?) throws
    -> JSONValue
}

extension DownstreamMCPClient {
  package func closeConnection(server: MCPServerConfig) throws -> JSONValue {
    throw GatewayToolError.disabled(
      "This downstream client does not support selected connection close.")
  }

  package func readEvents(
    server: MCPServerConfig, afterCursor: Int, maxResults: Int, sessionID: String?
  ) throws -> JSONValue {
    guard sessionID == nil else {
      throw GatewayToolError.invalidArguments(
        "[cursor.session_unavailable] This downstream client cannot validate event session cursors."
      )
    }
    return try readEvents(server: server, afterCursor: afterCursor, maxResults: maxResults)
  }
  package func readRequest(server: MCPServerConfig, requestID: String, offset: Int, maxBytes: Int)
    throws -> JSONValue
  {
    throw GatewayToolError.disabled("Downstream MCP client does not retain execution results.")
  }
  package func callToolAsync(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?
  ) async throws -> JSONValue {
    try Task.checkCancellation()
    let admission = MCPInvocationAdmission.current
    let target = MCPContinuationTarget.current
    let session = GatewayControlSession.current
    let result = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result {
            try MCPInvocationAdmission.$current.withValue(admission) {
              try GatewayControlSession.$current.withValue(session) {
                try MCPContinuationTarget.$current.withValue(target) {
                  try self.callTool(
                    server: server, name: name, arguments: arguments, requestID: requestID)
                }
              }
            }
          })
      }
    }
    try Task.checkCancellation()
    return result
  }
  package func toolChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  package func shutdown() async {}
  package func isServerVisible(_ server: MCPServerConfig) -> Bool { true }
  package func callTool(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String?
  ) throws -> JSONValue {
    try callTool(server: server, name: name, arguments: arguments)
  }

  package func connectionStatus(server: MCPServerConfig) throws -> JSONValue {
    .object([
      "state": .string("not_observed"),
      "persistent_session": .bool(false),
    ])
  }

  package func startToolCall(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String
  ) throws -> JSONValue {
    throw GatewayToolError.disabled(
      "Downstream MCP client does not support asynchronously started tool calls."
    )
  }

  package func readEvents(
    server: MCPServerConfig,
    afterCursor: Int,
    maxResults: Int
  ) throws -> JSONValue {
    guard afterCursor == 0 else {
      throw GatewayToolError.invalidArguments(
        "[cursor.session_unavailable] This downstream client has no retained event session.")
    }
    return .object([
      "server": .string(server.id),
      "after_cursor": .integer(Int64(afterCursor)),
      "next_cursor": .integer(Int64(afterCursor)),
      "events": .array([]),
      "missed_events": .null,
      "session_id": .null, "session_verified": .bool(false),
      "cursor_state": .string("unavailable"), "reset_required": .bool(afterCursor > 0),
      "oldest_available_cursor": .null, "latest_event_cursor": .null, "has_more": .bool(false),
      "persistent_session": .bool(false),
    ])
  }

  package func activeRequests(server: MCPServerConfig) throws -> JSONValue {
    .object([
      "server": .string(server.id),
      "requests": .array([]),
      "persistent_session": .bool(false),
    ])
  }

  package func cancelRequest(
    server: MCPServerConfig,
    requestID: String,
    reason: String?
  ) throws -> JSONValue {
    throw GatewayToolError.disabled(
      "Downstream MCP client does not support request cancellation."
    )
  }
}
