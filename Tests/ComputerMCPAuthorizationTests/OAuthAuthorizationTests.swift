import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPAuthorization

struct OAuthAuthorizationTests {
  @Test func authorizationCodeAndRefreshFlow() async throws {
    let flow = Flow()
    let (grant, code) = try await flow.approve()
    let issued = try await flow.exchange(code)
    #expect(issued.accessToken.count == 43)
    #expect(issued.refreshToken.count == 43)
    #expect(issued.accessToken != issued.refreshToken)
    #expect(issued.expiresIn == 3_600)
    let authenticated = try await flow.server.authenticate(
      accessToken: issued.accessToken, address: "browser")
    #expect(authenticated?.principalID == "oauth:" + grant.id)
    #expect(authenticated?.profileID == .cloudflareObserve)
    let refreshed = try await flow.refresh(issued.refreshToken)
    #expect(refreshed.accessToken != issued.accessToken)
    #expect(refreshed.refreshToken != issued.refreshToken)
    #expect(
      try await flow.server.authenticate(accessToken: refreshed.accessToken, address: "browser")
        != nil)
    #expect(
      flow.store.snapshot.codes.values.allSatisfy { $0.digest.count == 64 && $0.usedAt != nil })
    let stored = String(decoding: try JSONEncoder().encode(flow.store.snapshot), as: UTF8.self)
    for secret in [
      code, issued.accessToken, issued.refreshToken, refreshed.accessToken, refreshed.refreshToken,
    ] {
      #expect(!stored.contains(secret))
    }
    #expect(
      flow.store.snapshot.audit.map(\.capabilityID) == [
        "oauth.authorization_requested", "oauth.authorization_approved", "oauth.tokens_issued",
        "oauth.tokens_refreshed",
      ])
  }

  @Test func codeIsSingleUseAcrossServerInstances() async throws {
    let flow = Flow()
    let (_, code) = try await flow.approve()
    _ = try await flow.exchange(code)
    let second = flow.newServer()
    await #expect(throws: OAuthError.invalidGrant) {
      try await second.token(flow.codeFields(code), address: "other")
    }
  }

  @Test func concurrentCodeExchangeHasOneWinner() async throws {
    let flow = Flow()
    let (_, code) = try await flow.approve()
    let other = flow.newServer()
    async let first: OAuthTokenResponse? = try? flow.server.token(
      flow.codeFields(code), address: "one")
    async let second: OAuthTokenResponse? = try? other.token(flow.codeFields(code), address: "two")
    let results = await [first, second]
    #expect(results.compactMap { $0 }.count == 1)
    #expect(flow.store.snapshot.tokens.count == 2)
  }

  @Test(arguments: ["client_id", "redirect_uri", "code_verifier"])
  func codeBindsClientRedirectAndPKCE(field: String) async throws {
    let flow = Flow()
    let (_, code) = try await flow.approve()
    var fields = flow.codeFields(code)
    fields[field] =
      field == "code_verifier"
      ? String(repeating: "z", count: 43) : "https://other.example/callback"
    await #expect(throws: OAuthError.invalidGrant) {
      try await flow.server.token(fields, address: "browser")
    }
    #expect(flow.store.snapshot.tokens.isEmpty)
    _ = try await flow.exchange(code)
  }

  @Test func resourceBindingAtEveryStage() async throws {
    let flow = Flow()
    var request = flow.authorizeFields
    request["resource"] = "https://other.example/mcp"
    await #expect(throws: OAuthError.invalidRequest) {
      try await flow.server.authorize(request, address: "browser")
    }
    let (_, code) = try await flow.approve()
    var exchange = flow.codeFields(code)
    exchange["resource"] = "https://other.example/mcp"
    await #expect(throws: OAuthError.invalidRequest) {
      try await flow.server.token(exchange, address: "browser")
    }
    let tokens = try await flow.exchange(code)
    let other = OAuthAuthorizationServer(
      configuration: .init(
        tunnelID: "tunnel", tunnelName: "named",
        hostname: "other.example"), store: flow.store, clock: { flow.clock.now })
    #expect(
      try await other.authenticate(accessToken: tokens.accessToken, address: "browser") == nil)
    var refresh = flow.refreshFields(tokens.refreshToken)
    refresh["resource"] = "https://other.example/mcp"
    await #expect(throws: OAuthError.invalidRequest) {
      try await flow.server.token(refresh, address: "browser")
    }
  }

  @Test func refreshReuseRevokesEveryTokenIncludingTheReplacement() async throws {
    let flow = Flow()
    let (grant, code) = try await flow.approve()
    let original = try await flow.exchange(code)
    let replacement = try await flow.refresh(original.refreshToken)
    // Reuse recognition outlives the original token's idle expiry.
    flow.clock.advance(OAuthLimits.refreshTokenLifetime + 1)
    await #expect(throws: OAuthError.invalidGrant) { try await flow.refresh(original.refreshToken) }
    #expect(flow.store.snapshot.grants[grant.id]?.revokedAt == flow.clock.now)
    #expect(
      try await flow.server.authenticate(accessToken: replacement.accessToken, address: "browser")
        == nil)
    await #expect(throws: OAuthError.invalidGrant) {
      try await flow.refresh(replacement.refreshToken)
    }
    #expect(
      flow.store.snapshot.audit.suffix(2).map(\.capabilityID) == [
        "oauth.refresh_token_reuse", "oauth.grant_revoked",
      ])
  }

  @Test func pairingAndCodeExpiry() async throws {
    let flow = Flow()
    let pairing = try await flow.server.authorize(flow.authorizeFields, address: "browser")
    flow.clock.advance(OAuthLimits.requestLifetime)
    let result = try await flow.server.status(statusToken: pairing.statusToken, address: "browser")
    guard case .redirect(let target) = result else {
      Issue.record("Expected expired redirect")
      return
    }
    #expect(
      URLComponents(string: target)?.queryItems?.contains(
        .init(name: "error", value: "access_denied")) == true)
    #expect(try await flow.server.pendingRequests(approver: .localCLI).isEmpty)
    #expect(flow.store.snapshot.audit.last?.capabilityID == "oauth.authorization_expired")
    let (_, code) = try await flow.approve()
    flow.clock.advance(OAuthLimits.codeLifetime)
    await #expect(throws: OAuthError.invalidGrant) { try await flow.exchange(code) }
  }

  @Test func tokenExpiryAndRefreshIdleLifetime() async throws {
    let flow = Flow()
    let (_, code) = try await flow.approve()
    let tokens = try await flow.exchange(code)
    flow.clock.advance(OAuthLimits.accessTokenLifetime)
    #expect(
      try await flow.server.authenticate(accessToken: tokens.accessToken, address: "browser") == nil
    )
    let replacement = try await flow.refresh(tokens.refreshToken)
    flow.clock.advance(OAuthLimits.refreshTokenLifetime - 1)
    _ = try await flow.refresh(replacement.refreshToken)
    let expiredFlow = Flow()
    let (_, expiredCode) = try await expiredFlow.approve()
    let expired = try await expiredFlow.exchange(expiredCode)
    expiredFlow.clock.advance(OAuthLimits.refreshTokenLifetime)
    await #expect(throws: OAuthError.invalidGrant) {
      try await expiredFlow.refresh(expired.refreshToken)
    }
  }

  @Test(arguments: [GatewayCallerKind.cloudflareTunnel, .secureTunnel, .localMCP])
  func approvalOperationsRequireLocalOwner(caller: GatewayCallerKind) async throws {
    let flow = Flow()
    let pairing = try await flow.server.authorize(flow.authorizeFields, address: "browser")
    await #expect(throws: OAuthError.accessDenied) {
      try await flow.server.pendingRequests(approver: caller)
    }
    await #expect(throws: OAuthError.accessDenied) {
      try await flow.server.approve(pairingCode: pairing.request.pairingCode, approver: caller)
    }
    await #expect(throws: OAuthError.accessDenied) {
      try await flow.server.deny(pairingCode: pairing.request.pairingCode, approver: caller)
    }
    await #expect(throws: OAuthError.accessDenied) {
      try await flow.server.grants(approver: caller)
    }
    await #expect(throws: OAuthError.accessDenied) {
      try await flow.server.revokeGrant(id: "anything", approver: caller)
    }
  }

  @Test func pairingRequiresCorrectCodeAndDecisionsAreSingleUse() async throws {
    let flow = Flow()
    let pairing = try await flow.server.authorize(flow.authorizeFields, address: "browser")
    #expect(pairing.request.pairingCode.count == 6)
    #expect(
      pairing.request.pairingCode.allSatisfy { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) })
    await #expect(throws: OAuthError.invalidRequest) {
      try await flow.server.approve(pairingCode: "000000", approver: .localApp)
    }
    await #expect(throws: OAuthError.invalidRequest) {
      try await flow.server.status(statusToken: pairing.request.pairingCode, address: "browser")
    }
    try await flow.server.deny(pairingCode: pairing.request.pairingCode, approver: .localApp)
    await #expect(throws: OAuthError.invalidRequest) {
      try await flow.server.approve(pairingCode: pairing.request.pairingCode, approver: .localApp)
    }
    guard
      case .redirect(let denied) = try await flow.server.status(
        statusToken: pairing.statusToken, address: "browser")
    else {
      Issue.record("Expected denial")
      return
    }
    #expect(denied.contains("error=access_denied"))
    #expect(flow.store.snapshot.grants.isEmpty)
  }

  @Test func approvalCannotExposeLocalAdminOrLocalProfiles() async throws {
    let flow = Flow()
    let pairing = try await flow.server.authorize(flow.authorizeFields, address: "browser")
    await #expect(throws: OAuthError.accessDenied) {
      try await flow.server.approve(
        pairingCode: pairing.request.pairingCode, profile: .localAdmin, approver: .localCLI)
    }
  }

  @Test func revocationEndpointIsIdempotentAndBindsTheClient() async throws {
    let flow = Flow()
    let (_, code) = try await flow.approve()
    let tokens = try await flow.exchange(code)
    try await flow.server.revoke(
      ["client_id": "https://other.example/metadata", "token": tokens.accessToken],
      address: "browser")
    #expect(
      try await flow.server.authenticate(accessToken: tokens.accessToken, address: "browser") != nil
    )
    let accessFields = ["client_id": flow.clientID, "token": tokens.accessToken]
    try await flow.server.revoke(accessFields, address: "browser")
    try await flow.server.revoke(accessFields, address: "browser")
    #expect(
      try await flow.server.authenticate(accessToken: tokens.accessToken, address: "browser") == nil
    )
    let next = try await flow.refresh(tokens.refreshToken)
    try await flow.server.revoke(
      ["client_id": flow.clientID, "token": next.refreshToken], address: "browser")
    #expect(
      try await flow.server.authenticate(accessToken: next.accessToken, address: "browser") == nil)
    try await flow.server.revoke(
      ["client_id": flow.clientID, "token": "unknown"], address: "browser")
  }

  @Test func ownerGrantRevocationInvalidatesAllTokensImmediately() async throws {
    let flow = Flow()
    let (grant, code) = try await flow.approve()
    let tokens = try await flow.exchange(code)
    try await flow.server.revokeGrant(id: grant.id, approver: .localCLI)
    #expect(
      try await flow.server.authenticate(accessToken: tokens.accessToken, address: "browser") == nil
    )
    await #expect(throws: OAuthError.invalidGrant) { try await flow.refresh(tokens.refreshToken) }
  }

  @Test func limitsAndFailureAuditAreBounded() async throws {
    let flow = Flow()
    for _ in 0..<Int(OAuthLimits.addressCapacity) {
      try await flow.server.authenticationFailed(address: "one")
    }
    await #expect(throws: OAuthError.rateLimited) {
      try await flow.server.authenticationFailed(address: "one")
    }
    #expect(flow.store.snapshot.audit.count == 1)
    try await flow.server.checkRate(address: "two")
    flow.clock.advance(OAuthLimits.failureAuditInterval)
    try await flow.server.authenticationFailed(address: "one")
    #expect(flow.store.snapshot.audit.count == 2)
    var limiter = OAuthRateLimiter()
    for _ in 0..<Int(OAuthLimits.grantCapacity) {
      let allowed = limiter.allow(
        address: UUID().uuidString, grantID: "shared", now: flow.clock.now)
      #expect(allowed)
    }
    let blocked = limiter.allow(address: "new", grantID: "shared", now: flow.clock.now)
    #expect(!blocked)
  }

  @Test(arguments: [
    "response_type", "state", "resource", "client_id", "redirect_uri", "code_challenge",
    "code_challenge_method",
  ])
  func requiredAuthorizationFieldsCannotBeMissing(field: String) async throws {
    let flow = Flow()
    var fields = flow.authorizeFields
    fields.removeValue(forKey: field)
    await #expect(throws: OAuthError.invalidRequest) {
      try await flow.server.authorize(fields, address: "browser")
    }
    #expect(flow.store.snapshot.requests.isEmpty)
  }
}

