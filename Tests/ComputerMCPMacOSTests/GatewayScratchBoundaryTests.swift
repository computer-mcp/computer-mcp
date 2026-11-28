import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDarwinTestSupport
import ComputerMCPGateway
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(1)))
struct GatewayScratchBoundaryTests {
  @Test(arguments: [false, true])
  func nativeHelpersReadAndWriteOnlyTheirOwnScratch(projectHelper: Bool) async throws {
    let fixture = try ScratchBoundaryFixture(projectHelper: projectHelper)
    defer { fixture.remove() }
    let authorization = try await fixture.authorize()
    let prepared = try await fixture.prepare(authorization)
    let home = prepared.environment.home.value
    let sibling = fixture.storage.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
    let siblingFile = sibling.appendingPathComponent("private")
    let hostFile = fixture.state.appendingPathComponent("host-state")
    for file in [siblingFile, hostFile] { try Data("private fixture".utf8).write(to: file) }
    let outside = fixture.root.appendingPathComponent("outside")
    let script = """
      set -eu
      printf owned > "$HOME/allowed"
      test "$(cat "$HOME/allowed")" = owned
      if (printf forbidden > "$1") 2>/dev/null; then exit 90; fi
      shift
      for file in "$@"; do
        if head -c 1 "$file" >/dev/null 2>&1; then exit 91; fi
      done
      printf ok
      """
    let launcher = fixture.launcher
    let directory = projectHelper ? fixture.project : URL(fileURLWithPath: home)
    let arguments = [
      "-c", script, "scratch-probe", outside.path, siblingFile.path,
      hostFile.path, fixture.databaseURL.path,
    ]
    let result = try await BlockingOperationExecutor(label: "scratch-boundary-test").perform {
      try prepared.withValue {
        try ManagedCommandRunner(launcher: launcher).run(
          executable: "/bin/sh", arguments: arguments, workingDirectory: directory,
          environment: [:], timeoutMilliseconds: 5_000, maxOutputBytes: 4096)
      }
    }
    #expect(result.exitCode == 0 && !result.timedOut, "\(result.stderr)")
    #expect(result.stdout == "ok")
    #expect(!FileManager.default.fileExists(atPath: outside.path))
    #expect(try String(contentsOf: siblingFile, encoding: .utf8) == "private fixture")
    #expect(try String(contentsOf: hostFile, encoding: .utf8) == "private fixture")
    #expect(try String(contentsOfFile: home + "/allowed", encoding: .utf8) == "owned")
    try prepared.finishAdmission()
    try await fixture.requireRemoved(URL(fileURLWithPath: home))
    #expect(FileManager.default.fileExists(atPath: siblingFile.path))
    #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
  }

  @Test(arguments: ["path", "owner", "machine", "connection", "sandbox"])
  func explicitDenialsKeepPrecedenceOverThePrivateScratchException(source: String) async throws {
    let fixture = try ScratchBoundaryFixture(projectHelper: true, denial: source)
    defer { fixture.remove() }
    let authorization = try await fixture.authorize()
    let scratch = fixture.storage.appendingPathComponent(authorization.id.uuidString)
    do {
      let prepared = try await fixture.prepare(authorization)
      try prepared.finishAdmission()
      Issue.record("An explicit \(source) denial was reopened as host scratch")
    } catch {
      #expect(
        error as? ExecutionEnvironmentError
          == .invalidConfiguration(
            "Writable locations intersect a forbidden root"))
    }
    try await fixture.requireRemoved(scratch)
  }

  @Test(arguments: [false, true])
  func existingDirectoriesAndSymlinksCannotBecomeOwnedScratch(symbolicLink: Bool) async throws {
    let fixture = try ScratchBoundaryFixture(projectHelper: false)
    defer { fixture.remove() }
    let authorization = try await fixture.authorize()
    let scratch = fixture.storage.appendingPathComponent(authorization.id.uuidString)
    let target = symbolicLink ? fixture.root.appendingPathComponent("existing") : scratch
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let sentinel = target.appendingPathComponent("owner-file")
    try Data("preserve".utf8).write(to: sentinel)
    if symbolicLink {
      try FileManager.default.createSymbolicLink(at: scratch, withDestinationURL: target)
    }
    do {
      let prepared = try await fixture.prepare(authorization)
      try prepared.finishAdmission()
      Issue.record("An existing filesystem object was adopted as private execution scratch")
    } catch {
      #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
    if symbolicLink {
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: scratch.path) == target.path)
    }
  }

  @Test(arguments: [false, true])
  func preparingWithoutLaunchingCleansItsScratch(aliasedState: Bool) async throws {
    let fixture = try ScratchBoundaryFixture(projectHelper: false, aliasedState: aliasedState)
    defer { fixture.remove() }
    let authorization = try await fixture.authorize()
    let prepared = try await fixture.prepare(authorization)
    let scratch = URL(fileURLWithPath: prepared.environment.home.value)
    #expect(FileManager.default.fileExists(atPath: scratch.path))
    try prepared.finishAdmission()
    try await fixture.requireRemoved(scratch)
  }
}

private final class ScratchBoundaryFixture {
  let root: URL
  let state: URL
  let project: URL
  let databaseURL: URL
  let storage: URL
  let database: GatewayDatabase
  let runtime: GatewayPermissionRuntime
  let subject: GatewayPermissionSubject
  let launcher: ExecutionLauncher
  let projectHelper: Bool
  let denial: String?
  let connectionID = UUID().uuidString

