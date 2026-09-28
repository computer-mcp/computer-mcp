import Foundation

/// Host-created authority retained by invocations, independently of runtime generations.
final class GatewayControlSession: @unchecked Sendable, Equatable {
  @TaskLocal static var current: GatewayControlSession?

  let id = UUID().uuidString
  let principalID: String
  let profileID: GatewayProfileID
  let caller: GatewayCallerKind
  private let lock = NSLock()
  private var revision: Int64 = 0
  private var accessLimit = GatewayPermissionMode.localFullAccess
  private var ended = false

  init(principalID: String, profileID: GatewayProfileID, caller: GatewayCallerKind) {
    self.principalID = principalID
    self.profileID = profileID
    self.caller = caller
  }

  static func == (lhs: GatewayControlSession, rhs: GatewayControlSession) -> Bool { lhs === rhs }

  var snapshot: GatewayControlSessionSnapshot {
    lock.withLock {
      GatewayControlSessionSnapshot(
        id: id, principalID: principalID, profileID: profileID, caller: caller,
        revision: revision, accessLimit: accessLimit, ended: ended)
    }
  }

  func limitAccess(to mode: GatewayPermissionMode, expectedRevision: Int64) throws {
    try lock.withLock {
      guard !ended, revision == expectedRevision, revision < Int64.max else {
        throw Self.denied("The control session changed. Reload before changing its access.")
      }
      accessLimit = mode
      revision += 1
    }
  }

  func end() {
    lock.withLock {
      ended = true
    }
  }

  func apply(to grant: ProfileGrant, context: ExecutionContext) throws -> ProfileGrant {
    try lock.withLock {
      guard !ended, !principalID.isEmpty,
        context.trustedPrincipalID == principalID,
        context.profileID == profileID, context.caller == caller, grant.id == profileID
      else { throw Self.denied("The control session is no longer authorized for this caller.") }
      var effective = grant
      switch accessLimit {
      case .readOnly:
        effective.mode = .readOnly
        effective.fullShellEnabled = false
      case .workspaceOperations:
        if effective.mode == .localFullAccess { effective.mode = .workspaceOperations }
        effective.fullShellEnabled = false
      case .localFullAccess:
        break
      }
      return effective
    }
  }

  func requireRevision(_ expected: Int64?) throws {
    try lock.withLock {
      guard !ended, expected == revision else {
        throw Self.denied("The control session changed after this operation was prepared.")
      }
    }
  }

  private static func denied(_ message: String) -> GatewayToolError {
    .invalidArguments("[policy.control_session_denied] " + message)
  }
}

package struct GatewayControlSessionSnapshot: Codable, Equatable, Sendable, Identifiable {
  package let id: String
  package let principalID: String
  package let profileID: GatewayProfileID
  package let caller: GatewayCallerKind
  package let revision: Int64
  package let accessLimit: GatewayPermissionMode
  package let ended: Bool
}
