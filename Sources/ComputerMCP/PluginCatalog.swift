import Foundation

package struct PluginCatalogEntry: Codable, Equatable, Identifiable, Sendable {
  package let repositoryID: Int64
  package let repository: String
  package let publisherID: Int64
  package let revision: String
  package let manifestBlobSHA: String
  package let manifestSHA256: String
  package let pluginID: String
  package let name: String
  package let version: PluginVersion
  package let summary: String?
  package let mcp: [String]
  package let cli: [String]
  package let skills: [String]
  package var id: String { "\(repositoryID)@\(revision)" }
  package var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
  package var manifestURL: URL {
    repositoryURL.appendingPathComponent("blob").appendingPathComponent(revision)
      .appendingPathComponent(PluginManifest.filename)
  }

  func matches(query: String, kind: IntegrationKind?) -> Bool {
    if let kind {
      switch kind {
      case .mcp: guard !mcp.isEmpty else { return false }
      case .cli: guard !cli.isEmpty else { return false }
      case .skills: guard !skills.isEmpty else { return false }
      }
    }
    let text = [repository, pluginID, name, summary ?? ""].joined(separator: "\n").lowercased()
    return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
  }
}

package struct PluginCatalogIssue: Codable, Equatable, Sendable {
  package let repository: String
  package let code: String
  package let message: String
  package var httpStatus: Int? = nil
}

package struct PluginCatalogSearchResult: Codable, Sendable {
  package let publisher: String
  package let publisherID: Int64
  package let query: String
  package let kind: IntegrationKind?
  package let page: Int
  package let nextPage: Int?
  package let checkedRepositories: Int
  package let fetchedAt: Date
  package let cached: Bool
  package let entries: [PluginCatalogEntry]
  package let issues: [PluginCatalogIssue]
  package var catalog: PluginCatalogStatus? = nil
}

package struct PluginCatalogStatus: Codable, Equatable, Sendable {
  package let generation: Int64
  package let revision: String
  package let generatedAt: Date
  package let validatedAt: Date
  package let stale: Bool
  package let nextRefreshAt: Date
}

package enum PluginCatalogError: Error, Equatable, LocalizedError, Sendable {
  case invalidQuery
  case busy
  case invalidResponse
  case invalidManifest
  case invalidProvenance
  case responseTooLarge
  case unsafeRequest
  case authenticationRequired
  case httpStatus(Int)
  case rateLimited(retryAfterSeconds: Int?)
  case timedOut
  case networkUnavailable

  package var code: String {
    switch self {
    case .invalidQuery: "plugin.catalog.invalid_query"
    case .busy: "plugin.catalog.busy"
    case .invalidResponse: "plugin.catalog.invalid_response"
    case .invalidManifest: "plugin.catalog.invalid_manifest"
    case .invalidProvenance: "plugin.catalog.invalid_provenance"
    case .responseTooLarge: "plugin.catalog.response_too_large"
    case .unsafeRequest: "plugin.catalog.unsafe_request"
    case .authenticationRequired: "plugin.catalog.authentication_required"
    case .httpStatus: "plugin.catalog.http_error"
    case .rateLimited: "plugin.catalog.rate_limited"
    case .timedOut: "plugin.catalog.timed_out"
    case .networkUnavailable: "plugin.catalog.network_unavailable"
    }
  }

  package var errorDescription: String? {
    switch self {
    case .invalidQuery:
      "Invalid plugin request. Check repository identity, tag, query length and page bounds."
    case .busy: "The plugin catalog is busy. Try again shortly."
    case .invalidResponse: "The plugin publisher returned an invalid catalog response."
    case .invalidManifest: "The repository's plugin declaration is invalid."
    case .invalidProvenance:
      "The plugin publisher, repository, release or catalog revision does not match the verified source."
    case .responseTooLarge: "The plugin catalog response exceeded its size limit."
    case .unsafeRequest: "The plugin request was refused because its destination is not allowed."
    case .authenticationRequired:
      "The plugin publisher requested authentication. Public plugin requests do not use host credentials."
    case .httpStatus(let status): "Plugin request failed with HTTP \(status)."
    case .rateLimited: "The plugin publisher has limited requests. Wait before trying again."
    case .timedOut: "The plugin request timed out. Check the connection and try again."
    case .networkUnavailable:
      "The plugin publisher is unavailable. Check the connection and try again."
    }
  }
}

package protocol PluginCatalogBrowsing: Sendable {
  func search(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async throws
    -> PluginCatalogSearchResult
  func artifacts(repository: String, repositoryID: Int64, tag: String?, page: Int) async throws
    -> GitHubPluginReleaseArtifacts
}
