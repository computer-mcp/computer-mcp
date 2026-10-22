import ComputerMCPCore
import ComputerMCPPlatform
import Crypto
import Foundation

/// Discovery metadata from the publisher. Installation independently revalidates GitHub authority.
package struct StaticPluginCatalogDocument: Decodable, Equatable, Sendable {
  static let maximumBytes = 4 * 1_024 * 1_024
  let schemaVersion: Int
  let publisher: Publisher
  let generation: Int64
  let revision: String
  let generatedAt: String
  let releases: [Release]

  struct Publisher: Decodable, Equatable, Sendable {
    let login: String
    let id: Int64
  }

  struct Release: Decodable, Equatable, Sendable {
    let repositoryID: Int64
    let repository: String
    let releaseID: Int64
    let tag: String
    let commit: String
    let manifestBlobSHA: String
    let manifestSHA256: String
    let pluginID: String
    let name: String
    let version: PluginVersion
    let summary: String?
    let contributions: Contributions
    let compatibility: Compatibility
    let dependencies: [PluginDependency]
    let prerelease: Bool
    let publishedAt: String
    let withdrawn: Bool
    let withdrawalReason: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
      case repository, tag, commit, name, version, summary, contributions, compatibility,
        dependencies
      case prerelease, withdrawn, assets
      case repositoryID = "repository_id"
      case releaseID = "release_id"
      case pluginID = "plugin_id"
      case manifestBlobSHA = "manifest_blob_sha"
      case manifestSHA256 = "manifest_sha256"
      case publishedAt = "published_at"
      case withdrawalReason = "withdrawal_reason"
    }

    var declaration: PluginCatalogEntry {
      PluginCatalogEntry(
        repositoryID: repositoryID, repository: repository,
        publisherID: GitHubPluginSource.publisherID, revision: commit,
        manifestBlobSHA: manifestBlobSHA, manifestSHA256: manifestSHA256,
        pluginID: pluginID, name: name, version: version, summary: summary,
        mcp: contributions.mcp, cli: contributions.cli, skills: contributions.skills)
    }

    func artifact(_ asset: Asset) -> GitHubPluginArtifact {
      GitHubPluginArtifact(
        declaration: declaration, releaseID: releaseID, tag: tag, prerelease: prerelease,
        assetID: asset.id, name: asset.name, size: asset.size, sha256: asset.sha256,
        compatibility: asset.compatibility)
    }

    func refusal(host: PluginVersion, architecture: String, platform: String = PluginHost.platform)
      -> PluginCompatibilityRefusal?
    {
      PluginCompatibilityRefusal.evaluate(
        pluginID: pluginID, version: version, pluginAPI: compatibility.pluginAPI,
        target: compatibility.target, artifacts: assets.map(\.compatibility),
        minimumHost: compatibility.minimumHost, maximumHost: compatibility.maximumHost,
        host: host, architecture: architecture, platform: platform)
    }

    func validate() throws {
      try GitHubPluginSource.Repository.validateName(repository)
      try validatePluginID(pluginID)
      guard GitHubPluginArtifact.validID(repositoryID), GitHubPluginArtifact.validID(releaseID),
        tag == version.description || tag == "v" + version.description,
        version.description.utf8.count <= 256,
        StaticPluginCatalogDocument.timestamp(publishedAt) != nil,
        Self.validText(name, limit: 4_096),
        summary.map({ Self.validText($0, limit: 16_384, allowEmpty: true) }) ?? true,
        (withdrawn && withdrawalReason.map({ Self.validText($0, limit: 4_096) }) == true)
          || (!withdrawn && withdrawalReason == nil),
        (1...100).contains(assets.count), dependencies.count <= 1_024
      else { throw PluginCatalogError.invalidResponse }
      let ids = contributions.mcp + contributions.cli + contributions.skills
      guard (1...1_024).contains(ids.count) else { throw PluginCatalogError.invalidResponse }
      guard Set(ids).count == ids.count,
        Set(dependencies.map(\.id)).count == dependencies.count
      else { throw PluginCatalogError.invalidResponse }
      for id in ids { try validatePluginID(id) }
      for dependency in dependencies {
        guard Self.validText(dependency.instructions, limit: 16_384),
          dependency.commands.count <= 1_024,
          dependency.commands.allSatisfy({ Self.validText($0, limit: 255) }),
          (dependency.documentation?.utf8.count ?? 0) <= 4_096
        else { throw PluginCatalogError.invalidResponse }
      }
      try compatibility.validate()
      guard Set(assets.map { $0.name.lowercased() }).count == assets.count else {
        throw PluginCatalogError.invalidResponse
      }
      for asset in assets {
        try artifact(asset).validate()
        guard asset.compatibility.isSubset(of: compatibility.target) else {
          throw PluginCatalogError.invalidResponse
        }
        guard let url = URLComponents(string: asset.url), url.scheme == "https",
          url.host == "github.com", url.port == nil, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil,
          url.path == "/\(repository)/releases/download/\(tag)/\(asset.name)"
        else { throw PluginCatalogError.invalidProvenance }
      }
    }

    private static func validText(_ value: String, limit: Int, allowEmpty: Bool = false) -> Bool {
      value.utf8.count <= limit
        && (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && !value.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) }
    }
  }

  struct Contributions: Decodable, Equatable, Sendable {
    let mcp: [String]
    let cli: [String]
    let skills: [String]
  }

  struct Compatibility: Decodable, Equatable, Sendable {
    let pluginAPI: Int
    let target: PluginPlatformCompatibility
    var platforms: [String] { target.platforms }
    var architectures: [String] { target.architectures }
    let minimumHost: PluginVersion?
    let maximumHost: PluginVersion?
    enum CodingKeys: String, CodingKey {
      case platforms, architectures
      case pluginAPI = "plugin_api"
      case minimumHost = "minimum_host"
      case maximumHost = "maximum_host"
    }

    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      pluginAPI = try c.decode(Int.self, forKey: .pluginAPI)
      target = try PluginPlatformCompatibility(
        platforms: c.decode([String].self, forKey: .platforms),
        architectures: c.decode([String].self, forKey: .architectures))
      minimumHost = try c.decodeIfPresent(PluginVersion.self, forKey: .minimumHost)
      maximumHost = try c.decodeIfPresent(PluginVersion.self, forKey: .maximumHost)
    }

    func validate() throws {
      guard pluginAPI > 0 else { throw PluginCatalogError.invalidResponse }
      guard (minimumHost?.description.utf8.count ?? 0) <= 256,
        (maximumHost?.description.utf8.count ?? 0) <= 256
      else { throw PluginCatalogError.invalidResponse }
      if let minimumHost, let maximumHost, !minimumHost.precedes(maximumHost) {
        throw PluginCatalogError.invalidResponse
      }
    }
  }

  struct Asset: Decodable, Equatable, Sendable {
    let id: Int64
    let name: String
    let size: Int64
    let sha256: String
    let url: String
    let compatibility: PluginPlatformCompatibility

    func matches(platform: String, architecture: String) -> Bool {
      compatibility.permits(platform: platform, architecture: architecture)
    }
  }

  enum CodingKeys: String, CodingKey {
    case publisher, generation, revision, releases
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
  }

  static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw PluginCatalogError.responseTooLarge }
    do {
      let raw = try JSONDecoder().decode(JSONValue.self, from: data)
      // The publisher's canonical serialization also rejects duplicate keys, alternate numeric
      // encodings and parser-dependent whitespace before accepting a revision or a cache record.
      guard try canonical(raw) == data else { throw PluginCatalogError.invalidResponse }
      try validateShape(raw)
      let value = try JSONDecoder().decode(Self.self, from: data)
      guard value.schemaVersion == 3,
        value.publisher.login == GitHubPluginSource.publisher,
        value.publisher.id == GitHubPluginSource.publisherID,
        GitHubPluginArtifact.validID(value.generation),
        timestamp(value.generatedAt) != nil, value.releases.count <= 1_024,
        var content = raw.objectValue
      else { throw PluginCatalogError.invalidResponse }
      try PluginArchiveSnapshot.validateDigest(value.revision)
      content.removeValue(forKey: "generation")
      content.removeValue(forKey: "revision")
      content.removeValue(forKey: "generated_at")
      let digest = SHA256.hash(data: try canonical(.object(content)))
        .map { String(format: "%02x", $0) }.joined()
      guard digest == value.revision else { throw PluginCatalogError.invalidProvenance }
      var releases = Set<String>()
      var versions = Set<String>()
      var assets = Set<Int64>()
      var pluginOwners: [String: Int64] = [:]
      var repositories: [Int64: String] = [:]
      var repositoryNames: [String: Int64] = [:]
      for release in value.releases {
        try release.validate()
        let siblings = value.releases.filter { $0.repositoryID == release.repositoryID }
        guard siblings.allSatisfy({ $0.pluginID == release.pluginID }),
          siblings.filter({ $0.prerelease == release.prerelease }).count == 1,
          !release.prerelease
            || siblings.filter({ !$0.prerelease }).allSatisfy({
              $0.version.precedes(release.version)
            })
        else { throw PluginCatalogError.invalidProvenance }
        guard releases.insert("\(release.repositoryID)/\(release.releaseID)").inserted,
          versions.insert("\(release.repositoryID)/\(release.version)").inserted,
          pluginOwners[release.pluginID].map({ $0 == release.repositoryID }) ?? true,
          repositories[release.repositoryID].map({ $0 == release.repository }) ?? true,
          repositoryNames[release.repository].map({ $0 == release.repositoryID }) ?? true
        else { throw PluginCatalogError.invalidProvenance }
        pluginOwners[release.pluginID] = release.repositoryID
        repositories[release.repositoryID] = release.repository
        repositoryNames[release.repository] = release.repositoryID
        for asset in release.assets {
          guard assets.insert(asset.id).inserted else { throw PluginCatalogError.invalidProvenance }
        }
      }
      return value
    } catch let error as PluginCatalogError {
      throw error
    } catch {
      throw PluginCatalogError.invalidResponse
    }
  }

  /// A newer discovery snapshot cannot resurrect a withdrawal or silently rewrite a package.
  func validateSuccessor(of previous: Self) throws {
    guard schemaVersion >= previous.schemaVersion, generation >= previous.generation else {
      throw PluginCatalogError.invalidProvenance
    }
    if generation == previous.generation {
      guard self == previous else { throw PluginCatalogError.invalidProvenance }
      return
    }
    guard revision != previous.revision, generatedAt >= previous.generatedAt else {
      throw PluginCatalogError.invalidProvenance
    }
    for old in previous.releases {
      guard
        let current = releases.first(where: {
          $0.repositoryID == old.repositoryID && $0.releaseID == old.releaseID
        })
      else {
        guard
          releases.contains(where: {
            $0.repositoryID == old.repositoryID && $0.repository == old.repository
              && $0.pluginID == old.pluginID && (old.prerelease || !$0.prerelease)
              && old.version.precedes($0.version)
          })
        else { throw PluginCatalogError.invalidProvenance }
        continue
      }
      guard !old.withdrawn || current.withdrawn, current.declaration == old.declaration,
        current.assets == old.assets, current.tag == old.tag,
        current.compatibility == old.compatibility,
        current.dependencies == old.dependencies, current.publishedAt == old.publishedAt
      else { throw PluginCatalogError.invalidProvenance }
    }
  }

  static func timestamp(_ value: String) -> Date? {
    guard value.utf8.count == 20, value.hasSuffix("Z") else { return nil }
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
      return nil
    }
    return date
  }

  /// Matches the publisher's sorted, two-space UTF-8 JSON representation.
  package static func canonical(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    func render(_ value: JSONValue, depth: Int) throws -> String {
      guard depth <= 24 else { throw PluginCatalogError.invalidResponse }
      let padding = String(repeating: "  ", count: depth)
      let next = padding + "  "
      switch value {
      case .array(let values) where !values.isEmpty:
        return try "[\n"
          + values.map { next + (try render($0, depth: depth + 1)) }
          .joined(separator: ",\n") + "\n" + padding + "]"
      case .object(let values) where !values.isEmpty:
        return try "{\n"
          + values.keys.sorted().map { key in
            next + String(decoding: try encoder.encode(key), as: UTF8.self) + ": "
              + (try render(values[key]!, depth: depth + 1))
          }.joined(separator: ",\n") + "\n" + padding + "}"
      default:
        return String(decoding: try encoder.encode(value), as: UTF8.self)
      }
    }
    return Data((try render(value, depth: 0) + "\n").utf8)
  }

  private static func validateShape(_ raw: JSONValue) throws {
    func fields(_ value: JSONValue, _ keys: Set<String>) throws -> [String: JSONValue] {
      guard let object = value.objectValue, Set(object.keys) == keys else {
        throw PluginCatalogError.invalidResponse
      }
      return object
    }
    let root = try fields(
      raw, ["schema_version", "publisher", "generation", "revision", "generated_at", "releases"])
    guard root["schema_version"] == .integer(3) else {
      throw PluginCatalogError.invalidResponse
    }
    let assetKeys: Set<String> = ["id", "name", "size", "sha256", "url", "compatibility"]
    _ = try fields(root["publisher"]!, ["login", "id"])
    for value in root["releases"]?.arrayValue ?? [] {
      let record = try fields(
        value,
        [
          "repository_id", "repository", "release_id", "tag", "commit", "manifest_blob_sha",
          "manifest_sha256",
          "plugin_id", "name", "version", "summary", "contributions", "compatibility",
          "dependencies",
          "prerelease", "published_at", "withdrawn", "withdrawal_reason", "assets",
        ])
      _ = try fields(record["contributions"]!, ["mcp", "cli", "skills"])
      _ = try fields(
        record["compatibility"]!,
        ["plugin_api", "platforms", "architectures", "minimum_host", "maximum_host"])
      for asset in record["assets"]?.arrayValue ?? [] {
        let record = try fields(asset, assetKeys)
        if let target = record["compatibility"] {
          _ = try fields(target, ["platforms", "architectures"])
        }
      }
      for dependency in record["dependencies"]?.arrayValue ?? [] {
        _ = try fields(
          dependency, ["id", "commands", "applications", "instructions", "documentation"])
      }
    }
  }
}
