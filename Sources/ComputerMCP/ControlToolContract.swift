import Foundation

enum ControlArgumentType: Sendable {
  case boolean
  case integer
  case object
  case string
  case strings

  var schema: JSONValue {
    switch self {
    case .boolean:
      return .object(["type": .string("boolean")])
    case .integer:
      return .object(["type": .string("integer")])
    case .object:
      return .object(["type": .string("object")])
    case .string:
      return .object(["type": .string("string")])
    case .strings:
      return .object(["type": .string("array"), "items": .object(["type": .string("string")])])
    }
  }

  func accepts(_ value: JSONValue) -> Bool {
    switch self {
    case .boolean:
      return value.boolValue != nil
    case .integer:
      return value.intValue != nil
    case .object:
      return value.objectValue != nil
    case .string:
      return value.stringValue != nil
    case .strings:
      return value.arrayValue?.allSatisfy { $0.stringValue != nil } == true
    }
  }

  var description: String {
    switch self {
    case .boolean: "a Boolean"
    case .integer: "an integer"
    case .object: "an object"
    case .string: "a string"
    case .strings: "an array of strings"
    }
  }
}

struct ControlToolContract: Sendable {
  let name: String
  let arguments: [String: ControlArgumentType]
  let requiredArguments: Set<String>
  let readOnly: Bool

  func tool() throws -> MCPTool {
    guard let capability = AppControlCapabilityCatalog.byID[name],
      capability.readOnly == readOnly
    else {
      throw GatewayToolError.executionFailed(
        "Local control capability metadata is inconsistent: \(name).")
    }
    return MCPTool(
      name: name,
      description: capability.summary
        + " Available only through the current-user owner-only control socket.",
      inputSchema: inputSchema,
      annotations: .init(
        readOnlyHint: readOnly, destructiveHint: capability.destructive,
        idempotentHint: capability.idempotent, openWorldHint: false))
  }

  init(
    _ name: String,
    arguments: [String: ControlArgumentType] = [:],
    required: Set<String> = [],
    readOnly: Bool
  ) {
    self.name = name
    self.arguments = arguments
    self.requiredArguments = required
    self.readOnly = readOnly
  }

  var inputSchema: JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(arguments.mapValues(\.schema)),
      "additionalProperties": .bool(false),
    ]
    if !requiredArguments.isEmpty {
      schema["required"] = .array(requiredArguments.sorted().map(JSONValue.string))
    }
    return .object(schema)
  }

  func validate(_ value: JSONValue?) throws -> [String: JSONValue] {
    let object: [String: JSONValue]
    if let value {
      guard let decoded = value.objectValue else {
        throw GatewayToolError.invalidArguments("Control arguments must be a JSON object.")
      }
      object = decoded
    } else {
      object = [:]
    }

    let unknownArguments = Set(object.keys).subtracting(arguments.keys).sorted()
    guard unknownArguments.isEmpty else {
      throw GatewayToolError.invalidArguments(
        "Unknown control argument\(unknownArguments.count == 1 ? "" : "s"): "
          + unknownArguments.joined(separator: ", ")
      )
    }

    let missingArguments = requiredArguments.subtracting(object.keys).sorted()
    guard missingArguments.isEmpty else {
      throw GatewayToolError.invalidArguments(
        "Missing required control argument\(missingArguments.count == 1 ? "" : "s"): "
          + missingArguments.joined(separator: ", ")
      )
    }

    for (name, value) in object {
      guard let type = arguments[name], type.accepts(value) else {
        throw GatewayToolError.invalidArguments(
          "Control argument '\(name)' must be \(arguments[name]?.description ?? "valid")."
        )
      }
    }
    return object
  }
}
