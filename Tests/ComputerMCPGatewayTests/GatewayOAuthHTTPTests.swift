import ComputerMCPAuthorization
import ComputerMCPConfiguration
import ComputerMCPCore
import Foundation
import MCP
import Testing

@testable import ComputerMCPGateway

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.timeLimit(.minutes(1)))
struct GatewayOAuthHTTPTests {
  @Test func discoveryAndChallengeUseThePublicResource() async throws {
    let fixture = try HTTPFixture()
    let app = fixture.app()
    for path in [
      "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp",
    ] {
      let response = await app.handle(fixture.request(path))
      #expect(Self.status(response) == 200)
      let object = try Self.object(response)
      #expect(object == fixture.configuration.protectedResourceMetadata)
    }
    let metadata = await app.handle(fixture.request("/.well-known/oauth-authorization-server"))
    #expect(try Self.object(metadata) == fixture.configuration.authorizationServerMetadata)
    let challenge = await app.handle(fixture.request("/mcp", method: "POST"))
    #expect(Self.status(challenge) == 401)
    #expect(
      challenge.headers["WWW-Authenticate"]
        == "Bearer resource_metadata=\"https://gateway.example/.well-known/oauth-protected-resource/mcp\", scope=\"mcp\""
    )
    #expect(challenge.headers["Cache-Control"] == "no-store")
    #expect(
      try fixture.database.auditEvents(limit: 100).contains {
        $0.capabilityID == "oauth.authentication_failed"
      })
  }

  @Test func everyOAuthPathRejectsWrongHostAndDisabledConfiguration() async throws {
    let fixture = try HTTPFixture()
    let app = fixture.app()
    let disabled = fixture.app(enabled: false)
    for path in GatewayOAuthHTTP.paths {
      for method in ["GET", "POST", "OPTIONS"] {
        let wrongHost = HTTPRequest(method: method, headers: ["Host": "127.0.0.1:8765"], path: path)
        #expect(Self.status(await app.handle(wrongHost)) == 404)
        #expect(Self.status(await disabled.handle(fixture.request(path, method: method))) == 404)
      }
    }
  }

  @Test func pairingPageStatusAndTokenHTTPFlow() async throws {
    let fixture = try HTTPFixture()
    let app = fixture.app()
    let page = await app.handle(
      fixture.request("/oauth/authorize?" + Self.form(fixture.authorizationFields)))
    #expect(Self.status(page) == 200)
    #expect(page.headers["Cache-Control"] == "no-store")
    #expect(page.headers["Content-Security-Policy"] == "frame-ancestors 'none'")
    let pending = try await fixture.server.pendingRequests(approver: .localApp)
    let authorization = try #require(pending.first)
    let text = String(decoding: page.bodyData ?? Data(), as: UTF8.self)
    #expect(text.contains(authorization.pairingCode))
    #expect(text.contains("client.example"))
    #expect(text.contains("consumer.example"))
    #expect(!text.contains("Approve access</button>"))
    let start = try #require(text.range(of: "/oauth/authorize/status?request="))
    let statusToken = String(text[start.upperBound...].prefix(43))
    let path = "/oauth/authorize/status?request=" + statusToken
    let status = await app.handle(fixture.request(path))
    #expect(try Self.object(status)["status"] == .string("pending"))
    #expect(status.headers["Content-Security-Policy"] == "frame-ancestors 'none'")
    let grant = try await fixture.server.approve(
      pairingCode: authorization.pairingCode, approver: .localCLI)
    let approved = await app.handle(fixture.request(path))
    let redirect = try #require(try Self.object(approved)["redirect_uri"]?.stringValue)
    let query = try GatewayOAuthHTTP.form(
      #require(URLComponents(string: redirect)?.percentEncodedQuery))
    #expect(
      query["state"] == fixture.authorizationFields["state"])
    #expect(query["iss"] == "https://gateway.example")
    let code = try #require(query["code"])
    let tokenRequest = fixture.request(
      "/oauth/token", method: "POST", fields: fixture.codeFields(code))
    let tokenResponse = await app.handle(tokenRequest)
    #expect(Self.status(tokenResponse) == 200)
    #expect(tokenResponse.headers["Cache-Control"] == "no-store")
    let tokens = try Self.object(tokenResponse)
    let access = try #require(tokens["access_token"]?.stringValue)
    #expect(tokens["token_type"] == .string("Bearer"))
    #expect(tokens["expires_in"] == .integer(3_600))
    #expect(
      try await fixture.server.authenticate(accessToken: access, address: "fixture")?.id == grant.id
    )
    #expect(Self.status(await app.handle(tokenRequest)) == 400)
    let revoke = await app.handle(
      fixture.request(
        "/oauth/revoke", method: "POST", fields: ["token": access, "client_id": fixture.clientID]))
    #expect(Self.status(revoke) == 200)
    #expect(try await fixture.server.authenticate(accessToken: access, address: "fixture") == nil)
    #expect(
      Self.status(
        await app.handle(
          fixture.request(
            "/oauth/revoke", method: "POST",
            fields: ["token": "unknown", "client_id": fixture.clientID]))) == 200)
  }

  @Test func malformedFormsMethodsAndCredentialsFailClosed() async throws {
    let fixture = try HTTPFixture()
    let app = fixture.app()
    let duplicated = HTTPRequest(
      method: "POST",
      headers: ["Host": "gateway.example", "Content-Type": "application/x-www-form-urlencoded"],
      body: Data("grant_type=refresh_token&grant_type=authorization_code".utf8),
      path: "/oauth/token")
    #expect(Self.status(await app.handle(duplicated)) == 400)
    #expect(Self.status(await app.handle(fixture.request("/oauth/token"))) == 405)
    #expect(Self.status(await app.handle(fixture.request("/oauth/authorize?state=%ZZ"))) == 400)
    #expect(
      Self.status(await app.handle(fixture.request("/oauth/authorize/status?request=wrong"))) == 400
    )
    let empty = HTTPRequest(
      method: "POST", headers: ["Host": "gateway.example", "Content-Type": "application/json"],
      body: Data("{}".utf8), path: "/oauth/token")
    #expect(Self.status(await app.handle(empty)) == 400)
    #expect(
      try Self.object(
        await app.handle(
          fixture.request(
            "/oauth/token", method: "POST", fields: ["resource": fixture.configuration.resource])))[
          "error"] == .string("invalid_request"))
  }

  @Test func endpointsAndFailedBearerAreRateLimited() async throws {
    let fixture = try HTTPFixture()
    let app = fixture.app()
    for _ in 0..<Int(OAuthLimits.addressCapacity) {
      _ = await app.handle(fixture.request("/.well-known/oauth-authorization-server"))
    }
    let limited = await app.handle(fixture.request("/.well-known/oauth-authorization-server"))
    #expect(Self.status(limited) == 429)
    #expect(limited.headers["Retry-After"] != nil)
    let denied = await app.handle(fixture.request("/mcp", method: "POST"))
    #expect(Self.status(denied) == 429)
    #expect(
      try fixture.database.auditEvents(limit: 100).filter {
        $0.capabilityID == "oauth.authentication_failed"
      }.count <= 1)
  }

  @Test func runningListenerRotatesTheAccessTokenImmediately() async throws {
    let fixture = try HTTPFixture()
    let credential = HTTPAccessTokenCredential(token: "old-fixture-token")
    let runtime = GatewayHTTPRuntime(
      configuration: .init(), registry: EmptyHTTPRegistry(), host: "127.0.0.1", port: 0,
      publicBaseURL: fixture.configuration.issuer, accessCredential: credential,
      oauth: GatewayOAuthHTTP(server: fixture.server))
    try await runtime.startListening()
    do {
      let port = try #require(await runtime.boundPort())
      #expect(try await Self.post(runtimePort: port, token: "old-fixture-token").statusCode == 400)
      credential.replace(with: "new-fixture-token")
      #expect(try await Self.post(runtimePort: port, token: "old-fixture-token").statusCode == 401)
      #expect(try await Self.post(runtimePort: port, token: "new-fixture-token").statusCode == 400)
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test func oauthAdmissionUsesGrantPrincipalAndProfileAndKeepsLocalConsent() async throws {
    let fixture = try HTTPFixture()
    let pairing = try await fixture.server.authorize(
      fixture.authorizationFields, address: "fixture")
    let grant = try await fixture.server.approve(
      pairingCode: pairing.request.pairingCode, profile: { _ in .cloudflareOperate },
      approver: .localApp)
    guard
      case .redirect(let target) = try await fixture.server.status(
        statusToken: pairing.statusToken, address: "fixture"),
      let code = URLComponents(string: target)?.queryItems?.first(where: { $0.name == "code" })?
        .value
    else { throw OAuthError.invalidGrant }
    let tokens = try await fixture.server.token(fixture.codeFields(code), address: "fixture")
    let source = GatewayHTTPManagedSessions(
      makeSession: { principal in
        GatewayControlSessionServing(
          base: EmptyHTTPRegistry(),
          session: GatewayControlSession(
            principalID: principal, profileID: .cloudflareObserve, caller: .cloudflareTunnel))
      }, closeSession: { _ in }, shutdown: {},
      makeOAuthSession: { principal, profile in
        GatewayControlSessionServing(
          base: EmptyHTTPRegistry(),
          session: GatewayControlSession(
            principalID: principal, profileID: profile, caller: .cloudflareTunnel,
            database: fixture.database, profile: .init(grant: .cloudflareOperate, persisted: false))
        )
      })
    let runtime = GatewayHTTPRuntime(
      configuration: .init(), source: .managed(source), host: "127.0.0.1", port: 0,
      publicBaseURL: fixture.configuration.issuer, accessToken: "static-fixture",
      oauth: GatewayOAuthHTTP(server: fixture.server))
    try await runtime.startListening()
    do {
      let port = try #require(await runtime.boundPort())
      let initialized = try await Self.post(
        runtimePort: port, token: tokens.accessToken, initialize: true)
      #expect(initialized.statusCode == 200)
      let sessions = await runtime.controlSessions()
      let scope = try #require(sessions.first)
      #expect(scope.principalID == grant.principalID)
      #expect(scope.profileID == .cloudflareOperate)
      #expect(scope.caller == .cloudflareTunnel)
      #expect(scope.fullAccessConsent == nil)
      #expect(scope.accessLimit == .workspaceOperations)
      try await fixture.server.revokeGrant(id: grant.id, approver: .localApp)
      #expect(try await Self.post(runtimePort: port, token: tokens.accessToken).statusCode == 401)
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test(arguments: ["grant_type", "client_id", "resource", "code", "redirect_uri", "code_verifier"])
  func malformedCodeParametersHaveExactWireErrors(field: String) async throws {
    let fixture = try HTTPFixture()
    let (_, code) = try await fixture.code()
    let valid = fixture.codeFields(code)
    let app = fixture.app()
    var missing = valid
    missing.removeValue(forKey: field)
    try Self.expectError(
      await app.handle(fixture.request("/oauth/token", method: "POST", fields: missing)),
      "invalid_request")
    var empty = valid
    empty[field] = ""
    try Self.expectError(
      await app.handle(fixture.request("/oauth/token", method: "POST", fields: empty)),
      "invalid_request")
    let duplicate = HTTPRequest(
      method: "POST",
      headers: ["Host": "gateway.example", "Content-Type": "application/x-www-form-urlencoded"],
      body: Data((Self.form(valid) + "&" + field + "=duplicate").utf8), path: "/oauth/token")
    try Self.expectError(await app.handle(duplicate), "invalid_request")
  }

  @Test(arguments: ["grant_type", "client_id", "resource", "refresh_token"])
  func malformedRefreshParametersHaveExactWireErrors(field: String) async throws {
    let fixture = try HTTPFixture()
    let (_, code) = try await fixture.code()
    let issued = try await fixture.server.token(fixture.codeFields(code), address: "fixture")
    let valid = fixture.refreshFields(issued.refreshToken)
    let app = fixture.app()
    var missing = valid
    missing.removeValue(forKey: field)
    try Self.expectError(
      await app.handle(fixture.request("/oauth/token", method: "POST", fields: missing)),
      "invalid_request")
    var empty = valid
    empty[field] = ""
    try Self.expectError(
      await app.handle(fixture.request("/oauth/token", method: "POST", fields: empty)),
      "invalid_request")
    let duplicate = HTTPRequest(
      method: "POST",
      headers: ["Host": "gateway.example", "Content-Type": "application/x-www-form-urlencoded"],
      body: Data((Self.form(valid) + "&" + field + "=duplicate").utf8), path: "/oauth/token")
    try Self.expectError(await app.handle(duplicate), "invalid_request")
  }

  @Test(arguments: [
    "code", "client_id", "resource", "redirect_uri", "code_verifier", "short_verifier", "expired",
    "reused",
  ])
  func invalidCodeBindingsHaveExactWireErrors(mutation: String) async throws {
    let fixture = try HTTPFixture()
    let (_, code) = try await fixture.code()
    var fields = fixture.codeFields(code)
    switch mutation {
    case "expired": fixture.clock.advance(OAuthLimits.codeLifetime)
    case "reused": _ = try await fixture.server.token(fields, address: "fixture")
    case "short_verifier": fields["code_verifier"] = "short"
    default: fields[mutation] = "wrong+value"
    }
    try Self.expectError(
      await fixture.app().handle(fixture.request("/oauth/token", method: "POST", fields: fields)),
      "invalid_grant")
  }

  @Test(arguments: ["refresh_token", "client_id", "resource", "expired", "reused", "access_token"])
  func invalidRefreshBindingsHaveExactWireErrors(mutation: String) async throws {
    let fixture = try HTTPFixture()
    let (_, code) = try await fixture.code()
    let issued = try await fixture.server.token(fixture.codeFields(code), address: "fixture")
    var fields = fixture.refreshFields(issued.refreshToken)
    switch mutation {
    case "expired": fixture.clock.advance(OAuthLimits.refreshTokenLifetime)
    case "reused": _ = try await fixture.server.token(fields, address: "fixture")
    case "access_token": fields["refresh_token"] = issued.accessToken
    default: fields[mutation] = "wrong+value"
    }
    try Self.expectError(
      await fixture.app().handle(fixture.request("/oauth/token", method: "POST", fields: fields)),
      "invalid_grant")
  }

  @Test func unsupportedGrantsScopesContentTypesAndClientAuthenticationHaveExactErrors()
    async throws
  {
    let fixture = try HTTPFixture()
    let (_, code) = try await fixture.code()
    let app = fixture.app()
    var fields = fixture.codeFields(code)
    fields["grant_type"] = "password"
    try Self.expectError(
      await app.handle(fixture.request("/oauth/token", method: "POST", fields: fields)),
      "unsupported_grant_type")
    fields = fixture.codeFields(code)
    fields["scope"] = "other"
    try Self.expectError(
      await app.handle(fixture.request("/oauth/token", method: "POST", fields: fields)),
      "invalid_scope")
    for contentType in [nil, "application/json", "text/plain"] {
      var headers = ["Host": "gateway.example"]
      headers["Content-Type"] = contentType
      let request = HTTPRequest(
        method: "POST", headers: headers, body: Data(Self.form(fixture.codeFields(code)).utf8),
        path: "/oauth/token")
      try Self.expectError(await app.handle(request), "invalid_request")
    }
    fields = fixture.codeFields(code)
    fields["client_secret"] = "synthetic-secret"
    try Self.expectError(
      await app.handle(fixture.request("/oauth/token", method: "POST", fields: fields)),
      "invalid_client", status: 401)
    let request = HTTPRequest(
      method: "POST",
      headers: [
        "Host": "gateway.example", "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": "Basic synthetic",
      ], body: Data(Self.form(fixture.codeFields(code)).utf8), path: "/oauth/token")
    let response = await app.handle(request)
    try Self.expectError(response, "invalid_client", status: 401)
    #expect(response.headers["WWW-Authenticate"] == "Basic")
    #expect(
      OAuthError.unsupportedGrantType.auditClassification?.code == "oauth.unsupported_grant_type")
    #expect(
      OAuthError.unsupportedResponseType.auditClassification?.code
        == "oauth.unsupported_response_type")
    #expect(OAuthError.invalidScope.auditClassification?.code == "oauth.invalid_scope")
  }

  @Test(arguments: ["response_type", "scope"])
  func authorizationProtocolErrorsRedirectToTheValidatedCallback(field: String) async throws {
    let fixture = try HTTPFixture()
    var fields = fixture.authorizationFields
    fields[field] = "unsupported"
    let response = await fixture.app().handle(
      fixture.request("/oauth/authorize?" + Self.form(fields)))
    #expect(Self.status(response) == 302)
    let location = try #require(response.headers["Location"])
    let query = try GatewayOAuthHTTP.form(
      #require(URLComponents(string: location)?.percentEncodedQuery))
    #expect(
      query["error"] == (field == "response_type" ? "unsupported_response_type" : "invalid_scope"))
    #expect(query["state"] == fields["state"])
    #expect(query["iss"] == fixture.configuration.issuer)
    #expect(try await fixture.server.pendingRequests(approver: .localApp).isEmpty)
  }

  @Test func fourthPairingIsRateRejectedWhileAnotherAddressStillPairs() async throws {
    let fixture = try HTTPFixture()
    let app = fixture.app()
    let request = fixture.request("/oauth/authorize?" + Self.form(fixture.authorizationFields))
    for _ in 0..<3 { #expect(Self.status(await app.handle(request)) == 200) }
    try Self.expectError(await app.handle(request), "temporarily_unavailable", status: 429)
    let other = HTTPRequest(
      method: "GET", headers: ["Host": "gateway.example", "CF-Connecting-IP": "198.51.100.9"],
      path: request.path)
    #expect(Self.status(await app.handle(other)) == 200)
  }

  @Test(arguments: ["app", "cli", "refresh_reuse", "refresh_revoke"])
  func grantRevocationEndsOpenStreamsAndSessions(source: String) async throws {
    let fixture = try HTTPFixture()
    let (grant, code) = try await fixture.code()
    let tokens = try await fixture.server.token(fixture.codeFields(code), address: "fixture")
    let managed = GatewayHTTPManagedSessions(
      makeSession: { principal in
        GatewayControlSessionServing(
          base: EmptyHTTPRegistry(),
          session: GatewayControlSession(
            principalID: principal, profileID: .cloudflareObserve, caller: .cloudflareTunnel))
      }, closeSession: { _ in }, shutdown: {},
      makeOAuthSession: { principal, profile in
        GatewayControlSessionServing(
          base: EmptyHTTPRegistry(),
          session: GatewayControlSession(
            principalID: principal, profileID: profile, caller: .cloudflareTunnel))
      })
    let runtime = GatewayHTTPRuntime(
      configuration: .init(), source: .managed(managed), host: "127.0.0.1", port: 0,
      publicBaseURL: fixture.configuration.issuer, accessToken: "fixture",
      oauth: GatewayOAuthHTTP(server: fixture.server))
    try await runtime.startListening()
    do {
      let port = try #require(await runtime.boundPort())
      let initialized = try await Self.post(
        runtimePort: port, token: tokens.accessToken, initialize: true)
      let id = try #require(initialized.value(forHTTPHeaderField: "MCP-Session-Id"))
      let stream = try OAuthTestHTTPConnection(port: port)
      defer { stream.close() }
      try stream.send(
        "GET /mcp HTTP/1.1\r\nHost: gateway.example\r\nAuthorization: Bearer \(tokens.accessToken)\r\nMCP-Session-Id: \(id)\r\nAccept: text/event-stream\r\n\r\n"
      )
      #expect(try stream.response().hasPrefix("HTTP/1.1 200"))
      switch source {
      case "refresh_reuse":
        _ = try await fixture.server.token(
          fixture.refreshFields(tokens.refreshToken), address: "fixture")
        await #expect(throws: OAuthError.invalidGrant) {
          try await fixture.server.token(
            fixture.refreshFields(tokens.refreshToken), address: "fixture")
        }
      case "refresh_revoke":
        try await fixture.server.revoke(
          ["client_id": fixture.clientID, "token": tokens.refreshToken], address: "fixture")
      default:
        try await fixture.server.revokeGrant(
          id: grant.id, approver: source == "app" ? .localApp : .localCLI)
      }
      #expect(try stream.streamEnded())
      #expect(await runtime.activeSessionCount() == 0)
      #expect(await runtime.controlSessions().isEmpty)
      #expect(try await Self.post(runtimePort: port, token: tokens.accessToken).statusCode == 401)
      #expect(
        try fixture.database.auditEvents(limit: 100).contains {
          $0.capabilityID == "oauth.sessions_ended"
            && $0.principalDigest == AuditEvent.verifiedPrincipalDigest(grant.principalID)
        })
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func revocationDuringInitializationRefusesTheSession(duringIdleCleanup: Bool) async throws {
    let fixture = try HTTPFixture()
    let (grant, code) = try await fixture.code()
    let tokens = try await fixture.server.token(fixture.codeFields(code), address: "fixture")
    let paused = AsyncStream<Void>.makeStream()
    let gate = OAuthInitializationGate()
    let managed = GatewayHTTPManagedSessions(
      makeSession: { principal in
        GatewayControlSessionServing(
          base: EmptyHTTPRegistry(),
          session: GatewayControlSession(
            principalID: principal, profileID: .cloudflareObserve, caller: .cloudflareTunnel))
      },
      closeSession: { _ in
        if duringIdleCleanup {
          paused.continuation.yield(())
          await gate.wait()
        }
      }, shutdown: {},
      makeOAuthSession: { principal, profile in
        if !duringIdleCleanup {
          paused.continuation.yield(())
          await gate.wait()
        }
        return GatewayControlSessionServing(
          base: EmptyHTTPRegistry(),
          session: GatewayControlSession(
            principalID: principal, profileID: profile, caller: .cloudflareTunnel))
      })
    let runtime = GatewayHTTPRuntime(
      configuration: .init(), source: .managed(managed), host: "127.0.0.1", port: 0,
      publicBaseURL: fixture.configuration.issuer, accessToken: "static-fixture",
      limits: .init(sessionIdleTimeout: 0.01, cleanupInterval: 3_600),
      oauth: GatewayOAuthHTTP(server: fixture.server))
    try await runtime.startListening()
    let port = try #require(await runtime.boundPort())
    do {
      let idle = try await Self.post(runtimePort: port, token: "static-fixture", initialize: true)
      #expect(idle.statusCode == 200)
      try await Task.sleep(for: .milliseconds(20))
    } catch {
      await gate.resume()
      await runtime.stop()
      throw error
    }
    let initializing = Task {
      try await Self.post(runtimePort: port, token: tokens.accessToken, initialize: true)
    }
    do {
      var events = paused.stream.makeAsyncIterator()
      _ = await events.next()
      try await fixture.server.revokeGrant(id: grant.id, approver: .localApp)
      await gate.resume()
      let response = try await initializing.value
      #expect(response.statusCode == 401)
      #expect(response.value(forHTTPHeaderField: "MCP-Session-Id") == nil)
      #expect(await runtime.activeSessionCount() == 0)
      #expect(await runtime.controlSessions().isEmpty)
      #expect(try await Self.post(runtimePort: port, token: tokens.accessToken).statusCode == 401)
      await runtime.stop()
    } catch {
      await gate.resume()
      _ = await initializing.result
      await runtime.stop()
      throw error
    }
  }

  private static func expectError(_ response: HTTPResponse, _ error: String, status: Int = 400)
    throws
  {
    #expect(Self.status(response) == status)
    #expect(try Self.object(response)["error"] == .string(error))
  }

  private static func post(runtimePort: Int, token: String, initialize: Bool = false) async throws
    -> HTTPURLResponse
  {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(runtimePort)/mcp")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("gateway.example", forHTTPHeaderField: "Host")
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = Data(
      (initialize
        ? #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fixture","version":"1"}}}"#
        : "{}").utf8)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (_, response) = try await session.data(for: request)
    return try #require(response as? HTTPURLResponse)
  }

  static func form(_ fields: [String: String]) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return fields.sorted { $0.key < $1.key }.map {
      $0.key + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }.joined(separator: "&")
  }
  private static func status(_ response: HTTPResponse) -> Int {
    response.headers["X-Computer-MCP-Status"].flatMap(Int.init) ?? response.statusCode
  }
  private static func object(_ response: HTTPResponse) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: response.bodyData ?? Data())
  }
}

