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
    let query = try #require(URLComponents(string: redirect)?.queryItems)
    #expect(
      query.first(where: { $0.name == "state" })?.value == fixture.authorizationFields["state"])
    #expect(query.first(where: { $0.name == "iss" })?.value == "https://gateway.example")
    let code = try #require(query.first(where: { $0.name == "code" })?.value)
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
          "error"] == .string("invalid_client"))
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
    let runtime = GatewayHTTPRuntime(
      configuration: .init(), registry: EmptyHTTPRegistry(), host: "127.0.0.1", port: 0,
      publicBaseURL: fixture.configuration.issuer, accessToken: "old-fixture-token",
      oauth: GatewayOAuthHTTP(server: fixture.server))
    try await runtime.startListening()
    do {
      let port = try #require(await runtime.boundPort())
      #expect(try await Self.post(runtimePort: port, token: "old-fixture-token").statusCode == 400)
      await runtime.updateAccessToken("new-fixture-token")
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
      pairingCode: pairing.request.pairingCode, profile: .cloudflareOperate, approver: .localApp)
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

private struct HTTPFixture: Sendable {
  let database: GatewayDatabase
  let server: OAuthAuthorizationServer
  let configuration = OAuthServerConfiguration(
    tunnelID: "tunnel", tunnelName: "named", hostname: "gateway.example",
    clientAllowlist: ["client.example"])
  let clientID = "https://client.example/cimd"
  let verifier = String(repeating: "a", count: 43)
  init() throws {
    database = try GatewayDatabase(inMemory: ())
    server = OAuthAuthorizationServer(
      configuration: configuration, store: database,
      identifier: CIMDClientIdentifier(fetcher: HTTPDocument()))
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
