import Foundation
import Testing
import os

@testable import ComputerMCP

struct OperationProviderBindingTests {
  @Test(arguments: ProviderBindingChange.allCases)
  func approvedTicketCannotFollowAReplacedProvider(change: ProviderBindingChange) async throws {
    let fixture = try ProviderBindingFixture()
    defer { fixture.removeFiles() }
    let original = try fixture.runtime(scenario: change)
    let replacement = try fixture.runtime(scenario: change, changed: true)
    do {
      let ticket = try fixture.prepare(in: original)
      try fixture.approve(ticket)
      do {
        _ = try fixture.commit(ticket, in: replacement)
        Issue.record("A changed provider must not execute an existing approval.")
      } catch {
        #expect(error.localizedDescription.contains("operations.ticket_arguments_mismatch"))
      }
      #expect(fixture.client.calls.isEmpty)
      #expect(try fixture.database.operationTicket(id: ticket)?.state == .approved)

      _ = try fixture.commit(ticket, in: original)
      #expect(fixture.client.calls == ["alpha:mutate"])
      #expect(try fixture.database.operationTicket(id: ticket)?.state == .succeeded)
      #expect(throws: (any Error).self) { try fixture.commit(ticket, in: original) }
      #expect(fixture.client.calls == ["alpha:mutate"])
      await original.shutdown()
      await replacement.shutdown()
    } catch {
      await original.shutdown()
      await replacement.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func identicalBindingAcrossRuntimesConsumesOnlyItsApprovedEntryOnce(generic: Bool) async throws {
    let fixture = try ProviderBindingFixture()
    defer { fixture.removeFiles() }
    let original = try fixture.runtime()
    let reconnected = try fixture.runtime()
    do {
      let ticket = try fixture.prepare(in: original, generic: generic)
      #expect(try fixture.database.operationTicket(id: ticket)?.state == .pendingApproval)
      #expect(throws: (any Error).self) {
        try fixture.commit(ticket, in: reconnected, generic: generic)
      }
      #expect(fixture.client.calls.isEmpty)
      try fixture.approve(ticket)
      do {
        _ = try fixture.commit(ticket, in: reconnected, generic: !generic)
        Issue.record("An alias and a generic entry must not exchange operation tickets.")
      } catch {
        #expect(error.localizedDescription.contains("operations.ticket_context_mismatch"))
      }
      #expect(fixture.client.calls.isEmpty)
      _ = try fixture.commit(ticket, in: reconnected, generic: generic)
      #expect(fixture.client.calls == ["alpha:mutate"])
      #expect(throws: (any Error).self) {
        try fixture.commit(ticket, in: original, generic: generic)
      }
      #expect(fixture.client.calls == ["alpha:mutate"])
      await original.shutdown()
      await reconnected.shutdown()
    } catch {
      await original.shutdown()
      await reconnected.shutdown()
      throw error
    }
  }
}

enum ProviderBindingChange: String, CaseIterable, Sendable {
  case serverMapping, toolMapping, command, environment, authentication, pluginSource
}

private struct ProviderBindingFixture {
  let root: URL
  let database: GatewayDatabase
  let client = ProviderBindingClient()
  let profile = ProfileGrantConfig(
    id: .chatGPTOperate,
    capabilities: ["operations.prepare", "operations.commit", "review.mutate", "mcp.tools.call"],
    workspaces: ["fixture"], allowedCallers: [.secureTunnel], mcpServers: ["alpha", "beta"],
    mode: .workspaceOperations, confirmationPolicy: .riskBased)

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try GatewayDatabase(inMemory: ())
    try database.saveProfile(profile.grant)
  }

  func runtime(scenario: ProviderBindingChange? = nil, changed: Bool = false) throws
    -> GatewayRuntime
  {
    let endpoint = "http://127.0.0.1:1/mcp"
    let authenticated = scenario == .authentication
    let alpha = MCPServerConfig(
      id: "alpha", transport: authenticated ? .streamableHTTP : .stdio,
      url: authenticated ? endpoint : nil,
      command: authenticated ? nil : (changed && scenario == .command ? "/bin/echo" : "/bin/cat"),
      env: ["FIXTURE_MODE": changed && scenario == .environment ? "replacement" : "original"],
      allowedTools: ["mutate", "replace"],
      toolRisks: ["mutate": .externalWrite, "replace": .externalWrite],
      authentication: authenticated
        ? .init(
          endpoint: endpoint,
          keychainAccount: changed ? "test-provider-replacement" : "test-provider-original") : nil)
    let beta = MCPServerConfig(
      id: "beta", transport: .stdio, command: "/bin/cat", allowedTools: ["mutate", "replace"],
      toolRisks: ["mutate": .externalWrite, "replace": .externalWrite])
    let origin = PluginContributionOrigin(
      pluginID: "fixture", componentID: "provider", version: try PluginVersion("1.0.0"),
      source: .init(
        kind: .development, root: root,
        revision: changed && scenario == .pluginSource
          ? "replacement-revision" : "reviewed-revision"))
    let plugin = ResolvedPlugin(
      id: "fixture", mcpServers: [alpha], cliCommands: [], skillRoots: [],
      origins: [.init(kind: .mcp, id: "alpha"): origin], diagnostics: [])
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate), profiles: [profile],
      mcp: .init(servers: [beta]),
      tools: [
        .init(
          name: "review.mutate", adapter: .mcp,
          source: changed && scenario == .serverMapping ? "beta" : "alpha",
          tool: changed && scenario == .toolMapping ? "replace" : "mutate",
          risk: CapabilityRisk.externalWrite.rawValue)
      ], workspaceDirectory: root)
    return try GatewayRuntime(
      configuration: configuration,
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "verified-owner"),
      database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
      mcpClient: client, plugins: [plugin])
  }

  func prepare(in runtime: GatewayRuntime, generic: Bool = false) throws -> String {
    let result = try runtime.callTool(
      name: "operations.prepare",
      arguments: .object([
        "workspace_id": .string("fixture"),
        "tool": .string(generic ? "mcp.tools.call" : "review.mutate"),
        "arguments": arguments(generic: generic),
      ]))
    return try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["ticket_id"]?
        .stringValue)
  }

  func approve(_ ticket: String) throws {
    try database.resolveOperationApproval(id: ticket, approved: true, resolver: .localCLI)
  }

  func commit(_ ticket: String, in runtime: GatewayRuntime, generic: Bool = false) throws
    -> JSONValue
  {
    try runtime.callTool(
      name: "operations.commit",
      arguments: .object([
        "workspace_id": .string("fixture"), "ticket_id": .string(ticket),
        "tool": .string(generic ? "mcp.tools.call" : "review.mutate"),
        "arguments": arguments(generic: generic),
      ]))
  }

  private func arguments(generic: Bool) -> JSONValue {
    let input = JSONValue.object(["value": .string("reviewed")])
    return generic
      ? .object(["server": .string("alpha"), "tool": .string("mutate"), "arguments": input])
      : input
  }

  func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

private final class ProviderBindingClient: DownstreamMCPClient, Sendable {
  private let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())
  var calls: [String] { recordedCalls.withLock { $0 } }

  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient { self }

  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    ["mutate", "replace"].map {
      .init(
        name: $0, description: "Change a fixture value",
        inputSchema: .object(["type": .string("object")]),
        annotations: .init(readOnlyHint: false))
    }
  }

  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    recordedCalls.withLock { $0.append("\(server.id):\(name)") }
    return .object([
      "content": .array([.object(["type": .string("text"), "text": .string("changed")])]),
      "isError": .bool(false),
    ])
  }

  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