private actor OAuthInitializationGate {
  private var resumed = false
  private var waiter: CheckedContinuation<Void, Never>?
  func wait() async {
    if !resumed { await withCheckedContinuation { waiter = $0 } }
  }
  func resume() {
    resumed = true
    waiter?.resume()
    waiter = nil
  }
}

private struct HTTPFixture: Sendable {
  let database: GatewayDatabase
  let server: OAuthAuthorizationServer
  let configuration = OAuthServerConfiguration(
    tunnelID: "tunnel", tunnelName: "named", hostname: "gateway.example",
    clientAllowlist: ["client.example"])
  let clock = HTTPTestClock()
  let clientID = "https://client.example/cimd"
  let verifier = String(repeating: "a", count: 43)
  init() throws {
    database = try GatewayDatabase(inMemory: ())
    server = OAuthAuthorizationServer(
      configuration: configuration, store: database,
      identifier: CIMDClientIdentifier(fetcher: HTTPDocument()), clock: { [clock] in clock.now })
  }
  var authorizationFields: [String: String] {
    [
      "response_type": "code", "client_id": clientID,
      "redirect_uri": "https://consumer.example/callback", "state": "state + & value",
      "resource": configuration.resource, "scope": "mcp",
      "code_challenge": OAuthSecret.challenge(verifier), "code_challenge_method": "S256",
    ]
  }
  func codeFields(_ code: String) -> [String: String] {
    [
      "grant_type": "authorization_code", "client_id": clientID, "code": code,
      "redirect_uri": "https://consumer.example/callback", "code_verifier": verifier,
      "resource": configuration.resource,
    ]
  }
  func refreshFields(_ value: String) -> [String: String] {
    [
      "grant_type": "refresh_token", "client_id": clientID, "refresh_token": value,
      "resource": configuration.resource,
    ]
  }
  func code() async throws -> (OAuthGrant, String) {
    let pairing = try await server.authorize(authorizationFields, address: "fixture")
    let grant = try await server.approve(
      pairingCode: pairing.request.pairingCode, approver: .localApp)
    guard
      case .redirect(let target) = try await server.status(
        statusToken: pairing.statusToken, address: "fixture"),
      let query = URLComponents(string: target)?.percentEncodedQuery,
      let code = try GatewayOAuthHTTP.form(query)["code"]
    else { throw OAuthError.invalidGrant }
    return (grant, code)
  }
  func app(enabled: Bool = true) -> GatewayHTTPApp {
    GatewayHTTPApp(
      configuration: .init(), source: .registry(EmptyHTTPRegistry()), listeningPort: 0,
      publicBaseURL: configuration.issuer, accessToken: "static-fixture",
      logger: .init(label: "oauth-fixture"), limits: .v1, control: nil,
      oauth: GatewayOAuthHTTP(
        server: server, currentConfiguration: { enabled ? configuration : nil }))
  }
  func request(_ path: String, method: String = "GET", fields: [String: String]? = nil)
    -> HTTPRequest
  {
    HTTPRequest(
      method: method,
      headers: [
        "Host": "gateway.example", "Content-Type": "application/x-www-form-urlencoded",
        "CF-Connecting-IP": "198.51.100.8",
      ],
      body: fields.map { Data(GatewayOAuthHTTPTests.form($0).utf8) }, path: path)
  }
}

private struct HTTPDocument: CIMDFetching {
  func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
    Data(
      #"{"client_id":"https://client.example/cimd","redirect_uris":["https://consumer.example/callback"]}"#
        .utf8)
  }
}

private struct EmptyHTTPRegistry: GatewayToolServing {
  func listTools(context: InvocationContext) throws -> [MCPTool] { [] }
  func callTool(name: String, arguments: JSONValue?, context: InvocationContext) throws -> JSONValue
  { .null }
}

private final class HTTPTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
