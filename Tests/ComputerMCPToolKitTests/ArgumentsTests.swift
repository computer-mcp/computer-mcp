import ComputerMCPCore
import ComputerMCPToolKit
import Foundation
import Testing

struct ArgumentsTests {
  @Test
  func stringsDistinguishMissingEmptyAndWrongTypes() throws {
    #expect(try requiredString("name", in: ["name": .string("value")]) == "value")
    #expect(throws: GatewayToolError.invalidArguments("Missing required string argument: name")) {
      try requiredString("name", in: ["name": .string("")])
    }
    #expect(throws: GatewayToolError.invalidArguments("Missing required string argument: name")) {
      try requiredStringAllowingEmpty("name", in: [:])
    }
    #expect(try requiredStringAllowingEmpty("name", in: ["name": .string("")]) == "")
    #expect(try optionalString("name", in: [:]) == nil)
    #expect(throws: GatewayToolError.invalidArguments("name must not be empty.")) {
      try optionalString("name", in: ["name": .string("")])
    }
    #expect(try optionalStringAllowingEmpty("name", in: ["name": .string("")]) == "")
    #expect(throws: GatewayToolError.invalidArguments("name must be a string.")) {
      try optionalStringAllowingEmpty("name", in: ["name": .null])
    }
  }

  @Test
  func mapsAndArraysRetainValidationOrderAndIndexedErrors() throws {
    #expect(try optionalStringMap("env", in: [:]) == nil)
    #expect(try optionalStringMap("env", in: ["env": .object([:])]) == [:])
    #expect(throws: GatewayToolError.invalidArguments("env.a must be a string.")) {
      try optionalStringMap("env", in: ["env": .object(["z": .null, "a": .number(1)])])
    }
    #expect(jsonObject(["KEY": "value"]) == .object(["KEY": .string("value")]))
    #expect(try optionalStringArray("items", in: [:]) == [])
    #expect(try requiredStringArray("items", in: ["items": .array([.string("")])]) == [""])
    #expect(throws: GatewayToolError.invalidArguments("Missing required array argument: items")) {
      try requiredStringArray("items", in: [:])
    }
    #expect(throws: GatewayToolError.invalidArguments("items must be an array of strings.")) {
      try optionalStringArray("items", in: ["items": .array([.null])])
    }
    #expect(throws: GatewayToolError.invalidArguments("items[1] must be an object.")) {
      try requiredObjectArray("items", in: ["items": .array([.object([:]), .null])])
    }
    #expect(try requiredObjectArray("items", in: ["items": .array([.object([:])])]) == [[:]])
  }

  @Test
  func scalarAndRangeValidationKeepsExactBoundaries() throws {
    #expect(optionalInt("n", in: ["n": .number(1.5)]) == nil)
    #expect(optionalInt("n", in: ["n": .integer(42)]) == 42)
    #expect(try optionalBool("enabled", in: [:]) == nil)
    #expect(try optionalBool("enabled", in: ["enabled": .bool(false)]) == false)
    #expect(throws: GatewayToolError.invalidArguments("enabled must be a Boolean.")) {
      try optionalBool("enabled", in: ["enabled": .number(1)])
    }
    try validateUTF8ByteLimit("空", name: "value", maxBytes: 3)
    #expect(throws: GatewayToolError.invalidArguments("value must be at most 2 bytes.")) {
      try validateUTF8ByteLimit("空", name: "value", maxBytes: 2)
    }
    try validateBoundedNonNegative(0, name: "n", upperBound: 1)
    try validateBoundedPositive(1, name: "n", upperBound: 1)
    #expect(throws: GatewayToolError.invalidArguments("n must be zero or greater.")) {
      try validateNonNegative(-1, name: "n")
    }
    #expect(throws: GatewayToolError.invalidArguments("n must be greater than zero.")) {
      try validateBoundedPositive(0, name: "n", upperBound: 1)
    }
    #expect(throws: GatewayToolError.invalidArguments("n must be less than or equal to 1.")) {
      try validateBoundedNonNegative(2, name: "n", upperBound: 1)
    }
  }

  @Test
  func structuredPathsKeepSegmentKindsAndLimits() throws {
    let segments = try requiredStructuredPath(
      "path", in: ["path": .array([.string(""), .integer(0), .string("key")])])
    #expect(segments.map(\.json) == [.string(""), .integer(0), .string("key")])
    #expect(try requiredStructuredPath("path", in: ["path": .array([])]).isEmpty)
    #expect(
      try requiredStructuredPath(
        "path", in: ["path": .array(Array(repeating: .integer(0), count: 256))]
      ).count == 256)
    #expect(throws: GatewayToolError.invalidArguments("path must contain 256 or fewer segments.")) {
      try requiredStructuredPath(
        "path", in: ["path": .array(Array(repeating: .integer(0), count: 257))])
    }
    #expect(throws: GatewayToolError.invalidArguments("path[1] index must be zero or greater.")) {
      try requiredStructuredPath("path", in: ["path": .array([.string("key"), .integer(-1)])])
    }
    #expect(
      throws: GatewayToolError.invalidArguments("path must be an array of strings or integers.")
    ) {
      try requiredStructuredPath("path", in: ["path": .array([.number(0.5)])])
    }
  }

  @Test
  func datesAndPrefixesKeepTheirTextConventions() throws {
    #expect(try optionalISO8601Date("at", in: [:]) == nil)
    #expect(
      try optionalISO8601Date("at", in: ["at": .string("1970-01-01T00:00:00Z")])
        == Date(timeIntervalSince1970: 0))
    #expect(
      try optionalISO8601Date("at", in: ["at": .string("1970-01-01T00:00:00.125Z")])
        == Date(timeIntervalSince1970: 0.125))
    #expect(throws: GatewayToolError.invalidArguments("at must be an ISO8601 timestamp.")) {
      try optionalISO8601Date("at", in: ["at": .string("yesterday")])
    }
    #expect(iso8601String(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    #expect("Prefix:  value\n".droppingPrefix("Prefix:") == "value")
    #expect("prefix: value".droppingPrefix("Prefix:") == nil)
  }

  @Test
  func textResultsKeepExactPrettySortedBytesAndStructuredValues() throws {
    let value: JSONValue = .object([
      "z": .integer(9_007_199_254_740_993), "a": .array([.bool(false), .string("空\n格")]),
    ])
    let expected = """
      {
        "a" : [
          false,
          "空\\n格"
        ],
        "z" : 9007199254740993
      }
      """
    #expect(
      try textResult(value)
        == .object([
          "content": .array([.object(["type": .string("text"), "text": .string(expected)])]),
          "structuredContent": .object(["result": value]), "isError": .bool(false),
        ]))
  }

  @Test
  func resultEncoderSupportsConcurrentCalls() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<32 {
        group.addTask {
          let result = try textResult(.array([.null, .string("value")]))
          #expect(
            result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]
              == .string("[\n  null,\n  \"value\"\n]"))
        }
      }
      try await group.waitForAll()
    }
  }
}