private struct FixtureFetcher: CIMDFetching {
  let clientID: String
  let redirects: [String]
  func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
    try JSONSerialization.data(withJSONObject: ["client_id": clientID, "redirect_uris": redirects])
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { value } }
  func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private struct Flow: Sendable {
  let store = MemoryOAuthStore()
  let clock = TestClock()
  let clientID = "https://client.example/metadata.json"
  let redirectURI = "https://consumer.example/callback?existing=1"
  let verifier = String(repeating: "a", count: 43)
  let configuration = OAuthServerConfiguration(
    tunnelID: "tunnel", tunnelName: "named",
    hostname: "gateway.example", clientAllowlist: ["client.example"])
  let server: OAuthAuthorizationServer
  init() {
    server = OAuthAuthorizationServer(
      configuration: configuration, store: store,
      identifier: CIMDClientIdentifier(
        fetcher: FixtureFetcher(clientID: clientID, redirects: [redirectURI])),
      clock: { [clock] in clock.now })
  }
  func newServer() -> OAuthAuthorizationServer {
    OAuthAuthorizationServer(configuration: configuration, store: store, clock: { clock.now })
  }
  var authorizeFields: [String: String] {
    [
      "response_type": "code", "client_id": clientID, "redirect_uri": redirectURI,
      "state": "state + & value",
      "code_challenge": OAuthSecret.challenge(verifier), "code_challenge_method": "S256",
      "resource": configuration.resource, "scope": "mcp",
    ]
  }
  func codeFields(_ code: String) -> [String: String] {
    [
      "grant_type": "authorization_code", "client_id": clientID, "redirect_uri": redirectURI,
      "code": code, "code_verifier": verifier, "resource": configuration.resource,
    ]
  }
  func refreshFields(_ refresh: String) -> [String: String] {
    [
      "grant_type": "refresh_token", "client_id": clientID, "refresh_token": refresh,
      "resource": configuration.resource,
    ]
  }
  func approve() async throws -> (OAuthGrant, String) {
    let pairing = try await server.authorize(authorizeFields, address: "browser")
    let grant = try await server.approve(
      pairingCode: pairing.request.pairingCode, approver: .localCLI)
    guard
      case .redirect(let target) = try await server.status(
        statusToken: pairing.statusToken, address: "browser"),
      let items = URLComponents(string: target)?.queryItems,
      let code = items.first(where: { $0.name == "code" })?.value
    else { throw OAuthError.invalidGrant }
    #expect(items.first(where: { $0.name == "state" })?.value == authorizeFields["state"])
    #expect(items.first(where: { $0.name == "iss" })?.value == configuration.issuer)
    return (grant, code)
  }
  func exchange(_ code: String) async throws -> OAuthTokenResponse {
    try await server.token(codeFields(code), address: "browser")
  }
  func refresh(_ value: String) async throws -> OAuthTokenResponse {
    try await server.token(refreshFields(value), address: "browser")
  }
}

