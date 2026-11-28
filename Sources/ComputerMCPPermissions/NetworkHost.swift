import Foundation

/// Shared lexical identity for permission rules and egress destinations. DNS,
/// IDNA conversion and route classification remain host responsibilities.
package enum NetworkHost {
  package enum Error: Swift.Error { case invalidHost }

  package static func normalize(_ raw: String) throws -> String {
    var value = raw.lowercased()
    if value.hasPrefix("["), value.hasSuffix("]") {
      value = String(value.dropFirst().dropLast())
      guard value.contains(":") else { throw Error.invalidHost }
    }
    if value.contains(":") {
      guard !value.contains("%"), let words = ipv6(value) else { throw Error.invalidHost }
      if words.prefix(5).allSatisfy({ $0 == 0 }), words[5] == 0xffff {
        return "::ffff:\(words[6] >> 8).\(words[6] & 255).\(words[7] >> 8).\(words[7] & 255)"
      }
      var bestStart = 0
      var bestCount = 0
      var index = 0
      while index < 8 {
        if words[index] != 0 {
          index += 1
          continue
        }
        let start = index
        while index < 8 && words[index] == 0 { index += 1 }
        if index - start > bestCount {
          bestStart = start
          bestCount = index - start
        }
      }
      let parts = words.map { String($0, radix: 16) }
      guard bestCount >= 2 else { return parts.joined(separator: ":") }
      return parts.prefix(bestStart).joined(separator: ":") + "::"
        + parts.dropFirst(bestStart + bestCount).joined(separator: ":")
    }
    if value.hasSuffix(".") { value.removeLast() }
    if let bytes = ipv4(value) {
      guard !raw.hasSuffix(".") else { throw Error.invalidHost }
      return bytes.map(String.init).joined(separator: ".")
    }
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    guard !value.isEmpty, value.utf8.count <= 253,
      !value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
      !labels.allSatisfy({
        $0.utf8.allSatisfy({ (48...57).contains($0) })
          || ($0.hasPrefix("0x") && UInt64($0.dropFirst(2), radix: 16) != nil)
      }),
      labels.allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
          && label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
          )
      })
    else { throw Error.invalidHost }
    return value
  }

  /// Invalid spellings remain identifiable for diagnostics but never match a rule.
  package static func canonical(_ raw: String) -> String {
    if raw.hasPrefix("*.") {
      return (try? normalize(String(raw.dropFirst(2)))).map { "*." + $0 } ?? raw.lowercased()
    }
    return (try? normalize(raw)) ?? raw.lowercased()
  }

  package static func matches(_ host: String, rule: String) -> Bool {
    guard let host = try? normalize(host), let rule = validRule(rule) else { return false }
    if rule.hasPrefix("*.") {
      return host.hasSuffix(String(rule.dropFirst())) && host != String(rule.dropFirst(2))
    }
    return host == rule
  }

  /// Whether every destination admitted by `narrower` is admitted by `broader`.
  package static func contains(_ broader: String, rule narrower: String) -> Bool {
    guard let broader = validRule(broader), let narrower = validRule(narrower) else { return false }
    if broader == narrower { return true }
    if narrower.hasPrefix("*.") {
      return broader.hasPrefix("*.")
        && String(narrower.dropFirst(2)).hasSuffix(String(broader.dropFirst()))
    }
    return matches(narrower, rule: broader)
  }

  package static func intersection(_ lhs: Set<String>, _ rhs: Set<String>) -> Set<String> {
    var result: Set<String> = []
    for left in lhs {
      for right in rhs {
        if contains(left, rule: right) {
          result.insert(canonical(right))
        } else if contains(right, rule: left) {
          result.insert(canonical(left))
        }
      }
    }
    return result
  }

  static func precedes(_ lhs: String, _ rhs: String) -> Bool {
    if lhs.hasPrefix("*.") != rhs.hasPrefix("*.") { return !lhs.hasPrefix("*.") }
    if lhs.count != rhs.count { return lhs.count > rhs.count }
    return lhs < rhs
  }

  static func validRule(_ raw: String) -> String? {
    if raw.hasPrefix("*.") {
      guard let suffix = try? normalize(String(raw.dropFirst(2))),
        !suffix.contains(":"), ipv4(suffix) == nil
      else { return nil }
      return "*." + suffix
    }
    return try? normalize(raw)
  }

  private static func ipv4(_ value: String) -> [UInt8]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var result: [UInt8] = []
    for part in parts {
      guard !part.isEmpty, part.count == 1 || part.first != "0",
        part.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt8(part)
      else { return nil }
      result.append(number)
    }
    return result
  }

  private static func ipv6(_ value: String) -> [UInt16]? {
    let halves = value.components(separatedBy: "::")
    guard halves.count <= 2 else { return nil }
    func parse(_ half: String) -> [UInt16]? {
      if half.isEmpty { return [] }
      let parts = half.split(separator: ":", omittingEmptySubsequences: false)
      var result: [UInt16] = []
      for (index, part) in parts.enumerated() {
        if part.contains(".") {
          guard index == parts.count - 1, let bytes = ipv4(String(part)) else { return nil }
          result += [
            UInt16(bytes[0]) << 8 | UInt16(bytes[1]), UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
          ]
        } else {
          guard (1...4).contains(part.count),
            part.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            let word = UInt16(part, radix: 16)
          else { return nil }
          result.append(word)
        }
      }
      return result
    }
    guard let left = parse(halves[0]) else { return nil }
    if halves.count == 1 { return left.count == 8 ? left : nil }
    guard !halves[0].contains("."), let right = parse(halves[1]), left.count + right.count < 8
    else {
      return nil
    }
    return left + Array(repeating: 0, count: 8 - left.count - right.count) + right
  }
}
