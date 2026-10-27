import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayPermissionAdmissionTests {
  @Test(arguments: [false, true])
  func probeUsesPublicRequirementsWithoutDisclosingAnUngrantedProjectRoot(projectMissing: Bool)
    async throws
  {
    let fixture = try AdmissionFixture(
      permissions: [.machineInformation: .granted(.access)],
      projectIDs: ["known"], boundProjectID: "known")
    try await fixture.run { fixture in
      let project = try #require(fixture.projects.first)
      let directory = URL(fileURLWithPath: project.rootPath)
      let content = "probe-private-" + UUID().uuidString
      try Data(content.utf8).write(to: directory.appendingPathComponent("value.txt"))
      let physicalDirectory = try ProjectPathResolver.canonicalProject(directory)
      if projectMissing { try FileManager.default.removeItem(at: directory) }
      let before = try fixture.control.view().requests.map(\.request.id)
      let response = try await fixture.call(
        "policy.probe",
        [
          "project_id": .string("known"), "capability_id": .string("file.read"),
          "arguments": .object(["path": .string("value.txt")]),
        ])
      let result = try payload(response)
      #expect(result["decision"] == .string("permission.required"))
      #expect(result["requirements"]?.objectValue?["access"] == .string("read"))
      #expect(result["requirements"]?.objectValue?["paths"]?.arrayValue?.isEmpty == false)
      let text = String(describing: response)
      #expect(!text.contains(project.rootPath))
      #expect(!text.contains(physicalDirectory.path))
      #expect(!text.contains(content))
      #expect(try fixture.control.view().requests.map(\.request.id) == before)
      try fixture.gateway.permissionRuntime.store.readWithDatabase { _, ledger in
        #expect(ledger.executions.isEmpty)
      }
      if projectMissing {
        #expect(!FileManager.default.fileExists(atPath: directory.path))
      } else {
        #expect(
          try String(contentsOf: directory.appendingPathComponent("value.txt"), encoding: .utf8)
            == content)
      }
    }
  }

  @Test func absoluteAliasesPreserveAuthorityAndEscapesCannotBorrowIt() async throws {
    let fixture = try AdmissionFixture(
      permissions: [.project("bound"): .granted(.read), .project("other"): .denied],
      projectIDs: ["bound", "other"], boundProjectID: "bound")
    try await fixture.run { fixture in
      let bound = URL(
        fileURLWithPath: try #require(fixture.projects.first { $0.id == "bound" }).rootPath)
      let other = URL(
        fileURLWithPath: try #require(fixture.projects.first { $0.id == "other" }).rootPath)
      let file = bound.appendingPathComponent("allowed.txt")
      try Data("exact project".utf8).write(to: file)
      try Data("outside project".utf8).write(to: other.appendingPathComponent("denied.txt"))
      let physical = try ProjectPathResolver.canonicalProject(bound)
      #expect(physical.path != bound.path)
      let allowed = try await fixture.call("file.read", ["path": .string(file.path)])
      #expect(try payload(allowed)["content"] == .string("exact project"))
      let before = try fixture.control.view().requests.count
      let relative = try await fixture.call("file.read", ["path": .string("../other/denied.txt")])
      #expect(relative.objectValue?["isError"] == .bool(true))
      #expect(try failure(relative)["request_ids"] == nil)
      let absolute = try await fixture.call(
        "file.read", ["path": .string(other.appendingPathComponent("denied.txt").path)])
      #expect(try failure(absolute)["code"] == .string("permission.denied"))
      #expect(try failure(absolute)["request_ids"] == nil)
      #expect(!String(describing: absolute).contains("outside project"))
      #expect(try fixture.control.view().requests.count == before)
    }
  }

  @Test(arguments: ["admission", "terminal", "lifecycle"])
  func auditFailureClosesAdmissionAndMarksUncertainCompletion(stage: String) async throws {
    let afterDispatch = stage != "admission"
    let provider = AdmissionCountingProvider()
    let fixture = try AdmissionFixture(
      permissions: [.machineInformation: .granted(.access)], provider: provider)
    try await fixture.run { fixture in
      try await fixture.database.connection.writer.write { database in
        let predicate =
          stage == "lifecycle"
          ? "NEW.capabilityID = 'execution.admission.closed'"
          : afterDispatch
            ? "NEW.capabilityID = 'system.info' AND NEW.errorCode IS NULL"
            : "NEW.errorCode = 'permission.admitted'"
        try database.execute(
          sql:
            "CREATE TRIGGER fail_fixture_audit BEFORE INSERT ON auditEvents WHEN \(predicate) BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END"
        )
      }
      let report = try await fixture.call("system.info")
      #expect(provider.executions == (afterDispatch ? 1 : 0))
      let error = try failure(report)
      #expect(report.objectValue?["isError"] == .bool(true))
      let records = try fixture.database.auditEvents().filter { $0.capabilityID == "system.info" }
      if afterDispatch {
        #expect(error["code"] == .string("audit.outcome_unknown"))
        #expect(error["message"]?.stringValue?.contains("does not authorize replay") == true)
        #expect(records.filter { $0.errorCode == "permission.admitted" }.count == 1)
        #expect(records.filter { $0.errorCode == "audit.outcome_unknown" }.count == 1)
      } else {
        #expect(records.count == 1)
        #expect(records.first?.decision == .failed)
        #expect(records.allSatisfy { $0.errorCode != "permission.admitted" })
      }
      try await fixture.database.connection.writer.write { database in
        try database.execute(sql: "DROP TRIGGER fail_fixture_audit")
      }
      try await fixture.gateway.permissionRuntime.coordinator.reconcile()
      #expect(provider.executions == (afterDispatch ? 1 : 0), "Recovery must not replay work")
      let recovered = try await fixture.call("system.info")
      #expect(recovered.objectValue?["isError"] != .bool(true))
      #expect(recovered.objectValue?["executed"] == .bool(true))
      #expect(
        provider.executions == (afterDispatch ? 2 : 1), "Only an explicit call dispatches again")
    }
  }

  @Test func stableListingsProbesViewsAndIdleMonitoringDoNotAdvanceAuthority() async throws {
    let fixture = try AdmissionFixture(permissions: [.machineInformation: .granted(.access)])
    try await fixture.run { fixture in
      _ = try payload(await fixture.call("system.info"))
      try await fixture.requireNoScratchDirectories()
      let subject = try GatewayPermissionSubject(
        context: .init(
          caller: .localMCP,
          profileID: fixture.grant.id, trustedPrincipalID: fixture.session.principalID))
      let service = fixture.gateway.permissionRuntime.service
      let requirements = try InvocationRequirements(actions: [
        .init(requirement: .init(.machineInformation, .access))
      ])
      _ = try service.probe(
        subject: subject, tool: "system.info", projectID: nil,
        argumentsDigest: "preview", requirements: requirements, connectionID: fixture.session.id)
      _ = try fixture.control.view()
      _ = try await fixture.gateway.listToolsAsync(context: .empty)
      let counter = TestAuthorizationEpochCounter.shared(
        forDatabasePath: try #require(fixture.database.fileURL).path)
      let before = try counter.withExclusiveAccess { try $0.read() }
      for _ in 0..<3 {
        _ = try service.probe(
          subject: subject, tool: "system.info", projectID: nil,
          argumentsDigest: "preview", requirements: requirements, connectionID: fixture.session.id)
        _ = try fixture.control.view()
        _ = try await fixture.gateway.listToolsAsync(context: .empty)
      }
      try await Task.sleep(for: .milliseconds(700))
      #expect(try counter.withExclusiveAccess { try $0.read() } == before)
      fixture.reader.set(.machineFile, .available(Data("[permissions]\nscreen = 'deny'\n".utf8)))
      _ = try fixture.control.view()
      #expect(try counter.withExclusiveAccess { try $0.read() } != before)
    }
  }

  @Test func admissionAndOutcomeCarryTheSameAuthorityWithoutArgumentsOrOutput() async throws {
    let fixture = try AdmissionFixture(permissions: [.machineInformation: .granted(.access)])
    try await fixture.run { fixture in
      let secret = "fixture-private-value-" + UUID().uuidString
      _ = try payload(await fixture.call("system.info", ["unused_private_value": .string(secret)]))
      let events = try fixture.database.auditEvents()
      let admitted = try #require(
        events.first { $0.capabilityID == "system.info" && $0.errorCode == "permission.admitted" })
      let terminal = try #require(
        events.first { $0.capabilityID == "system.info" && $0.errorCode == nil })
      #expect(events.filter { $0.requestID == admitted.requestID }.count == 2)
      let before = try #require(admitted.errorDetails?.objectValue)
      let after = try #require(terminal.errorDetails?.objectValue)
      for key in [
        "authorization_id", "authorization_epoch", "permission_revision", "profile_revision",
        "policy_revisions", "acting_principal",
      ] {
        #expect(before[key] != nil && before[key] == after[key])
      }
      let executionID = try #require(after["execution_id"]?.stringValue)
      #expect(
        events.contains {
          $0.capabilityID == "execution.reserved" && $0.invocationID == executionID
            && $0.parentRequestID == admitted.requestID
        })
      let bytes = try JSONEncoder().encode(events)
      #expect(!String(decoding: bytes, as: UTF8.self).contains(secret))
      #expect(admitted.inputDigest == terminal.inputDigest)
      #expect(admitted.outputDigest == nil && terminal.outputDigest != nil)
    }
  }

  @Test func machinePolicyTighteningReachesLiveWorkWithoutAnotherGatewayCall() async throws {
    let fixture = try AdmissionFixture(permissions: [.screen: .granted(.access)])
    try await fixture.run { fixture in
      _ = try payload(await fixture.call("project.list"))
      let runtime = fixture.gateway.permissionRuntime
      try await runtime.ready()
      let subject = try GatewayPermissionSubject(
        context: .init(
          caller: .localMCP,
          profileID: fixture.grant.id, trustedPrincipalID: fixture.session.principalID))
      let requirements = try InvocationRequirements(actions: [
        .init(requirement: .init(.screen, .access))
      ])
      guard
        case .allowed(let authorization) = try runtime.service.admit(
          subject: subject,
          tool: "fixture.live", projectID: nil, argumentsDigest: "fixture-digest",
          requirements: requirements,
          connectionID: fixture.session.id)
      else { throw PermissionModelError.invalidAuthorization }
      let scratch = fixture.root.appendingPathComponent("state.sqlite.executions")
        .appendingPathComponent(authorization.id.uuidString)
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
      let prepared = try await runtime.coordinator.prepare(
        authorizationID: authorization.id,
        context: .init(
          directory: SandboxPath(scratch.path), temporaryDirectory: SandboxPath(scratch.path),
          purpose: .remoteService, privateWorkingDirectory: true), connectionID: fixture.session.id)
      let cancelled = AdmissionCancellation()
      let work = try prepared.retainWork { await cancelled.mark() }
      try prepared.finishAdmission()
      fixture.reader.set(.machineFile, .available(Data("[permissions]\nscreen = 'deny'\n".utf8)))
      for _ in 0..<100 {
        if await cancelled.value { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await cancelled.value)
      #expect(throws: (any Error).self) {
        try prepared.accessExecution(prepared.executionID, operation: .readResult)
      }
      try work.finish()
      try await runtime.coordinator.reconcile()
    }
  }

  @Test(arguments: [false, true])
  func machineInformationDoesNotRequireProjectAccess(registeredProject: Bool) async throws {
    let fixture = try AdmissionFixture(
      permissions: [.machineInformation: .granted(.access)],
      projectIDs: registeredProject ? ["bound"] : [],
      boundProjectID: registeredProject ? "bound" : nil)
    try await fixture.run { fixture in
      let report = try await fixture.call("system.info")
      let result = try payload(report)
      #expect(result["operating_system"]?.objectValue?["name"] == .string("macOS"))
      #expect(
        result["process"]?.objectValue?["id"]?.int64Value
          == Int64(ProcessInfo.processInfo.processIdentifier))
      #expect(try fixture.control.view().requests.isEmpty)
      #expect(fixture.grant.permissions.state(for: .project("bound")) == .notGranted)
      try await fixture.requireNoScratchDirectories()
    }
  }

  @Test(arguments: ["missing", "explicit", "managed"])
  func screenAuthorizationRemainsIndependentOfFullAccess(source: String) async throws {
    var permissions: [Permission: PermissionState] = [.machineInformation: .granted(.access)]
    if source == "explicit" { permissions[.screen] = .denied }
    let fixture = try AdmissionFixture(permissions: permissions, fullAccess: true)
    try await fixture.run { fixture in
      try #require(fixture.session.snapshot.fullAccessConsent != nil)
      if source == "managed" {
        fixture.reader.set(.machineFile, .available(Data("[permissions]\nscreen = 'deny'\n".utf8)))
      }
      let report = try await fixture.call("computer.displays")
      let error = try failure(report)
      if source == "missing" {
        #expect(error["code"] == .string("permission.required"))
        let requests = try #require(error["requests"]?.arrayValue)
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.objectValue?["permission"] == .string("screen") })
        let persisted = try fixture.control.view().requests
        #expect(persisted.count == requests.count)
        let refusalAudit = try #require(
          fixture.database.auditEvents().first { $0.errorCode == "permission.required" })
        let recordedIDs = try #require(
          refusalAudit.errorDetails?.objectValue?["permission_request_ids"]?.arrayValue)
        #expect(
          Set(recordedIDs.compactMap(\.stringValue))
            == Set(persisted.map { $0.request.id.uuidString }))
        #expect(refusalAudit.errorDetails?.objectValue?["authorization_epoch"]?.stringValue != nil)
        #expect(
          persisted.allSatisfy {
            guard case .permission(let content) = $0.request.content else { return false }
            return content.requirement.permission == .screen && content.requirement.value == .access
          })
      } else {
        #expect(
          error["code"]
            == .string(source == "managed" ? "permission.managed_limit" : "permission.denied"))
        #expect(error["request_ids"] == nil)
        #expect(try fixture.control.view().requests.isEmpty)
      }
      #expect(fixture.session.snapshot.fullAccessConsent != nil)
    }
  }

  @Test(arguments: ["managed", "connection"])
  func projectMetadataHidesDeniedRootsUnderAWildcardReadGrant(source: String) async throws {
    let fixture = try AdmissionFixture(
      permissions: [.project("*"): .granted(.read)], projectIDs: ["public", "secret"])
    try await fixture.run { fixture in
      for id in ["public", "secret"] {
        let result = try payload(
          await fixture.call("project.describe", ["project_id": .string(id)]))
        #expect(
          result["root_path"]
            == .string(try #require(fixture.projects.first { $0.id == id }).rootPath))
        #expect(result["caller_access"] == .string("read"))
      }
      if source == "managed" {
        fixture.reader.set(.machineFile, .available(Data("[projects]\nsecret = 'deny'\n".utf8)))
      } else {
        try fixture.session.limitAccess(
          to: ManagedPolicy(permissionCeilings: fixturePermissions([.project("secret"): .denied])),
          expectedRevision: fixture.session.revision)
      }
      let list = try payload(await fixture.call("project.list"))
      let rows = try #require(list["projects"]?.arrayValue)
      #expect(rows.count == 2)
      #expect(rows.allSatisfy { $0.objectValue?["root_path"] == nil })
      #expect(
        rows.first { $0.objectValue?["id"] == .string("secret") }?.objectValue?["caller_access"]
          == .string("deny"))
      #expect(
        rows.first { $0.objectValue?["id"] == .string("public") }?.objectValue?["caller_access"]
          == .string("read"))
      let denied = try payload(
        await fixture.call("project.describe", ["project_id": .string("secret")]))
      #expect(denied["caller_access"] == .string("deny"))
      #expect(
        denied["root_path"] == nil && denied["bookmark_stale"] == nil && denied["access"] == nil)
      let readable = try payload(
        await fixture.call("project.describe", ["project_id": .string("public")]))
      #expect(
        readable["root_path"]
          == .string(try #require(fixture.projects.first { $0.id == "public" }).rootPath))
      #expect(try fixture.control.view().requests.isEmpty)
    }
  }

  @Test
  func missingPrivacyToolsAreListedAndManagedDeniedToolsAreHiddenWithoutPrompting() async throws {
    let fixture = try AdmissionFixture(permissions: [.machineInformation: .granted(.access)])
    try await fixture.run { fixture in
      let tools = try await fixture.gateway.listToolsAsync(context: .empty)
      let requestable = try #require(tools.first { $0.name == "computer.displays" })
      #expect(requestable.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
      #expect(try fixture.control.view().requests.isEmpty)
      fixture.reader.set(.machineFile, .available(Data("[permissions]\nscreen = 'deny'\n".utf8)))
      let limited = try await fixture.gateway.listToolsAsync(context: .empty)
      #expect(!limited.contains { $0.name == "computer.displays" })
      #expect(limited.contains { $0.name == "system.info" })
      #expect(try fixture.control.view().requests.isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func knownNetworkDiagnosticsRefuseBeforeAnyCommandStarts(fullAccess: Bool) async throws {
    let fixture = try AdmissionFixture(
      permissions: [.machineInformation: .granted(.access)], fullAccess: fullAccess)
    try await fixture.run { fixture in
      #expect(ExecutionAdministration.current == nil)
      #expect(try PreparedExecutionContext.current() == nil)
      let report = try await fixture.call(
        "network.ping", ["host": .string("127.0.0.1"), "count": .integer(1)])
      let error = try failure(report)
      #expect(error["code"] == .string("execution.unavailable"))
      #expect(
        error["message"]?.stringValue?.contains("prepared fixed-service network execution context")
          == true)
      #expect(try fixture.control.view().requests.isEmpty)
      #expect(
        try fixture.database.auditEvents().contains {
          $0.capabilityID == "network.ping" && $0.errorCode == "execution.unavailable"
        })
      #expect(ExecutionAdministration.current == nil)
      #expect(try PreparedExecutionContext.current() == nil)
      try await fixture.requireNoScratchDirectories()
    }
  }

  @Test
  func sandboxReadHelpersRemoveScratchAfterSuccessAndProviderFailure() async throws {
    let fixture = try AdmissionFixture(
      permissions: [.project("readable"): .granted(.read)], projectIDs: ["readable"],
      boundProjectID: "readable")
    try await fixture.run { fixture in
      let root = URL(fileURLWithPath: try #require(fixture.projects.first).rootPath)
      try Data("bounded read".utf8).write(to: root.appendingPathComponent("value.txt"))
      let allowed = try await fixture.call("file.read", ["path": .string("value.txt")])
      #expect(try payload(allowed)["content"] == .string("bounded read"))
      try await fixture.requireNoScratchDirectories()
      let failed = try await fixture.call("file.read", ["path": .string("missing.txt")])
      #expect(failed.objectValue?["isError"] == .bool(true))
      try await fixture.requireNoScratchDirectories()
    }
  }

  @Test
  func nativeLauncherRefusesACommandWithoutAnAuthorizedContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cm-no-context-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("started")
    #expect(ExecutionAdministration.current == nil)
    #expect(try PreparedExecutionContext.current() == nil)
    do {
      let child = try await testExecutionLauncher().start(
        executable: SandboxPath("/usr/bin/touch"), arguments: [marker.path],
        directory: SandboxPath(root.path),
        environment: ExecutionEnvironment(fullAccessVariables: [:]),
        mode: .fullAccess)
      _ = try await child.wait()
      Issue.record("A native command started without an authorized context")
    } catch {
      #expect(
        (error as? ExecutionEnvironmentError)?.description.contains(
          "No authorized execution context is installed") == true)
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  private func payload(_ report: JSONValue) throws -> [String: JSONValue] {
    try #require(report.objectValue?["isError"] != .bool(true), "\(report)")
    return try #require(
      report.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
  }

  private func failure(_ report: JSONValue) throws -> [String: JSONValue] {
    try #require(report.objectValue?["isError"] == .bool(true), "\(report)")
    return try #require(
      report.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
  }
}

