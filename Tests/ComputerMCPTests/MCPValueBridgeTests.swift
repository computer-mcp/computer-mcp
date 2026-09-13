import Foundation
import MCP
import Testing

@testable import ComputerMCP

struct MCPValueBridgeTests {
  @Test(arguments: [false, true])
  func imageOnlyAndEmptyProtocolResultsKeepTheirShape(empty: Bool) throws {
    let content: [MCP.Tool.Content] =
      empty
      ? []
      : [
        .image(
          data: "AP8=", mimeType: "image/png", annotations: .init(audience: [.user], priority: 0.5),
          _meta: .init(additionalFields: ["fixture": .string("image")]))
      ]
    let original = try JSONValue.sdkToolResult(
      content: content, structuredContent: .object(["ok": .bool(true)]), isError: true,
      meta: .init(additionalFields: ["provider": .string("fixture")]))
    let result = try original.sdkCallToolResult()
    #expect(try JSONValue.encoded(result.content) == JSONValue.encoded(content))
    #expect(result.structuredContent == .object(["ok": .bool(true)]))
    #expect(result.isError == true)
    #expect(result._meta?["provider"] == .string("fixture"))
  }

  @Test(arguments: ["unknown", "image", "text"])
  func malformedContentCannotBecomeAPartialSuccessfulReply(type: String) {
    let value = JSONValue.object([
      "content": .array([
        .object(["type": .string("text"), "text": .string("valid first item")]),
        .object(["type": .string(type)]),
      ])
    ])
    #expect(throws: DecodingError.self) { try value.sdkCallToolResult() }
  }

  @Test
  func ordinaryJSONResultRemainsReadableText() throws {
    let value = JSONValue.object(["answer": .number(42)])
    let result = try value.sdkCallToolResult()
    let content = try JSONValue.encoded(result.content)
    let text = try #require(content.arrayValue?.first?.objectValue?["text"]?.stringValue)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == value)
  }
}
