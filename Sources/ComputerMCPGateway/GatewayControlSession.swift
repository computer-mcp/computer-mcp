import ComputerMCPCore
import ComputerMCPPermissions
import Foundation

package enum GatewayFullAccessLifetime: String, Codable, CaseIterable, Sendable {
  case thisSession = "this-session"
  case alwaysAllowClient = "always-allow-client"
}

/// The authority source distinguishes a manifest grant from a database override.
package struct GatewayControlProfile: Codable, Equatable, Sendable {
  package let grant: ProfileGrant
  package let persisted: Bool
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
package final class GatewayControlSession: GatewaySessionAuthority, @unchecked Sendable, Equatable {
  package let id = UUID().uuidString
  package let principalID: String
  package let profileID: GatewayProfileID
  package let caller: GatewayCallerKind
  package let changes = GatewayToolChangeBroadcaster()
  private let lock = NSLock()
  private var currentRevision: Int64 = 0
  private var accessLimit = ManagedPolicy()
  private var fullAccessConsent: GatewayFullAccessConsent?
  private let database: GatewayDatabase?
  private let permissionService: GatewayPermissionService?
  private var profile: GatewayControlProfile?
  private var ended = false

  package init(
    principalID: String, profileID: GatewayProfileID, caller: GatewayCallerKind,
    database: GatewayDatabase? = nil, profile: GatewayControlProfile? = nil,
    permissionService: GatewayPermissionService? = nil
  ) {
    self.principalID = principalID
    self.profileID = profileID
    self.caller = caller
    self.database = database
    self.profile = profile
    self.permissionService = permissionService
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
      try ensureConnection()
      let consent = GatewayFullAccessConsent(
        lifetime: .alwaysAllowClient, grantedAt: trust.updatedAt,
        profile: current, trustID: trust.id, trustRevision: trust.revision)
      guard
        try permissionService?.hasValidFullAccessConsent(
          subject: subject, connectionID: id, consent: consent) == true
      else { return }
      fullAccessConsent = consent
    }
  }

  /// Called only by the local owner control plane after explicit user consent.
  package func approveFullAccess(
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
      guard current.grant.fullAccess, accessLimit.allowsFullAccess else {
        throw Self.denied("Enable Full access in the profile before granting local consent.")
      }
      try ensureConnection()
      let consent = try database.recordFullAccessConsent(
        sessionID: id, principalID: principalID, profile: current, caller: caller,
        lifetime: lifetime, expectedTrustRevision: expectedTrustRevision, approver: approver)
      do {
        try permissionService?.setConnectionConsent(
          subject: subject, id: id, allowed: true, consent: consent)
      } catch {
        throw Self.denied("The durable permission connection could not select Full access.")
      }
      fullAccessConsent = consent
      currentRevision += 1
    }
    changes.send()
    return snapshot
  }

  /// Publication updates the baseline used by both current and retained invocations.
  package func updateProfile(_ current: GatewayControlProfile) {
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
        clearConsent()
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
        || (try? permissionService?.hasValidFullAccessConsent(
          subject: subject, connectionID: id, consent: consent)) != true
    else { return }
    clearConsent()
  }

  private func clearConsent() {
    fullAccessConsent = nil
    if let subject = try? subject {
      try? permissionService?.setConnectionConsent(subject: subject, id: id, allowed: false)
    }
    if currentRevision < Int64.max { currentRevision += 1 } else { ended = true }
    changes.send()
  }

  package static func == (lhs: GatewayControlSession, rhs: GatewayControlSession) -> Bool {
    lhs === rhs
  }

  package var revision: Int64 {
    lock.withLock {
      _ = try? currentProfile()
      refreshConsent()
      return currentRevision
    }
  }

  package var snapshot: GatewayControlSessionSnapshot {
    lock.withLock {
      let current = try? currentProfile()
      refreshConsent()
      return GatewayControlSessionSnapshot(
        id: id, principalID: principalID, profileID: profileID, caller: caller,
        revision: currentRevision, accessLimit: accessLimit, ended: ended,
        fullAccessConsent: fullAccessConsent, profile: current)
    }
  }

  package func limitAccess(
    to limits: ManagedPolicy, expectedRevision: Int64, allowIncrease: Bool = false
  ) throws {
    try lock.withLock {
      _ = try currentProfile()
      refreshConsent()
      guard !ended, currentRevision == expectedRevision, currentRevision < Int64.max,
        limits.narrows(accessLimit)
      else {
        throw Self.denied("A connection may only narrow its current permission limits.")
      }
      try ensureConnection()
      try permissionService?.limitConnection(subject: subject, id: id, to: limits)
      accessLimit = limits
      if !limits.allowsFullAccess { fullAccessConsent = nil }
      currentRevision += 1
    }
    changes.send()
  }

  package func end() {
    lock.withLock {
      ended = true
      fullAccessConsent = nil
      if let subject = try? subject {
        try? permissionService?.endConnection(subject: subject, id: id)
      }
    }
    changes.send()
  }

  package func apply(to grant: ProfileGrant, context: ExecutionContext) throws -> ProfileGrant {
    try lock.withLock { try appliedGrant(grant, context: context) }
  }

  /// Orders a short host mutation against consent changes. The closure must not
  /// suspend, perform subprocess I/O, or reenter this session.
  func withHostAuthorization<Result>(
    grant: ProfileGrant, context: ExecutionContext,
    operation: (ProfileGrant, GatewayFullAccessConsent?) throws -> Result
  ) throws -> Result {
    try lock.withLock {
      let effective = try appliedGrant(grant, context: context)
      return try operation(effective, fullAccessConsent)
    }
  }

  private func appliedGrant(_ grant: ProfileGrant, context: ExecutionContext) throws -> ProfileGrant
  {
    guard !ended, !principalID.isEmpty,
      context.trustedPrincipalID == principalID,
      context.profileID == profileID, context.caller == caller, grant.id == profileID
    else { throw Self.denied("The control session is no longer authorized for this caller.") }
    let current = try currentProfile()
    guard current != nil || profile == nil else {
      throw Self.denied("The client profile is no longer available.")
    }
    refreshConsent(profile: current)
    try ensureConnection()
    var effective = current?.grant ?? grant
    effective.fullAccess =
      effective.fullAccess && fullAccessConsent != nil && accessLimit.allowsFullAccess
    let original = effective.permissions
    let objects = Set(original.entries.keys).union(accessLimit.permissionCeilings.entries.keys)
    for permission in objects {
      let state = original.state(for: permission)
      let ceiling = accessLimit.permissionCeilings.state(for: permission)
      let hasCeiling =
        accessLimit.permissionCeilings.entries[permission] != nil
        || {
          switch permission {
          case .project: return accessLimit.permissionCeilings.entries[.project("*")] != nil
          case .plugin: return accessLimit.permissionCeilings.entries[.plugin("*")] != nil
          case .mcpServer: return accessLimit.permissionCeilings.entries[.mcpServer("*")] != nil
          default: return false
          }
        }()
      guard hasCeiling else { continue }
      switch (state, ceiling) {
      case (.granted(.write), .granted(.read)), (.granted(.all), .granted(.read)):
        try effective.permissions.set(.granted(.read), for: permission)
      case (_, .denied), (_, .notGranted): try effective.permissions.set(.denied, for: permission)
      default: break
      }
    }
    return effective
  }

  package func requireRevision(_ expected: Int64?) throws {
    try lock.withLock {
      _ = try currentProfile()
      refreshConsent()
      guard !ended, expected == currentRevision else {
        throw Self.denied("The control session changed after authorization.")
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
      guard
        !requiresFullAccess
          || (accessLimit.allowsFullAccess && fullAccessConsent != nil
            && current?.grant.fullAccess == true)
      else { throw Self.denied("This management operation requires approved Full Access.") }
      return try operation()
    }
  }

  private var subject: GatewayPermissionSubject {
    get throws {
      try GatewayPermissionSubject(
        context: ExecutionContext(
          caller: caller, profileID: profileID, trustedPrincipalID: principalID))
    }
  }

  private func ensureConnection() throws {
    guard let permissionService else {
      throw Self.denied("The durable permission service is unavailable.")
    }
    try permissionService.connect(subject: subject, id: id, attenuation: accessLimit)
  }

  private static func denied(_ message: String) -> GatewayToolError {
    .invalidArguments("[policy.control_session_denied] " + message)
  }
}

