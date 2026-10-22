import ComputerMCPCore
import ComputerMCPPlugins
import Crypto
import Foundation
import Testing

package func staticCatalogFixture() throws -> Data {
  let url = try #require(
    Bundle.module.url(
      forResource: "plugin-catalog-v3", withExtension: "json", subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

package func staticCatalogData(_ edit: (inout [String: JSONValue]) -> Void) throws -> Data {
  var root = try #require(
    JSONDecoder().decode(JSONValue.self, from: staticCatalogFixture()).objectValue)
  edit(&root)
  let content = root.filter { !["generation", "revision", "generated_at"].contains($0.key) }
  let digest = SHA256.hash(data: try StaticPluginCatalogDocument.canonical(.object(content)))
    .map { String(format: "%02x", $0) }.joined()
  root["revision"] = .string(digest)
  return try StaticPluginCatalogDocument.canonical(.object(root))
}

package func staticCatalogResponse(_ data: Data) -> PluginCatalogHTTPResponse {
  .init(
    status: 200, headers: ["content-type": "application/json", "etag": "\"fixture-v3\""], body: data
  )
}

package func staticCatalogResponse() throws -> PluginCatalogHTTPResponse {
  staticCatalogResponse(try staticCatalogFixture())
}

package actor StaticCatalogHTTPFake: StaticPluginCatalogFetching {
  package var replies: [Result<PluginCatalogHTTPResponse, PluginCatalogError>]
  package private(set) var validators: [StaticPluginCatalogValidators] = []
  package init(_ replies: [Result<PluginCatalogHTTPResponse, PluginCatalogError>]) {
    self.replies = replies
  }
  package func fetch(validators: StaticPluginCatalogValidators) async throws
    -> PluginCatalogHTTPResponse
  {
    self.validators.append(validators)
    guard !replies.isEmpty else { throw PluginCatalogError.networkUnavailable }
    return try replies.removeFirst().get()
  }
}
