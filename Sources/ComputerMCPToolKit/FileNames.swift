import ComputerMCPCore
import Foundation

package func fileNameMatchMode(_ value: String) throws -> FileNameMatchMode {
  guard let mode = FileNameMatchMode(rawValue: value) else {
    throw GatewayToolError.invalidArguments(
      "match must be one of: contains, prefix, suffix, exact.")
  }
  return mode
}

package func fileName(
  _ name: String,
  matches query: String,
  mode: FileNameMatchMode,
  caseSensitive: Bool
) -> Bool {
  let candidate = caseSensitive ? name : name.lowercased()
  let needle = caseSensitive ? query : query.lowercased()

  switch mode {
  case .contains:
    return candidate.contains(needle)
  case .prefix:
    return candidate.hasPrefix(needle)
  case .suffix:
    return candidate.hasSuffix(needle)
  case .exact:
    return candidate == needle
  }
}

package func utf8Preview(_ value: String, maxBytes: Int) -> (text: String, truncated: Bool) {
  let data = Data(value.utf8)
  guard data.count > maxBytes else {
    return (value, false)
  }

  var index = value.startIndex
  var byteCount = 0
  while index < value.endIndex {
    let next = value.index(after: index)
    let characterByteCount = value[index..<next].utf8.count
    guard byteCount + characterByteCount <= maxBytes else {
      break
    }
    byteCount += characterByteCount
    index = next
  }

  return (String(value[..<index]), true)
}

package enum FileNameMatchMode: String {
  case contains
  case prefix
  case suffix
  case exact
}
