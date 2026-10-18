import ComputerMCPPlatform
import Foundation

package typealias PluginPlatformCompatibility = ComputerMCPPlatform.PluginPlatformCompatibility

package struct PluginCompatibility: Codable, Equatable, Sendable {
  package let minimumHost: PluginVersion?
  package let maximumHost: PluginVersion?
  package let target: PluginPlatformCompatibility
  package let artifacts: [PluginArtifactDeclaration]
  private let declaredPlatforms: [String]?
  private let declaredArchitectures: [String]
  package var platforms: [String] { target.platforms }
  package var architectures: [String] { declaredArchitectures }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case minimumHost = "minimum_host"
    case maximumHost = "maximum_host"
    case platforms, architectures, artifacts
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    minimumHost = try c.decodeIfPresent(PluginVersion.self, forKey: .minimumHost)
    maximumHost = try c.decodeIfPresent(PluginVersion.self, forKey: .maximumHost)
    declaredPlatforms = try c.decodeIfPresent([String].self, forKey: .platforms)
    let architectures = try c.decodeIfPresent([String].self, forKey: .architectures) ?? []
    declaredArchitectures = architectures
    do {
      target = try PluginPlatformCompatibility(
        platforms: declaredPlatforms ?? ["macos"], architectures: architectures)
    } catch {
      throw PluginManifestError.invalid(
        "Compatibility requires unique supported platforms and architectures.")
    }
    artifacts = try c.decodeIfPresent([PluginArtifactDeclaration].self, forKey: .artifacts) ?? []
    if let minimumHost, let maximumHost, !minimumHost.precedes(maximumHost) {
      throw PluginManifestError.invalid("maximum_host must be greater than minimum_host.")
    }
    guard artifacts.count <= 100,
      Set(artifacts.map { $0.name.lowercased() }).count == artifacts.count,
      artifacts.allSatisfy({ $0.target.isSubset(of: target) }),
      platforms == ["macos"] || !artifacts.isEmpty
    else {
      throw PluginManifestError.invalid(
        "Artifact declarations must have unique names and targets within package compatibility; Windows packages require explicit artifacts."
      )
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(minimumHost, forKey: .minimumHost)
    try c.encodeIfPresent(maximumHost, forKey: .maximumHost)
    try c.encode(architectures, forKey: .architectures)
    // Keep parsed legacy declaration fingerprints stable for existing installations.
    try c.encodeIfPresent(declaredPlatforms, forKey: .platforms)
    if !artifacts.isEmpty { try c.encode(artifacts, forKey: .artifacts) }
  }

  package func permits(
    host: PluginVersion, architecture: String,
    platform: String = PluginPlatformCompatibility.currentPlatform
  ) -> Bool {
    (minimumHost.map { !host.precedes($0) } ?? true)
      && (maximumHost.map { host.precedes($0) } ?? true)
      && target.permits(platform: platform, architecture: architecture)
  }

  package func artifactTarget(named name: String?) -> PluginPlatformCompatibility? {
    artifacts.isEmpty ? target : artifacts.first { $0.name == name }?.target
  }
}

package struct PluginArtifactDeclaration: Codable, Equatable, Sendable {
  package let name: String
  package let target: PluginPlatformCompatibility
  private enum CodingKeys: String, CodingKey, CaseIterable { case name, platforms, architectures }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    guard !name.isEmpty, name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"),
      !name.contains(":"),
      !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      GitHubPluginArtifact.isArchive(name)
    else {
      throw PluginManifestError.invalid("Artifact names must identify one ZIP or TAR archive.")
    }
    do {
      target = try PluginPlatformCompatibility(
        platforms: c.decode([String].self, forKey: .platforms),
        architectures: c.decode([String].self, forKey: .architectures))
    } catch {
      throw PluginManifestError.invalid(
        "Artifact targets require unique supported platforms and architectures.")
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(target.platforms, forKey: .platforms)
    try c.encode(target.architectures, forKey: .architectures)
  }
}

extension PluginSource {
  func permits(manifest: PluginManifest, host: PluginVersion, architecture: String) -> Bool {
    guard let compatibility = manifest.compatibility else {
      return PluginPlatformCompatibility.macOS.permits(
        platform: PluginPlatformCompatibility.currentPlatform, architecture: architecture)
    }
    guard compatibility.permits(host: host, architecture: architecture) else { return false }
    guard kind == .artifact else { return true }
    return compatibility.artifactTarget(named: artifactName ?? githubRelease?.name)?.permits(
      platform: PluginPlatformCompatibility.currentPlatform, architecture: architecture) == true
  }
}
