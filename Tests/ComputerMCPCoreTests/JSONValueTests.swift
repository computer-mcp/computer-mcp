import Foundation
import Testing

@testable import ComputerMCPCore

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

  @Test(arguments: [
    Int64.min, -9_007_199_254_740_993, 9_007_199_254_740_991,
    9_007_199_254_740_992, 9_007_199_254_740_993, Int64.max,
  ])
  func integersPreserveIdentityAcrossWire(_ integer: Int64) throws {
    let literal = String(integer)
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(literal.utf8))
    #expect(value.int64Value == integer)
    #expect(value == .integer(integer))
    #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == literal)
    let nested = try JSONValue.encoded(["id": integer])
    #expect(nested.objectValue?["id"]?.int64Value == integer)
    #expect(JSONValue.integer(integer) != .integer(integer == .max ? integer - 1 : integer + 1))
  }

  @Test(arguments: ["9223372036854775808", "-9223372036854775809", "18446744073709551615", "1e100"])
  func unsupportedIntegersFailExplicitly(_ literal: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(JSONValue.self, from: Data(literal.utf8))
    }
  }

  @Test func exactEqualityAndNumericOrderingDoNotRoundAdjacentIntegers() {
    let large = JSONValue.integer(9_007_199_254_740_993)
    let rounded = JSONValue.number(9_007_199_254_740_992)
    #expect(large != rounded)
    #expect(rounded != large)
    #expect(large.numericComparison(to: rounded) == .orderedDescending)
    #expect(rounded.numericComparison(to: large) == .orderedAscending)
    #expect(
      JSONValue.integer(.max).numericComparison(to: .number(Double(Int64.max))) == .orderedAscending
    )
    #expect(
      JSONValue.integer(.min).numericComparison(to: .number(Double(Int64.min))) == .orderedSame)
    #expect(JSONValue.integer(-2).numericComparison(to: .number(-1.5)) == .orderedAscending)
    #expect(JSONValue.integer(-1).numericComparison(to: .number(-1.5)) == .orderedDescending)
    #expect(JSONValue.integer(1).numericComparison(to: .number(.nan)) == nil)
    #expect(JSONValue.integer(42) == .number(42))
  }

  @Test func foundationNumbersKeepBooleansAndIntegerStorageDistinct() throws {
    for integer: Int64 in [0, 1, 9_007_199_254_740_993, .min, .max] {
      #expect(try JSONValue(foundationNumber: NSNumber(value: integer)) == .integer(integer))
    }
    #expect(try JSONValue(foundationNumber: NSNumber(value: true)) == .bool(true))
    #expect(try JSONValue(foundationNumber: NSNumber(value: 1.25)) == .number(1.25))
    #expect(throws: DecodingError.self) {
      try JSONValue(foundationNumber: NSNumber(value: UInt64.max))
    }
    #expect(throws: EncodingError.self) { try JSONValue.integer(exactly: UInt64.max) }
  }

  @Test func floatingPointStorageCannotEmitAnUnsupportedInteger() throws {
    let minimum = try JSONEncoder().encode(JSONValue.number(Double(Int64.min)))
    #expect(String(decoding: minimum, as: UTF8.self) == String(Int64.min))
    #expect(throws: EncodingError.self) {
      try JSONEncoder().encode(JSONValue.number(Double(Int64.max)))
    }
  }

  @Test
  func testIntValueRejectsNonFiniteAndOutOfRangeNumbers() {
    #expect((JSONValue.number(.infinity).intValue) == nil)
    #expect((JSONValue.number(.nan).intValue) == nil)
    #expect((JSONValue.number(-Double(Int.min)).intValue) == nil)
  }

}
