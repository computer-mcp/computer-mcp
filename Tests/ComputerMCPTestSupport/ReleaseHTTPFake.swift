import ComputerMCPCore
import ComputerMCPPlugins
import Crypto
import Foundation

package actor ReleaseHTTPFake: PluginCatalogHTTPFetching {
  package private(set) var paths: [String] = []
  package private(set) var manifestRefs: [String] = []
  package private(set) var assetPages: [String] = []
  private var publisherID = 315_005_910
  private var repositoryID = 7
  private var tag = "release/1.2.3"
  private var revision = String(repeating: "a", count: 40)
  private var prerelease = false
  private var changeAfterValidation = false
  private var manifest: String
  private let artifactBytes: Data
  private var pages: [Int: [[String: JSONValue]]]
  private var links: [Int: String] = [:]

  package init(
    manifest: String = releaseManifestFixture, artifactBytes: Data = Data("archive fixture".utf8),
    tag: String = "release/1.2.3"
  ) {
    self.manifest = manifest
    self.artifactBytes = artifactBytes
    self.tag = tag
    pages = [
      1: [
        releaseAssetFixture(
          artifact: pluginArtifactFixture(bytes: artifactBytes, manifest: manifest))
      ]
    ]
  }

  package func setManifest(_ text: String) { manifest = text }

  package func setAssets(_ values: [[String: JSONValue]], page: Int, next: Int? = nil) {
    pages[page] = values
    links[page] = next.map {
      "https://api.github.com/repos/computer-mcp/combined/releases/9/assets?page=\($0)"
    }
  }
  package func setLink(_ link: String) { links[1] = link }
  package func setPrerelease() { prerelease = true }
  package func changeAfterFirstValidation() { changeAfterValidation = true }
  package func change(_ kind: String) {
    switch kind {
    case "publisher": publisherID = 99
    case "repository": repositoryID = 8
    case "tag": tag = "different"
    case "commit": revision = String(repeating: "b", count: 40)
    case "removed": pages[1] = []
    case "digest": pages[1]![0]["digest"] = .string("sha256:" + String(repeating: "0", count: 64))
    case "size": pages[1]![0]["size"] = .number(123)
    case "name": pages[1]![0]["name"] = .string("changed.zip")
    default: break
    }
  }

  package func fetch(path: String, query: [String: String], accept: String, maxBytes: Int)
    async throws
    -> PluginCatalogHTTPResponse
  {
    paths.append(path)
    let prefix = "/repos/computer-mcp/combined"
    if path == prefix {
      if changeAfterValidation && !assetPages.isEmpty { repositoryID = 8 }
      return json(
        .object([
          "id": .number(Double(repositoryID)), "name": .string("combined"),
          "full_name": .string("computer-mcp/combined"),
          "private": .bool(false), "archived": .bool(false), "disabled": .bool(false),
          "default_branch": .string("main"),
          "owner": .object([
            "id": .number(Double(publisherID)), "login": .string("computer-mcp"),
            "type": .string("Organization"),
          ]),
        ]))
    }
    if path.hasSuffix("/assets") {
      assetPages.append(query["page"] ?? "")
      let page = Int(query["page"] ?? "") ?? 1
      return json(.array((pages[page] ?? []).map(JSONValue.object)), link: links[page])
    }
    if path.hasPrefix(prefix + "/releases/") {
      return json(
        .object([
          "id": .number(9), "tag_name": .string(tag), "draft": .bool(false),
          "prerelease": .bool(prerelease),
          "published_at": .string("2026-09-08T00:00:00Z"),
        ]))
    }
    if path.hasPrefix(prefix + "/commits/") {
      return .init(status: 200, headers: [:], body: Data(revision.utf8))
    }
    if path.hasSuffix("/contents/" + PluginManifest.filename) {
      manifestRefs.append(query["ref"] ?? "")
      let bytes = Data(manifest.utf8)
      return json(
        .object([
          "type": .string("file"), "path": .string(PluginManifest.filename),
          "encoding": .string("base64"),
          "size": .number(Double(bytes.count)), "content": .string(bytes.base64EncodedString()),
          "sha": .string(
            Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes).map {
              String(format: "%02x", $0)
            }.joined()),
        ]))
    }
    return .init(status: 404, headers: [:], body: Data())
  }

  private func json(_ value: JSONValue, link: String? = nil) -> PluginCatalogHTTPResponse {
    var headers = ["content-type": "application/json"]
    headers["link"] = link.map { "<\($0)>; rel=\"next\"" }
    return .init(status: 200, headers: headers, body: try! JSONEncoder().encode(value))
  }
}
