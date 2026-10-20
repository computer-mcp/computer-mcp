#if !canImport(Darwin)
  import ComputerMCPTestSupport
  import Foundation
  import FoundationNetworking
  import Synchronization
  import Testing

  @testable import ComputerMCPPlugins

  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif

  struct PluginHTTPPlatformTests {
    @Test
    func catalogFetchesAndDownloadFailBeforeSendingRequests() async throws {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [PluginHTTPRequestSpy.self]
      let origin = URL(string: "https://example.invalid")!
      let attempts = PluginHTTPRequestSpy.requestCount
      await #expect(throws: PluginCatalogError.networkUnavailable) {
        try await StaticPluginCatalogHTTP(configuration: configuration, endpoint: origin)
          .fetch(validators: .init())
      }
      await #expect(throws: PluginCatalogError.networkUnavailable) {
        try await GitHubCatalogHTTPClient(configuration: configuration, origin: origin)
          .fetch(path: "/catalog", query: [:], accept: "application/json", maxBytes: 128)
      }

      let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let descriptor = open(output.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      try #require(descriptor >= 0)
      defer {
        close(descriptor)
        try? FileManager.default.removeItem(at: output)
      }
      await #expect(throws: PluginCatalogError.networkUnavailable) {
        try await GitHubPluginDownload(configuration: configuration, origin: origin)
          .download(pluginArtifactFixture(), to: descriptor)
      }
      #expect(try Data(contentsOf: output).isEmpty)
      #expect(PluginHTTPRequestSpy.requestCount == attempts)
    }
  }

  private final class PluginHTTPRequestSpy: URLProtocol, @unchecked Sendable {
    private static let attempts = Mutex(0)
    static var requestCount: Int { attempts.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool {
      attempts.withLock { $0 += 1 }
      return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
  }
#endif