private struct MemoryOAuthState: Codable {
  var requests: [String: OAuthAuthorizationRequest] = [:]
  var grants: [String: OAuthGrant] = [:]
  var codes: [String: OAuthAuthorizationCode] = [:]
  var tokens: [String: OAuthToken] = [:]
  var audit: [AuditEvent] = []
}

private final class MemoryOAuthStore: OAuthStore, @unchecked Sendable {
  private let lock = NSLock()
  private var state = MemoryOAuthState()
  var snapshot: MemoryOAuthState { lock.withLock { state } }
  func oauthTransaction<Result>(_ body: (any OAuthStoreTransaction) throws -> Result) throws
    -> Result
  {
    try lock.withLock {
      let transaction = MemoryTransaction(state: state)
      let result = try body(transaction)
      state = transaction.state
      return result
    }
  }
}

private final class MemoryTransaction: OAuthStoreTransaction {
  var state: MemoryOAuthState
  init(state: MemoryOAuthState) { self.state = state }
  func requests(tunnelID: String) throws -> [OAuthAuthorizationRequest] {
    state.requests.values.filter { $0.tunnelID == tunnelID }
  }
  func save(_ request: OAuthAuthorizationRequest) throws { state.requests[request.id] = request }
  func grant(id: String) throws -> OAuthGrant? { state.grants[id] }
  func grants(tunnelID: String) throws -> [OAuthGrant] {
    state.grants.values.filter { $0.tunnelID == tunnelID }
  }
  func save(_ grant: OAuthGrant) throws { state.grants[grant.id] = grant }
  func code(digest: String) throws -> OAuthAuthorizationCode? { state.codes[digest] }
  func save(_ code: OAuthAuthorizationCode) throws { state.codes[code.digest] = code }
  func token(digest: String) throws -> OAuthToken? { state.tokens[digest] }
  func save(_ token: OAuthToken) throws { state.tokens[token.digest] = token }
  func audit(_ event: AuditEvent) throws { state.audit.append(event) }
  func prune(before: Date) throws {}
}
