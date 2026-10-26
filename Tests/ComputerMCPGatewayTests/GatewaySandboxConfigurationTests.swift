import ComputerMCPCore
import ComputerMCPEgress
import ComputerMCPPermissions
import ComputerMCPSandbox
import Foundation
import Testing

@testable import ComputerMCPGateway

@Suite struct GatewaySandboxConfigurationTests {
  @Test func pathsKeepProjectPrecedenceNestedDenialsAndHostData() throws {
    var f = try SandboxCompilerFixture()
    let compiled = try f.compile()
    let sandbox = try #require(compiled.sandbox)
    #expect(readable("/people/me/Downloads/repo/file", in: sandbox))
    #expect(!readable("/people/me/Downloads/unrelated", in: sandbox))
    #expect(!readable("/people/me/Downloads/repo/secret/file", in: sandbox))
    #expect(!readable("/people/me/tasks/job/secret/file", in: sandbox))
    #expect(readable("/people/me/tasks/job/file", in: sandbox))
    #expect(!readable("/people/me/Downloads/repo/host/token", in: sandbox))
    #expect(!readable("/people/me/toolchains/swift/private/key", in: sandbox))
    #expect(readable("/people/me/toolchains/swift/bin/swift", in: sandbox))
    #expect(!readable("/people/me/other/file", in: sandbox))
    #expect(sandbox.listableAncestors.contains(try SandboxPath("/people/me")))
    #expect(!sandbox.hostNetwork && sandbox.git == nil)
    #expect(
      compiled.authorization.basis.contains {
        if case .permission(let grant) = $0 {
          return grant.requirement.permission == .project("project")
        }
        return false
      })
    let execution = try f.ledger.startExecution(
      owner: f.principal, authorizationIDs: [compiled.authorization.id])
    let revoked = try f.ledger.revoke(
      principal: f.principal, permission: .project("project"), expectedRevision: f.ledger.revision)
    #expect(revoked.executionsToTerminate == [execution.id])
  }

  @Test(arguments: FolderCategory.allCases)
  func mountedCategoriesOpenOnlyTheirLocations(category: FolderCategory) throws {
    var f = try SandboxCompilerFixture()
    var environment = f.ledger.environment
    environment.paths!.pathRules.insert(
      .init(root: try CanonicalPath("/volumes/mounted"), kind: .folder(category)))
    _ = try f.ledger.reconcile(environment: environment, expectedRevision: f.ledger.revision)
    try f.grant(.filesAndFolders(category), .read)
    let compiled = try f.compile()
    #expect(readable("/volumes/mounted/file", in: try #require(compiled.sandbox)))
    #expect(!readable("/volumes/other/file", in: try #require(compiled.sandbox)))
    let execution = try f.ledger.startExecution(
      owner: f.principal, authorizationIDs: [compiled.authorization.id])
    #expect(
      try f.ledger.revoke(
        principal: f.principal, permission: .filesAndFolders(category),
        expectedRevision: f.ledger.revision
      ).executionsToTerminate.contains(execution.id))
  }

  @Test(arguments: [false, true], [false, true])
  func screenAndDesktopAreIndependent(screen: Bool, desktop: Bool) throws {
    var f = try SandboxCompilerFixture()
    if screen { try f.grant(.screen) }
    if desktop { try f.grant(.desktopControl) }
    let compiled = try f.compile()
    #expect(compiled.sandbox?.services == .init(screenCapture: screen, accessibility: desktop))
    let execution = try f.ledger.startExecution(
      owner: f.principal, authorizationIDs: [compiled.authorization.id])
    if screen || desktop {
      #expect(
        try f.ledger.revoke(
          principal: f.principal, permission: screen ? .screen : .desktopControl,
          expectedRevision: f.ledger.revision
        ).executionsToTerminate.contains(execution.id))
    }
  }

  @Test(
    arguments: [
      NetworkAccess.none, .trusted, .full,
      .custom(hosts: ["*.example.test"], includesTrusted: true),
    ], [false, true])
  func egressUsesEffectiveHostsAndLocalPermission(network: NetworkAccess, local: Bool) throws {
    var f = try SandboxCompilerFixture()
    if local { try f.grant(.localNetwork) }
    _ = try f.ledger.setSandboxSettings(
      .init(network: network), for: .init(principal: f.principal, projectID: "project"),
      expectedRevision: f.ledger.revision)
    let compiled = try f.compile()
    #expect(compiled.egress.localNetwork == local)
    #expect(
      compiled.egress.admits(host: "registry.test")
        == network.allows("registry.test", trustedHosts: ["registry.test"]))
    #expect(
      compiled.egress.admits(host: "sub.example.test")
        == network.allows("sub.example.test", trustedHosts: ["registry.test"]))
    #expect(
      compiled.egress.admits(host: "outside.test")
        == network.allows("outside.test", trustedHosts: ["registry.test"]))
    #expect(compiled.sandbox?.proxy == nil)
  }

  @Test func managedAndConnectionCeilingsCannotBeReopened() throws {
    var f = try SandboxCompilerFixture()
    try f.grant(.screen)
    _ = try f.ledger.setSandboxSettings(
      .init(network: .full), for: .init(principal: f.principal, projectID: "project"),
      expectedRevision: f.ledger.revision)
    var environment = f.ledger.environment
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .screen)
    environment.connections["limited"] = .init(
      principal: f.principal,
      attenuation: .init(
        permissionCeilings: ceilings,
        network: .custom(hosts: ["*.example.test"], includesTrusted: false),
        deniedReadLocations: [try CanonicalPath("/people/me/Downloads/repo/limited")]))
    _ = try f.ledger.reconcile(environment: environment, expectedRevision: f.ledger.revision)
    let compiled = try f.compile(connectionID: "limited")
    #expect(compiled.sandbox?.services.screenCapture == false)
    #expect(!readable("/people/me/Downloads/repo/limited/file", in: try #require(compiled.sandbox)))
    #expect(compiled.egress.admits(host: "sub.example.test"))
    #expect(!compiled.egress.admits(host: "outside.test"))
    let execution = try f.ledger.startExecution(
      owner: f.principal, authorizationIDs: [compiled.authorization.id])
    #expect(
      f.ledger.executionAccess(
        execution.id, principal: f.principal, operation: .readResult, now: Date()) == .allowed)
  }

  @Test func noProjectHelpersAndUnavailableContextsFailClosed() throws {
    var f = try SandboxCompilerFixture()
    let compiled = try f.compile(projectID: nil, directory: "/system")
    #expect(readable("/system/bin/tool", in: try #require(compiled.sandbox)))
    #expect(!readable("/people/me/secrets", in: try #require(compiled.sandbox)))
    #expect(!compiled.egress.admits(host: "registry.test"))
    #expect(throws: ExecutionEnvironmentError.self) { try f.compile(purpose: .projectProgram) }
    #expect(throws: ExecutionEnvironmentError.self) { try f.compile(purpose: .pluginProgram) }
    var environment = f.ledger.environment
    environment.paths = nil
    _ = try f.ledger.reconcile(environment: environment, expectedRevision: f.ledger.revision)
    #expect(throws: PermissionModelError.self) {
      try f.compile(projectID: nil, directory: "/system")
    }
  }

  @Test func onlyThisTimeNetworkKeepsHostAndLocalScopes() throws {
    var f = try SandboxCompilerFixture()
    let call = InvocationIdentity(
      principal: f.principal, tool: "helper", projectID: "project", argumentsDigest: "once")
    let requirements = InvocationRequirements(
      networks: [.init(host: "device.test", projectID: "project", isLocalNetwork: true)],
      sandboxProjectID: "project")
    guard
      case .requests(let localRequests) = try f.ledger.authorize(
        invocation: call, requirements: requirements, now: Date())
    else { throw PermissionModelError.invalidAuthorization }
    var retries = Set(localRequests.map(\.id))
    for request in localRequests {
      _ = try f.ledger.answer(request.id, with: .onlyThisTime, now: Date())
    }
    guard
      case .requests(let networkRequests) = try f.ledger.authorize(
        invocation: call, requirements: requirements, retryIDs: retries, now: Date())
    else { throw PermissionModelError.invalidAuthorization }
    retries.formUnion(networkRequests.map(\.id))
    for request in networkRequests {
      _ = try f.ledger.answer(request.id, with: .onlyThisTime, now: Date())
    }
    guard
      case .allowed(let proof) = try f.ledger.authorize(
        invocation: call, requirements: requirements, retryIDs: retries, now: Date())
    else { throw PermissionModelError.invalidAuthorization }
    let compiled = try GatewaySandboxCompiler.compile(
      ledger: &f.ledger, authorizationID: proof.id,
      context: .init(
        directory: SandboxPath("/system"), temporaryDirectory: SandboxPath("/tmp/execution")))
    #expect(compiled.egress.admits(host: "device.test"))
    #expect(!compiled.egress.admits(host: "other.test"))
    #expect(!compiled.egress.localNetwork)
    #expect(compiled.egress.localNetworkHosts == ["device.test"])
  }

  @Test func newBoundaryRevokesCompiledReadOpening() throws {
    var f = try SandboxCompilerFixture()
    let compiled = try f.compile()
    let execution = try f.ledger.startExecution(
      owner: f.principal, authorizationIDs: [compiled.authorization.id])
    var environment = f.ledger.environment
    environment.paths!.pathRules.insert(
      .init(root: try CanonicalPath("/system/private"), kind: .hostData))
    #expect(
      try f.ledger.reconcile(environment: environment, expectedRevision: f.ledger.revision)
        .executionsToTerminate.contains(execution.id))
  }

  private func readable(_ raw: String, in sandbox: SandboxConfiguration) -> Bool {
    let path = try! SandboxPath(raw)
    return sandbox.readableRoots.contains { $0.contains(path) }
      && !sandbox.forbiddenReads.contains { $0.contains(path) }
      && !sandbox.deniedReadRegions.contains { region in
        region.path.contains(path) && !region.exceptions.contains { $0.contains(path) }
      }
  }
}

