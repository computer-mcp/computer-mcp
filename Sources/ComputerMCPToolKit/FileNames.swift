import ComputerMCPCore

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

package enum FileNameMatchMode: String {
  case contains
  case prefix
  case suffix
  case exact
}
