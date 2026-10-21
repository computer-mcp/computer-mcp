import Foundation
import NIOCore
import Testing

@testable import ComputerMCPAuthorization

struct CIMDClientIdentificationTests {
  private let clientID = "https://client.example/metadata.json"
  private let redirect = "https://consumer.example/callback"

  @Test(arguments: [
    "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1",
    "192.168.1.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1",
    "255.255.255.255", "::", "::1", "::ffff:127.0.0.1", "fc00::1", "fe80::1", "ff02::1",
    "2001:db8::1", "2002:7f00:1::1",
  ])
  func privateAndSpecialDestinationsCannotBeConnected(address: String) throws {
    #expect(!CIMDAddressPolicy.isPublic(try SocketAddress(ipAddress: address, port: 443)))
  }

  @Test(arguments: ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"])
  func publicDestinationsAreAccepted(address: String) throws {
    #expect(CIMDAddressPolicy.isPublic(try SocketAddress(ipAddress: address, port: 443)))
  }

  @Test func metadataBindsExactClientAndCallback() async throws {
    let identifier = CIMDClientIdentifier(
      fetcher: Document(clientID: clientID, redirects: [redirect]))
    try await identifier.identify(
      clientID: clientID, redirectURI: redirect, allowlist: ["client.example"])
    await #expect(throws: OAuthError.invalidClient) {
      try await identifier.identify(
        clientID: "https://client.example/other", redirectURI: redirect,
        allowlist: ["client.example"])
    }
    await #expect(throws: OAuthError.invalidRequest) {
      try await identifier.identify(
        clientID: clientID, redirectURI: redirect + "/", allowlist: ["client.example"])
    }
  }

  @Test(arguments: [
    "https://outside.example/metadata", "http://client.example/metadata",
    "https://user@client.example/metadata", "https://client.example/metadata#fragment",
    "https://127.0.0.1/metadata", "https://[::1]/metadata", "https://10.2.3.4/metadata",
    "https://localhost/metadata",
  ])
  func unsafeClientsNeverReachTheFetcher(clientID: String) async {
    let identifier = CIMDClientIdentifier(fetcher: UnreachableFetcher())
    await #expect(throws: OAuthError.invalidClient) {
      try await identifier.identify(
        clientID: clientID, redirectURI: redirect,
        allowlist: ["client.example", "127.0.0.1", "[::1]", "10.2.3.4", "localhost"])
    }
  }

  @Test(arguments: ["127.0.0.1", "[::1]", "localhost"])
  func loopbackRedirectIgnoresOnlyThePort(host: String) async throws {
    let registered = "http://\(host):1234/callback?x=1"
    let identifier = CIMDClientIdentifier(
      fetcher: Document(clientID: clientID, redirects: [registered]))
    try await identifier.identify(
      clientID: clientID, redirectURI: "http://\(host):54321/callback?x=1",
      allowlist: ["client.example"])
    #expect(
      !CIMDClientIdentifier.redirectMatches(
        "http://\(host):54321/other?x=1", registered: registered))
    #expect(
      !CIMDClientIdentifier.redirectMatches(
        "http://\(host):54321/callback?x=2", registered: registered))
    #expect(
      !CIMDClientIdentifier.redirectMatches(
        "https://\(host):54321/callback?x=1", registered: registered))
    #expect(
      !CIMDClientIdentifier.redirectMatches(
        "https://consumer.example:444/callback", registered: "https://consumer.example:443/callback"
      ))
  }

  @Test func metadataByteBoundIsEnforcedEvenForInjectedFetchers() async {
    let identifier = CIMDClientIdentifier(fetcher: OversizedDocument())
    await #expect(throws: OAuthError.invalidClient) {
      try await identifier.identify(
        clientID: clientID, redirectURI: redirect, allowlist: ["client.example"])
    }
  }
}

private struct Document: CIMDFetching {
  let clientID: String
  let redirects: [String]
  func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
    #expect(maxBytes == OAuthLimits.metadataMaxBytes)
    #expect(timeout == OAuthLimits.metadataTimeout)
    return try JSONSerialization.data(withJSONObject: [
      "client_id": clientID, "redirect_uris": redirects,
    ])
  }
}

private struct UnreachableFetcher: CIMDFetching {
  func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
    Issue.record("Unsafe client URL reached the network adapter")
    throw OAuthError.invalidClient
  }
}

private struct OversizedDocument: CIMDFetching {
  func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
    Data(repeating: 32, count: maxBytes + 1)
  }
}
