import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite
struct GatewayExecutionOwnersTests {
  @Test
  func locatorRejectsUnknownFieldsInvalidIdentifiersAndUnboundedProject() throws {
    let owner = GatewayOwnerSelection(
      runtimeID: UUID(), projectID: "project", ownershipID: UUID())
    #expect(try GatewayOwnerSelection(owner.json) == owner)
    let object = try #require(owner.json.objectValue)
    for (key, value): (String, JSONValue) in [
      ("runtime_id", .string("invalid")), ("ownership_id", .integer(1)),
      ("project_id", .string("")), ("project_id", .string("line\nbreak")),
      ("project_id", .string(String(repeating: "x", count: 1_025))),
      ("permission", .string("full-access")),
    ] {
      var invalid = object
      invalid[key] = value
      #expect(throws: GatewayToolError.self) { try GatewayOwnerSelection(.object(invalid)) }
    }
  }

  @Test(.nativeIntegration)
  func derivedProjectDirectoryUsesInheritedAccessAndKeepsTheExactOwner() async throws {
    let fixture = try FixedHostFixture(fullAccess: false, lifecycle: true)
    try await fixture.run { fixture in
      try await fixture.initializeRepository()
      func router(principalID: String) async throws -> GatewayStandaloneGenerations {
        let runtime = try await GatewayRuntime.make(
          configuration: fixture.configuration,
          context: .init(
            caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: principalID),
          database: fixture.database, platform: fixture.platform,
          bundledPlugins: .init(packages: [], issues: []), requiresControlSession: true)
        return GatewayStandaloneGenerations(runtime)
      }
      let calls = try await router(principalID: fixture.session.principalID)
      do {
        let ownerSession = try await calls.makeControlSession()
        defer { ownerSession.end() }
        func call(
          _ name: String, _ arguments: [String: JSONValue],
          using router: GatewayStandaloneGenerations? = nil, session: GatewayControlSession? = nil
        ) async throws -> JSONValue {
          try await (router ?? calls).callToolForMCPAsync(
            name: name, arguments: .object(arguments),
            context: .init(session: session ?? ownerSession))
        }
        func payload(_ result: JSONValue) throws -> [String: JSONValue] {
          try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
          return try #require(
            result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
        }
        func errorCode(_ result: JSONValue) -> String? {
          result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]?
            .stringValue
        }
        let created = try payload(
          await call(
            "git.worktree_add", ["project_id": .string("fixture"), "name": .string("owners")]))
        let projectID = try #require(created["project_id"]?.stringValue)
        let scope: [String: JSONValue] = ["project_id": .string(projectID)]
        #expect(try fixture.database.derivedSourceID(for: projectID) == "fixture")
        let grant = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
        #expect(grant.permissions.state(for: .project("fixture")) == .granted(.write))
        #expect(grant.permissions.state(for: .project(projectID)) == .notGranted)

        let started = try payload(
          await call(
            "process.spawn",
            [
              "project_id": .string(projectID), "id": .string("fixture"),
              "argv": .array([.string("-c"), .string("exec /bin/cat")]),
            ]))
        let processID = try #require(started["process_id"]?.stringValue)
        let directory = try payload(await call("runtime.owners.list", scope))
        let owners = try #require(directory["owners"]?.arrayValue)
        let record = try #require(
          owners.first {
            $0.objectValue?["resource_id"] == .string(processID)
          }?.objectValue)
        let owner = try GatewayOwnerSelection(record["owner"])
        #expect(owner.projectID == projectID)
        let sourceDirectory = try payload(
          await call("runtime.owners.list", ["project_id": .string("fixture")]))
        #expect(
          sourceDirectory["owners"]?.arrayValue?.contains {
            $0.objectValue?["resource_id"] == .string(processID)
          } == false)

        let selection: [String: JSONValue] = [
          "project_id": .string(projectID), "owner": owner.json, "tool": .string("process.read"),
          "arguments": .object(["process_id": .string(processID)]),
        ]
        let result = try await call("runtime.owners.call", selection)
        #expect(try payload(result)["is_running"] == .bool(true))
        var wrongProject = selection
        wrongProject["project_id"] = .string("fixture")
        let mismatched = try await call("runtime.owners.call", wrongProject)
        #expect(errorCode(mismatched) == "runtime.owner_unavailable")

        let foreign = try await router(principalID: "other-owner")
        do {
          let session = try await foreign.makeControlSession()
          defer { session.end() }
          let foreignDirectory = try payload(
            await call("runtime.owners.list", scope, using: foreign, session: session))
          #expect(foreignDirectory["owners"] == .array([]))
          let refused = try await call(
            "runtime.owners.call", selection, using: foreign, session: session)
          #expect(errorCode(refused) == "runtime.owner_unavailable")
        } catch {
          await foreign.shutdown()
          throw error
        }
        await foreign.shutdown()