  init(projectHelper: Bool, denial: String? = nil, aliasedState: Bool = false) throws {
    // Repository-owned ignored test state exercises real home-directory classification.
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    root = repository.appendingPathComponent(".agent/tests/gateway-scratch-boundaries/\(UUID())")
      .resolvingSymlinksInPath()
    let physicalState = root.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: physicalState, withIntermediateDirectories: true)
    state = aliasedState ? root.appendingPathComponent("state-link") : physicalState
    if aliasedState {
      try FileManager.default.createSymbolicLink(at: state, withDestinationURL: physicalState)
    }
    project = root.appendingPathComponent("project")
    databaseURL = state.appendingPathComponent("gateway.sqlite")
    storage = state.appendingPathComponent("gateway.sqlite.executions")
    self.projectHelper = projectHelper
    self.denial = denial
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    database = try fixturePermissionDatabase(path: databaseURL.path)
    var permissions: [Permission: PermissionState] = [.machineInformation: .granted(.access)]
    if projectHelper { permissions[.project("project")] = .granted(.read) }
    let grant = ProfileGrant(
      id: .chatGPTOperate, permissions: fixturePermissions(permissions), allowedCallers: [.localMCP]
    )
    try database.saveProfile(grant)
    try database.bootstrapPermissionProfiles([grant])
    let registered = ComputerMCPCore.RegisteredProject(
      id: "project", displayName: "Project", rootPath: project.path)
    try database.saveProject(registered)
    launcher = testExecutionLauncher()
    let reader = TestManagedPolicyReader()
    if denial == "machine" {
      reader.set(
        .machineFile,
        .available(Data("denied_read_locations = ['\(state.path)']\n".utf8)))
    }
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = reader
    runtime = try database.permissionRuntime(platform: platform)
    subject = try GatewayPermissionSubject(
      context: .init(
        caller: .localMCP, profileID: grant.id, trustedPrincipalID: "scratch-fixture"))
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
    var rules: Set<PathRule> = [
      .init(root: try CanonicalPath("/Users"), kind: .userData),
      .init(root: try CanonicalPath(home.path), kind: .userData),
      .init(root: try CanonicalPath(state.resolvingSymlinksInPath().path), kind: .hostData),
    ]
    for path in launcher.hostSystemReadPaths {
      rules.insert(.init(root: try CanonicalPath(path.value), kind: .systemOrApplication))
    }
    if denial == "path" {
      rules.insert(
        .init(root: try CanonicalPath(state.resolvingSymlinksInPath().path), kind: .denied))
    }
    let paths = try PathEnvironmentSnapshot(
      projects: [
        .init(id: registered.id, root: CanonicalPath(project.path))
      ], rules: rules)
    try runtime.service.configureEnvironment(
      paths, trustedHosts: [],
      expectedProjects: try database.projects(), expectedConfigurationRevision: nil)
  }

  func authorize() async throws -> InvocationAuthorization {
    try await runtime.ready()
    if denial == "owner" {
      let owner = try GatewayPermissionOwner(
        context: .init(
          caller: .localApp,
          profileID: .localAdmin, trustedPrincipalID: "scratch-owner"), validate: {})
      let revision = try runtime.service.view(owner: owner).revision
      _ = try runtime.service.setOwnerPolicy(
        Data("denied_read_locations = ['\(state.path)']\n".utf8),
        profileID: .chatGPTOperate, owner: owner, expectedRevision: revision)
    }
    if denial == "connection" {
      try runtime.service.connect(
        subject: subject, id: connectionID,
        attenuation: .init(deniedReadLocations: [
          try CanonicalPath(state.resolvingSymlinksInPath().path)
        ]))
    }
    let machine = try PermissionRequirement(.machineInformation, .access)
    let paths: [PathRequirement] =
      projectHelper
      ? [try .init(path: CanonicalPath(project.path), operation: .read)] : []
    let requirements = InvocationRequirements(
      actions: [.init(requirement: machine)], paths: paths,
      sandboxProjectID: projectHelper ? "project" : nil)
    if denial == "sandbox" {
      // Establish the subject before tightening its independent project sandbox settings.
      _ = try runtime.service.admit(
        subject: subject, tool: "system.info", projectID: "project",
        argumentsDigest: "initialize", requirements: requirements)
      try runtime.store.transactionWithDatabase { _, ledger in
        _ = try ledger.setSandboxSettings(
          .init(deniedReadLocations: [CanonicalPath(state.resolvingSymlinksInPath().path)]),
          for: .init(principal: subject.principal, projectID: "project"),
          expectedRevision: ledger.revision)
      }
    }
    let decision = try runtime.service.admit(
      subject: subject, tool: "system.info",
      projectID: projectHelper ? "project" : nil, argumentsDigest: UUID().uuidString,
      requirements: requirements, connectionID: denial == "connection" ? connectionID : nil)
    guard case .allowed(let authorization) = decision else {
      throw PermissionModelError.invalidAuthorization
    }
    return authorization
  }

  func prepare(_ authorization: InvocationAuthorization) async throws -> PreparedExecutionContext {
    let descriptor = CapabilityDescriptor(
      id: "system.info", risk: .readOnly,
      requirement: .init(access: .none, permissions: [try .init(.machineInformation, .access)]))
    let authority = try await runtime.prepare(
      authorization: authorization, descriptor: descriptor,
      directory: projectHelper ? project : nil,
      connectionID: denial == "connection" ? connectionID : nil)
    return try #require(authority as? PreparedExecutionContext)
  }

  func requireRemoved(_ scratch: URL) async throws {
    for _ in 0..<100 {
      try await runtime.coordinator.reconcile()
      if !FileManager.default.fileExists(atPath: scratch.path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Completed or refused execution retained its private scratch")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
