import Foundation
import Testing

@testable import ComputerMCP

struct OperationApprovalPreviewTests {
  @Test
  func genericMCPPreviewShowsNestedTargetAndMutation() throws {
    let arguments: [String: JSONValue] = [
      "server": .string("mail"), "tool": .string("send"),
      "arguments": .object([
        "recipient": .string("fixture@example.invalid"),
        "subject": .string("Review this draft"), "body": .string("The reviewed message."),
        "attachments": .array([.object(["path": .string("draft.txt")])]),
      ]),
    ]
    #expect(try preview(arguments) == .object(arguments))
  }

  @Test
  func builtinPreviewIncludesAttributeAndReplacementValues() throws {
    let arguments: [String: JSONValue] = [
      "path": .string("value.txt"), "name": .string("com.example.attribute"),
      "search": .string("old text"), "replacement": .string("new text"),
      "mode": .string("overwrite"), "dry_run": .bool(false), "confirm": .bool(true),
    ]
    #expect(try preview(arguments) == .object(arguments))
  }

  @Test
  func previewRedactsSecretsWithoutHashingTheRestOfTheRequest() throws {
    let result = try preview([
      "arguments": .object([
        "path": .string("reviewed.txt"), "api_key": .string("fixture-private-value"),
        "authorization": .string("Bearer fixture-other-value"),
      ]),
      "argv": .array([.string("--token"), .string("fixture-token-value"), .string("publish")]),
    ])
    #expect(result.objectValue?["arguments"]?.objectValue?["path"] == .string("reviewed.txt"))
    #expect(result.objectValue?["arguments"]?.objectValue?["api_key"] == .string("[REDACTED]"))
    #expect(
      result.objectValue?["arguments"]?.objectValue?["authorization"] == .string("[REDACTED]"))
    #expect(
      result.objectValue?["argv"]
        == .array([.string("--token"), .string("[REDACTED]"), .string("publish")]))
  }

  @Test(arguments: ["depth", "entries", "string", "bytes", "key", "ambiguous-key"])
  func unreviewableRequestsFailClosedInsteadOfBeingTruncated(kind: String) {
    var arguments: [String: JSONValue]
    switch kind {
    case "depth":
      var nested = JSONValue.string("target")
      for _ in 0..<13 { nested = .object(["child": nested]) }
      arguments = ["arguments": nested]
    case "entries": arguments = ["items": .array(Array(repeating: .bool(true), count: 1_000))]
    case "string": arguments = ["content": .string(String(repeating: "x", count: 8_193))]
    case "bytes":
      arguments = [
        "items": .array(Array(repeating: .string(String(repeating: "x", count: 6_000)), count: 3))
      ]
    case "key": arguments = [String(repeating: "x", count: 257): .bool(true)]
    default: arguments = ["token=first": .bool(true), "token=second": .bool(false)]
    }
    #expect(throws: (any Error).self) { try preview(arguments) }
  }

  private func preview(_ arguments: [String: JSONValue]) throws -> JSONValue {
    let summary = try GatewayRuntime.operationReviewSummary(arguments)
    return try JSONDecoder().decode(JSONValue.self, from: Data(summary.utf8))
  }
}
