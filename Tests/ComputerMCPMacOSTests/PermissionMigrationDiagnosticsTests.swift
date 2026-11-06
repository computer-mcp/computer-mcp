import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import computer_mcp

struct PermissionMigrationDiagnosticsTests {
  @Test func appStartupReportsRemovedBuiltinAndDroppedGrantsOnce() throws {
    let temporary = try ScopedTemporaryDirectory()
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: temporary.url.appendingPathComponent("app"),
      logs: temporary.url.appendingPathComponent("logs"))
    try directories.prepare()
    let database = try fixturePermissionDatabase(path: directories.database.path)
    let platform = fixtureHostedPlatform()
    let manifest = """
      schema_version=1
      [builtin]
      enabled=["system.info", "delivery.apply"]
      [[profiles]]
      id="private-profile"
      mode="workspace-operations"
      capabilities=["delivery.apply", "private-grant"]
      allowed_callers=["secure-tunnel"]
      """
    try Data(manifest.utf8).write(to: directories.manifest)
    try AppControlPlaneService.activatePermissionMigration(
      directories: directories, database: database, platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    let log = directories.logs.appendingPathComponent("computer-mcp.jsonl")
    let first = try String(contentsOf: log, encoding: .utf8)
    #expect(first.split(separator: "\n").count == 1)
    #expect(first.contains("permissions.upgrade"))
    #expect(first.contains("Removed builtins: delivery.apply."))
    #expect(first.contains("Dropped grants: 2"))
    #expect(!first.contains("private-profile") && !first.contains("private-grant"))
    let store = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, applications: platform.applications))
    #expect(try store.activeConfiguration().builtin.enabled == ["system.info"])
    try AppControlPlaneService.activatePermissionMigration(
      directories: directories, database: database, platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    #expect(try String(contentsOf: log, encoding: .utf8) == first)
  }

  @Test func appSinkDeliversCompleteLongRetirementPathsBeforeAcknowledgement() throws {
    let temporary = try ScopedTemporaryDirectory()
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: temporary.url.appendingPathComponent("app"),
      logs: temporary.url.appendingPathComponent("logs"))
    try directories.prepare()
    let database = try fixturePermissionDatabase(path: directories.database.path)
    let checkout = "/" + String(repeating: "checkout/", count: 400) + "終\npath"
    let repository = "/" + String(repeating: "source/", count: 400) + "repository"
    let reportID = UUID().uuidString.lowercased()
    try database.connection.writer.write {
      try $0.execute(
        sql: """
          INSERT INTO pluginWorktreeRetirements
            (reportID, checkoutPath, sourceProjectID, sourceRegisteredAt, sourceRepository)
          VALUES (?, ?, ?, ?, ?)
          """, arguments: [reportID, checkout, "source", 1_700_000_000.0, repository])
    }
    try Data(GatewayConfiguration(builtin: .init(enabled: ["system.info"])).exportedTOML().utf8)
      .write(to: directories.manifest)
    try AppControlPlaneService.activatePermissionMigration(
      directories: directories, database: database, platform: fixtureHostedPlatform(),
      bundledPlugins: .init(packages: [], issues: []))
    let data = try Data(contentsOf: directories.logs.appendingPathComponent("computer-mcp.jsonl"))
    let records = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    let record = try #require(
      records.first {
        $0.objectValue?["event"] == .string(PluginWorktreeRetirementNotice.code)
      })
    let fields = try #require(record.objectValue?["fields"]?.objectValue)
    #expect(fields["checkout_path"] == .string(checkout))
    #expect(fields["source_repository"] == .string(repository))
    #expect(fields["source_project_id"] == .string("source"))
    #expect(fields["report_id"] == .string(reportID))
    #expect(fields["source_registered_at"] == .string("2023-11-14T22:13:20.000Z"))
    #expect(fields["code"] == .string(PluginWorktreeRetirementNotice.code))
    #expect(try PluginWorktreeRetirementStore(connection: database.connection).pending().isEmpty)
  }

  @Test func standaloneStartupReportsDroppedGrantsToStderrOnce() async throws {
    let temporary = try ScopedTemporaryDirectory()
    let database = try fixturePermissionDatabase(
      path: temporary.url.appendingPathComponent("state.sqlite").path)
    let legacy = LegacyProfileGrant(
      id: .chatGPTOperate, capabilityIDs: ["private-grant"],
      allowedCallers: [.localMCP], authorizationRevision: 1)
    try await database.connection.writer.write {
      try LegacyProfileRecord(legacy, updatedAt: Date()).insert($0)
    }
    let manifest = temporary.url.appendingPathComponent("standalone.toml")
    let original = try GatewayConfiguration(
      profiles: [.init(grant: .operate)], builtin: .init(enabled: ["system.info"])
    ).exportedTOML()
    try Data(original.utf8).write(to: manifest)
    let output = temporary.url.appendingPathComponent("stderr")
    try Data().write(to: output)
    let stderr = try FileHandle(forWritingTo: output)
    defer { try? stderr.close() }
    let command = try ServeStdio.parse(["--config", manifest.path])
    for _ in 0..<2 {
      _ = try await command.runtime.loadConfiguration(
        database: database, platform: fixtureHostedPlatform(), diagnosticOutput: stderr)
    }
    let diagnostic = try String(contentsOf: output, encoding: .utf8)
    #expect(diagnostic == "Permission upgrade: Dropped grants: 1 (grant details omitted).\n")
    #expect(!diagnostic.contains("private-grant"))
    #expect(try String(contentsOf: manifest, encoding: .utf8) == original)
  }
}
