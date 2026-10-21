import ComputerMCPAuthorization
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPTunnels
import Foundation

package struct OAuthPendingAuthorization: Codable, Equatable, Sendable, Identifiable {
  package let id: String
  package let tunnelID: String
  package let pairingCode: String
  package let clientHost: String
  package let redirectHost: String
  package let createdAt: Date
  package let expiresAt: Date

  package init(
    id: String, tunnelID: String, pairingCode: String, clientHost: String, redirectHost: String,
    createdAt: Date, expiresAt: Date
  ) {
    self.id = id
    self.tunnelID = tunnelID
    self.pairingCode = pairingCode
    self.clientHost = clientHost
    self.redirectHost = redirectHost
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }

  init(_ request: OAuthAuthorizationRequest) {
    id = request.id
    tunnelID = request.tunnelID
    pairingCode = request.pairingCode
    clientHost = request.clientHost
    redirectHost = request.redirectHost
    createdAt = request.createdAt
    expiresAt = request.expiresAt
  }
}

extension AppControlPlaneService {
  func oauthServer(for profile: CloudflareTunnelConfiguration) -> OAuthAuthorizationServer {
    let sessions = cloudflareOAuthSessions[profile.id] ?? GatewayOAuthSessions()
    cloudflareOAuthSessions[profile.id] = sessions
    return OAuthAuthorizationServer(
      configuration: .init(
        tunnelID: profile.id, tunnelName: profile.tunnelName,
        hostname: profile.publicHostname, clientAllowlist: profile.oauthClientAllowlist),
      store: database, endSessions: { principalID in await sessions.end(principalID: principalID) })
  }

  package func oauthAuthorizations(tunnelID: String? = nil, approver: GatewayCallerKind = .localApp)
    async throws -> [OAuthPendingAuthorization]
  {
    try requireOAuthOwner(approver)
    var requests: [OAuthPendingAuthorization] = []
    for profile in try cloudflareTunnelConfigurations()
    where profile.oauthEnabled && (tunnelID == nil || profile.id == tunnelID) {
      requests += try await oauthServer(for: profile).pendingRequests(approver: approver).map(
        OAuthPendingAuthorization.init)
    }
    return requests.sorted { $0.id < $1.id }
  }

  package func authorizeOAuthClient(
    pairingCode: String, tunnelID: String? = nil,
    profileID: GatewayProfileID? = nil, expectedAuthorizationDigest: String? = nil,
    approver: GatewayCallerKind = .localApp
  ) async throws -> OAuthGrant {
    let requests = try await oauthAuthorizations(tunnelID: tunnelID, approver: approver)
      .filter { $0.pairingCode == pairingCode.uppercased() }
    guard requests.count == 1, let request = requests.first else { throw OAuthError.invalidRequest }
    await beginCloudflareCredentialMutation(profileID: request.tunnelID)
    defer { endCloudflareCredentialMutation(profileID: request.tunnelID) }
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    guard
      try database.oauthTransaction({ transaction in
        try transaction.requests(tunnelID: request.tunnelID).contains {
          $0.id == request.id && $0.status == .pending
        }
      })
    else { throw OAuthError.invalidRequest }
    guard
      let tunnel = try cloudflareTunnelConfigurations().first(where: {
        $0.id == request.tunnelID && $0.oauthEnabled
      }),
      let profile = try await profileGrants().first(where: {
        $0.id == (profileID ?? .cloudflareObserve)
      })
    else { throw OAuthError.invalidRequest }
    if let expectedAuthorizationDigest,
      try OAuthApprovalProfile(grant: profile).authorizationDigest != expectedAuthorizationDigest
    {
      throw GatewayToolError.invalidArguments(
        "Profile authorization changed. Reload the profile and review it before approving."
      )
    }
    guard profileID != nil || profile.mode == .readOnly else {
      throw GatewayToolError.invalidArguments(
        "cloudflare-observe is not read-only. Choose an explicit profile with --profile in the CLI or profile_id in the control plane."
      )
    }
    try await oauthApprovalWillCommit()
    try Task.checkCancellation()
    return try await oauthServer(for: tunnel).approve(
      pairingCode: request.pairingCode, profile: profile, approver: approver)
  }

  package func denyOAuthAuthorization(
    pairingCode: String, tunnelID: String? = nil,
    approver: GatewayCallerKind = .localApp
  ) async throws {
    let requests = try await oauthAuthorizations(tunnelID: tunnelID, approver: approver)
      .filter { $0.pairingCode == pairingCode.uppercased() }
    guard requests.count == 1, let request = requests.first,
      let tunnel = try cloudflareTunnelConfigurations().first(where: { $0.id == request.tunnelID })
    else { throw OAuthError.invalidRequest }
    try await oauthServer(for: tunnel).deny(pairingCode: request.pairingCode, approver: approver)
  }

  package func oauthGrants(tunnelID: String? = nil, approver: GatewayCallerKind = .localApp)
    async throws -> [OAuthGrant]
  {
    try requireOAuthOwner(approver)
    var grants: [OAuthGrant] = []
    for profile in try cloudflareTunnelConfigurations()
    where tunnelID == nil || profile.id == tunnelID {
      grants += try await oauthServer(for: profile).grants(approver: approver)
    }
    return grants.sorted { $0.id < $1.id }
  }

  package func revokeOAuthGrant(id: String, approver: GatewayCallerKind = .localApp) async throws {
    try requireOAuthOwner(approver)
    let grant = try database.oauthTransaction { try $0.grant(id: id) }
    guard let grant,
      let tunnel = try cloudflareTunnelConfigurations().first(where: { $0.id == grant.tunnelID })
    else { throw OAuthError.invalidRequest }
    try await oauthServer(for: tunnel).revokeGrant(id: id, approver: approver)
  }

  private func requireOAuthOwner(_ caller: GatewayCallerKind) throws {
    guard caller == .localApp || caller == .localCLI else { throw OAuthError.accessDenied }
  }
}
