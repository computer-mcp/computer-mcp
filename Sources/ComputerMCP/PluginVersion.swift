import Foundation

/// Semantic release identity. Build metadata does not change compatibility precedence.
package struct PluginVersion: Codable, Hashable, Sendable, CustomStringConvertible {
  package let description: String
  private let core: [String]
  private let prerelease: [String]

  package init(_ value: String) throws {
    let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
    guard buildParts.count <= 2 else {
      throw PluginManifestError.invalid("Invalid release version.")
    }
    let releaseParts = buildParts[0].split(
      separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let core = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false).map(
      String.init)
    guard core.count == 3, core.allSatisfy(Self.isCanonicalNumber) else {
      throw PluginManifestError.invalid(
        "Release versions must use major.minor.patch semantic versions.")
    }
    let prerelease =
      releaseParts.count == 2
      ? releaseParts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      : []
    for part in prerelease {
      guard Self.isIdentifier(part), !Self.isNumber(part) || Self.isCanonicalNumber(part) else {
        throw PluginManifestError.invalid("Invalid semantic prerelease identifier.")
      }
    }
    if buildParts.count == 2 {
      guard
        buildParts[1].split(separator: ".", omittingEmptySubsequences: false)
          .allSatisfy({ Self.isIdentifier(String($0)) })
      else {
        throw PluginManifestError.invalid("Invalid semantic build identifier.")
      }
    }
    description = value
    self.core = core
    self.prerelease = prerelease
  }

  package func precedes(_ other: PluginVersion) -> Bool {
    for (left, right) in zip(core, other.core) where left != right {
      return Self.numericPrecedes(left, right)
    }
    if prerelease.isEmpty { return false }
    if other.prerelease.isEmpty { return true }
    for (left, right) in zip(prerelease, other.prerelease) where left != right {
      let leftNumeric = Self.isNumber(left)
      let rightNumeric = Self.isNumber(right)
      if leftNumeric != rightNumeric { return leftNumeric }
      return leftNumeric ? Self.numericPrecedes(left, right) : left < right
    }
    return prerelease.count < other.prerelease.count
  }

  package init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  private static func isNumber(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
  }

  private static func isCanonicalNumber(_ value: String) -> Bool {
    isNumber(value) && (value.count == 1 || value.first != "0")
  }

  private static func isIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      }
  }

  private static func numericPrecedes(_ left: String, _ right: String) -> Bool {
    left.count == right.count ? left < right : left.count < right.count
  }
}
