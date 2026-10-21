package protocol GatewayToolProvider: Sendable {
  var id: String { get }
  /// The tool-name namespaces this provider owns. A name belongs to namespace `n` when it
  /// starts with `n` followed by `.`. The catalog lists downstream contributions under an
  /// owned namespace with the owning provider.
  var namespaces: [String] { get }
  func definitions() throws -> [ToolDefinition]
  func callTool(_ invocation: ToolInvocation) throws -> JSONValue
  func callToolAsync(_ invocation: ToolInvocation) async throws -> JSONValue
  func shutdown() async
}

extension GatewayToolProvider {
  package var namespaces: [String] { [] }

  package func callToolAsync(_ invocation: ToolInvocation) async throws -> JSONValue {
    try Task.checkCancellation()
    return try await GatewayProviderExecution.blocking.perform {
      try self.callTool(invocation)
    }
  }

  package func shutdown() async {}
}

private enum GatewayProviderExecution {
  static let blocking = BlockingOperationExecutor(
    label: "computer-mcp.provider-calls", serial: false)
}
