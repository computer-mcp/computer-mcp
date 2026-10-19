import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPPlatform

struct ConfigurationValueTests {
  @Test func bearerTokensAreReadWithoutAuthenticationUI() async throws {
    let binding = MCPHTTPAuthentication(
      endpoint: "https://example.test/mcp", keychainAccount: "mcp.test")
    let store = StubSecretStore(value: "token-1")
    #expect(try await binding.bearerToken(from: store) == "token-1")
    #expect(store.reads == [.init(account: "mcp.test", authenticationUI: .fail)])

    #expect(await failure { try await binding.bearerToken(from: nil) } == .unavailable)
    #expect(
      await failure { try await binding.bearerToken(from: StubSecretStore(value: nil)) }
        == .missing)
    #expect(
      await failure { try await binding.bearerToken(from: StubSecretStore(value: "a b")) }
        == .invalidToken)
    #expect(
      await failure { try await binding.bearerToken(from: StubSecretStore(failure: true)) }
        == .unavailable)
  }

  @Test func treeSourceFieldsMustMatchTheirKind() throws {
    for valid in [
      #"{"kind":"file","path":"tree.json"}"#,
      #"{"kind":"introspection","args":["--export"]}"#,
      #"{"kind":"helper","helper":"/opt/tool/export"}"#,
    ] {
      #expect(throws: Never.self) {
        try JSONDecoder().decode(CLITreeSource.self, from: Data(valid.utf8))
      }
    }
    for invalid in [
      #"{"kind":"file"}"#,
      #"{"kind":"file","path":"tree.json","args":["x"]}"#,
      #"{"kind":"introspection"}"#,
      #"{"kind":"helper","helper":"relative/export"}"#,
    ] {
      #expect(throws: ConfigurationError.self) {
        try JSONDecoder().decode(CLITreeSource.self, from: Data(invalid.utf8))
      }
    }
  }

  @Test func executablesResolveFromPathBeforeCandidates() throws {
    let root = try ScopedTemporaryDirectory()
    let path = try executable("path/tool", in: root.url)
    let candidate = try executable("candidate/tool", in: root.url)
    let missing = root.url.appendingPathComponent("missing/tool")
    let pathDirectory = path.deletingLastPathComponent().path
    #expect(
      DefaultGatewayConfiguration.resolvedExecutable(
        named: "tool", environment: ["PATH": pathDirectory], candidates: [candidate])
        == path.standardizedFileURL.path)
    #expect(
      DefaultGatewayConfiguration.resolvedExecutable(
        named: "tool", environment: [:], candidates: [missing, candidate])
        == candidate.standardizedFileURL.path)
    #expect(
      DefaultGatewayConfiguration.resolvedExecutable(
        named: "tool", environment: [:], candidates: [missing]) == "tool")
  }

  @Test func httpProxiesMustBePlainProxyURLs() {
    #expect(openAITunnelHTTPProxyValidationFailure("http://proxy.test:8080") == nil)
    #expect(openAITunnelHTTPProxyValidationFailure("https://proxy.test/") == nil)
    for invalid in [
      "", " http://proxy.test", "socks5://proxy.test", "http://user:secret@proxy.test",
      "http://proxy.test/path", "http://proxy.test?query", "http://proxy.test#fragment",
    ] {
      #expect(openAITunnelHTTPProxyValidationFailure(invalid) != nil, "\(invalid)")
    }
    #expect(
      openAITunnelHTTPProxyValidationFailure("http://proxy.test:0")
        == "http_proxy port must be between 1 and 65535.")
  }

  private func executable(_ relativePath: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func failure(_ body: () async throws -> String) async -> AuthenticationFailure? {
    do {
      _ = try await body()
      return nil
    } catch let error as MCPHTTPAuthenticationError {
      return AuthenticationFailure(error)
    } catch {
      return .other
    }
  }
}

private enum AuthenticationFailure: Equatable {
  case invalidBinding, unavailable, missing, invalidToken, other

  init(_ error: MCPHTTPAuthenticationError) {
    switch error {
    case .invalidBinding: self = .invalidBinding
    case .unavailable: self = .unavailable
    case .missing: self = .missing
    case .invalidToken: self = .invalidToken
    }
  }
}

private final class StubSecretStore: SecretStore, @unchecked Sendable {
  struct Read: Equatable {
    let account: String
    let authenticationUI: KeychainAuthenticationUI
  }

  private let value: String?
  private let failure: Bool
  private let lock = NSLock()
  private var recorded: [Read] = []

  init(value: String? = nil, failure: Bool = false) {
    self.value = value
    self.failure = failure
  }

  var reads: [Read] { lock.withLock { recorded } }

  func setAsynchronously(_ secret: String, for reference: SecretReference) async throws {}

  func valueAsynchronously(
    for reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> String? {
    lock.withLock {
      recorded.append(.init(account: reference.account, authenticationUI: authenticationUI))
    }
    if failure { throw CancellationError() }
    return value
  }

  func containsAsynchronously(
    _ reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> Bool { value != nil }

  func deleteAsynchronously(_ reference: SecretReference) async throws {}
}
