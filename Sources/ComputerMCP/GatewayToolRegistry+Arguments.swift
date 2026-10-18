import Foundation

extension GatewayToolRegistry {
  internal func optionalStringMap(_ name: String, in object: [String: JSONValue]) throws
    -> [String: String]?
  {
    guard let value = object[name] else {
      return nil
    }
    guard let dictionary = value.objectValue else {
      throw GatewayToolError.invalidArguments("\(name) must be an object.")
    }
    var result: [String: String] = [:]
    for key in dictionary.keys.sorted() {
      guard let string = dictionary[key]?.stringValue else {
        throw GatewayToolError.invalidArguments("\(name).\(key) must be a string.")
      }
      result[key] = string
    }
    return result
  }

  internal func jsonObject(_ dictionary: [String: String]) -> JSONValue {
    .object(dictionary.mapValues(JSONValue.string))
  }

  internal func validateUTF8ByteLimit(_ value: String, name: String, maxBytes: Int) throws {
    let bytes = Data(value.utf8).count
    guard bytes <= maxBytes else {
      throw GatewayToolError.invalidArguments("\(name) must be at most \(maxBytes) bytes.")
    }
  }

  internal func validateNonNegative(_ value: Int, name: String) throws {
    guard value >= 0 else {
      throw GatewayToolError.invalidArguments("\(name) must be zero or greater.")
    }
  }

  internal func validateBoundedNonNegative(_ value: Int, name: String, upperBound: Int) throws {
    try validateNonNegative(value, name: name)
    guard value <= upperBound else {
      throw GatewayToolError.invalidArguments(
        "\(name) must be less than or equal to \(upperBound).")
    }
  }

  internal func validateBoundedPositive(_ value: Int, name: String, upperBound: Int) throws {
    guard value > 0 else {
      throw GatewayToolError.invalidArguments("\(name) must be greater than zero.")
    }
    guard value <= upperBound else {
      throw GatewayToolError.invalidArguments(
        "\(name) must be less than or equal to \(upperBound).")
    }
  }

  internal func textResult(_ value: JSONValue) throws -> JSONValue {
    let data = try encoder.encode(value)
    return .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(String(decoding: data, as: UTF8.self)),
        ])
      ]),
      "structuredContent": .object(["result": value]),
      "isError": .bool(false),
    ])
  }

  internal func requiredString(_ name: String, in object: [String: JSONValue]) throws -> String {
    guard let value = object[name]?.stringValue, !value.isEmpty else {
      throw GatewayToolError.invalidArguments("Missing required string argument: \(name)")
    }
    return value
  }

  internal func requiredStringAllowingEmpty(
    _ name: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard object[name] != nil else {
      throw GatewayToolError.invalidArguments("Missing required string argument: \(name)")
    }
    guard let value = object[name]?.stringValue else {
      throw GatewayToolError.invalidArguments("\(name) must be a string.")
    }
    return value
  }

  internal func optionalString(_ name: String, in object: [String: JSONValue]) throws -> String? {
    guard let value = object[name] else {
      return nil
    }
    guard let string = value.stringValue else {
      throw GatewayToolError.invalidArguments("\(name) must be a string.")
    }
    guard !string.isEmpty else {
      throw GatewayToolError.invalidArguments("\(name) must not be empty.")
    }
    return string
  }

  internal func optionalStringAllowingEmpty(_ name: String, in object: [String: JSONValue]) throws
    -> String?
  {
    guard let value = object[name] else {
      return nil
    }
    guard let string = value.stringValue else {
      throw GatewayToolError.invalidArguments("\(name) must be a string.")
    }
    return string
  }

  internal func optionalISO8601Date(_ name: String, in object: [String: JSONValue]) throws -> Date?
  {
    guard let value = try optionalString(name, in: object) else {
      return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    let fallbackFormatter = ISO8601DateFormatter()
    fallbackFormatter.formatOptions = [.withInternetDateTime]
    guard let date = fallbackFormatter.date(from: value) else {
      throw GatewayToolError.invalidArguments("\(name) must be an ISO8601 timestamp.")
    }
    return date
  }

  internal func optionalStringArray(_ name: String, in object: [String: JSONValue]) throws
    -> [String]
  {
    guard let value = object[name] else {
      return []
    }
    guard let array = value.arrayValue else {
      throw GatewayToolError.invalidArguments("\(name) must be an array of strings.")
    }
    return try array.map { item in
      guard let string = item.stringValue else {
        throw GatewayToolError.invalidArguments("\(name) must be an array of strings.")
      }
      return string
    }
  }

  internal func requiredStructuredPath(_ name: String, in object: [String: JSONValue]) throws
    -> [StructuredPathSegment]
  {
    guard let value = object[name] else {
      throw GatewayToolError.invalidArguments("Missing required array argument: \(name)")
    }
    guard let array = value.arrayValue else {
      throw GatewayToolError.invalidArguments("\(name) must be an array of strings or integers.")
    }
    guard array.count <= 256 else {
      throw GatewayToolError.invalidArguments("\(name) must contain 256 or fewer segments.")
    }
    return try array.enumerated().map { index, item in
      if let key = item.stringValue {
        return .key(key)
      }
      if let int = item.intValue {
        guard int >= 0 else {
          throw GatewayToolError.invalidArguments(
            "\(name)[\(index)] index must be zero or greater.")
        }
        return .index(int)
      }
      throw GatewayToolError.invalidArguments("\(name) must be an array of strings or integers.")
    }
  }

  internal func requiredStringArray(_ name: String, in object: [String: JSONValue]) throws
    -> [String]
  {
    guard object[name] != nil else {
      throw GatewayToolError.invalidArguments("Missing required array argument: \(name)")
    }
    return try optionalStringArray(name, in: object)
  }

  internal func requiredObjectArray(_ name: String, in object: [String: JSONValue]) throws
    -> [[String: JSONValue]]
  {
    guard let value = object[name] else {
      throw GatewayToolError.invalidArguments("Missing required array argument: \(name)")
    }
    guard let array = value.arrayValue else {
      throw GatewayToolError.invalidArguments("\(name) must be an array of objects.")
    }
    return try array.enumerated().map { index, item in
      guard let object = item.objectValue else {
        throw GatewayToolError.invalidArguments("\(name)[\(index)] must be an object.")
      }
      return object
    }
  }

  internal func optionalInt(_ name: String, in object: [String: JSONValue]) -> Int? {
    object[name]?.intValue
  }

  internal func optionalBool(_ name: String, in object: [String: JSONValue]) throws -> Bool? {
    guard let value = object[name] else {
      return nil
    }
    guard let bool = value.boolValue else {
      throw GatewayToolError.invalidArguments("\(name) must be a Boolean.")
    }
    return bool
  }
}

extension String {
  internal func droppingPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else {
      return nil
    }
    return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

internal func iso8601String(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}