struct SandboxCompilerFixture {
  var ledger = PermissionLedger()
  let principal = Principal.client("compiler")

  init() throws {
    ledger.register(principal)
    var environment = PermissionEnvironment()
    environment.trustedHosts = [HostRule("registry.test")]
    environment.paths = try PathEnvironmentSnapshot(
      projects: [
        .init(id: "project", root: CanonicalPath("/people/me/Downloads/repo")),
        .init(id: "inner", root: CanonicalPath("/people/me/Downloads/repo/secret")),
        .init(id: "derived", root: CanonicalPath("/people/me/tasks/job"), sourceID: "project"),
      ],
      rules: [
        .init(root: CanonicalPath("/people"), kind: .userData),
        .init(root: CanonicalPath("/volumes"), kind: .userData),
        .init(root: CanonicalPath("/people/me/Downloads"), kind: .folder(.downloads)),
        .init(root: CanonicalPath("/people/me/Downloads/repo/host"), kind: .hostData),
        .init(root: CanonicalPath("/people/me/toolchains/swift"), kind: .developer),
        .init(root: CanonicalPath("/system"), kind: .systemOrApplication),
      ])
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    try grant(.project("project"), .write)
    _ = try ledger.setPermission(
      .denied, for: .project("inner"), principal: principal, expectedRevision: ledger.revision)
    _ = try ledger.setSandboxSettings(
      .init(deniedReadLocations: [CanonicalPath("/people/me/toolchains/swift/private")]),
      for: .init(principal: principal, projectID: "project"), expectedRevision: ledger.revision)
  }

  mutating func grant(_ permission: Permission, _ value: PermissionValue = .access) throws {
    _ = try ledger.setPermission(
      .granted(value), for: permission, principal: principal, expectedRevision: ledger.revision)
  }

  mutating func compile(
    projectID: String? = "project", directory: String = "/people/me/Downloads/repo",
    purpose: GatewayExecutionPurpose = .readOnlyHelper, connectionID: String? = nil
  ) throws -> GatewayExecutionConfiguration {
    let decision = try ledger.authorize(
      invocation: .init(
        principal: principal, tool: "helper", projectID: projectID, argumentsDigest: "digest"),
      requirements: .init(sandboxProjectID: projectID), connectionID: connectionID, now: Date())
    guard case .allowed(let proof) = decision else {
      throw PermissionModelError.invalidAuthorization
    }
    return try GatewaySandboxCompiler.compile(
      ledger: &ledger, authorizationID: proof.id,
      context: .init(
        directory: SandboxPath(directory), temporaryDirectory: SandboxPath("/tmp/execution"),
        purpose: purpose))
  }
}