/// A connection borrows its principal's runtime; closing consent does not own runtime shutdown.
package struct GatewayControlSessionServing: GatewayAsyncToolServing {
  package let base: any GatewayAsyncToolServing
  package let session: GatewayControlSession

  package init(base: any GatewayAsyncToolServing, session: GatewayControlSession) {
    self.base = base
    self.session = session
  }

  package func listToolsAsync(context: InvocationContext) async throws -> [MCPTool] {
    try await base.listToolsAsync(context: sessionContext(context))
  }

  package func refreshTools(context: InvocationContext) async throws {
    try await base.refreshTools(context: sessionContext(context))
  }

  package func callToolAsync(name: String, arguments: JSONValue?, context: InvocationContext)
    async throws -> JSONValue
  {
    try await base.callToolAsync(name: name, arguments: arguments, context: sessionContext(context))
  }

  package func callToolForMCPAsync(name: String, arguments: JSONValue?, context: InvocationContext)
    async throws -> JSONValue
  {
    try await base.callToolForMCPAsync(
      name: name, arguments: arguments, context: sessionContext(context))
  }

  package func toolChanges(context: InvocationContext) -> AsyncStream<Void> {
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

  package func shutdown() async { session.end() }
}

package struct GatewayControlSessionSnapshot: Codable, Equatable, Sendable, Identifiable {
  package let id: String
  package let principalID: String
  package let profileID: GatewayProfileID
  package let caller: GatewayCallerKind
  package let revision: Int64
  package let accessLimit: ManagedPolicy
  package let ended: Bool
  package let fullAccessConsent: GatewayFullAccessConsent?
  package var profile: GatewayControlProfile? = nil
}
