import Darwin
import Foundation
import Testing

@testable import ComputerMCP

struct GatewayPermissionLifecycleTests {
  @Test
  func modelConfirmationCreatesPendingApprovalButOnlyExactLocallyApprovedCommitExecutes()
    async throws
  {
    let fixture = try PermissionFixture()
    defer { fixture.removeFiles() }
    do {
      #expect(
        try fixture.gateway.capabilityDescriptor(named: "file.remove_xattr").risk == .destructive)
      do {
        _ = try fixture.gateway.callTool(name: "file.remove_xattr", arguments: fixture.target)
        Issue.record("A model-supplied confirmation must not authorize a destructive operation.")
      } catch {
        #expect(error.localizedDescription.contains("operations.approval_required"))
      }
      let ticket = try #require(fixture.database.operationApprovals().first)
      #expect(ticket.state == .pendingApproval)
      #expect(fixture.hasAttribute())
      #expect(throws: (any Error).self) { try fixture.commit(ticket.id) }
      #expect(fixture.hasAttribute())

      try fixture.database.resolveOperationApproval(
        id: ticket.id, approved: true, resolver: .localCLI)
      #expect(try fixture.database.operationTicket(id: ticket.id)?.state == .approved)
      let result = try fixture.commit(ticket.id)
      #expect(result.objectValue?["isError"] != .bool(true))
      #expect(!fixture.hasAttribute())
      #expect(try fixture.database.operationTicket(id: ticket.id)?.state == .succeeded)
      #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "original")
      try fixture.replaceAttribute(with: "reviewed attribute")
      #expect(throws: (any Error).self) { try fixture.commit(ticket.id) }
      #expect(fixture.hasAttribute())
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test(arguments: [
    "deny", "expire", "arguments", "target-state", "target-attribute", "tool", "principal",
    "authorization",
  ])
  func invalidApprovalCannotProduceAFileSideEffect(change: String) async throws {
    let fixture = try PermissionFixture()
    defer { fixture.removeFiles() }
    do {
      let ticketID = try fixture.prepare()
      var arguments = fixture.target
      var tool = "file.remove_xattr"
      var principal = "verified-first"
      switch change {
      case "deny":
        try fixture.database.resolveOperationApproval(
          id: ticketID, approved: false, resolver: .localApp)
      case "expire":
        var ticket = try #require(try fixture.database.operationTicket(id: ticketID))
        ticket.expiresAt = Date(timeIntervalSince1970: 0)
        try fixture.database.saveOperationTicket(ticket)
      default:
        try fixture.database.resolveOperationApproval(
          id: ticketID, approved: true, resolver: .localCLI)
      }
      switch change {
      case "arguments":
        var changed = try #require(arguments.objectValue)
        changed["confirm"] = .bool(false)
        arguments = .object(changed)
      case "target-state":
        try Data("changed target".utf8).write(to: fixture.file)
      case "target-attribute":
        try fixture.replaceAttribute(with: "changed attribute")
      case "tool": tool = "file.write"
      case "principal": principal = "verified-second"
      case "authorization":
        var grant = try #require(fixture.database.profiles().first)
        let revision = grant.authorizationRevision
        grant.confirmationPolicy = .allWrites
        try fixture.database.saveProfile(grant, expectedRevision: revision)
        #expect(try fixture.database.operationTicket(id: ticketID)?.state == .denied)
      default: break
      }
      #expect(throws: (any Error).self) {
        try fixture.commit(ticketID, target: arguments, tool: tool, principal: principal)
      }
      #expect(fixture.hasAttribute())
      #expect(
        try String(contentsOf: fixture.file, encoding: .utf8)
          == (change == "target-state" ? "changed target" : "original"))
      if change == "expire" {
        #expect(try fixture.database.operationTicket(id: ticketID)?.state == .expired)
      }
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test
  func revocationChangesExistingRuntimeDiscoveryAndPreventsNewCalls() async throws {
    let fixture = try PermissionFixture()
    defer { fixture.removeFiles() }
    do {
      let ticketID = try fixture.prepare()
      #expect(try fixture.gateway.listTools().contains { $0.name == "file.write" })
      var grant = try #require(fixture.database.profiles().first)
      let revision = grant.authorizationRevision
      grant.capabilityIDs.remove("file.write")
      grant.capabilityIDs.remove("file.remove_xattr")
      try fixture.database.saveProfile(grant, expectedRevision: revision)
      #expect(try !fixture.gateway.listTools().contains { $0.name == "file.write" })
      #expect(try !fixture.gateway.listTools().contains { $0.name == "file.remove_xattr" })
      #expect(try fixture.database.operationTicket(id: ticketID)?.state == .denied)
      #expect(throws: (any Error).self) {
        try fixture.gateway.callTool(
          name: "file.write",
          arguments: .object([
            "workspace_id": .string("fixture"), "path": .string("value.txt"),
            "content": .string("unauthorized overwrite"), "confirm": .bool(true),
          ]))
      }
      #expect(throws: (any Error).self) {
        try fixture.database.resolveOperationApproval(
          id: ticketID, approved: true, resolver: .localCLI)
      }
      #expect(fixture.hasAttribute())
      #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "original")
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test(arguments: [GatewayCallerKind.secureTunnel, .cloudflareTunnel, .localMCP])
  func approvalResolutionIsLocalManagementOnly(resolver: GatewayCallerKind) async throws {
    let fixture = try PermissionFixture()
    defer { fixture.removeFiles() }
    do {
      let ticketID = try fixture.prepare()
      #expect(throws: GatewayDatabaseError.self) {
        try fixture.database.resolveOperationApproval(
          id: ticketID, approved: true, resolver: resolver)
      }
      #expect(try fixture.database.operationTicket(id: ticketID)?.state == .pendingApproval)
      #expect(fixture.hasAttribute())
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test
  func resultReadUsesVerifiedPrincipalEvenWhenProfileAndWorkspaceMatch() async throws {
    let database = try GatewayDatabase(inMemory: ())
    let server = MCPServerConfig(id: "fixture", transport: .stdio, command: "/usr/bin/false")
    func context(principal: String) -> MCPHostContext {
      MCPHostContext(
        runtimeID: UUID(),
        context: .init(
          caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: principal),
        workspaceID: "fixture", rootURL: URL(fileURLWithPath: "/private/tmp"), readOnly: true,
        executionDatabase: database)
    }
    let owner = context(principal: "verified-first")
    let scope = MCPExecutionRecord.digest(
      .array([
        .string(owner.principalID), .string(owner.profileID.rawValue), .string(owner.workspace.id),
      ]))
    let journal = MCPExecutionJournal(database: database, scope: scope)
    _ = try journal.reserve(
      server: server, tool: "metadata", arguments: .object([:]), requestID: "owned")
    try journal.update(serverID: server.id, requestID: "owned") {
      try $0.finish(result: .object(["content": .array([])]), failed: false)
    }
    let first = MCPProxyClient(hostContext: owner)
    let second = MCPProxyClient(hostContext: context(principal: "verified-second"))
    let reconnected = MCPProxyClient(hostContext: context(principal: "verified-first"))
    do {
      let result = try first.readRequest(
        server: server, requestID: "owned", offset: 0, maxBytes: 4096)
      #expect(result.objectValue?["state"] == .string("succeeded"))
      #expect(
        try reconnected.readRequest(server: server, requestID: "owned", offset: 0, maxBytes: 4096)
          == result)
      #expect(throws: (any Error).self) {
        try second.readRequest(server: server, requestID: "owned", offset: 0, maxBytes: 4096)
      }
      await first.shutdown()
      await second.shutdown()
      await reconnected.shutdown()
    } catch {
      await first.shutdown()
      await second.shutdown()
      await reconnected.shutdown()
      throw error
    }
  }
}

