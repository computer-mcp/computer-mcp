import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPPlugins

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct GitHubCatalogHTTPClientTests {
  @Test
  func rejectsAuthenticationChallengesWithoutSendingCredentials() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    await #expect(throws: PluginCatalogError.httpStatus(401)) {
      let response = try await client.fetch(
        path: "/auth", query: [:], accept: "application/json", maxBytes: 128)
      try response.requireSuccess()
    }
    let stats = try await client.fetch(
      path: "/stats", query: [:], accept: "application/json", maxBytes: 4096)
    #expect(try stats.decode(JSONValue.self).objectValue?["paths"] == .array([.string("/auth")]))
  }

  @Test
  func isolatesHeadersCookiesAndQueryEncoding() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpAdditionalHeaders = [
      "Authorization": "Bearer fixture-secret", "Cookie": "session=fixture-cookie",
    ]
    let client = GitHubCatalogHTTPClient(configuration: configuration, origin: fixture.origin)
    let query = ["ref": "feature/工具?x=a&b=#%", "empty": ""]
    for _ in 0..<2 {
      let response = try await client.fetch(
        path: "/echo", query: query,
        accept: "application/vnd.github+json", maxBytes: 4096)
      try response.requireSuccess()
      let value = try response.decode(JSONValue.self)
      let headers = value.objectValue?["headers"]?.objectValue
      #expect(headers?["authorization"] == nil)
      #expect(headers?["cookie"] == nil)
      #expect(headers?["x-github-api-version"] == .string("2026-03-10"))
      #expect(headers?["accept"] == .string("application/vnd.github+json"))
      #expect(
        value.objectValue?["query"]
          == .object([
            "ref": .array([.string(query["ref"]!)]), "empty": .array([.string("")]),
          ]))
    }
  }

  @Test
  func refusesRedirectsWithoutRequestingTheirTarget() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    let response = try await client.fetch(
      path: "/redirect", query: [:], accept: "application/json", maxBytes: 128)
    #expect(throws: PluginCatalogError.httpStatus(302)) { try response.requireSuccess() }
    let stats = try await client.fetch(
      path: "/stats", query: [:], accept: "application/json", maxBytes: 4096)
    #expect(
      try stats.decode(JSONValue.self).objectValue?["paths"] == .array([.string("/redirect")]))
  }

  @Test(arguments: ["/large-length", "/large-stream", "/large-gzip"])
  func boundsDeclaredStreamedAndDecompressedBodies(_ path: String) async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    await #expect(throws: PluginCatalogError.responseTooLarge) {
      _ = try await client.fetch(path: path, query: [:], accept: "application/json", maxBytes: 128)
    }
  }

  @Test
  func largeRateLimitBodyDoesNotHideStatus() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    let response = try await client.fetch(
      path: "/rate-limit", query: [:], accept: "application/json", maxBytes: 128)
    #expect(response.body.isEmpty)
    #expect(throws: PluginCatalogError.rateLimited(retryAfterSeconds: 42)) {
      try response.requireSuccess()
    }
  }

  @Test
  func cancellingAnActiveBodyReadStopsPromptly() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    let task = Task {
      try await client.fetch(path: "/slow", query: [:], accept: "application/json", maxBytes: 4096)
    }
    // The fixture blocks until /slow has actually received the request.
    _ = try await client.fetch(
      path: "/wait-slow", query: [:], accept: "application/json", maxBytes: 128)
    let start = ContinuousClock.now
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled body read returned success")
    } catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    #expect(ContinuousClock.now - start < .seconds(2))
    let healthy = try await client.fetch(
      path: "/echo", query: [:], accept: "application/json", maxBytes: 4096)
    try healthy.requireSuccess()
  }

  @Test(arguments: ["//evil.example/escape", "/../escape", "/a/../escape", "/bad\0path"])
  func rejectsUnsafeRequestPaths(_ path: String) async {
    let client = GitHubCatalogHTTPClient()
    await #expect(throws: PluginCatalogError.unsafeRequest) {
      _ = try await client.fetch(path: path, query: [:], accept: "application/json", maxBytes: 128)
    }
  }
}
