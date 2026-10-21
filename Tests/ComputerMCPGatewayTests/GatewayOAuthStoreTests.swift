import ComputerMCPCore
import ComputerMCPPersistence
import Foundation
import GRDB
import Testing

@testable import ComputerMCPAuthorization
@testable import ComputerMCPGateway

struct GatewayOAuthStoreTests {
  @Test func grantAndAuditRollbackTogether() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let store = GatewayDatabase(connection: connection)
    let grant = OAuthGrant(
      id: "grant", tunnelID: "tunnel", clientID: "https://client.example/cimd",
      redirectHost: "consumer.example", profileID: .cloudflareObserve,
      resource: "https://gateway.example/mcp", scope: "mcp", createdAt: Date())
    #expect(throws: StoreFailure.rollback) {
      try store.oauthTransaction { transaction in
        try transaction.save(grant)
        try transaction.audit(
          AuditEvent(
            requestID: "fixture", caller: .localCLI,
            profileID: .cloudflareObserve, capabilityID: "oauth.authorization_approved",
            decision: .allowed))
        throw StoreFailure.rollback
      }
    }
    try connection.writer.read { (database: Database) throws in
      #expect(try Int.fetchOne(database, sql: "SELECT count(*) FROM oauthGrants") == 0)
      #expect(try Int.fetchOne(database, sql: "SELECT count(*) FROM auditEvents") == 0)
    }
  }

  @Test func separateConnectionsSerializeCodeConsumptionAndRefreshReuse() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("gateway.sqlite").path
    let firstStore = try GatewayDatabase(path: path)
    let secondStore = try GatewayDatabase(path: path)
    let configuration = OAuthServerConfiguration(
      tunnelID: "tunnel", tunnelName: "named", hostname: "gateway.example",
      clientAllowlist: ["client.example"])
    let first = OAuthAuthorizationServer(
      configuration: configuration, store: firstStore,
      identifier: CIMDClientIdentifier(fetcher: StoreDocument()))
    let second = OAuthAuthorizationServer(configuration: configuration, store: secondStore)
    let verifier = String(repeating: "a", count: 43)
    let pairing = try await first.authorize(
      [
        "response_type": "code", "client_id": "https://client.example/cimd",
        "redirect_uri": "https://consumer.example/callback", "state": "fixture",
        "code_challenge": OAuthSecret.challenge(verifier), "code_challenge_method": "S256",
        "resource": configuration.resource,
      ], address: "one")
    let grant = try await first.approve(
      pairingCode: pairing.request.pairingCode, approver: .localApp)
    guard
      case .redirect(let target) = try await second.status(
        statusToken: pairing.statusToken, address: "two"),
      let code = URLComponents(string: target)?.queryItems?.first(where: { $0.name == "code" })?
        .value
    else {
      throw OAuthError.invalidGrant
    }
    let fields = [
      "grant_type": "authorization_code", "client_id": "https://client.example/cimd", "code": code,
      "redirect_uri": "https://consumer.example/callback", "code_verifier": verifier,
      "resource": configuration.resource,
    ]
    async let a = try? first.token(fields, address: "one")
    async let b = try? second.token(fields, address: "two")
    let winners = await [a, b].compactMap { $0 }
    #expect(winners.count == 1)
    let issued = try #require(winners.first)
    let refresh = [
      "grant_type": "refresh_token", "client_id": "https://client.example/cimd",
      "refresh_token": issued.refreshToken, "resource": configuration.resource,
    ]
    let replacement = try await second.token(refresh, address: "two")
    await #expect(throws: OAuthError.invalidGrant) {
      try await first.token(refresh, address: "one")
    }
    #expect(
      try await second.authenticate(accessToken: replacement.accessToken, address: "two") == nil)
    #expect(try firstStore.oauthTransaction { try $0.grant(id: grant.id)?.revokedAt } != nil)
    let reopened = try GatewayDatabaseConnection(path: path)
    try await reopened.writer.read { (database: Database) throws in
      for table in [
        "oauthAuthorizationRequests", "oauthGrants", "oauthAuthorizationCodes", "oauthTokens",
      ] {
        let payloads = try String.fetchAll(database, sql: "SELECT payloadJSON FROM \(table)")
          .joined()
        for secret in [
          pairing.statusToken, code, issued.accessToken, issued.refreshToken,
          replacement.accessToken, replacement.refreshToken,
        ] {
          #expect(!payloads.contains(secret))
        }
      }
      let audit = try String.fetchAll(
        database, sql: "SELECT capabilityID FROM auditEvents ORDER BY occurredAt, rowid")
      #expect(
        audit.suffix(3) == [
          "oauth.refresh_token_reuse", "oauth.grant_revoked", "oauth.sessions_ended",
        ])
    }
  }
}

private enum StoreFailure: Error, Equatable { case rollback }
private struct StoreDocument: CIMDFetching {
  func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
    Data(
      #"{"client_id":"https://client.example/cimd","redirect_uris":["https://consumer.example/callback"]}"#
        .utf8)
  }
}
