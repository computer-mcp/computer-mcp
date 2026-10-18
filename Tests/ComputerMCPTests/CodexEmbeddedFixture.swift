import Foundation
import Testing

@testable import ComputerMCP

/// Historical wire/schema data; no embedded Codex implementation is linked by these fixtures.
enum CodexEmbeddedFixture {
  static func read(_ name: String) throws -> JSONValue {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
  }

  static func catalog() throws -> [JSONValue] {
    try #require(read("CodexEmbeddedCatalog").arrayValue)
  }

  static func state(pendingApproval: Bool, root: URL, headOID: String) throws -> JSONValue {
    let now = Date().timeIntervalSinceReferenceDate
    let encodedRoot = String(decoding: try JSONEncoder().encode(root.path), as: UTF8.self)
    let jsonRoot = String(encodedRoot.dropFirst().dropLast()).replacingOccurrences(
      of: "'", with: "''")
    func bind(_ value: JSONValue) -> JSONValue {
      switch value {
      case .string("__PLAN_EXPIRES__"): return .number(now + 300)
      case .string(let text):
        return .string(
          text
            .replacingOccurrences(
              of: "__SQL_ROOT__", with: root.path.replacingOccurrences(of: "'", with: "''")
            )
            .replacingOccurrences(of: "__JSON_ROOT__", with: jsonRoot)
            .replacingOccurrences(of: "__ROOT__", with: root.path)
            .replacingOccurrences(of: "__HEAD_OID__", with: headOID)
            .replacingOccurrences(of: "__LEASE_EXPIRES__", with: String(now + 900))
            .replacingOccurrences(of: "__PLAN_EXPIRES__", with: String(now + 300)))
      case .array(let array): return .array(array.map(bind))
      case .object(let object): return .object(object.mapValues(bind))
      default: return value
      }
    }
    return bind(try read("CodexEmbeddedState-\(pendingApproval)"))
  }
}
