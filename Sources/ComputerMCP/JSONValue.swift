import CoreFoundation
import Foundation

/// A small Codable representation for JSON values used by JSON-RPC payloads.
package enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case integer(Int64)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  /// Bridges Foundation numeric storage without Boolean coercion or floating-point rounding.
  init(foundationNumber number: NSNumber) throws {
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      self = .bool(number.boolValue)
    } else {
      self = try JSONDecoder().decode(Self.self, from: Data(number.stringValue.utf8))
    }
  }

  static func integer(exactly value: some BinaryInteger) throws -> Self {
    guard let integer = Int64(exactly: value) else {
      throw EncodingError.invalidValue(
        value,
        .init(
          codingPath: [],
          debugDescription: "JSON integer is outside the supported signed 64-bit range."))
    }
    return .integer(integer)
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      guard value.isFinite, value.rounded() != value else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "JSON integer is outside the supported signed 64-bit range.")
      }
      self = .number(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.typeMismatch(
        JSONValue.self,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Unsupported JSON value"
        )
      )
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      if let integer = Int64(exactly: value) {
        try container.encode(integer)
      } else {
        guard value.rounded() != value else {
          throw EncodingError.invalidValue(
            value,
            .init(
              codingPath: encoder.codingPath,
              debugDescription: "JSON integer is outside the supported signed 64-bit range."))
        }
        try container.encode(value)
      }
    case .integer(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }

  /// Returns the underlying string if this value is a string.
  package var stringValue: String? {
    if case .string(let value) = self {
      return value
    }
    return nil
  }

  /// Returns a floating-point approximation. Use integer accessors for identities and bounds.
  package var numberValue: Double? {
    switch self {
    case .number(let value): return value
    case .integer(let value): return Double(value)
    default: return nil
    }
  }

  /// Returns the underlying number as an integer when it is integral.
  package var intValue: Int? {
    int64Value.flatMap(Int.init(exactly:))
  }

  /// Returns a signed 64-bit integer without rounding.
  package var int64Value: Int64? {
    switch self {
    case .integer(let value): value
    case .number(let value): Int64(exactly: value)
    default: nil
    }
  }

  /// Compares numeric values without converting integer bounds through Double.
  func numericComparison(to other: Self) -> ComparisonResult? {
    func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
      lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }
    func compare(_ integer: Int64, _ number: Double) -> ComparisonResult? {
      guard number.isFinite else { return nil }
      if let exact = Int64(exactly: number) { return compare(integer, exact) }
      // A nonintegral Double is below the precision boundary; an integral one
      // that cannot convert to Int64 lies outside its range.
      return Double(integer) <= number ? .orderedAscending : .orderedDescending
    }
    switch (self, other) {
    case (.integer(let lhs), .integer(let rhs)): return compare(lhs, rhs)
    case (.number(let lhs), .number(let rhs)):
      return lhs.isFinite && rhs.isFinite ? compare(lhs, rhs) : nil
    case (.integer(let lhs), .number(let rhs)): return compare(lhs, rhs)
    case (.number(let lhs), .integer(let rhs)):
      guard let result = compare(rhs, lhs) else { return nil }
      return result == .orderedSame
        ? .orderedSame
        : result == .orderedAscending ? .orderedDescending : .orderedAscending
    default: return nil
    }
  }

  package static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.integer(let lhs), .integer(let rhs)): lhs == rhs
    case (.number(let lhs), .number(let rhs)): lhs == rhs
    case (.integer(let lhs), .number(let rhs)): Int64(exactly: rhs) == lhs
    case (.number(let lhs), .integer(let rhs)): Int64(exactly: lhs) == rhs
    case (.string(let lhs), .string(let rhs)): lhs == rhs
    case (.bool(let lhs), .bool(let rhs)): lhs == rhs
    case (.object(let lhs), .object(let rhs)): lhs == rhs
    case (.array(let lhs), .array(let rhs)): lhs == rhs
    case (.null, .null): true
    default: false
    }
  }

  /// Returns the underlying Boolean if this value is a Boolean.
  package var boolValue: Bool? {
    if case .bool(let value) = self {
      return value
    }
    return nil
  }

  /// Returns the underlying object if this value is an object.
  package var objectValue: [String: JSONValue]? {
    if case .object(let value) = self {
      return value
    }
    return nil
  }

  /// Returns the underlying array if this value is an array.
  package var arrayValue: [JSONValue]? {
    if case .array(let value) = self {
      return value
    }
    return nil
  }

  /// Encodes an arbitrary `Encodable` value and decodes it as `JSONValue`.
  package static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}
