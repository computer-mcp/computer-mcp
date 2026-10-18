import Foundation
import Testing

@testable import ComputerMCP

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct CLIParameterMappingTests {
  @Test(arguments: [
    (CLIArgumentToken.Style.separate, ["--value", "", "你好 world", "a\"b'c", "$(never-execute)\n"]),
    (
      .repeated,
      ["--value", "", "--value", "你好 world", "--value", "a\"b'c", "--value", "$(never-execute)\n"]
    ),
    (.equals, ["--value=", "--value=你好 world", "--value=a\"b'c", "--value=$(never-execute)\n"]),
  ])
  func anActualProcessReceivesTheDeclaredOptionArray(
    style: CLIArgumentToken.Style, expected: [String]
  ) async throws {
    let command = CLICommandDescriptor(
      id: "argv", path: [], description: "Read exact argv",
      parameters: [.init(name: "values", schema: CLITreeTests.strings, required: true)],
      argv: [
        .init(kind: .literal, value: "-c"),
        .init(
          kind: .literal,
          value: "import json,sys; print(json.dumps(sys.argv[1:], ensure_ascii=False))"),
        .init(kind: .option, parameter: "values", flag: "--value", style: style),
      ], stdout: .json, outputSchema: CLITreeTests.strings)
    let provider = CLITreeTests.provider(command, executable: "/usr/bin/python3")
    let tool = try #require(provider.listTools().first?.name)
    let values: JSONValue = .array([
      .string(""), .string("你好 world"), .string("a\"b'c"), .string("$(never-execute)\n"),
    ])
    let result = try await provider.callToolAsync(
      name: tool, arguments: .object(["values": values]))
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(CLITreeTests.output(result)?["data"] == .array(expected.map(JSONValue.string)))
    await provider.execution.shutdown()
  }

  @Test func nativeCLIArgumentsAndJSONOutputPreserveLargeIntegers() async throws {
    let integer: Int64 = 9_007_199_254_740_993
    let schema = JSONValue.object(["type": .string("integer")])
    let command = CLICommandDescriptor(
      id: "exact", path: [], description: "Echo an exact integer",
      parameters: [.init(name: "value", schema: schema, required: true)],
      argv: [
        .init(kind: .literal, value: "-c"),
        .init(kind: .literal, value: "import json,sys; print(json.dumps(int(sys.argv[1])))"),
        .init(kind: .positional, parameter: "value"),
      ], stdout: .json, outputSchema: schema)
    let provider = CLITreeTests.provider(command, executable: "/usr/bin/python3")
    let tool = try #require(provider.listTools().first?.name)
    let result = try await provider.callToolAsync(
      name: tool, arguments: .object(["value": .integer(integer)]))
    await provider.execution.shutdown()
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(CLITreeTests.output(result)?["data"]?.int64Value == integer)
  }

  @Test(arguments: [
    (JSONValue.number(-42), "integer", "--value=-42"),
    (.integer(.max), "integer", "--value=9223372036854775807"),
    (.integer(.min), "integer", "--value=-9223372036854775808"),
    (.integer(9_007_199_254_740_993), "integer", "--value=9007199254740993"),
    (.number(-1.25), "number", "--value=-1.25"),
    (.bool(false), "boolean", "--value=false"),
    (.string("--"), "string", "--value=--"),
    (.string("-file"), "string", "--value=-file"),
  ])
  func scalarTypesHaveExactEqualsEncoding(value: JSONValue, type: String, expected: String) throws {
    let command = CLICommandDescriptor(
      id: "scalar", path: [], description: "Scalar values",
      parameters: [.init(name: "value", schema: .object(["type": .string(type)]))],
      argv: [.init(kind: .option, parameter: "value", flag: "--value", style: .equals)])
    #expect(
      try CLIArgumentEncoder.encode(.object(["value": value]), command: command).arguments == [
        expected
      ])
  }

  @Test(arguments: [
    JSONValue.object(["mode": .string("invalid")]),
    .object(["count": .number(1.5)]), .object(["count": .number(-1)]),
    .object(["count": .number(4)]),
    .object(["items": .array([])]),
    .object(["items": .array([.string("a"), .string("b"), .string("c")])]),
    .object(["items": .array([.bool(true)])]),
  ])
  func enumNumericAndArrayBoundsRejectInvalidInputs(input: JSONValue) throws {
    let command = CLICommandDescriptor(
      id: "bounded", path: [], description: "Bounded input",
      parameters: [
        .init(
          name: "mode",
          schema: .object([
            "type": .string("string"), "enum": .array([.string("read"), .string("write")]),
          ])),
        .init(
          name: "count",
          schema: .object([
            "type": .string("integer"), "minimum": .number(0), "maximum": .number(3),
          ])),
        .init(
          name: "items",
          schema: .object([
            "type": .string("array"), "items": CLITreeTests.string, "minItems": .number(1),
            "maxItems": .number(2),
          ])),
      ],
      argv: [
        .init(kind: .option, parameter: "mode", flag: "--mode", style: .equals),
        .init(kind: .option, parameter: "count", flag: "--count", style: .equals),
        .init(kind: .option, parameter: "items", flag: "--item", style: .repeated),
      ])
    try command.validate()
    #expect(throws: CLITreeError.self) { try CLIArgumentEncoder.encode(input, command: command) }
  }

  @Test(arguments: ["integer", "number"])
  func numericSchemaBoundsEnumsAndConstantsKeepAdjacentIntegersDistinct(type: String) throws {
    let low = JSONValue.integer(9_007_199_254_740_992)
    let high = JSONValue.integer(9_007_199_254_740_993)
    for (keyword, bound, rejected) in [
      ("minimum", high, low), ("maximum", low, high), ("const", high, low),
    ] {
      let schema = JSONValue.object(["type": .string(type), keyword: bound])
      try CLIValueValidation.validateSchema(schema)
      try CLIValueValidation.validate(bound, schema: schema, path: "id")
      #expect(throws: CLITreeError.self) {
        try CLIValueValidation.validate(rejected, schema: schema, path: "id")
      }
    }
    let reversed = JSONValue.object(["type": .string(type), "minimum": high, "maximum": low])
    #expect(throws: CLITreeError.self) { try CLIValueValidation.validateSchema(reversed) }
    let enumeration = JSONValue.object(["type": .string(type), "enum": .array([high])])
    #expect(throws: CLITreeError.self) {
      try CLIValueValidation.validate(low, schema: enumeration, path: "id")
    }
    let all = JSONValue.object([
      "type": .string(type), "minimum": .integer(.min), "maximum": .integer(.max),
    ])
    try CLIValueValidation.validateSchema(all)
    try CLIValueValidation.validate(.integer(.max), schema: all, path: "id")
  }

  @Test
  func fixedPositionalsAndDeclaredDryRunRemainOrdered() throws {
    let command = CLICommandDescriptor(
      id: "copy", path: ["copy"], description: "Declared copy mapping",
      parameters: [
        .init(name: "dry_run", schema: .object(["type": .string("boolean")])),
        .init(
          name: "pair",
          schema: .object([
            "type": .string("array"), "items": CLITreeTests.string, "minItems": .number(2),
            "maxItems": .number(2),
          ]), required: true),
        .init(name: "destination", schema: CLITreeTests.string, required: true),
      ],
      argv: [
        .init(kind: .literal, value: "copy"),
        .init(kind: .flag, parameter: "dry_run", flag: "--dry-run", inverse: "--execute"),
        .init(kind: .literal, value: "--"), .init(kind: .positional, parameter: "pair"),
        .init(kind: .positional, parameter: "destination"),
      ], dryRunParameter: "dry_run")
    let input: JSONValue = .object([
      "dry_run": .bool(true), "pair": .array([.string("-a"), .string("")]),
      "destination": .string("target"),
    ])
    #expect(
      try CLIArgumentEncoder.encode(input, command: command).arguments == [
        "copy", "--dry-run", "--", "-a", "", "target",
      ])
    var invalid = command
    invalid.dryRunParameter = "destination"
    #expect(throws: CLITreeError.self) { try invalid.validate() }
  }
}
