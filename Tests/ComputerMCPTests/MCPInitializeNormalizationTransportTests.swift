import Foundation
import MCP
import Testing

@testable import ComputerMCP

struct MCPInitializeNormalizationTransportTests {
  @Test
  func removesOpenEndedExperimentalCapabilitiesFromInitializeRequest() throws {
    let input = try #require(
      """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "protocolVersion": "2025-11-25",
          "capabilities": {
            "experimental": {
              "openai": {"formElicitation": true},
              "custom_feature": "supported"
            },
            "roots": {"listChanged": true}
          },
          "clientInfo": {"name": "ChatGPT", "version": "1"}
        }
      }
      """.data(using: .utf8)
    )

    let output = MCPInitializeNormalization.normalize(input)
    let object = try #require(
      JSONSerialization.jsonObject(with: output) as? [String: Any]
    )
    let parameters = try #require(object["params"] as? [String: Any])
    let capabilities = try #require(parameters["capabilities"] as? [String: Any])
    let experimental = try #require(capabilities["experimental"] as? [String: Any])

    #expect(experimental.keys.sorted() == ["custom_feature"])
    #expect(experimental["custom_feature"] as? String == "supported")
    #expect(capabilities["roots"] != nil)
  }

  @Test
  func preservesInitializeRequestWhenExperimentalCapabilitiesAreStrings() throws {
    let input = try #require(
      """
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"custom_feature":"supported"}}}}
      """.data(using: .utf8)
    )

    #expect(MCPInitializeNormalization.normalize(input) == input)
  }

  @Test
  func preservesNonInitializeMessages() throws {
    let input = try #require(
      """
      {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"experimental":{"openai":{}}}}
      """.data(using: .utf8)
    )

    #expect(MCPInitializeNormalization.normalize(input) == input)
  }

  @Test
  func replaysSuccessfulInitializeResponseForRepeatedRequest() async throws {
    let transports = await InMemoryTransport.createConnectedPair()
    let normalization = MCPInitializeNormalizationTransport(wrapping: transports.server)
    try await transports.client.connect()
    try await normalization.connect()

    let serverMessages = await normalization.receive()
    let clientMessages = await transports.client.receive()
    var serverIterator = serverMessages.makeAsyncIterator()
    var clientIterator = clientMessages.makeAsyncIterator()

    let firstRequest = try #require(
      """
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"experimental":{"openai/visibility":{"enabled":true}}},"clientInfo":{"name":"openai-mcp","version":"1.0.0"}}}
      """.data(using: .utf8)
    )
    try await transports.client.send(firstRequest)

    let normalizedRequest = try #require(try await serverIterator.next())
    let normalizedObject = try #require(
      JSONDecoder().decode(JSONValue.self, from: normalizedRequest).objectValue
    )
    let normalizedParameters = try #require(normalizedObject["params"]?.objectValue)
    let normalizedCapabilities = try #require(
      normalizedParameters["capabilities"]?.objectValue
    )
    #expect(normalizedCapabilities["experimental"] == nil)

    let firstResponse = try #require(
      """
      {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"computer-mcp","version":"0.1.0"}}}
      """.data(using: .utf8)
    )
    try await normalization.send(firstResponse)
    #expect(try await clientIterator.next() == firstResponse)

    let repeatedRequest = try #require(
      """
      {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"openai-mcp","version":"1.0.0"}}}
      """.data(using: .utf8)
    )
    try await transports.client.send(repeatedRequest)

    let replayedData = try #require(try await clientIterator.next())
    let replayed = try #require(
      JSONDecoder().decode(JSONValue.self, from: replayedData).objectValue
    )
    #expect(replayed["id"] == .number(0))
    #expect(replayed["result"] != nil)

    await normalization.disconnect()
  }
}
