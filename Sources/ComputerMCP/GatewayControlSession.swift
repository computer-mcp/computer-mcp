import Foundation

/// Host-created authority retained by invocations, independently of runtime generations.
final class GatewayControlSession: @unchecked Sendable, Equatable {
  @TaskLocal static var current: GatewayControlSession?

  let id = UUID().uuidString
  let principalID: String
  let profileID: GatewayProfileID
  let caller: GatewayCallerKind
  let changes = GatewayToolChangeBroadcaster()
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
    changes.send()
  }

  func end() {
    lock.withLock {
      ended = true
    }
    changes.send()
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

/// A connection borrows its principal's runtime; closing consent does not own runtime shutdown.
struct GatewayControlSessionServing: GatewayAsyncToolServing {
  let base: any GatewayAsyncToolServing
  let session: GatewayControlSession

  func listToolsAsync() async throws -> [MCPTool] {
    try await GatewayControlSession.$current.withValue(session) {
      try await base.listToolsAsync()
    }
  }

  func refreshTools() async throws {
    try await GatewayControlSession.$current.withValue(session) {
      try await base.refreshTools()
    }
  }

  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await GatewayControlSession.$current.withValue(session) {
      try await base.callToolAsync(name: name, arguments: arguments)
    }
  }

  func callToolForMCPAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await GatewayControlSession.$current.withValue(session) {
      try await base.callToolForMCPAsync(name: name, arguments: arguments)
    }
  }

  func toolChanges() -> AsyncStream<Void> {
    let sources = GatewayControlSession.$current.withValue(session) {
      [base.toolChanges(), session.changes.stream()]
    }
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let forwarding = Task {
      await withTaskGroup(of: Void.self) { group in
        for source in sources {
          group.addTask {
            for await _ in source {
              guard !Task.isCancelled else { break }
              continuation.yield(())
            }
          }
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in forwarding.cancel() }
    return stream
  }

  func shutdown() async { session.end() }
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
