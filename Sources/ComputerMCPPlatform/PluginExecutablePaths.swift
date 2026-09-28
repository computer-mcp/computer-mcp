/// Package-owned entry points selected by the host platform, never by file availability.
package struct PluginExecutablePaths: Codable, Equatable, Sendable {
  private let paths: [String: String]

  package var platforms: Set<String> { Set(paths.keys) }

  package init(_ paths: [String: String]) throws {
    guard !paths.isEmpty, Set(paths.keys).isSubset(of: ["macos", "windows"]),
      paths.allSatisfy({ platform, path in
        Self.isNormalizedRelativePath(path)
          && (platform != "windows"
            || (WindowsFilePath.isValid(path) && !WindowsFilePath.isAbsolute(path)))
      })
    else { throw ValidationError.invalidPaths }
    self.paths = paths
  }

  package func path(for platform: String) throws -> String {
    guard let path = paths[platform] else { throw ValidationError.missingPlatform }
    return path
  }

  package static func isNormalizedRelativePath(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !path.isEmpty && !path.hasPrefix("~") && !path.contains("\\") && !path.contains("\0")
      && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
  }

  package init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode([String: String].self))
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(paths)
  }

  package enum ValidationError: Error { case invalidPaths, missingPlatform }
}
