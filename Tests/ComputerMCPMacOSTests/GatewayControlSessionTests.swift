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

struct GatewayControlSessionTests {
  @Test
  func encodedContextCannotConveyAuthorityAndForeignPrincipalsCannotBorrowIt() throws {
    let session = try makeSession()
    let context = context(session)
    let decoded = try JSONDecoder().decode(
      ExecutionContext.self, from: JSONEncoder().encode(context))
    #expect(decoded.controlSession == nil)
    #expect(decoded.trustedPrincipalID == context.trustedPrincipalID)
    #expect(try session.apply(to: grant, context: context).fullAccess == false)
    var foreign = context
    foreign.trustedPrincipalID = "another-client"
    #expect(throws: (any Error).self) {
      try session.apply(to: grant, context: foreign)
    }
    var readOnly = grant
    readOnly.fullAccess = false
    #expect(try session.apply(to: readOnly, context: context).fullAccess == false)
    #expect(try session.apply(to: readOnly, context: context).permissions == grant.permissions)
  }

  @Test
  func samePrincipalSessionsHaveIndependentDiscoveryAndRealFileAdmission() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    do {
      let first = try fixture.session()
      let second = try fixture.session()
      try first.limitAccess(
        to: .init(permissionCeilings: fixturePermissions([.project("fixture"): .granted(.read)])),
        expectedRevision: first.revision)
      let firstTools = try await fixture.gateway.listToolsAsync(context: .init(session: first))
      let secondTools = try await fixture.gateway.listToolsAsync(context: .init(session: second))
      #expect(firstTools.contains { $0.name == "file.read" })
      #expect(firstTools.contains { $0.name == "file.write" })
      #expect(secondTools.contains { $0.name == "file.write" })
      await #expect(throws: (any Error).self) {
        try await fixture.gateway.callToolAsync(
          name: "file.write", arguments: fixture.write, context: .init(session: first))
      }
      #expect(try fixture.content() == "original")
      _ = try await fixture.gateway.callToolAsync(
        name: "file.write", arguments: fixture.write, context: .init(session: second))
      #expect(try fixture.content() == "authorized")
      first.end()
      await #expect(throws: (any Error).self) {
        try await fixture.gateway.callToolAsync(
          name: "file.read", arguments: fixture.read, context: .init(session: first))
      }
      _ = try await fixture.gateway.callToolAsync(
        name: "file.read", arguments: fixture.read, context: .init(session: second))
      let detached = try JSONDecoder().decode(
        ExecutionContext.self, from: JSONEncoder().encode(context(second)))
      await #expect(throws: (any Error).self) {
        try await fixture.gateway.callToolAsync(
          name: "file.write", arguments: fixture.write, context: detached, invocationContext: .empty
        )
      }
      #expect(
        try fixture.database.profiles().first { $0.id == .chatGPTOperate }?.fullAccess == true)
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test
  func limitsOnlyNarrowAndRejectStaleRevisions() throws {
    let session = try makeSession()
    let read = ManagedPolicy(
      permissionCeilings: fixturePermissions([.project("fixture"): .granted(.read)]),
      allowsFullAccess: false)
    try session.limitAccess(to: read, expectedRevision: 0)
    #expect(
      session.snapshot.accessLimit.permissionCeilings.state(for: .project("fixture"))
        == .granted(.read))
    #expect(!session.snapshot.accessLimit.allowsFullAccess)
    #expect(throws: (any Error).self) { try session.limitAccess(to: .init(), expectedRevision: 0) }
    #expect(throws: (any Error).self) {
      try session.limitAccess(to: .init(), expectedRevision: session.revision)
    }
    let denied = ManagedPolicy(
      permissionCeilings: fixturePermissions([.project("fixture"): .denied]),
      allowsFullAccess: false)
    try session.limitAccess(to: denied, expectedRevision: session.revision)
    #expect(
      session.snapshot.accessLimit.permissionCeilings.state(for: .project("fixture")) == .denied)
  }

  private var grant: ProfileGrant {
    .init(
      id: .chatGPTOperate, permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
      fullAccess: true, allowedCallers: [.secureTunnel])
  }

  private func makeSession() throws -> GatewayControlSession {
    let database = try GatewayDatabase(inMemory: ())
    try database.saveProfile(grant)
    let service = try GatewayPermissionService(
      store: database.configuredPermissionStore(), policyReader: TestManagedPolicyReader())
    return .init(
      principalID: "verified-client", profileID: .chatGPTOperate, caller: .secureTunnel,
      database: database, permissionService: service)
  }

  private func context(_ session: GatewayControlSession) -> ExecutionContext {
    var value = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "verified-client")
    value.controlSession = session
    return value
  }
}

private struct Fixture {
  let root: URL
  let database: GatewayDatabase
  let gateway: GatewayRuntime
  var read: JSONValue {
    .object(["project_id": .string("fixture"), "path": .string("value.txt")])
  }
  var write: JSONValue {
    .object([
      "project_id": .string("fixture"), "path": .string("value.txt"),
      "content": .string("authorized"), "confirm": .bool(true),
    ])
  }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: root.appendingPathComponent("value.txt"))
    database = try GatewayDatabase(inMemory: ())
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate,
      permissions: fixturePermissions([
        .machineInformation: .granted(.access), .skills: .granted(.access),
        .screen: .granted(.access), .desktopControl: .granted(.access),
        .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
        .project("fixture"): .granted(.write), .mcpServer("*"): .granted(.all),
        .plugin("*"): .granted(.use),
      ]), fullAccess: true, allowedCallers: [.secureTunnel])
    try database.saveProfile(profile.grant)
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    let fixture = try fixtureNonGitProject(root: root)
    gateway = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate), profiles: [profile],
        cli: .init(commands: [fixture.git]),
        builtin: .init(enabled: ["file.read", "file.write"]), projectDirectory: root),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "verified-client"),
      database: database,
      registeredProjects: [project], platform: fixture.platform,
      requiresControlSession: true)
  }

  func content() throws -> String {
    try String(contentsOf: root.appendingPathComponent("value.txt"), encoding: .utf8)
  }

  func session() throws -> GatewayControlSession {
    let session = try gateway.makeControlSession()
    _ = try session.approveFullAccess(expectedRevision: session.revision)
    return session
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
