import CryptoKit
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GitHubPluginSourceTests {
  @Test
  func readsOnlyThePinnedDeclarationAndKeepsPublisherAuthority() async throws {
    let http = PinnedManifestHTTP(manifest: catalogManifest)
    let repository = try JSONDecoder().decode(
      GitHubPluginSource.Repository.self,
      from: JSONEncoder().encode(catalogRepository("combined", id: 1)))
    let entry = try #require(
      try await GitHubPluginSource.entry(
        repository: repository, revision: catalogCommit, http: http))
    #expect(entry.repository == "computer-mcp/combined" && entry.publisherID == 315_005_910)
    #expect(entry.name == "Combined 工具" && entry.revision == catalogCommit)
    #expect(entry.mcp == ["native"] && entry.cli == ["command"] && entry.skills == ["guidance"])
    #expect(
      await http.requests == [
        "/repos/computer-mcp/combined/contents/computer-mcp-plugin.toml?ref=" + catalogCommit
      ])
  }

  @Test(arguments: ["publisher", "repository", "blob", "manifest"])
  func invalidSourceCannotBecomeAnInstallableDeclaration(_ fault: String) async throws {
    var source = catalogRepository("combined", id: 1)
    if fault == "publisher" {
      source["owner"] = .object([
        "id": .integer(999), "login": .string("computer-mcp"), "type": .string("Organization"),
      ])
    }
    if fault == "repository" { source["full_name"] = .string("another/combined") }
    let repository = try JSONDecoder().decode(
      GitHubPluginSource.Repository.self, from: JSONEncoder().encode(source))
    let http = PinnedManifestHTTP(
      manifest: fault == "manifest" ? "invalid [[[" : catalogManifest, invalidBlob: fault == "blob")
    await #expect(throws: PluginCatalogError.self) {
      try await GitHubPluginSource.entry(
        repository: repository, revision: catalogCommit, http: http)
    }
    if fault == "publisher" || fault == "repository" { #expect(await http.requests.isEmpty) }
  }
}

private let catalogCommit = String(repeating: "a", count: 40)
private let catalogManifest = """
  id = 'combined'
  name = 'Combined 工具'
  version = '1.0.0'
  repository = 'https://github.com/someone-else/claim'
  [[dependencies]]
  id = 'vendor'
  commands = ['vendor']
  instructions = 'Install separately.'
  [[mcp]]
  id = 'native'
  transport = 'http'
  url = 'https://example.invalid/mcp'
  [[cli]]
  id = 'command'
  executable = { dependency = 'vendor' }
  [[skills]]
  id = 'guidance'
  path = 'skills'
  """

private func catalogRepository(_ name: String, id: Int) -> [String: JSONValue] {
  [
    "id": .number(Double(id)), "name": .string(name), "full_name": .string("computer-mcp/\(name)"),
    "private": .bool(false), "archived": .bool(false), "disabled": .bool(false),
    "default_branch": .string("main"),
    "owner": .object([
      "id": .number(315_005_910), "login": .string("computer-mcp"), "type": .string("Organization"),
    ]),
  ]
}

private actor PinnedManifestHTTP: PluginCatalogHTTPFetching {
  let manifest: String
  let invalidBlob: Bool
  private(set) var requests: [String] = []
  init(manifest: String, invalidBlob: Bool = false) {
    self.manifest = manifest
    self.invalidBlob = invalidBlob
  }
  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
  {
    requests.append(path + "?ref=" + (query["ref"] ?? ""))
    let data = Data(manifest.utf8)
    let digest =
      invalidBlob
      ? String(repeating: "b", count: 40)
      : Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map {
        String(format: "%02x", $0)
      }.joined()
    let content: JSONValue = .object([
      "type": .string("file"), "path": .string(PluginManifest.filename),
      "encoding": .string("base64"), "size": .integer(Int64(data.count)), "sha": .string(digest),
      "content": .string(data.base64EncodedString()),
    ])
    return .init(
      status: 200, headers: ["content-type": "application/json"],
      body: try JSONEncoder().encode(content))
  }
}
