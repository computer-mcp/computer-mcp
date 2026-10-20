import ComputerMCPCore

/// Workspace provider assembly. The host shares these runtime owners across catalog generations.
package struct GatewayToolRegistry: Sendable {
  package let providers: @Sendable () throws -> [any GatewayToolProvider]
  let invalidations: AsyncStream<Void>?
  package let refreshInterval: Duration?
  package let downstreamPolicy:
    @Sendable (MCPToolReference, InvocationContext) throws -> MCPToolAdmissionPolicy
  private let shutdownRuntime: @Sendable () async -> Void

  package init(
    providers: @escaping @Sendable () throws -> [any GatewayToolProvider],
    invalidations: AsyncStream<Void>? = nil,
    refreshInterval: Duration? = nil,
    downstreamPolicy:
      @escaping @Sendable (MCPToolReference, InvocationContext) throws -> MCPToolAdmissionPolicy,
    shutdown: @escaping @Sendable () async -> Void = {}
  ) {
    self.providers = providers
    self.invalidations = invalidations
    self.refreshInterval = refreshInterval
    self.downstreamPolicy = downstreamPolicy
    self.shutdownRuntime = shutdown
  }

  package func shutdown() async { await shutdownRuntime() }
}
