import Foundation

/// Provider-owned argument bindings select existing work; they confer no permission.
struct MCPProviderContinuation: Sendable {
  static let metadataKey = "io.github.computer-mcp/continuation"
  static let maximumHandles = 16

  struct Query: Equatable, Sendable {
    let kind: String
    let handles: [String: MCPProviderWork.Identifier]
  }

  private struct Selector: Sendable {
    let kind: String
    let handles: [String: [String]]
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
      guard let object = value.objectValue, Set(object.keys) == ["kind", "handles"],
        let kind = object["kind"]?.stringValue, Self.validName(kind),
        let handles = object["handles"]?.objectValue,
        (1...Self.maximumHandles).contains(handles.count), handles.keys.allSatisfy(Self.validName)
      else { throw Self.invalidMetadata() }
      let paths = try handles.mapValues { value in
        guard let raw = value.stringValue, raw.hasPrefix("/"), raw.utf8.count <= 1024,
          !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw Self.invalidMetadata() }
        let parts = raw.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 32 else { throw Self.invalidMetadata() }
        return try parts.map { part in
          var decoded = ""
          var characters = part.makeIterator()
          while let character = characters.next() {
            if character == "~" {
              switch characters.next() {
              case "0": decoded.append("~")
              case "1": decoded.append("/")
              default: throw Self.invalidMetadata()
              }
            } else {
              decoded.append(character)
            }
          }
          return decoded
        }
      }
      return Selector(kind: kind, handles: paths)
    }
  }

  func queries(arguments: JSONValue) throws -> [Query] {
    try selectors.compactMap { selector in
      var handles: [String: MCPProviderWork.Identifier] = [:]
      var missing = false
      for name in selector.handles.keys.sorted() {
        guard let pointer = selector.handles[name] else { continue }
        guard let value = try Self.value(at: pointer, in: arguments) else {
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
      "[mcp.invalid_continuation_arguments] A continuation handle must be a bounded string or exact integer."
    )
  }
}
