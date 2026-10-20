import ComputerMCPCore
import Foundation
import NIOConcurrencyHelpers

/// Runtime-owned observations survive loss of the connection that reported them.
package final class MCPContinuationDirectory: Sendable {
  struct Entry: Sendable {
    let workspaceID: String?
    let registrationID: String
    let instanceID: UUID?
    let declarations: [String: MCPProviderContinuation]
    let resources: [MCPProviderWork.Resource]
    let observationPending: Bool
    let connected: Bool
  }

  package struct Match: Hashable, Sendable {
    package let connectionID: UUID
    package let instanceID: UUID
    package let resource: MCPProviderWork.Key
    package let acquiredBy: UUID
    package let connected: Bool
    package let uncertain: Bool
  }

  package struct Lookup: Equatable, Sendable {
    package var applicable = false
    package var matches: Set<Match> = []
    package var pendingConnections: Set<UUID> = []
  }

  private let entries = NIOLockedValueBox([UUID: Entry]())

  /// Callers combine only observations from one principal/profile routing scope.
  package static func uniqueOwner(in observations: [Lookup]) throws -> Set<Match>? {
    let matches = observations.reduce(into: Set<Match>()) { $0.formUnion($1.matches) }
    let pending = observations.reduce(into: Set<UUID>()) { $0.formUnion($1.pendingConnections) }
    let connections = Set(matches.map(\.connectionID))
    let instances = Set(matches.map(\.instanceID))
    guard connections.count <= 1, instances.count <= 1 else {
      throw GatewayToolError.invalidArguments(
        "[mcp.continuation_ambiguous] More than one retained instance owns this handle. Select its exact execution owner."
      )
    }
    guard pending.subtracting(connections).isEmpty else {
      throw GatewayToolError.invalidArguments(
        "[mcp.continuation_pending] Work observation has not settled. Retry after ownership is observed; no call was dispatched."
      )
    }
    guard !matches.isEmpty else { return nil }
    guard matches.allSatisfy(\.connected) else { throw MCPContinuationTarget.unavailable() }
    return matches
  }

  func update(connectionID: UUID, entry: Entry) {
    entries.withLockedValue { entries in
      if !entry.connected && entry.resources.isEmpty && !entry.observationPending {
        entries.removeValue(forKey: connectionID)
      } else {
        entries[connectionID] = entry
      }
    }
  }

  func retainsContinuation(workspaceID: String?, reference: MCPToolReference) -> Bool {
    entries.withLockedValue { entries in
      entries.values.contains {
        $0.workspaceID == workspaceID && $0.registrationID == reference.serverID
          && $0.declarations[reference.toolName] != nil
          && ($0.observationPending || !$0.resources.isEmpty)
      }
    }
  }

  func entry(connectionID: UUID) -> Entry? { entries.withLockedValue { $0[connectionID] } }

  /// A match is a locator, not call admission. Pending observations cannot prove absence.
  func lookup(
    workspaceID: String?, registrationID: String, tool: String, arguments: JSONValue
  ) throws -> Lookup {
    let snapshot = entries.withLockedValue { $0 }
    var result = Lookup()
    for (connectionID, entry) in snapshot
    where entry.workspaceID == workspaceID && entry.registrationID == registrationID {
      guard let declaration = entry.declarations[tool] else { continue }
      let queries = try declaration.queries(arguments: arguments)
      guard !queries.isEmpty else { continue }
      result.applicable = true
      if entry.observationPending { result.pendingConnections.insert(connectionID) }
      guard let instanceID = entry.instanceID else { continue }
      for resource in entry.resources where queries.contains(where: resource.matches) {
        result.matches.insert(
          .init(
            connectionID: connectionID, instanceID: instanceID, resource: resource.key,
            acquiredBy: resource.acquiredBy,
            connected: entry.connected, uncertain: resource.uncertain || !entry.connected))
      }
    }
    return result
  }
}

/// Host-selected routing evidence is private to a call; it does not confer authority.
package struct MCPContinuationTarget: ContinuationRoute {
  package let workspaceID: String?
  package let reference: MCPToolReference
  package let connectionID: UUID
  package let instanceID: UUID?
  package let resources: [MCPProviderWork.Key: UUID]
  var selectedOwnershipID: UUID? = nil

  package init(
    workspaceID: String?, reference: MCPToolReference, connectionID: UUID,
    instanceID: UUID?, resources: [MCPProviderWork.Key: UUID], selectedOwnershipID: UUID? = nil
  ) {
    self.workspaceID = workspaceID
    self.reference = reference
    self.connectionID = connectionID
    self.instanceID = instanceID
    self.resources = resources
    self.selectedOwnershipID = selectedOwnershipID
  }

  package static func unavailable() -> GatewayToolError {
    .invalidArguments(
      "[mcp.continuation_unavailable] The selected work owner is unavailable or has changed. No replacement connection was started."
    )
  }
}

extension InvocationContext {
  var continuationTarget: MCPContinuationTarget? { continuation as? MCPContinuationTarget }
}
