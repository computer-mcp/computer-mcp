import Foundation

/// Declared operating-system and architecture support, independent of launch authority.
package struct PluginPlatformCompatibility: Codable, Equatable, Sendable {
  package let platforms: [String]
  package let architectures: [String]

  package static let macOS = Self(uncheckedPlatforms: ["macos"], architectures: [])
  package static var currentPlatform: String {
    #if os(macOS)
      "macos"
    #elseif os(Windows)
      "windows"
    #endif
  }

  package init(platforms: [String], architectures: [String]) throws {
    guard !platforms.isEmpty, Set(platforms).count == platforms.count,
      platforms.allSatisfy({ ["macos", "windows"].contains($0) }),
      Set(architectures).count == architectures.count,
      architectures.allSatisfy({ ["arm64", "x86_64"].contains($0) })
    else { throw ValidationError.invalidTarget }
    self.init(uncheckedPlatforms: platforms.sorted(), architectures: architectures.sorted())
  }

  private init(uncheckedPlatforms: [String], architectures: [String]) {
    platforms = uncheckedPlatforms
    self.architectures = architectures
  }

  package func permits(platform: String, architecture: String) -> Bool {
    platforms.contains(platform) && ["arm64", "x86_64"].contains(architecture)
      && (architectures.isEmpty || architectures.contains(architecture))
  }

  package func isSubset(of other: Self) -> Bool {
    Set(platforms).isSubset(of: Set(other.platforms))
      && Set(architectures.isEmpty ? ["arm64", "x86_64"] : architectures)
        .isSubset(of: Set(other.architectures.isEmpty ? ["arm64", "x86_64"] : other.architectures))
  }

  package init(from decoder: any Decoder) throws {
    let all = try decoder.container(keyedBy: Key.self)
    guard Set(all.allKeys.map(\.stringValue)) == ["platforms", "architectures"] else {
      throw ValidationError.invalidTarget
    }
    try self.init(
      platforms: all.decode([String].self, forKey: Key("platforms")),
      architectures: all.decode([String].self, forKey: Key("architectures")))
  }

  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
  }

  package enum ValidationError: Error { case invalidTarget }
}
