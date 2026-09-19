import Testing

@testable import ComputerMCP

struct HostApprovalRedactorTests {
  @Test(arguments: [
    ("Authorization: Bearer example-value", "Authorization: Bearer [REDACTED]"),
    ("密码 token=example-value; next", "密码 token=[REDACTED]; next"),
    ("API_KEY: example-value, password=example-value", "API_KEY: [REDACTED], password=[REDACTED]"),
    ("credential=例子🧪 secret=example-value", "credential=[REDACTED] secret=[REDACTED]"),
    ("ordinary Unicode 文本 👩🏽‍💻", "ordinary Unicode 文本 👩🏽‍💻"),
    ("run --token example-value --mode test", "run --token [REDACTED] --mode test"),
    ("run --password 'two words'", "run --password [REDACTED]"),
    ("run --access-token \"two words\"", "run --access-token [REDACTED]"),
    ("run --token='two words'", "run --token=[REDACTED]"),
    ("password='two words'; mode=normal", "password=[REDACTED]; mode=normal"),
  ])
  func repeatedRedactionPreservesUnicodeBoundariesAndAllPatterns(input: String, expected: String) {
    for _ in 0..<1_000 {
      #expect(HostApprovalRedactor.redactString(input) == expected)
      #expect(
        HostApprovalRedactor.redactString(input, maximumCharacters: 8)
          == String(expected.prefix(8)))
    }
  }

  @Test
  func commandArgumentSecretsAndAPIKeysAreRedacted() {
    let result = HostApprovalRedactor.redact(
      .object([
        "argv": .array([
          .string("--token"), .string("example-value"),
          .string("--api-key"), .string("another-value"), .string("--mode"), .string("test"),
        ]),
        "api_key": .string("structured-value"),
      ]))
    #expect(result.objectValue?["api_key"] == .string("[REDACTED]"))
    #expect(
      result.objectValue?["argv"]
        == .array([
          .string("--token"), .string("[REDACTED]"),
          .string("--api-key"), .string("[REDACTED]"), .string("--mode"), .string("test"),
        ]))
  }

  @Test
  func sensitiveObjectFieldsConsumeTheSharedEntryBudget() {
    let fields = Dictionary(
      uniqueKeysWithValues: (0..<20_000).map {
        ("secret_\($0)", JSONValue.string("example-value"))
      })
    let result = HostApprovalRedactor.redact(.object(fields))
    #expect((result.objectValue?.count ?? 0) <= 10_000)
    #expect(result.objectValue?["_truncated"] == .bool(true))
  }

  @Test
  func testRedactionBoundsStringsCollectionsAndDepth() {
    var nested: JSONValue = .string("leaf")
    for _ in 0..<20 {
      nested = .object(["child": nested])
    }
    let redactedText = HostApprovalRedactor.redact(
      .object([
        "authorization": .string("Bearer approval-secret"),
        "message": .string(String(repeating: "x", count: 20_000)),
        "nested": nested,
      ])
    )
    let redactedCollection = HostApprovalRedactor.redact(
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
