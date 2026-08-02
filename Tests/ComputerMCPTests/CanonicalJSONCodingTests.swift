import Foundation
import Testing

@testable import ComputerMCP

@Suite
struct CanonicalJSONCodingTests {
  @Test
  func testInitialismsUseConventionalSnakeCaseKeys() throws {
    let document = InitialismDocument(
      capabilityIDs: ["file.read"],
      workspaceIDs: ["workspace-1"],
      requestID: "request-1",
      httpURL: "https://gateway.example.com/mcp",
      mcpRequestID: "mcp-1",
      openAITunnelIDs: ["tunnel-1"]
    )

    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    let data = try encoder.encode(document)
    let object = try #require(
      JSONDecoder().decode(JSONValue.self, from: data).objectValue
    )

    #expect(object["capability_ids"] != nil)
    #expect(object["workspace_ids"] != nil)
    #expect(object["request_id"] != nil)
    #expect(object["http_url"] != nil)
    #expect(object["mcp_request_id"] != nil)
    #expect(object["open_ai_tunnel_ids"] != nil)
    #expect(object.keys.allSatisfy { !$0.contains("_i_ds") })
  }

  @Test
  func testCanonicalKeysRoundTripToSwiftInitialisms() throws {
    let original = InitialismDocument(
      capabilityIDs: ["file.read"],
      workspaceIDs: ["workspace-1"],
      requestID: "request-1",
      httpURL: "https://gateway.example.com/mcp",
      mcpRequestID: "mcp-1",
      openAITunnelIDs: ["tunnel-1"]
    )
    let encoded = try CanonicalJSONCoding.encoder().encode(original)
    let decoded = try CanonicalJSONCoding.decoder().decode(
      InitialismDocument.self,
      from: encoded
    )

    #expect(decoded == original)
  }

  @Test
  func testKnownInitialismSequencesAreStable() {
    #expect(CanonicalJSONCoding.snakeCase("capabilityIDs") == "capability_ids")
    #expect(CanonicalJSONCoding.snakeCase("HTTPURL") == "http_url")
    #expect(CanonicalJSONCoding.snakeCase("MCPRequestID") == "mcp_request_id")
    #expect(CanonicalJSONCoding.snakeCase("openAITunnelIDs") == "open_ai_tunnel_ids")
    #expect(CanonicalJSONCoding.swiftPropertyName("assertion_ids") == "assertionIDs")
  }

  private struct InitialismDocument: Codable, Equatable {
    let capabilityIDs: [String]
    let workspaceIDs: [String]
    let requestID: String
    let httpURL: String
    let mcpRequestID: String
    let openAITunnelIDs: [String]
  }
}
