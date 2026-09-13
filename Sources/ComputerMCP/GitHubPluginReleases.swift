import Foundation

/// A publisher-bound release selection, not an artifact signature or tool grant.
/// Installers revalidate this snapshot and check the downloaded bytes before use.
package struct GitHubPluginArtifact: Codable, Equatable, Identifiable, Sendable {
  package let declaration: PluginCatalogEntry
  package let releaseID: Int64
  package let tag: String
  package let prerelease: Bool
  package let assetID: Int64
  package let name: String
  package let size: Int64
  package let sha256: String
  package var id: String { "\(declaration.repositoryID)/\(releaseID)/\(assetID)" }

  var apiPath: String { "/repos/\(declaration.repository)/releases/assets/\(assetID)" }

  func validate() throws {
    try GitHubPluginCatalog.Repository.validateName(declaration.repository)
    try validatePluginID(declaration.pluginID)
    guard declaration.publisherID == GitHubPluginCatalog.publisherID,
      Self.validID(declaration.repositoryID), Self.validID(releaseID), Self.validID(assetID),
      GitHubPluginCatalog.isGitSHA(declaration.revision),
      GitHubPluginCatalog.isGitSHA(declaration.manifestBlobSHA),
      !tag.isEmpty, tag.utf8.count <= 256,
      !tag.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !name.isEmpty, name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"),
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      Self.isArchive(name),
      size > 0, size <= PluginArchiveLimits().archiveBytes
    else { throw PluginCatalogError.invalidResponse }
    try PluginArchiveSnapshot.validateDigest(sha256)
    try PluginArchiveSnapshot.validateDigest(declaration.manifestSHA256)
  }

  static func validID(_ value: Int64) -> Bool { (1...9_007_199_254_740_991).contains(value) }

  static func isArchive(_ name: String) -> Bool {
    [".zip", ".tar", ".tar.gz", ".tgz"].contains { name.lowercased().hasSuffix($0) }
  }
}

package struct GitHubPluginReleaseArtifacts: Codable, Sendable {
  package let declaration: PluginCatalogEntry
  package let releaseID: Int64
  package let tag: String
  package let prerelease: Bool
  package let page: Int
  package let nextPage: Int?
  package let artifacts: [GitHubPluginArtifact]
  package let issues: [PluginCatalogIssue]
}

/// Reads public release metadata using the same publisher and declaration checks as search.
struct GitHubPluginReleases: Sendable {
  private let http: any PluginCatalogHTTPFetching

  private let timeout: Duration

  init(
    http: any PluginCatalogHTTPFetching = GitHubCatalogHTTPClient(),
    timeout: Duration = .seconds(30)
  ) {
    self.http = http
    self.timeout = min(max(timeout, .milliseconds(1)), .seconds(30))
  }

  func artifacts(
    repository: String, repositoryID: Int64, tag: String? = nil, page: Int = 1
  ) async throws -> GitHubPluginReleaseArtifacts {
    try await withDeadline {
      try await load(
        repository: repository, repositoryID: repositoryID, tag: tag, releaseID: nil, page: page)
    }
  }

  /// Re-fetch by immutable release/asset IDs; renamed, replaced or moved selections fail closed.
  func revalidate(_ artifact: GitHubPluginArtifact) async throws {
    try artifact.validate()
    try await withDeadline { try await checkRelease(artifact) }
  }

  private func checkRelease(_ artifact: GitHubPluginArtifact) async throws {
    let release = try await metadata(
      repository: artifact.declaration.repository, repositoryID: artifact.declaration.repositoryID,
      tag: nil, releaseID: artifact.releaseID)
    guard release.entry == artifact.declaration, release.release.tagName == artifact.tag,
      release.release.prerelease == artifact.prerelease
    else { throw PluginCatalogError.invalidProvenance }
    // The asset endpoint is repository-scoped. Only the release's own listing proves membership.
    var page = 1
    while true {
      let result = try await assets(
        repository: release.entry.repository, releaseID: release.release.id, page: page)
      if let asset = result.values.first(where: { $0.id == artifact.assetID }) {
        let current = try makeArtifact(asset, declaration: release.entry, release: release.release)
        guard current == artifact else { throw PluginCatalogError.invalidProvenance }
        return
      }
      guard let next = result.next else { throw PluginCatalogError.invalidProvenance }
      page = next
    }
  }

  private func load(
    repository: String, repositoryID: Int64, tag: String?, releaseID: Int64?, page: Int
  ) async throws -> GitHubPluginReleaseArtifacts {
    guard (1...1_000).contains(page) else { throw PluginCatalogError.invalidQuery }
    let (entry, release) = try await metadata(
      repository: repository, repositoryID: repositoryID, tag: tag, releaseID: releaseID)
    let result = try await assets(repository: entry.repository, releaseID: release.id, page: page)
    var artifacts: [GitHubPluginArtifact] = []
    var issues: [PluginCatalogIssue] = []
    for asset in result.values {
      guard GitHubPluginArtifact.isArchive(asset.name) else { continue }
      do { artifacts.append(try makeArtifact(asset, declaration: entry, release: release)) } catch {
        issues.append(
          .init(
            repository: entry.repository, code: "plugin.artifact.unavailable",
            message:
              "A release archive lacks valid uploaded content, a bounded size or a SHA-256 digest.")
        )
      }
    }
    return GitHubPluginReleaseArtifacts(
      declaration: entry, releaseID: release.id, tag: release.tagName,
      prerelease: release.prerelease, page: page, nextPage: result.next, artifacts: artifacts,
      issues: issues)
  }

