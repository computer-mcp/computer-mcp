import ComputerMCPCore
import Foundation

package actor OAuthAuthorizationServer {
  package nonisolated let configuration: OAuthServerConfiguration
  private let store: any OAuthStore
  private let identifier: any OAuthClientIdentifying
  private let clock: @Sendable () -> Date
  private var limiter = OAuthRateLimiter()
  private var lastFailureAudit: Date?

  package init(
    configuration: OAuthServerConfiguration, store: any OAuthStore,
    identifier: any OAuthClientIdentifying = CIMDClientIdentifier(),
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.store = store
    self.identifier = identifier
    self.clock = clock
  }

  package func checkRate(address: String) throws {
    guard limiter.allow(address: address, now: clock()) else { throw OAuthError.rateLimited }
  }

  package func authorize(
    _ fields: [String: String], address: String,
    clientAllowlist: [String]? = nil
  ) async throws -> OAuthPairing {
    try checkRate(address: address)
    guard fields["response_type"] == "code", let clientID = fields["client_id"],
      let redirectURI = fields["redirect_uri"], let state = fields["state"], !state.isEmpty,
      state.utf8.count <= 2_048, let challenge = fields["code_challenge"], challenge.count == 43,
      challenge.utf8.allSatisfy({ Self.base64URLCharacters.contains($0) }),
      fields["code_challenge_method"] == "S256", fields["resource"] == configuration.resource,
      fields["scope"] == nil || fields["scope"] == "mcp"
    else { throw OAuthError.invalidRequest }
    try await identifier.identify(
      clientID: clientID, redirectURI: redirectURI,
      allowlist: clientAllowlist ?? configuration.clientAllowlist)
    let now = clock()
    let statusToken = OAuthSecret.generate()
    return try store.oauthTransaction { transaction in
      try expireRequests(transaction, now: now)
      try transaction.prune(before: now)
      let requests = try transaction.requests(tunnelID: configuration.tunnelID)
      guard
        requests.filter({ $0.status == .pending || $0.status == .approved }).count
          < OAuthLimits.maxPendingRequests
      else { throw OAuthError.rateLimited }
      let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
      var pairingCode: String
      repeat {
        pairingCode = String((0..<6).map { _ in alphabet.randomElement()! })
      } while requests.contains(where: { $0.pairingCode == pairingCode })
      let request = OAuthAuthorizationRequest(
        id: UUID().uuidString, pairingCode: pairingCode,
        statusDigest: OAuthSecret.digest(statusToken), tunnelID: configuration.tunnelID,
        clientID: clientID, redirectURI: redirectURI, state: state, codeChallenge: challenge,
        resource: configuration.resource, scope: "mcp", createdAt: now,
        expiresAt: now.addingTimeInterval(OAuthLimits.requestLifetime), status: .pending)
      try transaction.save(request)
      try transaction.audit(audit("authorization_requested", now: now))
      return OAuthPairing(request: request, statusToken: statusToken)
    }
  }

  package func pendingRequests(approver: GatewayCallerKind) throws -> [OAuthAuthorizationRequest] {
    try requireLocal(approver)
    return try store.oauthTransaction { transaction in
      try expireRequests(transaction, now: clock())
      return try transaction.requests(tunnelID: configuration.tunnelID).filter {
        $0.status == .pending
      }
    }
  }

  package func approve(
    pairingCode: String, profile: ProfileGrant = .cloudflareObserve,
    approver: GatewayCallerKind
  ) throws -> OAuthGrant {
    try requireLocal(approver)
    guard profile.id != .localAdmin, profile.allowedCallers.contains(.cloudflareTunnel) else {
      throw OAuthError.accessDenied
    }
    let now = clock()
    return try store.oauthTransaction { transaction in
      try expireRequests(transaction, now: now)
      guard
        var request = try transaction.requests(tunnelID: configuration.tunnelID).first(where: {
          $0.pairingCode == pairingCode && $0.status == .pending
            && $0.resource == configuration.resource
        })
      else { throw OAuthError.invalidRequest }
      let grant = OAuthGrant(
        id: UUID().uuidString, tunnelID: configuration.tunnelID,
        clientID: request.clientID, redirectHost: request.redirectHost, profileID: profile.id,
        resource: request.resource, scope: request.scope, createdAt: now)
      request.status = .approved
      request.grantID = grant.id
      try transaction.save(grant)
      try transaction.save(request)
      try transaction.audit(
        audit("authorization_approved", grant: grant, caller: approver, now: now))
      return grant
    }
  }

  package func deny(pairingCode: String, approver: GatewayCallerKind) throws {
    try requireLocal(approver)
    let now = clock()
    try store.oauthTransaction { transaction in
      try expireRequests(transaction, now: now)
      guard
        var request = try transaction.requests(tunnelID: configuration.tunnelID).first(where: {
          $0.pairingCode == pairingCode && $0.status == .pending
        })
      else { throw OAuthError.invalidRequest }
      request.status = .denied
      try transaction.save(request)
      try transaction.audit(audit("authorization_denied", caller: approver, now: now, denied: true))
    }
  }

  package func status(statusToken: String, address: String) throws -> OAuthPairingStatus {
    try checkRate(address: address)
    let now = clock()
    return try store.oauthTransaction { transaction in
      try expireRequests(transaction, now: now)
      guard
        var request = try transaction.requests(tunnelID: configuration.tunnelID).first(where: {
          $0.statusDigest == OAuthSecret.digest(statusToken)
            && $0.resource == configuration.resource
        })
      else { throw OAuthError.invalidRequest }
      switch request.status {
      case .pending: return .pending
      case .approved:
        guard let id = request.grantID, let grant = try transaction.grant(id: id),
          grant.revokedAt == nil
        else { return .redirect(try redirect(request, error: "access_denied")) }
        guard limiter.allowGrant(id, now: now) else { throw OAuthError.rateLimited }
        let code = OAuthSecret.generate()
        try transaction.save(
          OAuthAuthorizationCode(
            digest: OAuthSecret.digest(code), grantID: id,
            clientID: request.clientID, redirectURI: request.redirectURI,
            codeChallenge: request.codeChallenge,
            resource: request.resource, scope: request.scope,
            expiresAt: now.addingTimeInterval(OAuthLimits.codeLifetime)))
        request.status = .delivered
        try transaction.save(request)
        return .redirect(try redirect(request, code: code))
      case .denied, .expired, .delivered:
        return .redirect(try redirect(request, error: "access_denied"))
      }
    }
  }

  package func token(_ fields: [String: String], address: String) throws -> OAuthTokenResponse {
    try checkRate(address: address)
    guard let clientID = fields["client_id"], !clientID.isEmpty, fields["client_secret"] == nil
    else { throw OAuthError.invalidClient }
    guard fields["resource"] == configuration.resource,
      fields["scope"] == nil || fields["scope"] == "mcp"
    else { throw OAuthError.invalidRequest }
    let now = clock()
    // Protocol errors may commit security state (notably refresh reuse revocation).
    let result: Result<OAuthTokenResponse, OAuthError> = try store.oauthTransaction { transaction in
      switch fields["grant_type"] {
      case "authorization_code":
        guard let value = fields["code"],
          var code = try transaction.code(digest: OAuthSecret.digest(value)),
          code.usedAt == nil, code.expiresAt > now, code.clientID == clientID,
          code.redirectURI == fields["redirect_uri"], code.resource == configuration.resource,
          let verifier = fields["code_verifier"], (43...128).contains(verifier.utf8.count),
          verifier.utf8.allSatisfy({ Self.verifierCharacters.contains($0) }),
          OAuthSecret.challenge(verifier) == code.codeChallenge,
          var grant = try liveGrant(code.grantID, clientID: clientID, transaction: transaction)
        else { return .failure(.invalidGrant) }
        guard limiter.allowGrant(grant.id, now: now) else { return .failure(.rateLimited) }
        code.usedAt = now
        try transaction.save(code)
        return .success(
          try issueTokens(
            grant: &grant, transaction: transaction, now: now, action: "tokens_issued"))
      case "refresh_token":
        guard let value = fields["refresh_token"],
          var token = try transaction.token(digest: OAuthSecret.digest(value)),
          token.kind == .refresh, token.resource == configuration.resource,
          var grant = try liveGrant(token.grantID, clientID: clientID, transaction: transaction)
        else { return .failure(.invalidGrant) }
        if token.rotatedAt != nil {
          grant.revokedAt = now
          try transaction.save(grant)
          try transaction.audit(audit("refresh_token_reuse", grant: grant, now: now, denied: true))
          try transaction.audit(audit("grant_revoked", grant: grant, now: now))
          return .failure(.invalidGrant)
        }
        guard limiter.allowGrant(grant.id, now: now) else { return .failure(.rateLimited) }
        guard token.expiresAt > now, token.revokedAt == nil else { return .failure(.invalidGrant) }
        token.rotatedAt = now
        try transaction.save(token)
        return .success(
          try issueTokens(
            grant: &grant, transaction: transaction, now: now, action: "tokens_refreshed"))
      default: return .failure(.invalidRequest)
      }
    }
    return try result.get()
  }

  package func authenticate(accessToken: String, address: String) throws -> OAuthGrant? {
    try checkRate(address: address)
    let now = clock()
    return try store.oauthTransaction { transaction in
      guard let token = try transaction.token(digest: OAuthSecret.digest(accessToken)),
        token.kind == .access, token.revokedAt == nil, token.expiresAt > now,
        token.resource == configuration.resource,
        var grant = try transaction.grant(id: token.grantID), grant.revokedAt == nil,
        grant.tunnelID == configuration.tunnelID, grant.resource == configuration.resource
      else { return nil }
      guard limiter.allowGrant(grant.id, now: now) else {
        throw OAuthError.rateLimited
      }
      grant.lastUsedAt = now
      try transaction.save(grant)
      return grant
    }
  }

  package func revoke(_ fields: [String: String], address: String) throws {
    try checkRate(address: address)
    guard let clientID = fields["client_id"], !clientID.isEmpty, fields["client_secret"] == nil
    else { throw OAuthError.invalidClient }
    guard let value = fields["token"], !value.isEmpty else { throw OAuthError.invalidRequest }
    let now = clock()
    try store.oauthTransaction { transaction in
      guard var token = try transaction.token(digest: OAuthSecret.digest(value)),
        var grant = try liveGrant(token.grantID, clientID: clientID, transaction: transaction)
      else { return }
      guard limiter.allowGrant(grant.id, now: now) else { throw OAuthError.rateLimited }
      token.revokedAt = now
      try transaction.save(token)
      try transaction.audit(audit("token_revoked", grant: grant, now: now))
      if token.kind == .refresh {
        grant.revokedAt = now
        try transaction.save(grant)
        try transaction.audit(audit("grant_revoked", grant: grant, now: now))
      }
    }
  }

  package func grants(approver: GatewayCallerKind) throws -> [OAuthGrant] {
    try requireLocal(approver)
    return try store.oauthTransaction { try $0.grants(tunnelID: configuration.tunnelID) }
  }

  package func revokeGrant(id: String, approver: GatewayCallerKind) throws {
    try requireLocal(approver)
    let now = clock()
    try store.oauthTransaction { transaction in
      guard var grant = try transaction.grant(id: id), grant.tunnelID == configuration.tunnelID
      else { throw OAuthError.invalidRequest }
      if grant.revokedAt == nil {
        grant.revokedAt = now
        try transaction.save(grant)
        try transaction.audit(audit("grant_revoked", grant: grant, caller: approver, now: now))
      }
    }
  }

  /// One audit row per interval summarizes failed credentials, never their values.
  package func authenticationFailed() throws {
    let now = clock()
    if lastFailureAudit == nil
      || now.timeIntervalSince(lastFailureAudit!) >= OAuthLimits.failureAuditInterval
    {
      let event = audit("authentication_failed", now: now, denied: true)
      try store.oauthTransaction { try $0.audit(event) }
      lastFailureAudit = now
    }
  }

  private func liveGrant(_ id: String, clientID: String, transaction: any OAuthStoreTransaction)
    throws -> OAuthGrant?
  {
    guard let grant = try transaction.grant(id: id), grant.revokedAt == nil,
      grant.clientID == clientID, grant.tunnelID == configuration.tunnelID,
      grant.resource == configuration.resource
    else { return nil }
    return grant
  }

  private func issueTokens(
    grant: inout OAuthGrant, transaction: any OAuthStoreTransaction,
    now: Date, action: String
  ) throws -> OAuthTokenResponse {
    let access = OAuthSecret.generate()
    let refresh = OAuthSecret.generate()
    try transaction.save(
      OAuthToken(
        digest: OAuthSecret.digest(access), kind: .access,
        grantID: grant.id, resource: grant.resource, scope: grant.scope,
        expiresAt: now.addingTimeInterval(OAuthLimits.accessTokenLifetime)))
    try transaction.save(
      OAuthToken(
        digest: OAuthSecret.digest(refresh), kind: .refresh,
        grantID: grant.id, resource: grant.resource, scope: grant.scope,
        expiresAt: now.addingTimeInterval(OAuthLimits.refreshTokenLifetime)))
    grant.lastUsedAt = now
    try transaction.save(grant)
    try transaction.audit(audit(action, grant: grant, now: now))
    return OAuthTokenResponse(accessToken: access, refreshToken: refresh)
  }

  private func expireRequests(_ transaction: any OAuthStoreTransaction, now: Date) throws {
    for var request in try transaction.requests(tunnelID: configuration.tunnelID)
    where (request.status == .pending || request.status == .approved) && request.expiresAt <= now {
      request.status = .expired
      try transaction.save(request)
      try transaction.audit(audit("authorization_expired", now: now, denied: true))
    }
  }

  private func redirect(
    _ request: OAuthAuthorizationRequest, code: String? = nil, error: String? = nil
  ) throws -> String {
    guard var url = URLComponents(string: request.redirectURI) else {
      throw OAuthError.invalidRequest
    }
    var items = url.queryItems ?? []
    items += [
      URLQueryItem(name: "state", value: request.state),
      URLQueryItem(name: "iss", value: configuration.issuer),
    ]
    if let code { items.append(URLQueryItem(name: "code", value: code)) }
    if let error { items.append(URLQueryItem(name: "error", value: error)) }
    url.queryItems = items
    guard let result = url.string else { throw OAuthError.invalidRequest }
    return result
  }

  private func requireLocal(_ caller: GatewayCallerKind) throws {
    guard caller == .localApp || caller == .localCLI else { throw OAuthError.accessDenied }
  }

  private func audit(
    _ action: String, grant: OAuthGrant? = nil, caller: GatewayCallerKind = .cloudflareTunnel,
    now: Date, denied: Bool = false
  ) -> AuditEvent {
    AuditEvent(
      occurredAt: now, requestID: UUID().uuidString, caller: caller,
      principalDigest: grant.flatMap { AuditEvent.verifiedPrincipalDigest($0.principalID) },
      transport: "cloudflare_tunnel", tunnelInstanceID: configuration.tunnelID,
      tunnelProfileID: configuration.tunnelName, profileID: grant?.profileID ?? .cloudflareObserve,
      capabilityID: "oauth." + action, decision: denied ? .denied : .allowed)
  }

  private static let base64URLCharacters = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
  private static let verifierCharacters = base64URLCharacters.union(".~".utf8)
}
