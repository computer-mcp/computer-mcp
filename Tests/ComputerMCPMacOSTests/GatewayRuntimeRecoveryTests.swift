import ComputerMCPDarwinTestSupport
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct GatewayRuntimeRecoveryTests {
  @Test(arguments: [false, true])
  func failedStartupRecoveryCanRetryThroughTheGateway(bootstrap: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectRoot = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    try "ready".write(
      to: projectRoot.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
    let database = try fixturePermissionDatabase(
      path: root.appendingPathComponent("gateway.sqlite").path)
    let profile = ProfileGrant(
      id: .chatGPTOperate,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.read), .machineInformation: .granted(.access),
      ]),
      allowedCallers: [.localMCP])
    try database.saveProfile(profile)
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: projectRoot.path)
    try database.saveProject(project)
    let recordID = UUID()
    let journal = database.permissionExecutionRoot.appendingPathComponent("ownership")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    let receipt = journal.appendingPathComponent(UUID().uuidString + ".json")
    if bootstrap {
      try await database.connection.writer.write { db in
        try ExecutionRuntimeRecord(id: recordID, ownerID: UUID(), boot: "previous-host").save(db)
        try db.execute(
          sql:
            "CREATE TRIGGER fail_recovery BEFORE UPDATE ON permissionRuntimeExecutions BEGIN SELECT RAISE(ABORT, 'fixture recovery failure'); END"
        )
      }
    } else {
      try Data("incomplete receipt".utf8).write(to: receipt)
    }
    let observations = ExecutionObservations()
    var platform = MacOSPlatform.services(
      launcher: testExecutionLauncher(observations: observations))
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let gateway = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: profile.id), profiles: [.init(grant: profile)],
        builtin: .init(enabled: ["file.read", "system.software"]), projectDirectory: projectRoot),
      context: .init(
        caller: .localMCP, profileID: profile.id, projectID: project.id,
        trustedPrincipalID: "recovery-client"),
      database: database, registeredProjects: [project], platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    do {
      for tool in ["file.read", "system.software"] {
        let denied = try await gateway.callToolForMCPAsync(
          name: tool,
          arguments: .object(["path": .string("value.txt")]),
          context: .empty)
        #expect(denied.objectValue?["isError"] == .bool(true))
      }
      #expect(
        try gateway.permissionRuntime.store.readWithDatabase { _, ledger in
          ledger.authorizations.isEmpty
        })
      #expect(observations.ownerships.isEmpty)
      if bootstrap {
        try await database.connection.writer.write {
          try $0.execute(sql: "DROP TRIGGER fail_recovery")
        }
      } else {
        try FileManager.default.removeItem(at: receipt)
      }
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
          group.addTask {
            let result = try await gateway.callToolForMCPAsync(
              name: "file.read", arguments: .object(["path": .string("value.txt")]), context: .empty
            )
            #expect(result.objectValue?["isError"] != .bool(true), "\(result)")
          }
        }
        try await group.waitForAll()
      }
      let software = try await gateway.callToolForMCPAsync(
        name: "system.software", arguments: .object(["path": .string("value.txt")]), context: .empty
      )
      #expect(software.objectValue?["isError"] != .bool(true), "\(software)")
      #expect(observations.members.count == 1)
      if bootstrap {
        try await database.connection.writer.read { db in
          let record = try #require(try ExecutionRuntimeRecord.load(recordID, db))
          #expect(record.admissionFinished && record.completed)
        }
      }
      await gateway.shutdown()
    } catch {
      await gateway.shutdown()
      throw error
    }
  }
}
