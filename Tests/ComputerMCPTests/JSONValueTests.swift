import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite

final class JSONValueTests {
  @Test
  func testRoundTripsNestedJSON() throws {
    let value = JSONValue.object([
      "name": .string("computer-mcp"),
      "enabled": .bool(true),
      "count": .number(2),
      "items": .array([.string("screen"), .string("mouse")]),
      "metadata": .object(["empty": .null]),
    ])

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    #expect((decoded) == (value))
  }

  @Test
  func testDecodesNumbersOutsideIntRangeWithoutConfusingThemWithBooleans() throws {
    let decoded = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        """
        {
          "large": 9223372036952888479,
          "negative": -9223372036854775808,
          "enabled": true
        }
        """.utf8
      )
    )

    let object = try #require(decoded.objectValue)
    #expect((try #require(object["large"]?.numberValue)) > (Double(Int.max)))
    #expect((object["large"]?.intValue) == nil)
    #expect((object["negative"]?.intValue) == (Int.min))
    #expect((object["enabled"]) == (.bool(true)))
  }

  @Test
  func testIntValueRejectsNonFiniteAndOutOfRangeNumbers() {
    #expect((JSONValue.number(.infinity).intValue) == nil)
    #expect((JSONValue.number(.nan).intValue) == nil)
    #expect((JSONValue.number(-Double(Int.min)).intValue) == nil)
  }

  @Test
  func testMCPBridgeKeepsIntegralNumbersOutsideIntRangeAsDouble() {
    let value = -Double(Int.min)

    #expect((JSONValue.number(value).sdkValue) == (MCP.Value.double(value)))
    #expect((JSONValue.number(42).sdkValue) == (MCP.Value.int(42)))
  }
}
