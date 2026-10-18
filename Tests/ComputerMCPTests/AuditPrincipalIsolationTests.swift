import Foundation
import GRDB
import Testing

@testable import ComputerMCP

struct AuditPrincipalIsolationTests {
  @Test
  func httpAuditsUseVerifiedPrincipalWhenConnectionTracesAreNil() async throws {
    let fixture = try AuditPrincipalFixture()
    defer { fixture.remove() }
    let firstContext = fixture.context(principal: "credential:first", connection: nil)
    let secondContext = fixture.context(principal: "credential:second", connection: nil)
    let first = try fixture.runtime(context: firstContext)
    let second = try fixture.runtime(context: secondContext)
    do {
      try fixture.inspect(first, context: firstContext, requestID: "first-http")
      try fixture.inspect(second, context: secondContext, requestID: "second-http")
      let database = try GatewayDatabase(path: fixture.databasePath)
      let firstAudits = try database.hostDiagnosticAudits(context: firstContext, limit: 100)
      let secondAudits = try database.hostDiagnosticAudits(context: secondContext, limit: 100)
      #expect(firstAudits.map(\.requestID) == ["first-http"])
      #expect(secondAudits.map(\.requestID) == ["second-http"])
      #expect(firstAudits.first?.socketConnectionID == nil)
      #expect(secondAudits.first?.socketConnectionID == nil)
      #expect(
        firstAudits.first?.principalDigest
          == AuditEvent.verifiedPrincipalDigest("credential:first"))
      var unverified = firstContext
      unverified.trustedPrincipalID = nil
      #expect(try database.hostDiagnosticAudits(context: unverified, limit: 100).isEmpty)
      unverified.trustedPrincipalID = " "
      #expect(try database.hostDiagnosticAudits(context: unverified, limit: 100).isEmpty)
      var wrongWorkspace = firstContext
      wrongWorkspace.workspaceID = "different-workspace"
      #expect(try database.hostDiagnosticAudits(context: wrongWorkspace, limit: 100).isEmpty)
      var wrongProfile = firstContext
      wrongProfile.profileID = .chatGPTObserve
      #expect(try database.hostDiagnosticAudits(context: wrongProfile, limit: 100).isEmpty)
      await first.shutdown()
      await second.shutdown()
    } catch {
      await first.shutdown()
      await second.shutdown()
      throw error
    }
  }

  @Test
  func reconnectReadsTheSamePrincipalHistoryWithoutTreatingTraceAsAuthority() async throws {
    let fixture = try AuditPrincipalFixture()
    defer { fixture.remove() }
    let original = fixture.context(principal: "tunnel-bridge:fixture", connection: "old-connection")
    let reconnect = fixture.context(
      principal: "tunnel-bridge:fixture", connection: "new-connection")
    let runtime = try fixture.runtime(context: original)
    do {
      try fixture.inspect(runtime, context: original, requestID: "before-reconnect")
      try fixture.inspect(runtime, context: reconnect, requestID: "after-reconnect")
      let audits = try fixture.database.hostDiagnosticAudits(context: reconnect, limit: 100)
      #expect(Set(audits.map(\.requestID)) == ["before-reconnect", "after-reconnect"])
      #expect(Set(audits.compactMap(\.socketConnectionID)) == ["old-connection", "new-connection"])
      var impostor = reconnect
      impostor.trustedPrincipalID = "tunnel-bridge:another"
      #expect(try fixture.database.hostDiagnosticAudits(context: impostor, limit: 100).isEmpty)
      var anotherChannel = reconnect
      anotherChannel.caller = .localCLI
      #expect(
        Set(
          try fixture.database.hostDiagnosticAudits(context: anotherChannel, limit: 100).map(\.id))
          == Set(audits.map(\.id)))
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func migrationPreservesUnboundHistoryWithoutInventingPrincipalAuthority() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("history.sqlite").path
    let historical = AuditEvent(
      id: "historical", occurredAt: Date(timeIntervalSince1970: 1000), requestID: "legacy",
      caller: .secureTunnel, transport: "http", profileID: .chatGPTOperate,
      workspaceID: "fixture", capabilityID: "file.read", decision: .allowed)
    try GatewayDatabase(path: path).recordAudit(historical)
    let previous = try DatabaseQueue(path: path)
    try previous.write { database in
      try database.execute(sql: "DROP INDEX auditEvents_on_verified_scope")
      try database.execute(sql: "ALTER TABLE auditEvents DROP COLUMN principalDigest")
      try database.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
        arguments: ["audit-verified-principal"])
    }
    try previous.close()
    let migrated = try GatewayDatabase(path: path)
    #expect(try migrated.auditEvents() == [historical])
    let remote = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate, workspaceID: "fixture",
      transportTrace: .init(transport: "http"), trustedPrincipalID: "credential:first")
    #expect(try migrated.hostDiagnosticAudits(context: remote, limit: 100).isEmpty)
    var bound = historical
    bound.id = "bound"
    bound.requestID = "verified"
    bound.principalDigest = AuditEvent.verifiedPrincipalDigest(remote.trustedPrincipalID)
    try migrated.recordAudit(bound)
    #expect(try migrated.hostDiagnosticAudits(context: remote, limit: 100) == [bound])
    #expect(try GatewayDatabase(path: path).auditEvents().count == 2)
  }
}

private struct AuditPrincipalFixture {
  let root: URL
  let database: GatewayDatabase
  var databasePath: String { root.appendingPathComponent("audits.sqlite").path }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try GatewayDatabase(path: root.appendingPathComponent("audits.sqlite").path)
    try database.saveProfile(
      .init(
        id: .chatGPTOperate, capabilityIDs: ["workspace.describe"], workspaceIDs: ["fixture"],
        allowedCallers: [.secureTunnel], mode: .readOnly))
  }

  func context(principal: String, connection: String?) -> ExecutionContext {
    .init(
      caller: .secureTunnel, profileID: .chatGPTOperate, workspaceID: "fixture",
      transportTrace: .init(
        transport: connection == nil ? "http" : "gateway_socket", socketConnectionID: connection),
      trustedPrincipalID: principal)
  }

  func runtime(context: ExecutionContext) throws -> GatewayRuntime {
    try GatewayRuntime(
      configuration: .init(), context: context, database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
      plugins: [])
  }

  func inspect(_ runtime: GatewayRuntime, context: ExecutionContext, requestID: String) throws {
    var request = context
    request.requestID = requestID
    _ = try runtime.callTool(
      name: "workspace.describe", arguments: .object(["workspace_id": .string("fixture")]),
      context: request)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
