import Foundation
import MCP
import Testing

@testable import ComputerMCP

struct MCPValueBridgeTests {
  @Test func structuredContentMetadataAndSchemaKeepExactIntegers() throws {
    let exact = MCP.Value.int(Int.max)
    let value = try JSONValue.sdkToolResult(
      content: [], structuredContent: .object(["id": exact]), isError: false,
      meta: .init(additionalFields: ["sequence": exact]))
    let wire = try JSONEncoder().encode(value)
    let result = try JSONDecoder().decode(JSONValue.self, from: wire).sdkCallToolResult()
    #expect(result.structuredContent == .object(["id": exact]))
    #expect(result._meta?["sequence"] == exact)
    let schema = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        "{\"type\":\"integer\",\"maximum\":9223372036854775807}".utf8))
    #expect(schema.sdkValue == .object(["type": .string("integer"), "maximum": exact]))
  }

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
