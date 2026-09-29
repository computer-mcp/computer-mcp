import Foundation
import Testing
import os

@testable import ComputerMCP

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

    #expect((try router.listTools().map(\.name)) == (["first.read", "second.read"]))
    #expect((try router.callTool(name: "second.read", arguments: nil)) == (.string("second")))
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
        workspaceRequirement: .required,
        localOnly: true
      )
    )
    let router = try GatewayProviderRouter(providers: [provider])

    let descriptor = try router.capability(named: "local.admin")
    #expect((descriptor.id) == ("local.admin"))
    #expect((descriptor.risk) == (.externalWrite))
    #expect((descriptor.workspaceRequirement) == (.required))
    #expect(descriptor.localOnly)
  }

  @Test
  func retainedContinuationRequiresPrivateSelectionAndExpiresWithItsOwner() async throws {
    let visibility = OSAllocatedUnfairLock(initialState: (visible: true, owned: true))
    let reference = MCPToolReference(serverID: "fixture", toolName: "inspect")
    let provider = TestGatewayToolProvider(
      id: "fixture",
      tool: MCPTool(name: "fixture.inspect", description: "", inputSchema: .object([:])),
      result: .string("original owner"),
      descriptor: CapabilityDescriptor(
        id: "fixture.inspect", risk: .readOnly, workspaceRequirement: .required,
        mcpReference: reference))
    let router = try GatewayProviderRouter(
      source: { visibility.withLock { $0.visible } ? [provider] : [] },
      retainsContinuation: { candidate in
        candidate == reference && visibility.withLock { $0.owned }
      })
    visibility.withLock { $0.visible = false }
    try await router.refreshTools()
    #expect(try router.listTools().isEmpty)
    #expect(router.continuationReference(named: "fixture.inspect") == reference)
    #expect(throws: GatewayToolError.self) {
      try router.callTool(name: "fixture.inspect", arguments: nil)
    }
    func target(_ reference: MCPToolReference) -> MCPContinuationTarget {
      .init(
        workspaceID: "ws", reference: reference, connectionID: UUID(), instanceID: UUID(),
        resources: [:])
    }
    try MCPContinuationTarget.$current.withValue(target(reference)) {
      let result = try router.callTool(name: "fixture.inspect", arguments: nil)
      #expect(result == .string("original owner"))
    }
    MCPContinuationTarget.$current.withValue(target(.init(serverID: "other", toolName: "inspect")))
    {
      #expect(throws: GatewayToolError.self) {
        try router.callTool(name: "fixture.inspect", arguments: nil)
      }
    }
    visibility.withLock { $0.owned = false }
    try await router.refreshTools()
    #expect(router.continuationReference(named: "fixture.inspect") == nil)
    MCPContinuationTarget.$current.withValue(target(reference)) {
      #expect(throws: GatewayToolError.self) {
        try router.callTool(name: "fixture.inspect", arguments: nil)
      }
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

  func listTools() throws -> [MCPTool] {
    [tool]
  }

  func capability(for tool: MCPTool) -> CapabilityDescriptor {
    descriptor ?? GatewayCapabilityCatalog().descriptor(for: tool)
  }

  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    guard name == tool.name else {
      throw GatewayToolError.unknownTool(name)
    }
    return result
  }
}
