import CryptoKit
import Foundation

/// Selected-release source verification. Discovery uses the publisher's static snapshot.
enum GitHubPluginSource {
  static let publisher = "computer-mcp"
  static let publisherID: Int64 = 315_005_910
  static func entry(
    repository: Repository, revision: String, http: any PluginCatalogHTTPFetching
  ) async throws -> PluginCatalogEntry? {
    try await declaration(repository: repository, revision: revision, http: http)?.entry
  }

  static func declaration(
    repository: Repository, revision: String, http: any PluginCatalogHTTPFetching
  ) async throws -> (entry: PluginCatalogEntry, manifest: PluginManifest)? {
    try repository.validate()
    guard isGitSHA(revision) else { throw PluginCatalogError.invalidResponse }
    let prefix = "/repos/\(repository.fullName)"
    let response = try await http.fetch(
      path: prefix + "/contents/" + PluginManifest.filename,
      query: ["ref": revision], accept: "application/vnd.github+json", maxBytes: 2_097_152)
    if response.status == 404 { return nil }
    try response.requireSuccess()
    let file = try response.decode(Content.self)
    guard file.type == "file", file.path == PluginManifest.filename, file.encoding == "base64",
      (1...1_048_576).contains(file.size), Self.isGitSHA(file.sha),
      let bytes = Data(base64Encoded: file.content.filter { !$0.isWhitespace }),
      bytes.count == file.size,
      let text = String(data: bytes, encoding: .utf8)
    else { throw PluginCatalogError.invalidResponse }
    let gitObject = Data("blob \(bytes.count)\0".utf8) + bytes
    let blobSHA =
      file.sha.count == 40
      ? Insecure.SHA1.hash(data: gitObject).map { String(format: "%02x", $0) }.joined()
      : SHA256.hash(data: gitObject).map { String(format: "%02x", $0) }.joined()
    guard blobSHA == file.sha else { throw PluginCatalogError.invalidResponse }
    let manifest: PluginManifest
    do { manifest = try PluginManifest.parse(text) } catch {
      throw PluginCatalogError.invalidManifest
    }
    guard manifest.name.utf8.count <= 4_096, (manifest.description?.utf8.count ?? 0) <= 16_384
    else {
      throw PluginCatalogError.responseTooLarge
    }
    let entry = PluginCatalogEntry(
      repositoryID: repository.id, repository: repository.fullName, publisherID: Self.publisherID,
      revision: revision, manifestBlobSHA: file.sha,
      manifestSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      pluginID: manifest.id, name: manifest.name, version: manifest.version,
      summary: manifest.description,
      mcp: manifest.mcp.map(\.id), cli: manifest.cli.map(\.id), skills: manifest.skills.map(\.id))
    return (entry, manifest)
  }

  struct Repository: Decodable {
    struct Owner: Decodable {
      let id: Int64
      let login: String
      let type: String
    }
    let id: Int64
    let name: String
    let fullName: String
    let owner: Owner
    let isPrivate: Bool
    let archived: Bool
    let disabled: Bool
    enum CodingKeys: String, CodingKey {
      case id, name, owner, archived, disabled
      case fullName = "full_name"
      case isPrivate = "private"
    }
    func validate() throws {
      guard id > 0, id <= 9_007_199_254_740_991, owner.id == GitHubPluginSource.publisherID,
        owner.login.lowercased() == GitHubPluginSource.publisher, owner.type == "Organization",
        !isPrivate,
        fullName == "\(owner.login)/\(name)", !name.isEmpty, name != ".", name != "..",
        name.utf8.count <= 100,
        name.utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || [45, 46, 95].contains($0)
        })
      else { throw PluginCatalogError.invalidProvenance }
    }

    static func validateName(_ fullName: String) throws {
      let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, parts[0].lowercased() == GitHubPluginSource.publisher,
        !parts[1].isEmpty, parts[1] != ".", parts[1] != "..", parts[1].utf8.count <= 100,
        parts[1].utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || [45, 46, 95].contains($0)
        })
      else { throw PluginCatalogError.invalidProvenance }
    }
  }

  private struct Content: Decodable {
    let type: String
    let path: String
    let encoding: String
    let size: Int
    let sha: String
    let content: String
  }

  static func isGitSHA(_ value: String) -> Bool {
    [40, 64].contains(value.utf8.count)
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

}
