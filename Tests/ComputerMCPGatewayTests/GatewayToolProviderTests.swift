import ComputerMCPTestSupport
import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway

@Suite

final class GatewayToolProviderTests {
  @Test
  func testRouterListsAndDispatchesAcrossProviders() throws {
    let first = TestGatewayToolProvider(
      id: "first",
      tool: MCPTool(
        name: "first.read",
        description: "Read first.",
        inputSchema: .object([:])
      ),
      result: .string("first")
    )
    let second = TestGatewayToolProvider(
      id: "second",
      tool: MCPTool(
        name: "second.read",
        description: "Read second.",
        inputSchema: .object([:])
      ),
      result: .string("second")
    )
    let router = try GatewayProviderRouter(providers: [first, second])

    #expect((try router.listTools(context: .empty).map(\.name)) == (["first.read", "second.read"]))
    #expect(
      (try router.callTool(name: "second.read", arguments: nil, context: .empty))
        == (.string("second")))
  }

  @Test
  func testRouterUsesProviderCapabilityDescriptor() throws {
    let provider = TestGatewayToolProvider(
      id: "local",
      tool: MCPTool(
        name: "local.admin",
        description: "Local administrative operation.",
        inputSchema: .object([:])
      ),
      result: .null,
      descriptor: CapabilityDescriptor(
        id: "local.admin",
        risk: .externalWrite,
        projectRequirement: .required,
        localOnly: true
      )
    )
    let router = try GatewayProviderRouter(providers: [provider])

    let descriptor = try router.capability(named: "local.admin", context: .empty)
    #expect((descriptor.id) == ("local.admin"))
    #expect((descriptor.risk) == (.externalWrite))
    #expect((descriptor.projectRequirement) == (.required))
    #expect(descriptor.localOnly)
  }

  @Test
  func retainedContinuationRequiresPrivateSelectionAndExpiresWithItsOwner() async throws {
    let visibility = NIOLockedValueBox((visible: true, owned: true))
    let reference = MCPToolReference(serverID: "fixture", toolName: "inspect")
    let provider = TestGatewayToolProvider(
      id: "fixture",
      tool: MCPTool(name: "fixture.inspect", description: "", inputSchema: .object([:])),
      result: .string("original owner"),
      descriptor: CapabilityDescriptor(
        id: "fixture.inspect", risk: .readOnly, projectRequirement: .required,
        mcpReference: reference))
    let router = try GatewayProviderRouter(
      source: { visibility.withLockedValue { $0.visible } ? [provider] : [] },
      retainsContinuation: { candidate in
        candidate == reference && visibility.withLockedValue { $0.owned }
      })
    visibility.withLockedValue { $0.visible = false }
    try await router.refreshTools(context: .empty)
    #expect(try router.listTools(context: .empty).isEmpty)
    #expect(router.continuationReference(named: "fixture.inspect") == reference)
    #expect(throws: GatewayToolError.self) {
      try router.callTool(name: "fixture.inspect", arguments: nil, context: .empty)
    }
    func target(_ reference: MCPToolReference) -> MCPContinuationTarget {
      .init(
        projectID: "ws", reference: reference, connectionID: UUID(), instanceID: UUID(),
        resources: [:])
    }
    let result = try router.callTool(
      name: "fixture.inspect", arguments: nil, context: .init(continuation: target(reference)))
    #expect(result == .string("original owner"))
    #expect(throws: GatewayToolError.self) {
      try router.callTool(
        name: "fixture.inspect", arguments: nil,
        context: .init(continuation: target(.init(serverID: "other", toolName: "inspect"))))
    }
    visibility.withLockedValue { $0.owned = false }
    try await router.refreshTools(context: .empty)
    #expect(router.continuationReference(named: "fixture.inspect") == nil)
    #expect(throws: GatewayToolError.self) {
      try router.callTool(
        name: "fixture.inspect", arguments: nil, context: .init(continuation: target(reference)))
    }
    await router.shutdown()
  }

  @Test
  func testRouterRejectsDuplicateToolNames() throws {
    let tool = MCPTool(
      name: "duplicate.read",
      description: "Duplicate.",
      inputSchema: .object([:])
    )

    expectThrows(
      try GatewayProviderRouter(
        providers: [
          TestGatewayToolProvider(id: "first", tool: tool, result: .null),
          TestGatewayToolProvider(id: "second", tool: tool, result: .null),
        ]
      )
    ) { error in
      #expect((error as? GatewayProviderRouterError) == (.duplicateTool("duplicate.read")))
    }
  }
}

private struct TestGatewayToolProvider: GatewayToolProvider {
  let id: String
  let tool: MCPTool
  let result: JSONValue
  var descriptor: CapabilityDescriptor?

  init(
    id: String,
    tool: MCPTool,
    result: JSONValue,
    descriptor: CapabilityDescriptor? = nil
  ) {
    self.id = id
    self.tool = tool
    self.result = result
    self.descriptor = descriptor
  }

  func definitions() throws -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: tool,
        capability: descriptor ?? CapabilityDescriptor(id: tool.name, risk: .externalWrite))
    ]
  }

  func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    guard invocation.name == tool.name else {
      throw GatewayToolError.unknownTool(invocation.name)
    }
    return result
  }
}
