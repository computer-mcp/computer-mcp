import Foundation
import MCP
import Testing

@testable import ComputerMCP

struct MCPToolCatalogLoaderTests {
  @Test
  func readsEmptyIntermediatePagesAndOpaqueCursors() async throws {
    let second = Tool(
      name: "second", title: "Second", description: "Second page",
      inputSchema: .object(["type": .string("object")]),
      annotations: .init(readOnlyHint: true),
      outputSchema: .object(["type": .string("object")]))
    let tools = try await MCPToolCatalogLoader.load { cursor in
      switch cursor {
      case nil: return ([Self.tool("first")], "")
      case "": return ([], "页 / +==")
      case "页 / +==": return ([second], nil)
      default: throw PageError.unexpectedCursor
      }
    }
    #expect(tools == [Self.tool("first"), second])
  }

  @Test
  func returnsAnEmptyCatalog() async throws {
    let tools = try await MCPToolCatalogLoader.load { _ in ([], nil) }
    #expect(tools.isEmpty)
  }

  @Test
  func rejectsCursorCycles() async throws {
    await #expect(
      throws: GatewayToolError.executionFailed(
        "MCP tools/list returned a repeated pagination cursor.")
    ) {
      _ = try await MCPToolCatalogLoader.load { cursor in
        ([], cursor == "a" ? "b" : "a")
      }
    }
  }

  @Test
  func rejectsDuplicateNamesAcrossPages() async throws {
    await #expect(
      throws: GatewayToolError.executionFailed("MCP tools/list returned duplicate tool names.")
    ) {
      _ = try await MCPToolCatalogLoader.load { cursor in
        ([Self.tool("duplicate")], cursor == nil ? "next" : nil)
      }
    }
  }

  @Test
  func propagatesLaterPageFailureWithoutReturningPartialTools() async throws {
    await #expect(throws: PageError.failed) {
      _ = try await MCPToolCatalogLoader.load { cursor in
        guard cursor == nil else { throw PageError.failed }
        return ([Self.tool("first")], "next")
      }
    }
  }

  @Test
  func enforcesPageLimit() async throws {
    await #expect(
      throws: GatewayToolError.executionFailed("MCP tools/list exceeded the catalog page limit.")
    ) {
      _ = try await MCPToolCatalogLoader.load(maxPages: 2) { cursor in
        ([], (cursor ?? "") + "next")
      }
    }
  }

  @Test
  func enforcesToolLimitAcrossPages() async throws {
    await #expect(
      throws: GatewayToolError.executionFailed("MCP tools/list exceeded the catalog tool limit.")
    ) {
      _ = try await MCPToolCatalogLoader.load(maxTools: 1) { cursor in
        ([Self.tool(cursor ?? "first")], cursor == nil ? "second" : nil)
      }
    }
  }

  @Test
  func enforcesByteLimitAcrossPages() async throws {
    let first = Self.tool("first")
    let firstBytes = try JSONEncoder().encode([first]).count
    await #expect(
      throws: GatewayToolError.executionFailed("MCP tools/list exceeded the catalog byte limit.")
    ) {
      _ = try await MCPToolCatalogLoader.load(maxEncodedBytes: firstBytes + 4) { cursor in
        ([first], cursor == nil ? "next" : nil)
      }
    }
  }

  @Test
  func includesCursorInByteLimit() async throws {
    await #expect(
      throws: GatewayToolError.executionFailed("MCP tools/list exceeded the catalog byte limit.")
    ) {
      _ = try await MCPToolCatalogLoader.load(maxEncodedBytes: 4) { _ in ([], "secret-cursor") }
    }
  }

  @Test(arguments: ["", "contains\0null"])
  func rejectsInvalidNames(name: String) async throws {
    await #expect(
      throws: GatewayToolError.executionFailed("MCP tools/list returned an invalid tool name.")
    ) {
      _ = try await MCPToolCatalogLoader.load { _ in ([Self.tool(name)], nil) }
    }
  }

  @Test(arguments: [false, true])
  func rejectsNonObjectSchemas(output: Bool) async throws {
    let invalid = Tool(
      name: "invalid", description: nil,
      inputSchema: output ? .object([:]) : .null,
      outputSchema: output ? .string("invalid") : nil)
    let field = output ? "output" : "input"
    await #expect(
      throws: GatewayToolError.executionFailed(
        "MCP tools/list returned a non-object \(field) schema.")
    ) {
      _ = try await MCPToolCatalogLoader.load { _ in ([invalid], nil) }
    }
  }

  @Test
  func checksCancellationAfterEachPage() async throws {
    let task = Task {
      try await MCPToolCatalogLoader.load { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return ([Self.tool("first")], "next")
      }
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
  }

  private static func tool(_ name: String) -> Tool {
    Tool(name: name, description: nil, inputSchema: .object(["type": .string("object")]))
  }

  private enum PageError: Error { case failed, unexpectedCursor }
}
