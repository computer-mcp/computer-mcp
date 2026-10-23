import ComputerMCPMacOS
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

struct GatewayControlSessionTests {
  @Test
  func encodedContextCannotConveyAuthorityAndForeignPrincipalsCannotBorrowIt() throws {
    let session = makeSession()
    let context = context(session)
    let decoded = try JSONDecoder().decode(
      ExecutionContext.self, from: JSONEncoder().encode(context))
    #expect(decoded.controlSession == nil)
    #expect(decoded.trustedPrincipalID == context.trustedPrincipalID)
    #expect(try session.apply(to: grant, context: context).mode == .projectOperations)
    #expect(try session.apply(to: grant, context: context).fullShellEnabled == false)
    var foreign = context
    foreign.trustedPrincipalID = "another-client"
    #expect(throws: (any Error).self) {
      try session.apply(to: grant, context: foreign)
    }
    var readOnly = grant
    readOnly.mode = .readOnly
    readOnly.fullShellEnabled = false
    #expect(try session.apply(to: readOnly, context: context).mode == .readOnly)
    #expect(try session.apply(to: readOnly, context: context).capabilityIDs == grant.capabilityIDs)
  }

  @Test
  func samePrincipalSessionsHaveIndependentDiscoveryAndRealFileAdmission() async throws {
    let fixture = try Fixture(confirmation: .never)
    defer { fixture.remove() }
    do {
      let first = makeSession()
      let second = makeSession()
      try first.limitAccess(to: .readOnly, expectedRevision: 0)
      let firstTools = try await fixture.gateway.listToolsAsync(context: .init(session: first))
      let secondTools = try await fixture.gateway.listToolsAsync(context: .init(session: second))
      #expect(firstTools.contains { $0.name == "file.read" })
      #expect(!firstTools.contains { $0.name == "file.write" })
      #expect(secondTools.contains { $0.name == "file.write" })
      await #expect(throws: (any Error).self) {
        try await fixture.gateway.callToolAsync(
          name: "file.write", arguments: fixture.write, context: context(first),
          invocationContext: .empty)
      }
      #expect(try fixture.content() == "original")
      _ = try await fixture.gateway.callToolAsync(
        name: "file.write", arguments: fixture.write, context: context(second),
        invocationContext: .empty)
      #expect(try fixture.content() == "authorized")
      first.end()
      await #expect(throws: (any Error).self) {
        try await fixture.gateway.callToolAsync(
          name: "file.read", arguments: fixture.read, context: context(first),
          invocationContext: .empty)
      }
      _ = try await fixture.gateway.callToolAsync(
        name: "file.read", arguments: fixture.read, context: context(second),
        invocationContext: .empty)
      let detached = try JSONDecoder().decode(
        ExecutionContext.self, from: JSONEncoder().encode(context(second)))
      await #expect(throws: (any Error).self) {
        try await fixture.gateway.callToolAsync(
          name: "file.write", arguments: fixture.write, context: detached, invocationContext: .empty
        )
      }
      #expect(try fixture.database.profiles().first?.mode == .localFullAccess)
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test
  func ticketsDoNotTransferAcrossSessionsOrSurviveAccessChanges() async throws {
    let fixture = try Fixture(confirmation: .allWrites)
    defer { fixture.remove() }
    do {
      let first = makeSession()
      let second = makeSession()
      let ticket = try fixture.prepare(context: context(first))
      #expect(ticket.controlSessionID == first.id)
      #expect(ticket.controlSessionRevision == 0)
      try fixture.database.resolveOperationApproval(
        id: ticket.id, approved: true, resolver: .localApp)
      #expect(throws: (any Error).self) {
        try fixture.commit(ticket.id, context: context(second))
      }
      #expect(try fixture.content() == "original")
      #expect(try fixture.database.operationTicket(id: ticket.id)?.state == .approved)
      try first.limitAccess(to: .readOnly, expectedRevision: 0)
      #expect(throws: (any Error).self) {
        try first.limitAccess(to: .projectOperations, expectedRevision: 0)
      }
      try first.limitAccess(to: .projectOperations, expectedRevision: 1)
      #expect(throws: (any Error).self) {
        try fixture.commit(ticket.id, context: context(first))
      }
      #expect(try fixture.content() == "original")
      let current = try fixture.prepare(context: context(first))
      try fixture.database.resolveOperationApproval(
        id: current.id, approved: true, resolver: .localCLI)
      _ = try fixture.commit(current.id, context: context(first))
      #expect(try fixture.content() == "authorized")
      #expect(try fixture.database.operationTicket(id: current.id)?.state == .succeeded)
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  private var grant: ProfileGrant {
    .init(
      id: .chatGPTOperate, capabilityIDs: ["*"], projectIDs: ["fixture"],
      allowedCallers: [.secureTunnel], fullShellEnabled: true, mode: .localFullAccess)
  }

  private func makeSession() -> GatewayControlSession {
    .init(principalID: "verified-client", profileID: .chatGPTOperate, caller: .secureTunnel)
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

  init(confirmation: GatewayConfirmationPolicy) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: root.appendingPathComponent("value.txt"))
    database = try GatewayDatabase(inMemory: ())
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate, capabilities: ["*"], projects: ["fixture"],
      allowedCallers: [.secureTunnel], fullShellEnabled: true, mode: .localFullAccess,
      confirmationPolicy: confirmation)
    try database.saveProfile(profile.grant)
    gateway = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate), profiles: [profile],
        builtin: .init(enabled: ["file.read", "file.write"]), projectDirectory: root),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "verified-client"),
      database: database,
      registeredProjects: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
      platform: MacOSPlatform.services, requiresControlSession: true)
  }

  func content() throws -> String {
    try String(contentsOf: root.appendingPathComponent("value.txt"), encoding: .utf8)
  }

  func prepare(context: ExecutionContext) throws -> OperationTicket {
    let result = try gateway.callTool(
      name: "operations.prepare",
      arguments: .object([
        "project_id": .string("fixture"), "tool": .string("file.write"), "arguments": write,
      ]), context: context, invocationContext: .empty)
    let id = try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["ticket_id"]?
        .stringValue)
    return try #require(try database.operationTicket(id: id))
  }

  func commit(_ id: String, context: ExecutionContext) throws -> JSONValue {
    try gateway.callTool(
      name: "operations.commit",
      arguments: .object([
        "project_id": .string("fixture"), "tool": .string("file.write"), "arguments": write,
        "ticket_id": .string(id),
      ]), context: context, invocationContext: .empty)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
