import ComputerMCPCore
import ComputerMCPProcess
import Foundation
import NIOConcurrencyHelpers

/// Runtime-local ownership, separate from durable execution outcome and authorization.
package final class GatewayOwnedWork: OwnedWorkTracking, Sendable {
  package enum Kind: String, Sendable {
    case invocation
    case shell
    case mcpRequest
    case mcpResource
    case mcpObservation
    case mcpUnreportedWork
  }

  package struct Record: Sendable, Equatable {
    package let id: UUID
    package let kind: Kind
    package let projectID: String?
    package let registrationID: String?
    package let connectionID: UUID?
    package let resourceID: String
    package var uncertain = false
  }

  private struct State {
    var records: [UUID: Record] = [:]
    var admitsInvocations = true
  }

  private let state = NIOLockedValueBox(State())
  private let changes = GatewayToolChangeBroadcaster()
  let continuations = MCPContinuationDirectory()

  package var snapshot: [Record] { state.withLockedValue { Array($0.records.values) } }
  package func updates() -> AsyncStream<Void> { changes.stream() }

  package func retainShell(projectID: String?, sessionID: String) -> any OwnedWorkLease {
    retain(.shell, projectID: projectID, resourceID: sessionID)
  }

  func retain(
    _ kind: Kind, projectID: String? = nil, registrationID: String? = nil,
    resourceID: String, connectionID: UUID? = nil
  ) -> Lease {
    let record = Record(
      id: UUID(), kind: kind, projectID: projectID, registrationID: registrationID,
      connectionID: connectionID, resourceID: resourceID)
    state.withLockedValue { $0.records[record.id] = record }
    changes.send()
    return Lease(owner: self, id: record.id)
  }

  /// Call admission and the idle-retirement decision share one linearization point.
  package func admitInvocation(projectID: String?, resourceID: String) throws -> Lease {
    let record = Record(
      id: UUID(), kind: .invocation, projectID: projectID, registrationID: nil,
      connectionID: nil, resourceID: resourceID)
    try state.withLockedValue { state in
      guard state.admitsInvocations else {
        throw GatewayToolError.disabled(
          "[runtime.retired] This runtime no longer admits invocations.")
      }
      state.records[record.id] = record
    }
    changes.send()
    return Lease(owner: self, id: record.id)
  }

  func closeAdmissionIfDrained() -> Bool {
    state.withLockedValue { state in
      guard state.records.isEmpty else { return false }
      state.admitsInvocations = false
      return true
    }
  }

  func closeAdmission() { state.withLockedValue { $0.admitsInvocations = false } }

  private func finish(_ id: UUID) {
    if state.withLockedValue({ $0.records.removeValue(forKey: id) != nil }) { changes.send() }
  }

  private func setUncertain(_ id: UUID, _ uncertain: Bool) {
    let changed = state.withLockedValue { state in
      guard let record = state.records[id], record.uncertain != uncertain else { return false }
      state.records[id]?.uncertain = uncertain
      return true
    }
    if changed { changes.send() }
  }

  /// Losing observation cannot establish that the underlying work stopped.
  package final class Lease: OwnedWorkLease, Sendable {
    let id: UUID
    private let owner: GatewayOwnedWork

    fileprivate init(owner: GatewayOwnedWork, id: UUID) {
      self.owner = owner
      self.id = id
    }

    package func finish() { owner.finish(id) }
    func markUncertain() { owner.setUncertain(id, true) }
    func confirmObservation() { owner.setUncertain(id, false) }
    deinit { owner.setUncertain(id, true) }
  }
}