private struct AdmissionFixture {
  let root: URL
  let database: GatewayDatabase
  let grant: ProfileGrant
  let projects: [ComputerMCPCore.RegisteredProject]
  let session: GatewayControlSession
  let gateway: GatewayRuntime
  let control: PermissionControlService
  let reader = TestManagedPolicyReader()

  init(
    permissions: [Permission: PermissionState], projectIDs: [String] = [],
    boundProjectID: String? = nil, fullAccess: Bool = false,
    provider: AdmissionCountingProvider? = nil
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-admission-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try fixturePermissionDatabase(path: root.appendingPathComponent("state.sqlite").path)
    grant = ProfileGrant(
      id: .chatGPTOperate, permissions: fixturePermissions(permissions),
      fullAccess: fullAccess, allowedCallers: [.localMCP])
    try database.saveProfile(grant)
    try database.bootstrapPermissionProfiles([grant])
    let projectRoot = root
    let projectDatabase = database
    projects = try projectIDs.map { id in
      let directory = projectRoot.appendingPathComponent(id)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let project = ComputerMCPCore.RegisteredProject(
        id: id, displayName: id, rootPath: directory.path)
      try projectDatabase.saveProject(project)
      return project
    }
    var platform = fixtureHostedPlatform()
    if let provider {
      platform = PlatformServices(
        launcher: platform.launcher, projectGrants: platform.projectGrants,
        pluginDirectories: platform.pluginDirectories, applications: platform.applications,
        toolProviders: AdmissionCountingFactory(provider: provider),
        managementToolNames: platform.managementToolNames,
        executableSearchDirectories: platform.executableSearchDirectories,
        gitExecutable: platform.gitExecutable, fileChanges: platform.fileChanges,
        executionProxy: platform.executionProxy, hostDataPaths: platform.hostDataPaths)
    }
    platform.permissionPolicyReader = reader
    let service = try database.permissionRuntime(platform: platform).service
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "admission-owner"),
      validate: {})
    control = PermissionControlService(service: service, owner: { owner })
    session = GatewayControlSession(
      principalID: "verified-admission-client", profileID: grant.id, caller: .localMCP,
      database: database, profile: .init(grant: grant, persisted: true), permissionService: service)
    if fullAccess { _ = try session.approveFullAccess(expectedRevision: session.revision) }
    var context = ExecutionContext(
      caller: .localMCP, profileID: grant.id, projectID: boundProjectID,
      trustedPrincipalID: session.principalID)
    context.controlSession = session
    gateway = try GatewayRuntime(
      configuration: GatewayConfiguration(
        runtime: .init(caller: .localMCP, profileID: grant.id), profiles: [.init(grant: grant)],
        builtin: .init(enabled: ["system.info", "file.read", "network.ping"]),
        projectDirectory: root),
      context: context, database: database, registeredProjects: projects, platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
  }

  func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
    try await gateway.callToolForMCPAsync(
      name: name, arguments: .object(arguments), context: .empty)
  }

  func requireNoScratchDirectories() async throws {
    let storage = root.appendingPathComponent("state.sqlite.executions")
    for _ in 0..<100 {
      try await gateway.permissionRuntime.coordinator.reconcile()
      let children = try FileManager.default.contentsOfDirectory(
        at: storage, includingPropertiesForKeys: nil)
      if children.filter({ UUID(uuidString: $0.lastPathComponent) != nil }).isEmpty { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Completed invocation retained private scratch")
  }

  func run(_ operation: (AdmissionFixture) async throws -> Void) async throws {
    do {
      try await operation(self)
      session.end()
      await gateway.shutdown()
      try await database.connection.writer.write { database in
        try database.execute(sql: "DROP TRIGGER IF EXISTS fail_fixture_audit")
      }
      try await requireNoScratchDirectories()
      try FileManager.default.removeItem(at: root)
    } catch {
      session.end()
      await gateway.shutdown()
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
}

private actor AdmissionCancellation {
  var value = false
  func mark() { value = true }
}

private final class AdmissionCountingProvider: GatewayToolProvider, @unchecked Sendable {
  let id = "admission-counting"
  private let lock = NSLock()
  private var count = 0
  var executions: Int { lock.withLock { count } }

  func definitions() throws -> [ToolDefinition] {
    [
      .init(
        tool: MCPTool(
          name: "system.info", description: "Admission dispatch probe",
          inputSchema: .object(["type": .string("object")])),
        capability: .init(
          id: "system.info", risk: .readOnly,
          requirement: .privacy(.machineInformation)))
    ]
  }

  func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    lock.withLock { count += 1 }
    return .object(["executed": .bool(true)])
  }
}

private struct AdmissionCountingFactory: GatewayToolProviderFactory {
  let provider: AdmissionCountingProvider

  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    .init(
      providers: { [provider] },
      downstreamPolicy: { reference, _ in
        throw GatewayToolError.unknownTool(reference.toolName)
      })
  }
}
