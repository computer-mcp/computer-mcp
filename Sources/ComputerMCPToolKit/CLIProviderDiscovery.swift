import ComputerMCPProcess

/// Host-reviewed discovery authority. It is independent of a catalog's client and project.
package struct CLIProviderDiscovery: Sendable {
  package let identity: String
  package let prepare: @Sendable () throws -> PreparedExecutionContext

  package init(identity: String, prepare: @escaping @Sendable () throws -> PreparedExecutionContext)
  {
    self.identity = identity
    self.prepare = prepare
  }
}
