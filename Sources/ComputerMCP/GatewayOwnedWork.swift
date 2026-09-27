import Foundation
import os

/// Runtime-local ownership, separate from durable execution outcome and authorization.
final class GatewayOwnedWork: Sendable {
  enum Kind: String, Sendable {
    case invocation
    case shell
    case mcpRequest
    case mcpResource
    case mcpObservation
  }

  struct Record: Sendable, Equatable {
    let id: UUID
    let kind: Kind
    let workspaceID: String?
    let registrationID: String?
    let resourceID: String
    var uncertain = false
  }

  private let records = OSAllocatedUnfairLock(initialState: [UUID: Record]())
  private let changes = GatewayToolChangeBroadcaster()

  var snapshot: [Record] { records.withLock { Array($0.values) } }
  func updates() -> AsyncStream<Void> { changes.stream() }

  func retain(
    _ kind: Kind, workspaceID: String? = nil, registrationID: String? = nil,
    resourceID: String
  ) -> Lease {
    let record = Record(
      id: UUID(), kind: kind, workspaceID: workspaceID, registrationID: registrationID,
      resourceID: resourceID)
    records.withLock { $0[record.id] = record }
    changes.send()
    return Lease(owner: self, id: record.id)
  }

  private func finish(_ id: UUID) {
    if records.withLock({ $0.removeValue(forKey: id) != nil }) { changes.send() }
  }

  private func setUncertain(_ id: UUID, _ uncertain: Bool) {
    let changed = records.withLock { records in
      guard let record = records[id], record.uncertain != uncertain else { return false }
      records[id]?.uncertain = uncertain
      return true
    }
    if changed { changes.send() }
  }

  /// Losing observation cannot establish that the underlying work stopped.
  final class Lease: Sendable {
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
