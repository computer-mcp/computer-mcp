import Testing

@testable import ComputerMCP

struct CodexApprovalRedactorTests {
  @Test
  func testRedactionBoundsStringsCollectionsAndDepth() {
    var nested: JSONValue = .string("leaf")
    for _ in 0..<20 {
      nested = .object(["child": nested])
    }
    let redactedText = CodexApprovalRedactor.redact(
      .object([
        "authorization": .string("Bearer approval-secret"),
        "message": .string(String(repeating: "x", count: 20_000)),
        "nested": nested,
      ])
    )
    let redactedCollection = CodexApprovalRedactor.redact(
      .array((0..<20_000).map { .number(Double($0)) })
    )
    let object = redactedText.objectValue

    #expect(object?["authorization"] == .string("[REDACTED]"))
    #expect(object?["message"]?.stringValue?.count == 8_192)
    #expect((redactedCollection.arrayValue?.count ?? 0) <= 10_000)
    #expect(String(describing: redactedText).contains("approval-secret") == false)
    #expect(String(describing: redactedText).contains("[TRUNCATED]"))
    #expect(String(describing: redactedCollection).contains("[TRUNCATED]"))
  }
}
