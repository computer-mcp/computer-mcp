import ComputerMCPCore
import ComputerMCPProcess
import Foundation
import NIOConcurrencyHelpers

/// Runtime-local ownership, separate from durable execution outcome and authorization.
final class GatewayOwnedWork: OwnedWorkTracking, Sendable {
  enum Kind: String, Sendable {
    case invocation
    case shell
    case mcpRequest
    case mcpResource
    case mcpObservation
    case mcpUnreportedWork
  }

  struct Record: Sendable, Equatable {
    let id: UUID
    let kind: Kind
    let workspaceID: String?
    let registrationID: String?
    let connectionID: UUID?
    let resourceID: String
    var uncertain = false
  }

  private struct State {
    var records: [UUID: Record] = [:]
    var admitsInvocations = true
  }

  private let state = NIOLockedValueBox(State())
  private let changes = GatewayToolChangeBroadcaster()
  let continuations = MCPContinuationDirectory()

  var snapshot: [Record] { state.withLockedValue { Array($0.records.values) } }
  func updates() -> AsyncStream<Void> { changes.stream() }

  func retainShell(workspaceID: String?, sessionID: String) -> any OwnedWorkLease {
    retain(.shell, workspaceID: workspaceID, resourceID: sessionID)
  }

  func retain(
    _ kind: Kind, workspaceID: String? = nil, registrationID: String? = nil,
    resourceID: String, connectionID: UUID? = nil
  ) -> Lease {
    let record = Record(
      id: UUID(), kind: kind, workspaceID: workspaceID, registrationID: registrationID,
      connectionID: connectionID, resourceID: resourceID)
    state.withLockedValue { $0.records[record.id] = record }
    changes.send()
    return Lease(owner: self, id: record.id)
  }

  /// Call admission and the idle-retirement decision share one linearization point.
  func admitInvocation(workspaceID: String?, resourceID: String) throws -> Lease {
    let record = Record(
      id: UUID(), kind: .invocation, workspaceID: workspaceID, registrationID: nil,
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
  final class Lease: OwnedWorkLease, Sendable {
    let id: UUID
    private let owner: GatewayOwnedWork

    fileprivate init(owner: GatewayOwnedWork, id: UUID) {
      self.owner = owner
      self.id = id
    }

    func finish() { owner.finish(id) }
    func markUncertain() { owner.setUncertain(id, true) }
    func confirmObservation() { owner.setUncertain(id, false) }
    deinit { owner.setUncertain(id, true) }
  }
}