private struct PermissionFixture {
  static let attribute = "com.computer-mcp.permission-fixture"
  let root: URL
  let file: URL
  let database: GatewayDatabase
  let gateway: GatewayRuntime

  var target: JSONValue {
    .object([
      "workspace_id": .string("fixture"), "path": .string("value.txt"),
      "name": .string(Self.attribute), "dry_run": .bool(false), "confirm": .bool(true),
    ])
  }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    file = root.appendingPathComponent("value.txt")
    try Data("original".utf8).write(to: file)
    let data = Data("reviewed attribute".utf8)
    let attributePath = file.path
    let result = data.withUnsafeBytes {
      setxattr(attributePath, Self.attribute, $0.baseAddress, $0.count, 0, 0)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    database = try GatewayDatabase(inMemory: ())
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate,
      capabilities: ["operations.prepare", "operations.commit", "file.remove_xattr", "file.write"],
      workspaces: ["fixture"], allowedCallers: [.secureTunnel], mode: .workspaceOperations,
      confirmationPolicy: .riskBased)
    try database.saveProfile(profile.grant)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate), profiles: [profile],
      builtin: .init(enabled: ["file.remove_xattr", "file.write"]), workspaceDirectory: root)
    gateway = try GatewayRuntime(
      configuration: configuration,
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "verified-first"),
      database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)])
  }

  func prepare() throws -> String {
    let result = try gateway.callTool(
      name: "operations.prepare",
      arguments: .object([
        "workspace_id": .string("fixture"), "tool": .string("file.remove_xattr"),
        "arguments": target,
      ]))
    return try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["ticket_id"]?
        .stringValue)
  }

  func commit(
    _ ticketID: String, target: JSONValue? = nil, tool: String = "file.remove_xattr",
    principal: String = "verified-first"
  ) throws -> JSONValue {
    try gateway.callTool(
      name: "operations.commit",
      arguments: .object([
        "workspace_id": .string("fixture"), "ticket_id": .string(ticketID),
        "tool": .string(tool), "arguments": target ?? self.target,
      ]),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: principal))
  }

  func hasAttribute() -> Bool { getxattr(file.path, Self.attribute, nil, 0, 0, 0) >= 0 }
  func replaceAttribute(with value: String) throws {
    let data = Data(value.utf8)
    let result = data.withUnsafeBytes {
      setxattr(file.path, Self.attribute, $0.baseAddress, $0.count, 0, 0)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
  func removeFiles() { try? FileManager.default.removeItem(at: root) }
}
