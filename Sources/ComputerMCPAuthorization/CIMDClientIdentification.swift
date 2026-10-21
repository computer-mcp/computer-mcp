import Foundation
import NIOCore

/// Fetchers enforce the transport boundary: HTTPS, no redirects, public destination
/// addresses, no ambient credentials, and the supplied byte and elapsed-time bounds.
package protocol CIMDFetching: Sendable {
  func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data
}

package protocol OAuthClientIdentifying: Sendable {
  func identify(clientID: String, redirectURI: String, allowlist: [String]) async throws
}

package struct CIMDClientIdentifier: OAuthClientIdentifying {
  private let fetcher: any CIMDFetching

  package init(fetcher: any CIMDFetching = URLSessionCIMDFetcher()) { self.fetcher = fetcher }

  package func identify(clientID: String, redirectURI: String, allowlist: [String]) async throws {
    guard clientID.utf8.count <= 2_048,
      let components = URLComponents(string: clientID), components.scheme == "https",
      components.user == nil, components.password == nil, components.fragment == nil,
      let host = components.host, !host.isEmpty,
      allowlist.contains(where: { $0.lowercased() == host.lowercased() }),
      !host.lowercased().hasSuffix(".localhost"), host.lowercased() != "localhost",
      let url = components.url
    else { throw OAuthError.invalidClient }
    if let address = try? SocketAddress(
      ipAddress: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: 443),
      !CIMDAddressPolicy.isPublic(address)
    {
      throw OAuthError.invalidClient
    }
    let data: Data
    do {
      data = try await fetcher.fetch(
        url, maxBytes: OAuthLimits.metadataMaxBytes,
        timeout: OAuthLimits.metadataTimeout)
    } catch is CancellationError { throw CancellationError() } catch {
      throw OAuthError.invalidClient
    }
    struct Metadata: Decodable {
      let clientID: String
      let redirectURIs: [String]
      enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case redirectURIs = "redirect_uris"
      }
    }
    guard data.count <= OAuthLimits.metadataMaxBytes,
      let document = try? JSONDecoder().decode(Metadata.self, from: data),
      document.clientID == clientID
    else { throw OAuthError.invalidClient }
    guard
      document.redirectURIs.contains(where: { Self.redirectMatches(redirectURI, registered: $0) })
    else { throw OAuthError.invalidRequest }
  }

  package static func redirectMatches(_ requested: String, registered: String) -> Bool {
    guard requested.utf8.count <= 2_048,
      var lhs = URLComponents(string: requested), var rhs = URLComponents(string: registered),
      let host = lhs.host, lhs.user == nil, lhs.password == nil, lhs.fragment == nil,
      lhs.scheme == "https" || (lhs.scheme == "http" && isLoopback(host))
    else { return false }
    if isLoopback(host), rhs.host == host {
      lhs.port = nil
      rhs.port = nil
      return lhs.string == rhs.string
    }
    return requested == registered
  }

  private static func isLoopback(_ host: String) -> Bool {
    ["127.0.0.1", "[::1]", "::1", "localhost"].contains(host.lowercased())
  }
}

package enum CIMDAddressPolicy {
  package static func isPublic(_ address: SocketAddress) -> Bool {
    guard let ip = address.ipAddress else { return false }
    if ip.contains(":") {
      // Global unicast only. Exclude transition mechanisms and special-use space,
      // which can route to private IPv4 destinations.
      let parts = ip.lowercased().split(separator: ":", omittingEmptySubsequences: false)
      guard let first = parts.first.flatMap({ UInt16($0, radix: 16) }),
        (0x2000...0x3fff).contains(first),
        first != 0x2002
      else { return false }
      if first == 0x2001 {
        let second = parts.count > 1 ? UInt16(parts[1], radix: 16) ?? 0 : 0
        return second > 0x01ff && second != 0x0db8
      }
      return true
    }
    let bytes = ip.split(separator: ".").compactMap { UInt8($0) }
    guard bytes.count == 4 else { return false }
    let a = bytes[0]
    let b = bytes[1]
    let c = bytes[2]
    if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
    if a == 100 && (64...127).contains(b) { return false }
    if a == 169 && b == 254 { return false }
    if a == 172 && (16...31).contains(b) { return false }
    if a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99)) { return false }
    if a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)) { return false }
    if a == 203 && b == 0 && c == 113 { return false }
    return true
  }
}
