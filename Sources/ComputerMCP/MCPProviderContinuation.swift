import Foundation

/// Provider-owned argument bindings select existing work; they confer no permission.
struct MCPProviderContinuation: Equatable, Sendable {
  static let metadataKey = "io.github.computer-mcp/continuation"
  static let maximumHandles = 16

  struct Query: Equatable, Sendable {
    let kind: String
    let handles: [String: MCPProviderWork.Identifier]
  }

  private struct Selector: Equatable, Sendable {
    let kind: String
    let handles: [String: [String]]
    let nullableHandles: Set<String>
    let condition: Condition?
  }

  private struct Condition: Equatable, Sendable {
    let pointer: [String]
    let values: Set<String>

    func matches(_ arguments: JSONValue) throws -> Bool {
      guard let value = try MCPProviderContinuation.value(at: pointer, in: arguments) else {
        return false
      }
      guard let operation = value.stringValue else {
        throw MCPProviderContinuation.invalidArguments()
      }
      return values.contains(operation)
    }
  }

  private let selectors: [Selector]

  init?(_ tool: MCPTool) throws {
    guard let value = tool.meta?.objectValue?[Self.metadataKey] else { return nil }
    guard tool.meta?.objectValue?[MCPProviderWork.metadataKey] != nil,
      try JSONEncoder().encode(value).count <= 16_384,
      let object = value.objectValue, Set(object.keys) == ["format_version", "selectors"],
      object["format_version"]?.int64Value == 1,
      let entries = object["selectors"]?.arrayValue, (1...16).contains(entries.count)
    else { throw Self.invalidMetadata() }
    selectors = try entries.map { value in
      guard let object = value.objectValue,
        Set(object.keys).isSubset(of: ["kind", "handles", "when", "nullable_handles"]),
        let kind = object["kind"]?.stringValue, Self.validName(kind),
        let handles = object["handles"]?.objectValue,
        (1...Self.maximumHandles).contains(handles.count), handles.keys.allSatisfy(Self.validName)
      else { throw Self.invalidMetadata() }
      let paths = try handles.mapValues(Self.pointer)
      let nullableHandles: Set<String>
      if let value = object["nullable_handles"] {
        guard let names = value.arrayValue, !names.isEmpty, names.count <= handles.count,
          names.allSatisfy({ $0.stringValue.map { handles[$0] != nil } == true })
        else { throw Self.invalidMetadata() }
        nullableHandles = Set(names.compactMap(\.stringValue))
        guard nullableHandles.count == names.count else { throw Self.invalidMetadata() }
      } else {
        nullableHandles = []
      }
      let condition: Condition?
      if let value = object["when"] {
        guard let fields = value.objectValue, Set(fields.keys) == ["pointer", "values"],
          let pointer = fields["pointer"], let values = fields["values"]?.arrayValue,
          (1...64).contains(values.count)
        else { throw Self.invalidMetadata() }
        let names = try values.map { value in
          guard let name = value.stringValue, Self.validName(name) else {
            throw Self.invalidMetadata()
          }
          return name
        }
        guard Set(names).count == names.count else { throw Self.invalidMetadata() }
        condition = try Condition(pointer: Self.pointer(pointer), values: Set(names))
      } else {
        condition = nil
      }
      return Selector(
        kind: kind, handles: paths, nullableHandles: nullableHandles, condition: condition)
    }
  }

  func queries(arguments: JSONValue) throws -> [Query] {
    try selectors.compactMap { selector in
      if let condition = selector.condition, try !condition.matches(arguments) { return nil }
      var handles: [String: MCPProviderWork.Identifier] = [:]
      var missing = false
      for name in selector.handles.keys.sorted() {
        guard let pointer = selector.handles[name] else { continue }
        guard let value = try Self.value(at: pointer, in: arguments) else {
          missing = true
          continue
        }
        if value == .null && selector.nullableHandles.contains(name) {
          missing = true
          continue
        }
        guard let identifier = MCPProviderWork.Identifier(value) else {
          throw Self.invalidArguments()
        }
        handles[name] = identifier
      }
      return missing ? nil : Query(kind: selector.kind, handles: handles)
    }
  }

  static func validName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func pointer(_ value: JSONValue) throws -> [String] {
    guard let raw = value.stringValue, raw.hasPrefix("/"), raw.utf8.count <= 1024,
      !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw invalidMetadata() }
    let parts = raw.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 32 else { throw invalidMetadata() }
    return try parts.map { part in
      var decoded = ""
      var characters = part.makeIterator()
      while let character = characters.next() {
        if character == "~" {
          switch characters.next() {
          case "0": decoded.append("~")
          case "1": decoded.append("/")
          default: throw invalidMetadata()
          }
        } else {
          decoded.append(character)
        }
      }
      return decoded
    }
  }

  private static func value(at pointer: [String], in arguments: JSONValue) throws -> JSONValue? {
    var value = arguments
    for component in pointer {
      switch value {
      case .object(let object):
        guard let next = object[component] else { return nil }
        value = next
      case .array(let array):
        guard let index = Int(component), index >= 0, String(index) == component else {
          throw invalidArguments()
        }
        guard index < array.count else { return nil }
        value = array[index]
      default: throw invalidArguments()
      }
    }
    return value
  }

  private static func invalidMetadata() -> GatewayToolError {
    .executionFailed(
      "[mcp.invalid_continuation_metadata] Unsupported provider continuation declaration.")
  }

  private static func invalidArguments() -> GatewayToolError {
    .invalidArguments(
      "[mcp.invalid_continuation_arguments] Continuation handles and operation selectors must match their declared scalar types."
    )
  }
}
