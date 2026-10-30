import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPWorktrees
import Foundation
import Testing

@testable import ComputerMCPGateway

@Suite(.nativeIntegration, .serialized)
struct GatewayWorktreeExecutionContextTests {
  @Test func verifiedContextOpensOnlyItsContentAndPrivateGit() throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let result = try f.call(.add(name: "bound", branch: nil, base: nil))
    let id = try #require(result.objectValue?["project_id"]?.stringValue)
    let directory = URL(fileURLWithPath: try #require(result.objectValue?["path"]?.stringValue))
    let worktree = try #require(
      try f.database.executionWorktree(projectID: id, directory: directory, platform: f.platform))
    let authorization = try admit(f, projectID: id, directory: worktree.directory)
    let scratch = f.database.permissionExecutionRoot.appendingPathComponent(
      authorization.id.uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    let temporary = try SandboxPath(ProjectPathResolver.canonicalProject(scratch).path)
    let context = GatewaySandboxContext(
      directory: worktree.directory, temporaryDirectory: temporary, purpose: .projectProgram,
      worktree: worktree)
    let configuration = try f.runtime.store.transactionWithDatabase { _, ledger in
      try GatewaySandboxCompiler.compile(
        ledger: &ledger, authorizationID: authorization.id, context: context,
        ownedTemporaryDirectory: temporary)
    }
    let sandbox = try #require(configuration.sandbox)
    #expect(!sandbox.readOnly && configuration.permitsProgramLaunch)
    #expect(sandbox.git == worktree.git)
    #expect(!sandbox.writableDirectories.contains(worktree.git.sharedDirectory))
    #expect(
      sandbox.deniedReadRegions.contains {
        $0.path.value == worktree.git.sharedDirectory.value + "/computer-mcp"
      })
    let variables = try ExecutionEnvironment(
      searchPath: [.init("/usr/bin")], home: temporary, temporary: temporary, cache: temporary
    ).variables(sandbox: sandbox)
    #expect(variables["GIT_OBJECT_DIRECTORY"] == nil)
    #expect(variables["GIT_ALTERNATE_OBJECT_DIRECTORIES"] == nil)
    #expect(variables["HOME"] == temporary.value)
    #expect(throws: (any Error).self) {
      try f.runtime.store.transactionWithDatabase { _, ledger in
        try GatewaySandboxCompiler.compile(
          ledger: &ledger, authorizationID: authorization.id,
          context: .init(
            directory: .init(f.source.path), temporaryDirectory: temporary,
            purpose: .projectProgram, worktree: worktree))
      }
    }
    let pathAccess = GatewayPathAccess(
      store: f.runtime.store, authorizationID: authorization.id,
      validateWorktree: { try worktree.binding.verify() })
    let content = directory.appendingPathComponent("value")
    try pathAccess.check(content, operation: .write)
    let config = URL(fileURLWithPath: worktree.git.repository.value).appendingPathComponent(
      "config")
    let expected = try Data(contentsOf: config)
    try Data("[core]\n\thooksPath = /untrusted\n".utf8).write(to: config)
    #expect(throws: WorktreeError.self) { try pathAccess.check(content, operation: .write) }
    try expected.write(to: config)
    let operation = UUID()
    _ = try worktree.binding.admission.close(operationID: operation)
    #expect(throws: WorktreeError.self) {
      try worktree.binding.admission.reserve(ownerID: UUID(), executionID: UUID())
    }
    try worktree.binding.admission.reopen(operationID: operation)
    let moved = directory.appendingPathExtension("replaced")
    try FileManager.default.moveItem(at: directory, to: moved)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    #expect(throws: WorktreeError.self) { try worktree.binding.verify() }
  }

  @Test func coordinatorRequiresTheMatchingLeaseBeforeExposingContext() async throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let result = try f.call(.add(name: "lease", branch: nil, base: nil))
    let id = try #require(result.objectValue?["project_id"]?.stringValue)
    let directory = URL(fileURLWithPath: try #require(result.objectValue?["path"]?.stringValue))
    let worktree = try #require(
      try f.database.executionWorktree(projectID: id, directory: directory, platform: f.platform))
    let authorization = try admit(f, projectID: id, directory: worktree.directory)
    let scratch = f.database.permissionExecutionRoot.appendingPathComponent(
      authorization.id.uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    let context = try GatewaySandboxContext(
      directory: worktree.directory,
      temporaryDirectory: .init(ProjectPathResolver.canonicalProject(scratch).path),
      fixedHostOperation: .init(
        operation: .fileMutation, gitExecutable: .init(f.platform.gitExecutable),
        directory: worktree.directory, allowsWrites: true), worktree: worktree)
    try await f.runtime.ready()
    await #expect(throws: PermissionModelError.self) {
      try await f.runtime.coordinator.prepare(authorizationID: authorization.id, context: context)
    }
    #expect(try worktree.binding.admission.close(operationID: UUID()).isEmpty)
  }

  @Test func programPreparationBindsItsLeaseAndRefusesMissingOrDifferentDirectory() async throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let made = try f.call(.add(name: "program", branch: nil, base: nil))
    let id = try #require(made.objectValue?["project_id"]?.stringValue)
    let directory = URL(fileURLWithPath: try #require(made.objectValue?["path"]?.stringValue))
    let worktree = try #require(
      try f.database.executionWorktree(projectID: id, directory: directory, platform: f.platform))
    let path = worktree.directory
    let descriptor = CapabilityDescriptor(
      id: "shell.run", risk: .fullShell,
      requirement: .init(access: .projectWrite, execution: .start), projectRequirement: .required,
      localOnly: false, usesNetwork: false)
    for invalid in [nil, f.source] as [URL?] {
      let proof = try admit(f, projectID: id, directory: path)
      await #expect(throws: (any Error).self) {
        try await f.runtime.prepare(
          authorization: proof, descriptor: descriptor, directory: invalid, connectionID: nil)
      }
    }
    let proof = try admit(f, projectID: id, directory: path)
    if !f.platform.launcher.supportsDurableOwnership(sandboxed: true) {
      await #expect(throws: ExecutionEnvironmentError.self) {
        try await f.runtime.prepare(
          authorization: proof, descriptor: descriptor, directory: directory, connectionID: nil)
      }
      return
    }
    let prepared = try #require(
      try await f.runtime.prepare(
        authorization: proof, descriptor: descriptor, directory: directory, connectionID: nil)
        as? PreparedExecutionContext)
    #expect(prepared.worktreeGit != nil)
    let admission = try f.repository().admission(projectID: id)
    let operation = UUID()
    let uses = try admission.close(operationID: operation)
    #expect(uses.count == 1 && uses.first?.executionID == prepared.executionID)
    try prepared.finishAdmission()
    try await f.runtime.coordinator.reconcile()
    try admission.requireDrained(operationID: operation)
  }

  @Test(arguments: ["adapter.fixture.run", "mcp.tools.call"])
  func ordinaryPluginPreparationRequiresVerifiedProvider(tool: String) async throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    var profile = try #require(try f.database.profiles().first { $0.id == .chatGPTOperate })
    profile.fullAccess = true
    try f.database.saveProfile(profile)
    let session = GatewayControlSession(
      principalID: "plugin", profileID: profile.id, caller: .secureTunnel,
      database: f.database, permissionService: f.runtime.service)
    defer { session.end() }
    _ = try session.approveFullAccess(expectedRevision: session.revision)
    let decision = try f.runtime.service.admit(
      subject: .init(
        context: .init(
          caller: .secureTunnel, profileID: profile.id, trustedPrincipalID: "plugin")),
      tool: tool, projectID: "source", argumentsDigest: UUID().uuidString,
      requirements: .init(
        actions: [.init(requirement: .init(.project("source"), .write), scope: .project("source"))],
        mode: .fullAccess(.connection(session.id)), sandboxProjectID: "source"),
      connectionID: session.id)
    guard case .allowed(let proof) = decision else {
      Issue.record("Ordinary plugin invocation was refused: \(decision)")
      return
    }
    let descriptor = CapabilityDescriptor(
      id: tool, risk: .projectWrite,
      requirement: .init(access: .projectWrite), projectRequirement: .required,
      localOnly: false, usesNetwork: false,
      mcpReference: tool.hasPrefix("mcp.") ? nil : .init(serverID: "fixture", toolName: "run"))
    do {
      _ = try await f.runtime.prepare(
        authorization: proof, descriptor: descriptor, directory: f.source,
        connectionID: session.id)
      Issue.record("A plugin program was admitted without a verified provider")
    } catch ExecutionEnvironmentError.unavailable(let message) {
      #expect(
        message == "Local plugin programs require the plugin owner's verified execution context")
    }
  }

  @Test(arguments: ["adapter.fixture.run", "mcp.tools.call"])
  func worktreePluginPreparationRequiresVerifiedProvider(tool: String) async throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let made = try f.call(.add(name: "plugin", branch: nil, base: nil))
    let id = try #require(made.objectValue?["project_id"]?.stringValue)
    let directory = URL(fileURLWithPath: try #require(made.objectValue?["path"]?.stringValue))
    let worktree = try #require(
      try f.database.executionWorktree(projectID: id, directory: directory, platform: f.platform))
    let proof = try admit(f, projectID: id, directory: worktree.directory)
    let descriptor = CapabilityDescriptor(
      id: tool, risk: .readOnly,
      requirement: .init(access: .projectWrite), projectRequirement: .required,
      localOnly: false, usesNetwork: false,
      mcpReference: tool.hasPrefix("mcp.") ? nil : .init(serverID: "fixture", toolName: "run"))
    do {
      _ = try await f.runtime.prepare(
        authorization: proof, descriptor: descriptor, directory: directory, connectionID: nil)
      Issue.record("A plugin program acquired a host worktree context")
    } catch ExecutionEnvironmentError.unavailable(let message) {
      #expect(
        message == "Local plugin programs require the plugin owner's verified execution context")
    }
    #expect(try f.repository().admission(projectID: id).close(operationID: UUID()).isEmpty)
  }

  private func admit(_ f: WorktreeServiceFixture, projectID: String, directory: SandboxPath) throws
    -> InvocationAuthorization
  {
    let decision = try f.runtime.service.admit(
      subject: .init(
        context: .init(
          caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "execution")),
      tool: "shell.run", projectID: projectID, argumentsDigest: UUID().uuidString,
      requirements: .init(
        actions: [.init(requirement: .init(.project("source"), .write), scope: .project("source"))],
        paths: [.init(path: .init(directory.value), operation: .write)], sandboxProjectID: "source"
      ))
    guard case .allowed(let authorization) = decision else {
      throw PermissionModelError.invalidAuthorization
    }
    return authorization
  }
}
