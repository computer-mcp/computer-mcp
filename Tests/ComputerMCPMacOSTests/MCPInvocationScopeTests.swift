import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct MCPInvocationScopeTests {
  @Test(arguments: ["file.write", "archive.create"], ["direct", "alias", "generic"])
  func downstreamBuiltinNamesCannotBorrowTrustedDryRunBehavior(tool: String, entry: String)
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    var permissions = Permissions()
    try permissions.set(.granted(.write), for: .project("fixture"))
    try permissions.set(.granted(.read), for: .mcpServer("external"))
    let profile = ProfileGrantConfig(
      grant: .init(
        id: .chatGPTOperate, permissions: permissions,
        allowedCallers: [.secureTunnel]))
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
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, projectID: "fixture",
        trustedPrincipalID: "verified-fixture"),
      database: database,
      registeredProjects: [project],
      platform: fixtureHostedPlatform(), mcpClient: client)
    let input: JSONValue =
      tool == "file.write"
      ? .object(["path": .string("/remote/target"), "dry_run": .bool(true)]) : .object([:])
    let name = entry == "alias" ? "review.change" : (entry == "generic" ? "mcp.tools.call" : tool)
    let arguments: JSONValue =
      entry == "generic"
      ? .object(["server": .string("external"), "tool": .string(tool), "arguments": input])
      : input
    do {
      _ = try await runtime.callToolAsync(name: name, arguments: arguments, context: .empty)
      Issue.record("Downstream dry_run must not bypass server write permission.")
    } catch {
      #expect(GatewayRuntime.auditErrorCode(for: error) == "permission.required")
    }
    #expect(client.callCount == 0)
    await runtime.shutdown()
  }

  @Test
  func projectRevocationRefusesAccessAndCatalogKeepsToolsRequestable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("private project content".utf8).write(to: root.appendingPathComponent("private.txt"))
    let database = try GatewayDatabase(inMemory: ())
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate, permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
      allowedCallers: [.secureTunnel])
    try database.saveProfile(profile.grant)
    let context = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate, projectID: "fixture",
      trustedPrincipalID: "verified-fixture")
    let runtime = try GatewayRuntime(
      configuration: .init(
        profiles: [profile], builtin: .init(enabled: ["file.read", "file.write"])),
      context: context, database: database,
      registeredProjects: [project],
      platform: fixtureHostedPlatform())
    do {
      #expect(try runtime.listTools(context: .empty).contains { $0.name == "file.read" })
      var revoked = try #require(database.profiles().first { $0.id == .chatGPTOperate })
      try revoked.permissions.set(.denied, for: .project("fixture"))
      try database.saveProfile(revoked, expectedRevision: revoked.authorizationRevision)
      #expect(try runtime.listTools(context: .empty).contains { $0.name == "file.read" })
      #expect(throws: (any Error).self) {
        try runtime.callTool(
          name: "file.read", arguments: .object(["path": .string("private.txt")]), context: .empty)
      }
      var unbound = context
      unbound.projectID = nil
      #expect(
        try runtime.listTools(context: unbound, invocationContext: .empty).contains {
          $0.name == "file.read"
        })
      let list = try runtime.callTool(
        name: "project.list", arguments: .object([:]), context: unbound, invocationContext: .empty
      )
      let rows = try #require(
        list.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["projects"]?
          .arrayValue)
      #expect(rows.count == 1)
      #expect(rows.first?.objectValue?["id"] == .string("fixture"))
      #expect(rows.first?.objectValue?["caller_access"] == .string("deny"))
      #expect(!String(describing: rows).contains(root.path))
      let description = try runtime.callTool(
        name: "project.describe", arguments: .object(["project_id": .string("fixture")]),
        context: unbound, invocationContext: .empty)
      #expect(!String(describing: description).contains(root.path))
      #expect(!String(describing: description).contains("private project content"))
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }
}

private final class StateScopeMCPClient: DownstreamMCPClient, Sendable {
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    try? listTools(server: server, context: context)
  }

  private let calls = NIOLockedValueBox(0)
  var callCount: Int { calls.withLockedValue { $0 } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    ["mutate", "file.write", "archive.create"].map {
      MCPTool(
        name: $0, description: "Fixture mutation", inputSchema: .object(["type": .string("object")])
      )
    }
  }
  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    calls.withLockedValue { $0 += 1 }
    return .object(["content": .array([]), "isError": .bool(false)])
  }
  func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  { .null }
  func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func getPrompt(
    server: MCPServerConfig, name: String, arguments: [String: String]?, context: InvocationContext
  ) throws
    -> JSONValue
  { .null }
}
