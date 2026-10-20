import ComputerMCPCore
import Foundation

package enum GatewayFullAccessLifetime: String, Codable, CaseIterable, Sendable {
  case thisSession = "this-session"
  case alwaysAllowClient = "always-allow-client"
}

/// The authority source distinguishes a manifest grant from a database override.
package struct GatewayControlProfile: Codable, Equatable, Sendable {
  package let grant: ProfileGrant
  package let persisted: Bool
  // Configured Observe profiles derive their visible read tools and workspaces at runtime.
  package var configuredGrant: ProfileGrant? = nil

  func hasSameAuthorization(as other: Self) -> Bool {
    persisted == other.persisted
      && (configuredGrant ?? grant) == (other.configuredGrant ?? other.grant)
  }
}

package struct GatewayFullAccessConsent: Codable, Equatable, Sendable {
  package let lifetime: GatewayFullAccessLifetime
  package let grantedAt: Date
  package let profile: GatewayControlProfile
  package let trustID: String?
  package let trustRevision: Int64?
}

package struct GatewayClientTrust: Codable, Equatable, Sendable, Identifiable {
  package let id: String
  package let principalID: String
  package let profileID: GatewayProfileID
  package let caller: GatewayCallerKind
  package var revision: Int64
  package var profile: GatewayControlProfile
  package var fullAccessAllowed: Bool
  package var updatedAt: Date
}

/// Host-created authority retained by invocations, independently of runtime generations.
final class GatewayControlSession: GatewaySessionAuthority, @unchecked Sendable, Equatable {
  let id = UUID().uuidString
  let principalID: String
  let profileID: GatewayProfileID
  let caller: GatewayCallerKind
  let changes = GatewayToolChangeBroadcaster()
  private let lock = NSLock()
  private var currentRevision: Int64 = 0
  private var accessLimit = GatewayPermissionMode.workspaceOperations
  private var fullAccessConsent: GatewayFullAccessConsent?
  private let database: GatewayDatabase?
  private var profile: GatewayControlProfile?
  private var ended = false

  init(
    principalID: String, profileID: GatewayProfileID, caller: GatewayCallerKind,
    database: GatewayDatabase? = nil, profile: GatewayControlProfile? = nil
  ) {
    self.principalID = principalID
    self.profileID = profileID
    self.caller = caller
    self.database = database
    self.profile = profile
    accessLimit = profile?.grant.mode == .readOnly ? .readOnly : .workspaceOperations
  }

  func restoreTrustedAccess() throws {
    try lock.withLock {
      guard !ended, currentRevision == 0, fullAccessConsent == nil, let database,
        let trust = try database.clientTrust(
          principalID: principalID, profileID: profileID, caller: caller),
        trust.fullAccessAllowed,
        let current = try currentProfile(), current.hasSameAuthorization(as: trust.profile),
        current.grant.allowedCallers.contains(caller)
      else { return }
      fullAccessConsent = .init(
        lifetime: .alwaysAllowClient, grantedAt: trust.updatedAt,
        profile: current, trustID: trust.id, trustRevision: trust.revision)
      accessLimit = .localFullAccess
    }
  }

  /// Called only by the local owner control plane after explicit user consent.
  func approveFullAccess(
    lifetime: GatewayFullAccessLifetime = .thisSession,
    expectedRevision: Int64, expectedTrustRevision: Int64 = 0,
    approver: GatewayCallerKind = .localApp
  ) throws -> GatewayControlSessionSnapshot {
    try lock.withLock {
      refreshConsent()
      let current = try currentProfile()
      guard !ended, currentRevision == expectedRevision, currentRevision < Int64.max,
        let database, !principalID.isEmpty, let current
      else { throw Self.denied("Reload the connected client before granting access.") }
      // Persistence and audit must succeed before this session receives authority.
      let consent = try database.recordFullAccessConsent(
        sessionID: id, principalID: principalID, profile: current, caller: caller,
        lifetime: lifetime, expectedTrustRevision: expectedTrustRevision, approver: approver)
      fullAccessConsent = consent
      accessLimit = .localFullAccess
      currentRevision += 1
    }
    changes.send()
    return snapshot
  }

  /// Publication updates the baseline used by both current and retained invocations.
  func updateProfile(_ current: GatewayControlProfile) {
    lock.withLock {
      guard current.grant.id == profileID else { return }
      adoptProfile(current)
    }
  }

  private func adoptProfile(_ current: GatewayControlProfile) {
    let changed = profile.map { !current.hasSameAuthorization(as: $0) } ?? false
    profile = current
    if changed {
      if fullAccessConsent != nil {
        clearConsent(mode: current.grant.mode)
      } else {
        if currentRevision < Int64.max { currentRevision += 1 } else { ended = true }
        changes.send()
      }
    }
  }

  private func currentProfile() throws -> GatewayControlProfile? {
    if let stored = try database?.profiles().first(where: { $0.id == profileID }) {
      let current = GatewayControlProfile(grant: stored, persisted: true)
      adoptProfile(current)
      return current
    }
    return profile?.persisted == true ? nil : profile
  }