  private func assets(repository: String, releaseID: Int64, page: Int) async throws -> (
    values: [Asset], next: Int?
  ) {
    try Task.checkCancellation()
    let path = "/repos/\(repository)/releases/\(releaseID)/assets"
    let response = try await http.fetch(
      path: path, query: ["per_page": "100", "page": String(page)],
      accept: "application/vnd.github+json", maxBytes: 2_097_152)
    try response.requireSuccess()
    let values = try response.decode([Asset].self)
    guard values.count <= 100, Set(values.map(\.id)).count == values.count else {
      throw PluginCatalogError.invalidResponse
    }
    return (values, try nextPage(response.headers["link"], path: path, current: page))
  }

  private func withDeadline<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    do {
      return try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask(operation: operation)
        group.addTask {
          try await Task.sleep(for: timeout)
          throw PluginCatalogError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      if let error = error as? PluginCatalogError { throw error }
      if (error as? URLError)?.code == .timedOut { throw PluginCatalogError.timedOut }
      throw PluginCatalogError.networkUnavailable
    }
  }

  private func metadata(
    repository: String, repositoryID: Int64, tag: String?, releaseID: Int64?
  ) async throws -> (entry: PluginCatalogEntry, release: Release) {
    try GitHubPluginCatalog.Repository.validateName(repository)
    guard GitHubPluginArtifact.validID(repositoryID),
      releaseID.map(GitHubPluginArtifact.validID) ?? true,
      tag.map({
        !$0.isEmpty && $0.utf8.count <= 256
          && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      }) ?? true
    else { throw PluginCatalogError.invalidQuery }
    try Task.checkCancellation()
    let prefix = "/repos/\(repository)"
    let response = try await http.fetch(
      path: prefix, query: [:], accept: "application/vnd.github+json", maxBytes: 262_144)
    try response.requireSuccess()
    let repo = try response.decode(GitHubPluginCatalog.Repository.self)
    try repo.validate()
    guard repo.id == repositoryID, repo.fullName.lowercased() == repository.lowercased(),
      !repo.archived, !repo.disabled
    else { throw PluginCatalogError.invalidProvenance }
    let selector = releaseID.map(String.init) ?? tag.map { "tags/" + $0 } ?? "latest"
    let releaseResponse = try await http.fetch(
      path: prefix + "/releases/" + selector, query: [:], accept: "application/vnd.github+json",
      maxBytes: 2_097_152)
    try releaseResponse.requireSuccess()
    let release = try releaseResponse.decode(Release.self)
    guard GitHubPluginArtifact.validID(release.id), releaseID.map({ $0 == release.id }) ?? true,
      !release.draft, release.publishedAt != nil, !release.tagName.isEmpty,
      release.tagName.utf8.count <= 256,
      !release.tagName.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      }),
      tag.map({ $0 == release.tagName }) ?? true
    else { throw PluginCatalogError.invalidResponse }
    let commit = try await http.fetch(
      path: prefix + "/commits/refs/tags/" + release.tagName, query: [:],
      accept: "application/vnd.github.sha", maxBytes: 128)
    try commit.requireSuccess()
    guard
      let revision = String(data: commit.body, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines), GitHubPluginCatalog.isGitSHA(revision),
      let entry = try await GitHubPluginCatalog.entry(
        repository: repo, revision: revision, http: http)
    else { throw PluginCatalogError.invalidManifest }
    return (entry, release)
  }

  private func makeArtifact(_ asset: Asset, declaration: PluginCatalogEntry, release: Release)
    throws -> GitHubPluginArtifact
  {
    guard asset.state == "uploaded", let digest = asset.digest, digest.hasPrefix("sha256:"),
      asset.url
        == "https://api.github.com/repos/\(declaration.repository)/releases/assets/\(asset.id)"
    else { throw PluginCatalogError.invalidResponse }
    let artifact = GitHubPluginArtifact(
      declaration: declaration, releaseID: release.id, tag: release.tagName,
      prerelease: release.prerelease, assetID: asset.id, name: asset.name, size: asset.size,
      sha256: String(digest.dropFirst(7)))
    try artifact.validate()
    return artifact
  }

  private func nextPage(_ link: String?, path: String, current: Int) throws -> Int? {
    guard let link else { return nil }
    let links = link.split(separator: ",").filter { $0.contains("rel=\"next\"") }
    guard links.count <= 1 else { throw PluginCatalogError.invalidResponse }
    guard let link = links.first else { return nil }
    guard let start = link.firstIndex(of: "<"), let end = link.firstIndex(of: ">"), start < end,
      let url = URLComponents(string: String(link[link.index(after: start)..<end])),
      url.scheme == "https", url.host == "api.github.com", url.port == nil, url.user == nil,
      url.password == nil,
      url.fragment == nil, url.path == path, current < 1_000,
      url.queryItems?.filter({ $0.name == "page" }).map(\.value) == [String(current + 1)]
    else { throw PluginCatalogError.invalidResponse }
    return current + 1
  }

  private struct Release: Decodable {
    let id: Int64
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: String?
    enum CodingKeys: String, CodingKey {
      case id, draft, prerelease
      case tagName = "tag_name"
      case publishedAt = "published_at"
    }
  }

  private struct Asset: Decodable {
    let id: Int64
    let name: String
    let state: String
    let size: Int64
    let digest: String?
    let url: String
  }
}
