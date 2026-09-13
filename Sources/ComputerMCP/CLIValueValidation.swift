import Foundation

/// The supported JSON Schema subset is explicit: unsupported assertions fail at load time,
/// rather than being advertised to callers and silently ignored during execution.
enum CLIValueValidation {
  private static let common: Set<String> = ["type", "description", "enum", "const"]

  static func validateSchema(_ schema: JSONValue, depth: Int = 0) throws {
    guard depth <= 16, let object = schema.objectValue, let type = object["type"]?.stringValue
    else {
      throw CLITreeError.invalid("A schema needs a supported type and at most 16 nesting levels.")
    }
    var allowed = common
    switch type {
    case "string": allowed.formUnion(["minLength", "maxLength"])
    case "integer", "number": allowed.formUnion(["minimum", "maximum"])
    case "boolean", "null": break
    case "array":
      allowed.formUnion(["items", "minItems", "maxItems"])
      guard let items = object["items"] else {
        throw CLITreeError.invalid("Array schema needs items.")
      }
      try validateSchema(items, depth: depth + 1)
    case "object":
      allowed.formUnion(["properties", "required", "additionalProperties"])
      guard let properties = object["properties"]?.objectValue,
        object["additionalProperties"] == nil || object["additionalProperties"]?.boolValue != nil
      else {
        throw CLITreeError.invalid(
          "Object schema needs properties and a Boolean additionalProperties.")
      }
      let required = object["required"]?.arrayValue ?? []
      guard object["required"] == nil || object["required"]?.arrayValue != nil,
        required.allSatisfy({ $0.stringValue.map { properties[$0] != nil } == true })
      else { throw CLITreeError.invalid("Invalid required property names.") }
      for child in properties.values { try validateSchema(child, depth: depth + 1) }
    default: throw CLITreeError.invalid("Unsupported schema type.")
    }
    guard Set(object.keys).isSubset(of: allowed),
      object["description"] == nil || object["description"]?.stringValue != nil
    else { throw CLITreeError.invalid("Unsupported or malformed schema keyword.") }
    for (lower, upper) in [("minLength", "maxLength"), ("minItems", "maxItems")] {
      for key in [lower, upper] where object[key] != nil {
        guard let value = object[key]?.intValue, value >= 0 else {
          throw CLITreeError.invalid("Schema size bounds must be non-negative integers.")
        }
      }
      if let min = object[lower]?.intValue, let max = object[upper]?.intValue, min > max {
        throw CLITreeError.invalid("Reversed schema size bounds.")
      }
    }
    for key in ["minimum", "maximum"] where object[key] != nil {
      guard let number = object[key]?.numberValue, number.isFinite else {
        throw CLITreeError.invalid("Schema numeric bounds must be finite numbers.")
      }
    }
    if let min = object["minimum"]?.numberValue, let max = object["maximum"]?.numberValue, min > max
    {
      throw CLITreeError.invalid("Reversed numeric bounds.")
    }
    if let enumeration = object["enum"] {
      guard let values = enumeration.arrayValue, !values.isEmpty, values.count <= 1_024 else {
        throw CLITreeError.invalid("Enum must contain 1...1024 values.")
      }
      var shape = object
      shape.removeValue(forKey: "enum")
      for value in values { try validate(value, schema: .object(shape), path: "enum") }
    }
    if let constant = object["const"] {
      var shape = object
      shape.removeValue(forKey: "const")
      try validate(constant, schema: .object(shape), path: "const")
    }
  }

  static func validate(_ value: JSONValue, schema: JSONValue, path: String, depth: Int = 0) throws {
    guard depth <= 16, let shape = schema.objectValue else {
      throw CLITreeError.invalid("Invalid value depth.")
    }
    func reject() -> CLITreeError { .invalid("Value does not satisfy schema at '\(path)'.") }
    if let enumeration = shape["enum"]?.arrayValue, !enumeration.contains(value) { throw reject() }
    if let constant = shape["const"], constant != value { throw reject() }
    switch shape["type"]?.stringValue {
    case "string":
      guard let string = value.stringValue else { throw reject() }
      // JSON Schema counts Unicode code points, not grapheme clusters or UTF-8 bytes.
      let count = string.unicodeScalars.count
      if let min = shape["minLength"]?.intValue, count < min { throw reject() }
      if let max = shape["maxLength"]?.intValue, count > max { throw reject() }
    case "number", "integer":
      guard let number = value.numberValue, number.isFinite else { throw reject() }
      if shape["type"] == .string("integer"), number.rounded() != number { throw reject() }
      if let min = shape["minimum"]?.numberValue, number < min { throw reject() }
      if let max = shape["maximum"]?.numberValue, number > max { throw reject() }
    case "boolean": guard value.boolValue != nil else { throw reject() }
    case "null": guard value == .null else { throw reject() }
    case "array":
      guard let values = value.arrayValue, let items = shape["items"] else { throw reject() }
      if let min = shape["minItems"]?.intValue, values.count < min { throw reject() }
      if let max = shape["maxItems"]?.intValue, values.count > max { throw reject() }
      for (index, child) in values.enumerated() {
        try validate(child, schema: items, path: "\(path)[\(index)]", depth: depth + 1)
      }
    case "object":
      guard let object = value.objectValue, let properties = shape["properties"]?.objectValue else {
        throw reject()
      }
      for key in shape["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
      where object[key] == nil {
        throw reject()
      }
      for (key, child) in object {
        if let childSchema = properties[key] {
          try validate(child, schema: childSchema, path: "\(path).\(key)", depth: depth + 1)
        } else if shape["additionalProperties"] == .bool(false) {
          throw reject()
        }
      }
    default: throw reject()
    }
  }
}
