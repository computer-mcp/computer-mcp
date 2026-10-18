import Foundation
import Testing

@testable import ComputerMCP

@Suite
struct GatewayExecutionOwnersTests {
  @Test
  func locatorRejectsUnknownFieldsInvalidIdentifiersAndUnboundedWorkspace() throws {
    let owner = GatewayOwnerSelection(
      runtimeID: UUID(), workspaceID: "workspace", ownershipID: UUID())
    #expect(try GatewayOwnerSelection(owner.json) == owner)
    let object = try #require(owner.json.objectValue)
    for (key, value): (String, JSONValue) in [
      ("runtime_id", .string("invalid")), ("ownership_id", .integer(1)),
      ("workspace_id", .string("")), ("workspace_id", .string("line\nbreak")),
      ("workspace_id", .string(String(repeating: "x", count: 1_025))),
      ("permission", .string("full-access")),
    ] {
      var invalid = object
      invalid[key] = value
      #expect(throws: GatewayToolError.self) { try GatewayOwnerSelection(.object(invalid)) }
    }
  }

  @Test
  func directoryPagesHaveBoundedBytesAndExcludeForeignScopesAndRevokedGrants() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = RegisteredWorkspace(id: "root", displayName: "Root", rootPath: root.path)
    let database = try GatewayDatabase(inMemory: ())
    try database.saveWorkspace(workspace)
    let configuration = GatewayConfiguration(
      policy: .init(shellEnabled: true),
      profiles: [GatewayProfileID.localAdmin, .chatGPTOperate].map {
        ProfileGrantConfig(
          id: $0, capabilities: ["runtime.owners.list", "runtime.owners.call"],
          workspaces: ["root"], allowedCallers: [.localMCP, .localCLI],
          fullShellEnabled: true, mode: .localFullAccess, confirmationPolicy: .never)
      })
    for profile in configuration.profiles { try database.saveProfile(profile.grant) }
    let own = ExecutionContext(
      caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "owner")
    var foreignPrincipal = own
    foreignPrincipal.trustedPrincipalID = "foreign"
    var foreignProfile = own
    foreignProfile.profileID = .chatGPTOperate
    var foreignCaller = own
    foreignCaller.caller = .localCLI
    var runtimes: [GatewayRuntime] = []
    var leases: [GatewayOwnedWork.Lease] = []
    defer { for lease in leases { lease.finish() } }
    do {
      for context in [own, own, foreignPrincipal, foreignProfile, foreignCaller] {
        runtimes.append(
          try await GatewayRuntime.make(
            configuration: configuration, context: context, database: database,
            registeredWorkspaces: [workspace], bundledPlugins: .init(packages: [], issues: [])))
      }
      let current = try #require(runtimes.first)
      var expected = Set<UUID>()
      for (index, runtime) in runtimes.enumerated() {
        for _ in 0..<(index < 2 ? 60 : 1) {
          let lease = runtime.ownedWork.retain(
            .shell, workspaceID: "root",
            resourceID: String(repeating: "x", count: 4_096))
          leases.append(lease)
          if index < 2 { expected.insert(lease.id) }
        }
        leases.append(
          runtime.ownedWork.retain(.invocation, workspaceID: "root", resourceID: "private"))
        leases.append(
          runtime.ownedWork.retain(.shell, workspaceID: "foreign", resourceID: "private"))
        leases.append(
          runtime.ownedWork.retain(
            .mcpResource, workspaceID: "root",
            registrationID: "ungranted", resourceID: "private"))
      }
      try await GatewayOwnerRouting.$runtimes.withValue(runtimes) {
        for foreign in [foreignPrincipal, foreignProfile, foreignCaller] {
          #expect(throws: GatewayToolError.self) {
            try current.callTool(
              name: "runtime.owners.list",
              arguments: .object(["workspace_id": .string("root")]), context: foreign)
          }
        }
        func page(_ extra: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
          var arguments = extra
          arguments["workspace_id"] = .string("root")
          let result = try current.callTool(
            name: "runtime.owners.list", arguments: .object(arguments))
          return try #require(
            result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
        }
        var after: JSONValue?
        var observed = Set<UUID>()
        var cursors = Set<String>()
        var pageCount = 0
        repeat {
          var arguments: [String: JSONValue] = ["limit": .integer(100)]
          arguments["after"] = after
          let result = try page(arguments)
          #expect(try JSONEncoder().encode(JSONValue.object(result)).count <= 132_000)
          let rows = try #require(result["owners"]?.arrayValue)
          #expect(!rows.isEmpty && rows.count < 100)
          for row in rows {
            let owner = try GatewayOwnerSelection(row.objectValue?["owner"])
            #expect(expected.contains(owner.ownershipID))
            #expect(observed.insert(owner.ownershipID).inserted)
          }
          after = result["next_cursor"]?.stringValue.map(JSONValue.string)
          if let cursor = after?.stringValue { try #require(cursors.insert(cursor).inserted) }
          pageCount += 1
          try #require(pageCount < 10)
        } while after != nil
        #expect(observed == expected)
        #expect(pageCount > 1)
        #expect(try page(["server": .string("ungranted")])["owners"] == .array([]))
        for invalid: [String: JSONValue] in [
          ["limit": .integer(0)], ["limit": .integer(101)], ["limit": .number(1.5)],
          ["after": .string("invalid")], ["server": .integer(1)], ["principal": .string("foreign")],
        ] {
          #expect(throws: GatewayToolError.self) { try page(invalid) }
        }
        var grant = try #require(try database.profiles().first { $0.id == .localAdmin })
        grant.fullShellEnabled = false
        try database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
        #expect(try page()["owners"] == .array([]))
        let foreignOwner = GatewayOwnerSelection(
          runtimeID: runtimes[2].generationID, workspaceID: "root",
          ownershipID: try #require(leases.last).id)
        let rejected = try await current.callToolForMCPAsync(
          name: "runtime.owners.call",
          arguments: .object([
            "workspace_id": .string("root"), "owner": foreignOwner.json,
            "tool": .string("shell.read"),
            "arguments": .object(["session_id": .string("private")]),
          ]))
        #expect(rejected.objectValue?["isError"] == .bool(true))
        #expect(String(describing: rejected).contains("runtime.owner_unavailable"))
      }
      for runtime in runtimes { await runtime.shutdown() }
    } catch {
      for runtime in runtimes { await runtime.shutdown() }
      throw error
    }
  }
}
