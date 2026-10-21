import Combine
import ComputerMCPAuthorization
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import CryptoKit
import Foundation

struct ClientAccessSnapshot: Sendable {
  var sessions: [GatewayControlSessionSnapshot]
  var trusts: [GatewayClientTrust]
  var oauthRequests: [OAuthPendingAuthorization] = []
  var oauthGrants: [OAuthGrant] = []
  /// Profiles the control plane accepts when approving a tunnel client.
  var remoteProfiles: [ProfileGrant] = []
  /// Public hostnames keyed by Cloudflare tunnel ID.
  var tunnelHosts: [String: String] = [:]
}

/// A profile the owner picked for a sign-in, with the access level they saw.
struct OAuthProfileChoice: Equatable {
  var id: GatewayProfileID
  var mode: GatewayPermissionMode
}

@MainActor
protocol ClientAccessManaging {
  func fetchClientAccess() async throws -> ClientAccessSnapshot
  func grantClientFullAccess(
    id: String, lifetime: GatewayFullAccessLifetime,
    expectedRevision: Int64, expectedTrustRevision: Int64
  ) async throws
  func limitClientAccess(id: String, mode: GatewayPermissionMode, expectedRevision: Int64)
    async throws
  func endClientAccess(id: String, expectedRevision: Int64) async throws
  func revokeClientTrust(id: String, expectedRevision: Int64) async throws
  func approveOAuthRequest(
    _ request: OAuthPendingAuthorization, profile: GatewayProfileID,
    expectedAuthorizationRevision: Int64
  )
    async throws
  func denyOAuthRequest(_ request: OAuthPendingAuthorization) async throws
  func revokeOAuthGrant(id: String) async throws
}

extension ClientAccessManaging {
  func fetchClientAccess() async throws -> ClientAccessSnapshot { throw unavailableClientAccess() }
  func grantClientFullAccess(
    id: String, lifetime: GatewayFullAccessLifetime,
    expectedRevision: Int64, expectedTrustRevision: Int64
  ) async throws { throw unavailableClientAccess() }
  func limitClientAccess(id: String, mode: GatewayPermissionMode, expectedRevision: Int64)
    async throws
  {
    throw unavailableClientAccess()
  }
  func endClientAccess(id: String, expectedRevision: Int64) async throws {
    throw unavailableClientAccess()
  }
  func revokeClientTrust(id: String, expectedRevision: Int64) async throws {
    throw unavailableClientAccess()
  }
  func approveOAuthRequest(
    _ request: OAuthPendingAuthorization, profile: GatewayProfileID,
    expectedAuthorizationRevision: Int64
  )
    async throws
  {
    throw unavailableClientAccess()
  }
  func denyOAuthRequest(_ request: OAuthPendingAuthorization) async throws {
    throw unavailableClientAccess()
  }
  func revokeOAuthGrant(id: String) async throws { throw unavailableClientAccess() }
  private func unavailableClientAccess() -> AppControlPlaneError {
    .unavailable("Client access is unavailable. Refresh to check current connections.")
  }
}

struct ClientConsentDraft: Identifiable {
  let id = UUID()
  let session: GatewayControlSessionSnapshot
  let trustRevision: Int64
  var lifetime: GatewayFullAccessLifetime = .thisSession
}

@MainActor
final class ClientAccessModel: ObservableObject {
  @Published private(set) var snapshot: ClientAccessSnapshot?
  @Published private(set) var isAvailable = false
  @Published private(set) var isRefreshing = false
  @Published private(set) var isSaving = false
  @Published private(set) var errorMessage: String?
  @Published var pendingConsent: ClientConsentDraft?

  private let controlPlane: any ClientAccessManaging
  private var refreshGeneration = 0

  init(controlPlane: any ClientAccessManaging) { self.controlPlane = controlPlane }

  var controllingSessions: [GatewayControlSessionSnapshot] {
    (snapshot?.sessions ?? []).filter {
      $0.currentAccess == .workspaceOperations || $0.currentAccess == .localFullAccess
    }
  }

