import Foundation

enum HostApprovalRedactor {
  // Foundation regular expressions are immutable; compile the fixed policy once.
  private static let valuePatterns = [
    #"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#,
    #"(?i)((?:api[_-]?key|token|credential|password|secret)\s*[=:]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)"#,
    #"(?i)(--(?:[a-z0-9_-]*(?:token|credential|password|secret|authorization)|api[_-]?key)(?:\s+|=))(?:"[^"]*"|'[^']*'|[^\s]+)"#,
  ].map { try! NSRegularExpression(pattern: $0) }

  static func redact(_ value: JSONValue) -> JSONValue {
    var remainingEntries = 10_000
    return redact(value, depth: 0, remainingEntries: &remainingEntries)
  }

  private static func redact(
    _ value: JSONValue,
    depth: Int,
    remainingEntries: inout Int
  ) -> JSONValue {
    guard depth <= 16, remainingEntries > 0 else {
      return .string("[TRUNCATED]")
    }
    remainingEntries -= 1
    switch value {
    case .object(let object):
      var result: [String: JSONValue] = [:]
      for key in object.keys.sorted() {
        guard remainingEntries > 0 else {
          result["_truncated"] = .bool(true)
          break
        }
        let safeKey = redactString(key, maximumCharacters: 256)
        if isSensitiveKey(key) {
          remainingEntries -= 1
          result[safeKey] = .string("[REDACTED]")
        } else {
          result[safeKey] = redact(
            object[key] ?? .null, depth: depth + 1, remainingEntries: &remainingEntries)
        }
      }
      return .object(result)
    case .array(let values):
      var result: [JSONValue] = []
      var redactsNextArgument = false
      for value in values {
        guard remainingEntries > 0 else {
          result.append(.string("[TRUNCATED]"))
          break
        }
        if redactsNextArgument {
          remainingEntries -= 1
          result.append(.string("[REDACTED]"))
          redactsNextArgument = false
        } else {
          result.append(redact(value, depth: depth + 1, remainingEntries: &remainingEntries))
          if let argument = value.stringValue, argument.hasPrefix("--"),
            !argument.contains("=")
          {
            redactsNextArgument = isSensitiveKey(String(argument.dropFirst(2)))
          }
        }
      }
      return .array(result)
    case .string(let value):
      return .string(redactString(value))
    case .number, .bool, .null:
      return value
    }
  }

  static func redactString(
    _ value: String,
    maximumCharacters: Int = 8_192
  ) -> String {
    precondition(maximumCharacters > 0)
    return String(redactedString(value).prefix(maximumCharacters))
  }

  private static func isSensitiveKey(_ key: String) -> Bool {
    let normalized = key.lowercased()
    return [
      "authorization", "credential", "password", "secret", "token", "api_key", "api-key", "apikey",
    ]
    .contains { normalized.contains($0) }
  }

  private static func redactedString(_ value: String) -> String {
    let redacted = valuePatterns.reduce(value) { current, expression in
      let range = NSRange(current.startIndex..<current.endIndex, in: current)
      return expression.stringByReplacingMatches(
        in: current,
        range: range,
        withTemplate: "$1[REDACTED]"
      )
    }
    return redacted
  }
}
