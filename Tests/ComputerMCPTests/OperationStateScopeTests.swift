import Foundation
import Testing
import os

@testable import ComputerMCP

struct OperationStateScopeTests {
  @Test(arguments: ["file.write", "archive.create"], ["direct", "alias", "generic"])
  func downstreamBuiltinNamesCannotBorrowTrustedDryRunBehavior(tool: String, entry: String)
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate, capabilities: ["*"], workspaces: ["fixture"],
      allowedCallers: [.secureTunnel], mode: .workspaceOperations)
    try database.saveProfile(profile.grant)
    let client = StateScopeMCPClient()
    let server = MCPServerConfig(
      id: "external", transport: .stdio, command: "/usr/bin/false", exposure: .reexport,
      prefix: "", allowedTools: [tool], toolRisks: [tool: .destructive])
    let runtime = try GatewayRuntime(
      configuration: .init(
        profiles: [profile], mcp: .init(servers: [server]),
        tools: [
          .init(
            name: "review.change", adapter: .mcp, source: "external", tool: tool,
            risk: CapabilityRisk.destructive.rawValue)
        ]),
      context: .init(caller: .secureTunnel, profileID: .chatGPTOperate, workspaceID: "fixture"),
      database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
      mcpClient: client)
    do {
      let input: JSONValue =
        tool == "file.write"
        ? .object(["path": .string("/remote/target"), "dry_run": .bool(true)]) : .object([:])
      let name = entry == "alias" ? "review.change" : (entry == "generic" ? "mcp.tools.call" : tool)
      let arguments: JSONValue =
        entry == "generic"
        ? .object(["server": .string("external"), "tool": .string(tool), "arguments": input])
        : input
      do {
        _ = try await runtime.callToolAsync(name: name, arguments: arguments)
        Issue.record("Downstream dry_run must not bypass local approval.")
      } catch {
        #expect(error.localizedDescription.contains("operations.approval_required"))
      }
      #expect(client.callCount == 0)
      let prepared = try runtime.callTool(
        name: "operations.prepare",
        arguments: .object([
          "tool": .string(name), "arguments": arguments,
        ]))
      let payload = try #require(
        prepared.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
      let ticket = try #require(payload["ticket_id"]?.stringValue)
      #expect(try database.operationTicket(id: ticket)?.state == .pendingApproval)
      try database.resolveOperationApproval(id: ticket, approved: true, resolver: .localApp)
      _ = try runtime.callTool(
        name: "operations.commit",
        arguments: .object([
          "ticket_id": .string(ticket), "tool": .string(name), "arguments": arguments,
        ]))
      #expect(client.callCount == 1)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: ["mcp.tools.call", "mutate", "file.write"])
  func downstreamApprovalDoesNotClaimLocalFilesystemState(tool: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let unrelated = root.appendingPathComponent("unrelated.txt")
    try Data("before".utf8).write(to: unrelated)
    let database = try GatewayDatabase(inMemory: ())
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate, capabilities: ["*"], workspaces: ["fixture"],
      allowedCallers: [.secureTunnel], mode: .workspaceOperations)
    try database.saveProfile(profile.grant)
    let server = MCPServerConfig(
      id: "external", transport: .stdio, command: "/usr/bin/false", exposure: .reexport,
      prefix: "", allowedTools: ["mutate", "file.write"],
      toolRisks: ["mutate": .destructive, "file.write": .destructive])
    let runtime = try GatewayRuntime(
      configuration: .init(profiles: [profile], mcp: .init(servers: [server])),
      context: .init(caller: .secureTunnel, profileID: .chatGPTOperate, workspaceID: "fixture"),
      database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
      mcpClient: StateScopeMCPClient())
    do {
      let target: JSONValue =
        tool == "mcp.tools.call"
        ? .object([
          "server": .string("external"), "tool": .string("mutate"),
          "arguments": .object(["path": .string("/remote/target")]),
        ])
        : .object(["path": .string("/remote/target")])
      let prepared = try runtime.callTool(
        name: "operations.prepare",
        arguments: .object([
          "tool": .string(tool), "arguments": target,
        ]))
      let payload = try #require(
        prepared.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
      #expect(payload["state_digest"] == .null)
      let ticketID = try #require(payload["ticket_id"]?.stringValue)
      do {
        _ = try runtime.callTool(
          name: "operations.prepare",
          arguments: .object([
            "tool": .string(tool), "arguments": target, "state_digest": .string("unverifiable"),
          ]))
        Issue.record("A downstream operation claimed a local state binding.")
      } catch {
        #expect(error.localizedDescription.contains("operations.state_binding_unavailable"))
      }
      try Data("unrelated local change".utf8).write(to: unrelated)
      try database.resolveOperationApproval(id: ticketID, approved: true, resolver: .localApp)
      let result = try runtime.callTool(
        name: "operations.commit",
        arguments: .object([
          "ticket_id": .string(ticketID), "tool": .string(tool), "arguments": target,
        ]))
      #expect(result.objectValue?["isError"] != .bool(true))
      #expect(try database.operationTicket(id: ticketID)?.state == .succeeded)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func boundWorkspaceRevocationHidesToolsAndUnboundCatalogDoesNotRevealContents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("private workspace content".utf8).write(to: root.appendingPathComponent("private.txt"))
    let database = try GatewayDatabase(inMemory: ())
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate,
      capabilities: ["workspace.list", "workspace.describe", "file.read", "file.write"],
      workspaces: ["fixture"], allowedCallers: [.secureTunnel], mode: .workspaceOperations)
    try database.saveProfile(profile.grant)
    let context = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate, workspaceID: "fixture")
    let runtime = try GatewayRuntime(
      configuration: .init(
        profiles: [profile], builtin: .init(enabled: ["file.read", "file.write"])),
      context: context, database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)])
    do {
      #expect(try runtime.listTools().contains { $0.name == "file.read" })
      var revoked = try #require(database.profiles().first)
      revoked.workspaceIDs = []
      try database.saveProfile(revoked, expectedRevision: revoked.authorizationRevision)
      #expect(try runtime.listTools().isEmpty)
      #expect(throws: (any Error).self) {
        try runtime.callTool(
          name: "file.read", arguments: .object(["path": .string("private.txt")]))
      }
      var unbound = context
      unbound.workspaceID = nil
      #expect(try runtime.listTools(context: unbound).contains { $0.name == "file.read" })
      let list = try runtime.callTool(
        name: "workspace.list", arguments: .object([:]), context: unbound)
      #expect(
        list.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["workspaces"]
          == .array([]))
      #expect(throws: (any Error).self) {
        try runtime.callTool(
          name: "workspace.describe", arguments: .object(["workspace_id": .string("fixture")]),
          context: unbound)
      }
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }
}

private final class StateScopeMCPClient: DownstreamMCPClient, Sendable {
  private let calls = OSAllocatedUnfairLock(initialState: 0)
  var callCount: Int { calls.withLock { $0 } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    ["mutate", "file.write", "archive.create"].map {
      MCPTool(
        name: $0, description: "Fixture mutation", inputSchema: .object(["type": .string("object")])
      )
    }
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    calls.withLock { $0 += 1 }
    return .object(["content": .array([]), "isError": .bool(false)])
  }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