  var statusText: String {
    guard isAvailable,
      snapshot?.sessions.allSatisfy({ $0.ended || $0.profile != nil }) == true
    else { return AppLocalization.string("Client access status unavailable") }
    if !pendingOAuthRequests.isEmpty {
      return AppLocalization.formatted(
        "Sign-in requests waiting: %@", String(pendingOAuthRequests.count))
    }
    return controllingSessions.isEmpty
      ? AppLocalization.string("No clients have control")
      : AppLocalization.formatted("Clients with control: %@", String(controllingSessions.count))
  }

  func reload() async {
    guard !isSaving else { return }
    await load()
  }

  private func load() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    isRefreshing = true
    defer { if generation == refreshGeneration { isRefreshing = false } }
    do {
      let next = try await controlPlane.fetchClientAccess()
      guard generation == refreshGeneration else { return }
      snapshot = next
      isAvailable = true
      errorMessage = nil
    } catch {
      guard generation == refreshGeneration else { return }
      isAvailable = false
      errorMessage = AppLocalization.errorDescription(error)
    }
  }

  func requestFullAccess(_ session: GatewayControlSessionSnapshot) {
    guard isAvailable, !isSaving, !session.ended,
      session.profile?.grant.allowedCallers.contains(session.caller) == true
    else { return }
    let trust = snapshot?.trusts.first {
      $0.principalID == session.principalID && $0.profileID == session.profileID
        && $0.caller == session.caller
    }
    pendingConsent = ClientConsentDraft(session: session, trustRevision: trust?.revision ?? 0)
  }

  var consentIsCurrent: Bool {
    guard let draft = pendingConsent,
      let current = snapshot?.sessions.first(where: { $0.id == draft.session.id }),
      !current.ended, current.revision == draft.session.revision,
      current.profile?.grant.allowedCallers.contains(current.caller) == true
    else { return false }
    let trust = snapshot?.trusts.first {
      $0.principalID == current.principalID && $0.profileID == current.profileID
        && $0.caller == current.caller
    }
    return (trust?.revision ?? 0) == draft.trustRevision
  }

  @discardableResult
  func approve() async -> Bool {
    guard let draft = pendingConsent, consentIsCurrent else { return false }
    let approved = await perform {
      try await self.controlPlane.grantClientFullAccess(
        id: draft.session.id, lifetime: draft.lifetime,
        expectedRevision: draft.session.revision, expectedTrustRevision: draft.trustRevision)
    }
    if approved, pendingConsent?.id == draft.id { pendingConsent = nil }
    return approved
  }

  func limit(_ session: GatewayControlSessionSnapshot, to mode: GatewayPermissionMode) async {
    guard mode != .localFullAccess else { return }
    _ = await perform {
      try await self.controlPlane.limitClientAccess(
        id: session.id, mode: mode, expectedRevision: session.revision)
    }
  }

  func end(_ session: GatewayControlSessionSnapshot) async {
    _ = await perform {
      try await self.controlPlane.endClientAccess(
        id: session.id, expectedRevision: session.revision)
    }
  }

  func revoke(_ trust: GatewayClientTrust) async {
    _ = await perform {
      try await self.controlPlane.revokeClientTrust(id: trust.id, expectedRevision: trust.revision)
    }
  }

  @Published private(set) var oauthProfileChoices: [String: OAuthProfileChoice] = [:]

  /// Approvable profiles from the least to the most access, Cloudflare Observe first.
  var oauthProfileOptions: [ProfileGrant] {
    (snapshot?.remoteProfiles ?? []).sorted {
      ($0.mode.accessRank, $0.id == .cloudflareObserve ? 0 : 1, $0.id.rawValue)
        < ($1.mode.accessRank, $1.id == .cloudflareObserve ? 0 : 1, $1.id.rawValue)
    }
  }

  /// The owner's pick while it keeps the access level they saw, otherwise the first
  /// read-only profile. Nil means the owner must choose.
  func oauthProfile(for request: OAuthPendingAuthorization) -> ProfileGrant? {
    let options = oauthProfileOptions
    if let choice = oauthProfileChoices[request.id] {
      return options.first { $0.id == choice.id && $0.mode == choice.mode }
    }
    return options.first { $0.mode == .readOnly }
  }

  func chooseOAuthProfile(_ id: GatewayProfileID, for request: OAuthPendingAuthorization) {
    guard let profile = oauthProfileOptions.first(where: { $0.id == id }) else { return }
    oauthProfileChoices[request.id] = OAuthProfileChoice(id: profile.id, mode: profile.mode)
  }

  /// Approves only with the profile and access level the owner reviewed, before expiry.
  @discardableResult
  func approve(_ request: OAuthPendingAuthorization, reviewed: ProfileGrant) async -> Bool {
    guard request.expiresAt > Date() else {
      errorMessage = AppLocalization.string(
        "This sign-in request expired. Ask the client to sign in again.")
      return false
    }
    guard let current = oauthProfile(for: request), current.id == reviewed.id,
      current.mode == reviewed.mode, current.authorizationRevision == reviewed.authorizationRevision
    else {
      errorMessage = AppLocalization.string(
        "The profile for this sign-in changed. Review it and approve again.")
      return false
    }
    let approved = await perform {
      try await self.controlPlane.approveOAuthRequest(
        request, profile: reviewed.id, expectedAuthorizationRevision: reviewed.authorizationRevision
      )
    }
    if approved { oauthProfileChoices[request.id] = nil }
    return approved
  }

  func deny(_ request: OAuthPendingAuthorization) async {
    if await perform({ try await self.controlPlane.denyOAuthRequest(request) }) {
      oauthProfileChoices[request.id] = nil
    }
  }

  func revoke(_ grant: OAuthGrant) async {
    _ = await perform { try await self.controlPlane.revokeOAuthGrant(id: grant.id) }
  }

  var pendingOAuthRequests: [OAuthPendingAuthorization] {
    let now = Date()
    return (snapshot?.oauthRequests ?? []).filter { $0.expiresAt > now }
      .sorted { $0.createdAt < $1.createdAt }
  }

  var activeOAuthGrants: [OAuthGrant] {
    (snapshot?.oauthGrants ?? []).filter { $0.revokedAt == nil }
      .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
  }

  private func perform(_ operation: () async throws -> Void) async -> Bool {
    guard !isSaving, isAvailable else { return false }
    isSaving = true
    refreshGeneration += 1
    isRefreshing = false
    errorMessage = nil
    defer { isSaving = false }
    do {
      try Task.checkCancellation()
      try await operation()
      await load()
      return true
    } catch {
      await load()
      errorMessage = AppLocalization.errorDescription(error)
      return false
    }
  }
}

