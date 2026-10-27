import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Crypto
import Foundation
import Testing

@testable import ComputerMCPComputerUse
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)

final class GatewayRuntimeTests {
  @Test
  func testRoutesExplicitProjectAndRejectsCrossProjectAccess() throws {
    let first = try temporaryDirectory()
    let second = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    try "first".write(
      to: first.appendingPathComponent("value.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "second".write(
      to: second.appendingPathComponent("value.txt"),
      atomically: true,
      encoding: .utf8
    )
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([
        .project("first"): .granted(.read), .project("second"): .denied,
      ]), builtin: ["file.read"], database: database,
      projects: [
        project(id: "first", root: first),
        project(id: "second", root: second),
      ])

    let listedNames = try gateway.listTools(context: .empty).map(\.name)
    #expect(Set(["project.list", "project.describe", "file.read"]).isSubset(of: Set(listedNames)))
    let fileRead = try #require(
      gateway.listTools(context: .empty).first(where: { $0.name == "file.read" })
    )
    #expect(
      (fileRead.inputSchema.objectValue?["properties"]?.objectValue?["project_id"]?
        .objectValue?["type"]) == (.string("string")))

    expectThrows(
      try gateway.callTool(
        name: "file.read",
        arguments: .object(["path": .string("value.txt")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("project_id"))
    }

    let result = try gateway.callTool(
      name: "file.read",
      arguments: .object([
        "project_id": .string("first"),
        "path": .string("value.txt"),
      ]), context: .empty
    )
    #expect((try payload(result).objectValue?["content"]) == (.string("first")))

    expectThrows(
      try gateway.callTool(
        name: "file.read",
        arguments: .object([
          "project_id": .string("second"),
          "path": .string("value.txt"),
        ]), context: .empty
      )
    ) { error in
      #expect((error as? GatewayPermissionCallError)?.code == "permission.denied")
      #expect(GatewayRuntime.auditDecision(for: error) == .denied)
    }

    let projectList = try gateway.callTool(
      name: "project.list", arguments: .object([:]), context: .empty)
    let rows = try #require(payload(projectList).objectValue?["projects"]?.arrayValue)
    #expect(Set(rows.compactMap { $0.objectValue?["id"]?.stringValue }) == ["first", "second"])
    let allowed = try #require(rows.first { $0.objectValue?["id"] == .string("first") })
    let denied = try #require(rows.first { $0.objectValue?["id"] == .string("second") })
    #expect(allowed.objectValue?["caller_access"] == .string("read"))
    #expect(denied.objectValue?["caller_access"] == .string("deny"))
    #expect(rows.allSatisfy { $0.objectValue?["root_path"] == nil })
    let described = try gateway.callTool(
      name: "project.describe", arguments: .object(["project_id": .string("first")]),
      context: .empty)
    #expect(
      try payload(described).objectValue?["root_path"]
        == .string(first.resolvingSymlinksInPath().path))
    let hidden = try gateway.callTool(
      name: "project.describe", arguments: .object(["project_id": .string("second")]),
      context: .empty)
    #expect(try payload(hidden).objectValue?["root_path"] == nil)
  }

  @Test
  func testShellFacilityMustBeEnabled() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = project(id: "root", root: root)
    let database = try GatewayDatabase(inMemory: ())
    let execution = try programFixture(
      root: root, program: "import sys\nsys.stdout.write('gateway-shell')\n")
    let disabled = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.write)]), builtin: [],
      database: database, projects: [project], shellEnabled: false, fullAccess: true,
      caller: .localMCP, profileID: .localAdmin, platform: execution.platform)
    #expect(!(try disabled.listTools(context: .empty).contains(where: { $0.name == "shell.run" })))

    let enabled = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.write)]), builtin: [],
      database: database, projects: [project], shellEnabled: true, fullAccess: true,
      caller: .localMCP, profileID: .localAdmin, platform: execution.platform)
    do {
      #expect(try enabled.listTools(context: .empty).contains(where: { $0.name == "shell.run" }))
      let result = try await enabled.callToolAsync(
        name: "shell.run",
        arguments: .object([
          "project_id": .string(project.id), "mode": .string("argv"),
          "executable": .string("/usr/bin/python3"),
          "argv": .array([.string(execution.script.path)]),
        ]),
        context: .empty
      )
      #expect(
        (try payload(result).objectValue?["stdout"]?.objectValue?["text"])
          == (.string("gateway-shell")))
    } catch {
      await enabled.shutdown()
      await disabled.shutdown()
      throw error
    }
    await enabled.shutdown()
    await disabled.shutdown()
  }

  @Test
  func testRemoteCallerCanUseConsentedFullAccess() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let execution = try programFixture(
      root: root, program: "import sys\nsys.stdout.write('approved-shell')\n")
    let gateway = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.write)]), builtin: [],
      database: database, projects: [project(id: "root", root: root)], shellEnabled: true,
      fullAccess: true, caller: .secureTunnel, profileID: .chatGPTOperate,
      platform: execution.platform)

    do {
      #expect(try gateway.listTools(context: .empty).contains { $0.name == "shell.run" })
      let result = try await gateway.callToolAsync(
        name: "shell.run",
        arguments: .object([
          "project_id": .string("root"), "mode": .string("argv"),
          "executable": .string("/usr/bin/python3"),
          "argv": .array([.string(execution.script.path)]),
        ]),
        context: .empty
      )
      #expect(
        try payload(result).objectValue?["stdout"]?.objectValue?["text"]
          == .string("approved-shell")
      )
    } catch {
      await gateway.shutdown()
      throw error
    }
    await gateway.shutdown()
  }

  @Test
  func testAuthorizedWriteExecutesDirectlyAndKeepsAuditIdentity() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.write)]),
      builtin: ["file.write"], database: database, projects: [project(id: "root", root: root)],
      fullAccess: true)
    let result = try gateway.callTool(
      name: "file.write",
      arguments: .object([
        "path": .string("value.txt"), "content": .string("authorized"),
      ]), context: .empty)
    #expect(result.objectValue?["isError"] != .bool(true))
    #expect(
      try String(contentsOf: root.appendingPathComponent("value.txt"), encoding: .utf8)
        == "authorized")
    let audit = try #require(
      database.auditEvents().first {
        $0.capabilityID == "file.write" && $0.errorCode != "permission.admitted"
      })
    #expect(audit.decision == .allowed)
    #expect(audit.projectID == "root")
  }

  @Test
  func testEscapingSymlinkTargetFailsBeforeMutation() throws {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let target = outside.appendingPathComponent("protected.txt")
    try Data("unchanged".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let gateway = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.write)]),
      builtin: ["file.write"], database: try .init(inMemory: ()),
      projects: [project(id: "root", root: root)], fullAccess: true)
    #expect(throws: (any Error).self) {
      try gateway.callTool(
        name: "file.write",
        arguments: .object([
          "path": .string("escape/protected.txt"), "content": .string("changed"),
        ]), context: .empty)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
  }

  @Test
  func testFailedWriteRecordsTheTargetAuditAttribution() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.write)]),
      builtin: ["file.remove_xattr"], database: database,
      projects: [project(id: "root", root: root)], fullAccess: true)
    #expect(throws: (any Error).self) {
      try gateway.callTool(
        name: "file.remove_xattr",
        arguments: .object([
          "path": .string("missing.txt"), "name": .string("user.fixture"),
        ]), context: .empty)
    }
    let audit = try #require(
      database.auditEvents().first {
        $0.capabilityID == "file.remove_xattr" && $0.errorCode != "permission.admitted"
      })
    #expect(audit.decision == .failed || audit.decision == .denied)
    #expect(audit.projectID == "root")
  }

  @Test
  func testSingleProjectMayBeSelectedImplicitly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try "single".write(
      to: root.appendingPathComponent("value.txt"),
      atomically: true,
      encoding: .utf8
    )
    let gateway = try makeGateway(
      permissions: fixturePermissions([.project("only"): .granted(.read)]), builtin: ["file.read"],
      database: try GatewayDatabase(inMemory: ()), projects: [project(id: "only", root: root)])

    let result = try gateway.callTool(
      name: "file.read",
      arguments: .object(["path": .string("value.txt")]), context: .empty
    )
    #expect((try payload(result).objectValue?["content"]) == (.string("single")))
  }

  @Test
  func testGenericExecutionRequiresProjectWrite() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let command = CLICommandConfig(id: "echo", executable: "/bin/echo", allowAnyArgs: true)
    let restricted = try makeGateway(
      permissions: fixturePermissions([
        .machineInformation: .granted(.access), .project("root"): .granted(.read),
      ]), builtin: [], database: try .init(inMemory: ()),
      projects: [project(id: "root", root: root)],
      cli: .init(commands: [command]))
    #expect(try restricted.listTools(context: .empty).contains { $0.name == "process.spawn" })
    #expect(throws: (any Error).self) {
      try restricted.callTool(
        name: "process.spawn",
        arguments: .object([
          "id": .string("echo"), "argv": .array([.string("blocked")]),
        ]), context: .empty)
    }
  }

  @Test
  func testComputerUseToolsRequirePrivacyPermissions() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = project(id: "root", root: root)

    let gateway = try makeGateway(
      permissions: fixturePermissions([
        .screen: .granted(.access), .desktopControl: .granted(.access),
      ]), builtin: [], database: try GatewayDatabase(inMemory: ()), projects: [project])
    #expect(
      Set(["computer.permissions", "computer.displays", "computer.pointer.click"]).isSubset(
        of: Set(try gateway.listTools(context: .empty).map(\.name))))

    let permissions = try gateway.callTool(
      name: "computer.permissions", arguments: .object([:]), context: .empty)
    #expect((try payload(permissions).objectValue?["accessibility"]) != nil)
  }

  @Test
  func testEachGatewayCallReceivesAUniqueAuditRequestID() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([
        .screen: .granted(.access), .project("root"): .granted(.read),
      ]), builtin: [], database: database, projects: [project(id: "root", root: root)])

    _ = try gateway.callTool(name: "computer.permissions", arguments: .object([:]), context: .empty)
    _ = try gateway.callTool(name: "computer.permissions", arguments: .object([:]), context: .empty)

    let events = try database.auditEvents().filter { $0.capabilityID == "computer.permissions" }
    let admissions = events.filter { $0.errorCode == "permission.admitted" }
    let terminal = events.filter { $0.errorCode != "permission.admitted" }
    #expect(admissions.count == 2 && terminal.count == 2)
    #expect(Set(terminal.map(\.requestID)).count == 2)
    #expect(Set(admissions.map(\.requestID)) == Set(terminal.map(\.requestID)))
    #expect(terminal.allSatisfy { $0.decision == .allowed && $0.outputDigest != nil })
  }

  @Test
  func testSuccessfulCallReturnsThePersistedAuditCorrelation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.read)]), builtin: [],
      database: database, projects: [project(id: "root", root: root)])

    let result = try gateway.callTool(
      name: "project.list", arguments: .object([:]), context: .empty)
    let structuredContent = try #require(
      result.objectValue?["structuredContent"]?.objectValue
    )
    let execution = try #require(
      structuredContent["gateway_execution"]?.objectValue
    )
    let requestID = try #require(execution["request_id"]?.stringValue)
    let event = try #require(
      try database.auditEvents().first {
        $0.requestID == requestID && $0.capabilityID == "project.list"
          && $0.errorCode != "permission.admitted"
      })

    #expect((requestID) == (event.requestID))
    #expect((execution["caller"]) == (.string("secure-tunnel")))
    #expect((execution["profile_id"]) == (.string("chatgpt-operate")))
    #expect((execution["capability_id"]) == (.string("project.list")))
    #expect(
      (result.objectValue?["_meta"]?.objectValue?["computer_mcp"]?.objectValue?[
        "request_id"
      ]) == (.string(requestID)))
  }

  @Test
  func testUnknownToolAndRouteFailuresAreAudited() throws {
    let first = try temporaryDirectory()
    let second = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([
        .project("first"): .granted(.read), .project("second"): .denied,
      ]), builtin: ["file.read"], database: database,
      projects: [
        project(id: "first", root: first),
        project(id: "second", root: second),
      ])

    expectThrows(
      try gateway.callTool(name: "unknown.tool", arguments: .object([:]), context: .empty)
    )
    expectThrows(
      try gateway.callTool(
        name: "file.read",
        arguments: .object([
          "project_id": .string("second"),
          "path": .string("value.txt"),
        ]), context: .empty
      )
    )

    let events = try database.auditEvents()
    #expect((events.count) == (2))
    #expect((Set(events.map(\.capabilityID))) == (["unknown.tool", "file.read"]))
    let unknownTool = try #require(events.first { $0.capabilityID == "unknown.tool" })
    let crossProject = try #require(events.first { $0.capabilityID == "file.read" })
    #expect((unknownTool.decision) == (.failed))
    #expect((unknownTool.errorCode) == ("gateway.tool_unknown"))
    #expect((crossProject.decision) == (.denied))
    #expect(crossProject.errorCode == "permission.denied")
    #expect(
      events.allSatisfy {
        $0.inputDigest != nil && $0.outputDigest != nil && $0.outputByteCount != nil
      })
  }

  @Test
  func testComputerUsePermissionFailureHasStableDeniedAuditClassification() {
    let error = ComputerUseGatewayProviderError.service(
      .permissionRequired(.accessibility)
    )

    #expect((GatewayRuntime.auditDecision(for: error)) == (.denied))
    #expect((GatewayRuntime.auditErrorCode(for: error)) == ("computer_use.permission_required"))
  }

  @Test
  func testComputerUseArgumentFailureHasStableFailedAuditClassification() {
    let error = ComputerUseGatewayProviderError.invalidArguments("Invalid pointer button.")

    #expect(GatewayRuntime.auditDecision(for: error) == .failed)
    #expect(GatewayRuntime.auditErrorCode(for: error) == "computer_use.invalid_arguments")
  }

  @Test
  func testUnclassifiedErrorUsesDefaultAuditClassification() {
    struct UnclassifiedError: AuditErrorClassifying {
      var auditClassification: (decision: AuditDecision, code: String)? { nil }
    }

    #expect(GatewayRuntime.auditDecision(for: UnclassifiedError()) == .failed)
    #expect(GatewayRuntime.auditErrorCode(for: UnclassifiedError()) == nil)
  }

  @Test
  func testSecurityValidationFailuresHaveStableDeniedAuditClassification() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.read)]), builtin: ["file.read"],
      database: database, projects: [project(id: "root", root: root)])

    var refusalCode: String?
    do {
      _ = try gateway.callTool(
        name: "file.read",
        arguments: .object([
          "project_id": .string("root"), "path": .string("../outside.txt"),
        ]), context: .empty)
      Issue.record("A read outside the granted project must be refused")
    } catch {
      #expect(GatewayRuntime.auditDecision(for: error) == .denied)
      refusalCode = GatewayRuntime.auditErrorCode(for: error)
      #expect(refusalCode == "permission.invalid_path")
    }
    let event = try #require(
      try database.auditEvents().first {
        $0.capabilityID == "file.read" && $0.errorCode != "permission.admitted"
      })
    #expect(event.decision == .denied)
    #expect(event.errorCode == refusalCode)

    let inspectionFailure = ProjectPathResolutionError.cannotInspectExistingAncestor(
      path: root.path, code: EIO)
    #expect(GatewayRuntime.auditDecision(for: inspectionFailure) == .failed)
    #expect(GatewayRuntime.auditErrorCode(for: inspectionFailure) == nil)

    let deniedPermission = GatewayToolError.invalidArguments(
      "[permission.denied] The owner denied this permission."
    )
    let unapprovedDownstreamTool = GatewayToolError.invalidArguments(
      "[mcp.tool_not_approved] The downstream tool is not approved."
    )
    #expect((GatewayRuntime.auditDecision(for: deniedPermission)) == (.denied))
    #expect((GatewayRuntime.auditDecision(for: unapprovedDownstreamTool)) == (.denied))
    #expect(
      (GatewayRuntime.auditErrorCode(for: deniedPermission)) == ("permission.denied"))
    #expect(
      (GatewayRuntime.auditErrorCode(for: unapprovedDownstreamTool)) == ("mcp.tool_not_approved")
    )
  }

  @Test
  func testMCPFailureReturnsExactlyAuditedErrorEnvelope() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([.project("root"): .granted(.read)]), builtin: [],
      database: database, projects: [project(id: "root", root: root)])

    let result = try await gateway.callToolForMCPAsync(
      name: "unknown.tool",
      arguments: .object([:]), context: .empty
    )
    let event = try #require(try database.auditEvents().first)
    let data = try canonicalEncoder().encode(result)

    #expect((result.objectValue?["isError"]) == (.bool(true)))
    #expect((event.decision) == (.failed))
    #expect((event.errorCode) == ("gateway.tool_unknown"))
    #expect((event.outputByteCount) == (data.count))
    #expect((event.outputDigest) == (digest(data)))
  }

  @Test
  func testShellSessionsAreIsolatedByProjectRuntime() async throws {
    let first = try temporaryDirectory()
    let second = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let execution = try programFixture(
      root: first,
      program:
        "import sys, time\nsys.stdout.write('owned\\n')\nsys.stdout.flush()\ntime.sleep(30)\n")
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      permissions: fixturePermissions([
        .project("first"): .granted(.write), .project("second"): .granted(.write),
      ]), builtin: [], database: database,
      projects: [project(id: "first", root: first), project(id: "second", root: second)],
      shellEnabled: true, fullAccess: true, caller: .localMCP, profileID: .localAdmin,
      platform: execution.platform)
    do {
      let spawned = try await gateway.callToolAsync(
        name: "shell.spawn",
        arguments: .object([
          "project_id": .string("first"), "mode": .string("argv"),
          "executable": .string("/usr/bin/python3"),
          "argv": .array([.string(execution.script.path)]),
        ]), context: .empty)
      let sessionID = try #require(payload(spawned).objectValue?["session_id"]?.stringValue)
      let owner = try #require(gateway.ownedWork.snapshot.first)
      #expect(gateway.ownedWork.snapshot.count == 1)
      #expect(owner.kind == .shell && owner.projectID == "first" && owner.resourceID == sessionID)
      await #expect(throws: (any Error).self) {
        try await gateway.callToolAsync(
          name: "shell.read",
          arguments: .object([
            "project_id": .string("second"), "session_id": .string(sessionID),
          ]), context: .empty)
      }
      let retained = try await gateway.callToolAsync(
        name: "shell.read",
        arguments: .object([
          "project_id": .string("first"), "session_id": .string(sessionID),
        ]), context: .empty)
      #expect(retained.objectValue?["isError"] != .bool(true))
      #expect(gateway.ownedWork.snapshot.first?.projectID == "first")
      _ = try await gateway.callToolAsync(
        name: "shell.cancel",
        arguments: .object([
          "project_id": .string("first"), "session_id": .string(sessionID),
        ]), context: .empty)
      await gateway.shutdown()
    } catch {
      await gateway.shutdown()
      throw error
    }
  }

  private func makeGateway(
    permissions: Permissions, builtin: [String], database: GatewayDatabase,
    projects: [ComputerMCPCore.RegisteredProject], shellEnabled: Bool = false,
    fullAccess: Bool = false,
    cli: CLISectionConfig = .init(), caller: GatewayCallerKind = .secureTunnel,
    profileID: GatewayProfileID = .chatGPTOperate, allowedCallers: [GatewayCallerKind]? = nil,
    platform suppliedPlatform: PlatformServices? = nil
  ) throws -> GatewayRuntime {
    var grant = ProfileGrant(
      id: profileID, permissions: permissions, fullAccess: fullAccess,
      allowedCallers: Set(allowedCallers ?? [caller]))
    for project in projects { try database.saveProject(project) }
    try database.saveProfile(grant)
    grant = try #require(database.profiles().first { $0.id == profileID })
    let root = URL(fileURLWithPath: try #require(projects.first).rootPath)
    let nonGit = try fixtureNonGitProject(root: root)
    var platform = suppliedPlatform ?? nonGit.platform
    platform.permissionPolicyReader = TestManagedPolicyReader()
    var commands = cli
    if !commands.commands.contains(where: { $0.id == "git" }) {
      commands.commands.append(nonGit.git)
    }
    let configuration = GatewayConfiguration(
      schemaVersion: 1,
      runtime: .init(caller: caller, profileID: profileID),
      policy: .init(shellEnabled: shellEnabled),
      profiles: [.init(grant: grant)], cli: commands, builtin: .init(enabled: builtin),
      projectDirectory: root)
    let context =
      fullAccess
      ? try fixtureConsentedContext(
        database: database, grant: grant, caller: caller, platform: platform)
      : ExecutionContext(
        caller: caller, profileID: profileID, trustedPrincipalID: "verified-fixture")
    return try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: projects,
      platform: platform)
  }

  private func programFixture(root: URL, program: String) throws -> (
    platform: PlatformServices, script: URL
  ) {
    let nonGit = try fixtureNonGitProject(root: root)
    let script = root.appendingPathComponent("program.py")
    try program.write(to: script, atomically: true, encoding: .utf8)
    let gitProgram = try String(contentsOfFile: nonGit.git.executable, encoding: .utf8)
    let gitArguments =
      HostGitConfiguration.arguments + [
        "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
      ]
    let launcher = fixtureProtocolExecutionLauncher(
      root: root, scripts: [program, gitProgram], arguments: [[], gitArguments])
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    return (platform, script)
  }

  private func project(id: String, root: URL) -> ComputerMCPCore.RegisteredProject {
    ComputerMCPCore.RegisteredProject(id: id, displayName: id, rootPath: root.path)
  }

  private func payload(_ result: JSONValue) throws -> JSONValue {
    try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