        let permissionOwner = try GatewayPermissionOwner(
          context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
          validate: {})
        let permissionService = fixture.runtime.permissionRuntime.service
        let view = try permissionService.view(owner: permissionOwner)
        _ = try permissionService.revokePermission(
          .project("fixture"), profileID: .chatGPTOperate, owner: permissionOwner,
          expectedRevision: view.revision)
        let revokedDirectory = try await call("runtime.owners.list", scope)
        #expect(errorCode(revokedDirectory) == "permission.denied")
        let revokedSelection = try await call("runtime.owners.call", selection)
        #expect(errorCode(revokedSelection) == "permission.invalid_authorization")
      } catch {
        await calls.shutdown()
        throw error
      }
      await calls.shutdown()
    }
  }

  @Test
  func directoryPagesHaveBoundedBytesAndExcludeForeignScopesAndRevokedGrants() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = RegisteredProject(id: "root", displayName: "Root", rootPath: root.path)
    let database = try GatewayDatabase(inMemory: ())
    try database.saveProject(project)
    let configuration = GatewayConfiguration(
      policy: .init(shellEnabled: true),
      profiles: [GatewayProfileID.localAdmin, .chatGPTOperate].map {
        ProfileGrantConfig(
          id: $0, permissions: fixturePermissions([.project("root"): .granted(.read)]),
          fullAccess: true, allowedCallers: [.localMCP, .localCLI])
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
            registeredProjects: [project],
            platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
            bundledPlugins: .init(packages: [], issues: [])))
      }
      let current = try #require(runtimes.first)
      var expected = Set<UUID>()
      for (index, runtime) in runtimes.enumerated() {
        for _ in 0..<(index < 2 ? 60 : 1) {
          let lease = runtime.ownedWork.retain(
            .shell, projectID: "root",
            resourceID: String(repeating: "x", count: 4_096))
          leases.append(lease)
          if index < 2 { expected.insert(lease.id) }
        }
        leases.append(
          runtime.ownedWork.retain(.invocation, projectID: "root", resourceID: "private"))
        leases.append(
          runtime.ownedWork.retain(.shell, projectID: "foreign", resourceID: "private"))
        leases.append(
          runtime.ownedWork.retain(
            .mcpResource, projectID: "root",
            registrationID: "ungranted", resourceID: "private"))
      }
      try await GatewayOwnerRouting.$runtimes.withValue(runtimes) {
        for foreign in [foreignPrincipal, foreignProfile, foreignCaller] {
          #expect(throws: GatewayToolError.self) {
            try current.callTool(
              name: "runtime.owners.list",
              arguments: .object(["project_id": .string("root")]), context: foreign,
              invocationContext: .empty)
          }
        }
        func page(_ extra: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
          var arguments = extra
          arguments["project_id"] = .string("root")
          let result = try current.callTool(
            name: "runtime.owners.list", arguments: .object(arguments), context: .empty)
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
        let foreignOwner = GatewayOwnerSelection(
          runtimeID: runtimes[2].generationID, projectID: "root",
          ownershipID: try #require(leases.last).id)
        let rejected = try await current.callToolForMCPAsync(
          name: "runtime.owners.call",
          arguments: .object([
            "project_id": .string("root"), "owner": foreignOwner.json,
            "tool": .string("shell.read"),
            "arguments": .object(["session_id": .string("private")]),
          ]), context: .empty)
        #expect(rejected.objectValue?["isError"] == .bool(true))
        #expect(String(describing: rejected).contains("runtime.owner_unavailable"))
        var grant = try #require(try database.profiles().first { $0.id == .localAdmin })
        try grant.permissions.set(.denied, for: .project("root"))
        try database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
        var deniedPage: [String: JSONValue]?
        do {
          deniedPage = try page()
          Issue.record("A directory query exposed owners after Project read was denied.")
        } catch let error as GatewayPermissionCallError {
          guard case .denied(let reason, _) = error else { throw error }
          #expect(error.code == "permission.denied")
          #expect(reason == .permissionDenied(.project("root")))
        }
        #expect(deniedPage == nil)
      }
      for lease in leases { lease.finish() }
      for runtime in runtimes { await runtime.shutdown() }
    } catch {
      for lease in leases { lease.finish() }
      for runtime in runtimes { await runtime.shutdown() }
      throw error
    }
  }
}