extension GatewayPermissionMode {
  /// Orders modes from the least to the most access.
  var accessRank: Int {
    switch self {
    case .readOnly: 0
    case .workspaceOperations: 1
    case .localFullAccess: 2
    }
  }

  var clientAccessLabel: String {
    switch self {
    case .readOnly: "Observe"
    case .workspaceOperations: "Control — Restricted Access"
    case .localFullAccess: "Control — Full Access"
    }
  }
}

extension GatewayControlSessionSnapshot {
  var currentAccess: GatewayPermissionMode? {
    guard !ended, profile?.grant.allowedCallers.contains(caller) == true else { return nil }
    guard fullAccessConsent == nil else { return .localFullAccess }
    return accessLimit == .readOnly || profile?.grant.mode == .readOnly
      ? .readOnly : .workspaceOperations
  }
}

func clientAccessIdentity(_ principalID: String) -> String {
  let fingerprint = SHA256.hash(data: Data(principalID.utf8)).prefix(4)
    .map { String(format: "%02X", $0) }.joined()
  return AppLocalization.formatted("Client %@", fingerprint)
}

extension GatewayCallerKind {
  var clientAccessLabel: String {
    switch self {
    case .localApp: "Computer MCP"
    case .localCLI: "Local command line"
    case .localMCP: "Local MCP client"
    case .secureTunnel: "ChatGPT connection"
    case .cloudflareTunnel: "Remote MCP client"
    }
  }
}
