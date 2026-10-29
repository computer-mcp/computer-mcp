import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway

struct GatewayProviderContainerTests {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try ProjectPathResolver.canonicalProject(root)
  }

  @Test func storagePersistsPerPrincipalAndReplacedDirectoriesAreRefused() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("gateway.sqlite").path
    let database = try GatewayDatabase(path: path)
    let identity = PluginIdentity.package("same")
    let first = try database.prepareProviderContainer(identity)
    let file = URL(fileURLWithPath: try first.sandbox.state.value).appendingPathComponent("vendor")
    try Data("state".utf8).write(to: file)
    let reopened = try GatewayDatabase(path: path).prepareProviderContainer(identity)
    #expect(first.root == reopened.root && first.reservation == reopened.reservation)
    #expect(try String(contentsOf: file, encoding: .utf8) == "state")
    let local = try database.prepareProviderContainer(.localServer("same"))
    let other = try database.prepareProviderContainer(.package("other"))
    #expect(Set([first.root, local.root, other.root]).count == 3)
    let home = URL(fileURLWithPath: try first.sandbox.home.value)
    try FileManager.default.moveItem(at: home, to: home.appendingPathExtension("previous"))
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try database.prepareProviderContainer(identity) }
    try other.verify()
  }

  @Test func incompleteReservationsAndForeignStorageAreNotAdopted() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(path: root.appendingPathComponent("gateway.sqlite").path)
    let storage = try #require(database.providerContainerRoot)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try database.prepareProviderContainer(.package("one")) }
    try FileManager.default.removeItem(at: storage)
    #expect(throws: (any Error).self) { try database.prepareProviderContainer(.package("one")) }
    #expect(!FileManager.default.fileExists(atPath: storage.path))
    #expect(throws: FileIdentityError.self) {
      try GatewayDatabase(inMemory: ()).prepareProviderContainer(.package("one"))
    }
  }

  @Test(arguments: [false, true])
  func discoveryOpensOnlyItsOwnContainerAndNeverBorrowsProjects(fullAccess: Bool) throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(path: root.appendingPathComponent("gateway.sqlite").path)
    let identity = PluginIdentity.package("one")
    let principal = Principal.plugin(identity)
    let own = try database.prepareProviderContainer(identity)
    let other = try database.prepareProviderContainer(.package("two"))
    let scratch = root.appendingPathComponent("scratch")
    let project = root.appendingPathComponent("project")
    for directory in [scratch, project] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    var ledger = PermissionLedger()
    var environment = PermissionEnvironment()
    environment.paths = try .init(
      projects: [.init(id: "project", root: .init(project.path))],
      rules: [
        .init(root: .init(root.path), kind: .userData),
        .init(root: own.storageRoot, kind: .hostData),
      ])
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    var permissions = Permissions.newPrincipal
    try permissions.set(.granted(.write), for: .project("project"))
    _ = try ledger.setPermissions(permissions, for: principal, expectedRevision: ledger.revision)
    _ = try ledger.setProviderSandboxSettings(
      .init(defaults: .init(network: .trusted)), for: identity, expectedRevision: ledger.revision)
    if fullAccess {
      var environment = ledger.environment
      environment.modes[principal] = ledger.consent(for: principal, mode: .fullAccess(.standing))
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let decision = try ledger.authorize(
      invocation: .init(
        principal: principal, tool: "discover", projectID: nil, argumentsDigest: "discovery"),
      requirements: .init(), now: Date())
    guard case .allowed(let proof) = decision else {
      throw PermissionModelError.invalidAuthorization
    }
    func context(_ container: GatewayProviderContainer) throws -> GatewaySandboxContext {
      try .init(
        directory: .init(scratch.path), temporaryDirectory: .init(scratch.path),
        privateWorkingDirectory: true, providerContainer: container)
    }
    if fullAccess {
      let decision = try ledger.authorize(
        invocation: .init(
          principal: principal, tool: "discover", projectID: nil, argumentsDigest: "full"),
        requirements: .init(mode: .fullAccess(.standing)), now: Date())
      guard case .allowed(let unconfined) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      #expect(throws: ExecutionEnvironmentError.self) {
        try GatewaySandboxCompiler.compile(
          ledger: &ledger, authorizationID: unconfined.id, context: context(own))
      }
    }
    let compiled = try GatewaySandboxCompiler.compile(
      ledger: &ledger, authorizationID: proof.id, context: context(own),
      ownedTemporaryDirectory: .init(scratch.path))
    let sandbox = try #require(compiled.sandbox)
    #expect(sandbox.readOnly)
    #expect(
      Set(sandbox.writableDirectories) == [try .init(scratch.path), try .init(own.root.string)])
    #expect(sandbox.homeDirectory == (try own.sandbox.home))
    func readable(_ path: CanonicalPath) throws -> Bool {
      let value = try SandboxPath(path.string)
      return sandbox.readableRoots.contains { $0.contains(value) }
        && !sandbox.forbiddenReads.contains { $0.contains(value) }
        && !sandbox.deniedReadRegions.contains {
          $0.path.contains(value) && !$0.exceptions.contains { $0.contains(value) }
        }
    }
    #expect(try readable(own.root))
    #expect(try !readable(other.root))
    #expect(try !readable(.init(project.path)))
    #expect(throws: PermissionModelError.self) {
      try GatewaySandboxCompiler.compile(
        ledger: &ledger, authorizationID: proof.id, context: context(other))
    }
    let read = try ledger.authorize(
      invocation: .init(
        principal: principal, tool: "files.read", projectID: nil, argumentsDigest: "other"),
      requirements: .init(paths: [.init(path: other.root, operation: .read)]), now: Date())
    #expect(read == .denied(.hostData))
  }
}
