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
  /// Profiles a remote tunnel client may be approved with.
  var remoteProfiles: [GatewayProfileID] = []
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
  func approveOAuthRequest(_ request: OAuthPendingAuthorization, profile: GatewayProfileID)
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
  func approveOAuthRequest(_ request: OAuthPendingAuthorization, profile: GatewayProfileID)
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

  /// The profile the owner picked for each pending sign-in.
  @Published var oauthProfileChoices: [String: GatewayProfileID] = [:]

  /// Profiles that admit tunnel clients, read-only Cloudflare Observe first.
  var oauthProfileOptions: [GatewayProfileID] {
    let profiles = snapshot?.remoteProfiles ?? []
    return profiles.filter { $0 == .cloudflareObserve }
      + profiles.filter { $0 != .cloudflareObserve }
  }

  /// The owner's pick when it is still offered, otherwise the first option.
  func oauthProfile(for request: OAuthPendingAuthorization) -> GatewayProfileID? {
    let options = oauthProfileOptions
    if let choice = oauthProfileChoices[request.id], options.contains(choice) { return choice }
    return options.first
  }

  @discardableResult
  func approve(_ request: OAuthPendingAuthorization) async -> Bool {
    guard let profile = oauthProfile(for: request) else { return false }
    let approved = await perform {
      try await self.controlPlane.approveOAuthRequest(request, profile: profile)
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
    (snapshot?.oauthRequests ?? []).sorted { $0.createdAt < $1.createdAt }
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