  private func refreshConsent(profile current: GatewayControlProfile? = nil) {
    guard let consent = fullAccessConsent else { return }
    let current = current ?? (try? currentProfile())
    let trust = consent.trustID.flatMap { id in try? database?.clientTrust(id: id) }
    let trusted =
      consent.lifetime == .thisSession
      || (trust?.fullAccessAllowed == true && trust?.revision == consent.trustRevision)
    guard
      current?.hasSameAuthorization(as: consent.profile) != true
        || current?.grant.allowedCallers.contains(caller) != true
        || !trusted
    else { return }
    clearConsent(mode: current?.grant.mode)
  }

  private func clearConsent(mode: GatewayPermissionMode?) {
    fullAccessConsent = nil
    accessLimit = mode == .readOnly ? .readOnly : .workspaceOperations
    if currentRevision < Int64.max { currentRevision += 1 } else { ended = true }
    changes.send()
  }

  static func == (lhs: GatewayControlSession, rhs: GatewayControlSession) -> Bool { lhs === rhs }

  var revision: Int64 {
    lock.withLock {
      _ = try? currentProfile()
      refreshConsent()
      return currentRevision
    }
  }

  var snapshot: GatewayControlSessionSnapshot {
    lock.withLock {
      let current = try? currentProfile()
      refreshConsent()
      return GatewayControlSessionSnapshot(
        id: id, principalID: principalID, profileID: profileID, caller: caller,
        revision: currentRevision, accessLimit: accessLimit, ended: ended,
        fullAccessConsent: fullAccessConsent, profile: current)
    }
  }

  func limitAccess(
    to mode: GatewayPermissionMode, expectedRevision: Int64, allowIncrease: Bool = true
  ) throws {
    try lock.withLock {
      _ = try currentProfile()
      refreshConsent()
      guard !ended, currentRevision == expectedRevision, currentRevision < Int64.max else {
        throw Self.denied("The control session changed. Reload before changing its access.")
      }
      guard allowIncrease || accessLimit != .readOnly || mode == .readOnly else {
        throw Self.denied("Remote clients can only reduce their session access.")
      }
      guard mode != .localFullAccess else {
        throw Self.denied("Full Access requires explicit local consent.")
      }
      fullAccessConsent = nil
      accessLimit = mode
      currentRevision += 1
    }
    changes.send()
  }

  func end() {
    lock.withLock {
      ended = true
      fullAccessConsent = nil
    }
    changes.send()
  }

  func apply(to grant: ProfileGrant, context: ExecutionContext) throws -> ProfileGrant {
    try lock.withLock {
      guard !ended, !principalID.isEmpty,
        context.trustedPrincipalID == principalID,
        context.profileID == profileID, context.caller == caller, grant.id == profileID
      else { throw Self.denied("The control session is no longer authorized for this caller.") }
      let current = try currentProfile()
      guard current != nil || profile == nil else {
        throw Self.denied("The client profile is no longer available.")
      }
      refreshConsent(profile: current)
      var effective = current?.grant ?? grant
      if fullAccessConsent != nil, accessLimit == .localFullAccess {
        effective.mode = .localFullAccess
        effective.fullShellEnabled = true
        effective.capabilityIDs = ["*"]
        effective.workspaceIDs = ["*"]
        effective.confirmationPolicy = .never
      }
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
      _ = try currentProfile()
      refreshConsent()
      guard !ended, expected == currentRevision else {
        throw Self.denied("The control session changed after this operation was prepared.")
      }
    }
  }

  /// Serialize the final non-suspending management commit with consent revocation.
  func withManagementAuthorization<Result>(
    context: ExecutionContext, expectedRevision: Int64, requiresFullAccess: Bool,
    operation: () throws -> Result
  ) throws -> Result {
    try lock.withLock {
      let current = try currentProfile()
      refreshConsent(profile: current)
      guard !ended, currentRevision == expectedRevision, context.controlSession === self,
        context.trustedPrincipalID == principalID, context.profileID == profileID,
        context.caller == caller, current?.grant.allowedCallers.contains(caller) == true
      else { throw Self.denied("The management session changed before publication.") }
      guard !requiresFullAccess || (accessLimit == .localFullAccess && fullAccessConsent != nil)
      else { throw Self.denied("This management operation requires approved Full Access.") }
      return try operation()
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

  func listToolsAsync(context: InvocationContext) async throws -> [MCPTool] {
    try await base.listToolsAsync(context: sessionContext(context))
  }

  func refreshTools(context: InvocationContext) async throws {
    try await base.refreshTools(context: sessionContext(context))
  }

  func callToolAsync(name: String, arguments: JSONValue?, context: InvocationContext)
    async throws -> JSONValue
  {
    try await base.callToolAsync(name: name, arguments: arguments, context: sessionContext(context))
  }

  func callToolForMCPAsync(name: String, arguments: JSONValue?, context: InvocationContext)
    async throws -> JSONValue
  {
    try await base.callToolForMCPAsync(
      name: name, arguments: arguments, context: sessionContext(context))
  }

  func toolChanges(context: InvocationContext) -> AsyncStream<Void> {
    let sources = [base.toolChanges(context: sessionContext(context)), session.changes.stream()]
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

  private func sessionContext(_ context: InvocationContext) -> InvocationContext {
    .init(admission: context.admission, session: session, continuation: context.continuation)
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
  package let fullAccessConsent: GatewayFullAccessConsent?
  package var profile: GatewayControlProfile? = nil
}
