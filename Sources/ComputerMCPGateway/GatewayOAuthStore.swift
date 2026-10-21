import ComputerMCPAuthorization
import ComputerMCPCore
import ComputerMCPPersistence
import Foundation
import GRDB

/// Valid only during the enclosing GatewayDatabase write transaction.
struct GatewayOAuthTransaction: OAuthStoreTransaction {
  let database: Database

  func profile(id: GatewayProfileID) throws -> ProfileGrant? {
    try ProfileRecord.fetchOne(database, key: id.rawValue)?.value()
  }

  func workspaceIDs() throws -> Set<String> {
    Set(try String.fetchAll(database, sql: "SELECT id FROM workspaces"))
  }

  func requests(tunnelID: String) throws -> [OAuthAuthorizationRequest] {
    try rows("oauthAuthorizationRequests", tunnelID: tunnelID)
  }

  func save(_ request: OAuthAuthorizationRequest) throws {
    try database.execute(
      sql: """
        INSERT INTO oauthAuthorizationRequests (id, tunnelID, pairingCode, statusDigest, expiresAt, payloadJSON)
        VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payloadJSON = excluded.payloadJSON
        """,
      arguments: [
        request.id, request.tunnelID, request.pairingCode, request.statusDigest,
        request.expiresAt.timeIntervalSince1970, try encode(request),
      ])
  }

  func grant(id: String) throws -> OAuthGrant? {
    try row("oauthGrants", key: "id", value: id)
  }

  func grants(tunnelID: String) throws -> [OAuthGrant] {
    try rows("oauthGrants", tunnelID: tunnelID)
  }

  func save(_ grant: OAuthGrant) throws {
    try database.execute(
      sql: """
        INSERT INTO oauthGrants (id, tunnelID, payloadJSON) VALUES (?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET payloadJSON = excluded.payloadJSON
        """, arguments: [grant.id, grant.tunnelID, try encode(grant)])
  }

  func code(digest: String) throws -> OAuthAuthorizationCode? {
    try row("oauthAuthorizationCodes", key: "digest", value: digest)
  }

  func save(_ code: OAuthAuthorizationCode) throws {
    try database.execute(
      sql: """
        INSERT INTO oauthAuthorizationCodes (digest, grantID, expiresAt, payloadJSON) VALUES (?, ?, ?, ?)
        ON CONFLICT(digest) DO UPDATE SET payloadJSON = excluded.payloadJSON
        """,
      arguments: [
        code.digest, code.grantID, code.expiresAt.timeIntervalSince1970, try encode(code),
      ])
  }

  func token(digest: String) throws -> OAuthToken? {
    try row("oauthTokens", key: "digest", value: digest)
  }

  func save(_ token: OAuthToken) throws {
    try database.execute(
      sql: """
        INSERT INTO oauthTokens (digest, grantID, kind, expiresAt, payloadJSON) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(digest) DO UPDATE SET payloadJSON = excluded.payloadJSON
        """,
      arguments: [
        token.digest, token.grantID, token.kind.rawValue,
        token.expiresAt.timeIntervalSince1970, try encode(token),
      ])
  }

  func endAuthorizations(tunnelID: String) throws {
    try database.execute(
      sql:
        "DELETE FROM oauthAuthorizationCodes WHERE grantID IN (SELECT id FROM oauthGrants WHERE tunnelID = ?)",
      arguments: [tunnelID])
    try database.execute(
      sql: "DELETE FROM oauthAuthorizationRequests WHERE tunnelID = ?", arguments: [tunnelID])
  }

  func reconcileTunnels(activeIDs: Set<String>) throws {
    let storedIDs = try String.fetchAll(
      database,
      sql: """
        SELECT tunnelID FROM oauthGrants UNION SELECT tunnelID FROM oauthAuthorizationRequests
        """)
    let now = Date()
    for id in storedIDs where !activeIDs.contains(id) {
      try OAuthAuthorizationServer.revokeTunnel(
        id: id, transaction: self, now: now, approver: .localApp)
    }
  }

  func audit(_ event: AuditEvent) throws {
    try database.execute(
      sql: """
        INSERT INTO auditEvents (id, occurredAt, requestID, caller, transport, tunnelInstanceID,
          tunnelProfileID, profileID, capabilityID, decision, errorCode, principalDigest)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        event.id, event.occurredAt, event.requestID, event.caller.rawValue,
        event.transport, event.tunnelInstanceID, event.tunnelProfileID, event.profileID.rawValue,
        event.capabilityID, event.decision.rawValue, event.errorCode, event.principalDigest,
      ])
  }

  func prune(before now: Date) throws {
    // Keep a decision available to its browser for one additional pairing lifetime.
    try database.execute(
      sql: "DELETE FROM oauthAuthorizationRequests WHERE expiresAt < ?",
      arguments: [now.addingTimeInterval(-OAuthLimits.requestLifetime).timeIntervalSince1970])
    try database.execute(
      sql: "DELETE FROM oauthAuthorizationCodes WHERE expiresAt < ?",
      arguments: [now.timeIntervalSince1970])
    try database.execute(
      sql: "DELETE FROM oauthTokens WHERE kind = 'access' AND expiresAt < ?",
      arguments: [now.timeIntervalSince1970])
  }

  private func rows<T: Decodable>(_ table: String, tunnelID: String) throws -> [T] {
    try String.fetchAll(
      database, sql: "SELECT payloadJSON FROM \(table) WHERE tunnelID = ? ORDER BY id",
      arguments: [tunnelID]
    ).map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
  }

  private func row<T: Decodable>(_ table: String, key: String, value: String) throws -> T? {
    try String.fetchOne(
      database, sql: "SELECT payloadJSON FROM \(table) WHERE \(key) = ?", arguments: [value]
    )
    .map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
  }

  private func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
}
