import ComputerMCPSandbox
import Foundation
import NIOCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

package enum EgressAccess: Sendable, Equatable {
  case none
  case trusted
  case full
  case custom(hosts: [String], includeTrusted: Bool)
}

package struct EgressDenial: Error, Sendable, Equatable {
  package enum Reason: String, Error, Sendable {
    case hostNotAllowed
    case loopback
    case localNetworkRequired
    case invalidDestination
    case routeUnavailable
    case routeChanged
    case revoked
    case connectionLimit
  }
  package let executionID: String
  package let host: String
  package let port: UInt16
  package let reason: Reason
}

package struct EgressPolicy: Sendable {
  package let access: EgressAccess
  package let localNetwork: Bool

  /// Exact hosts and explicit suffixes. Wildcards match subdomains, never the suffix's siblings.
  package static let trustedHosts = [
    "github.com", "api.github.com", "codeload.github.com", "*.githubusercontent.com", "ghcr.io",
    "registry.npmjs.org", "registry.yarnpkg.com", "pypi.org", "files.pythonhosted.org",
    "crates.io", "index.crates.io", "static.crates.io", "rubygems.org", "*.rubygems.org",
    "repo.maven.apache.org", "repo1.maven.org", "plugins.gradle.org", "services.gradle.org",
    "downloads.gradle.org", "proxy.golang.org", "sum.golang.org", "dl.google.com",
    "api.nuget.org", "*.nuget.org", "repo.packagist.org", "packagist.org",
    "swift.org", "download.swift.org", "download.developer.apple.com", "developer.apple.com",
    "swcdn.apple.com", "swdownload.apple.com",
  ]

  package init(access: EgressAccess = .none, localNetwork: Bool = false) throws {
    if case .custom(let hosts, _) = access {
      for host in hosts {
        let value = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        guard try Self.normalizeHost(value) == value else {
          throw ExecutionEnvironmentError.invalidConfiguration(
            "Custom hosts must be canonical lowercase hostnames or addresses")
        }
      }
    }
    self.access = access
    self.localNetwork = localNetwork
  }

  package func admits(host: String) -> Bool {
    switch access {
    case .none: return false
    case .full: return true
    case .trusted: return Self.matches(host, patterns: Self.trustedHosts)
    case .custom(let hosts, let includeTrusted):
      return Self.matches(host, patterns: hosts + (includeTrusted ? Self.trustedHosts : []))
    }
  }

  package func rejection(address: SocketAddress, routing: any EgressRouting) -> EgressDenial.Reason?
  {
    switch checkedRoute(address: address, routing: routing) {
    case .success: return nil
    case .failure(let reason): return reason
    }
  }

  func checkedRoute(address: SocketAddress, routing: any EgressRouting) -> Result<
    EgressRoute, EgressDenial.Reason
  > {
    guard let ip = address.ipAddress, let bytes = Self.addressBytes(ip) else {
      return .failure(.invalidDestination)
    }
    let v4 =
      bytes.count == 4
      ? bytes
      : (bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255]
        ? Array(bytes.suffix(4)) : nil)
    if let v4 {
      if v4[0] == 127 { return .failure(.loopback) }
      if v4 == [0, 0, 0, 0] || v4 == [255, 255, 255, 255] { return .failure(.invalidDestination) }
    } else {
      if bytes == Array(repeating: 0, count: 15) + [1] { return .failure(.loopback) }
      if bytes.allSatisfy({ $0 == 0 }) { return .failure(.invalidDestination) }
    }
    let route: EgressRoute
    do {
      route = try routing.route(to: v4.map { $0.map(String.init).joined(separator: ".") } ?? ip)
    } catch { return .failure(.routeUnavailable) }
    guard route.interfaceIndex != 0 else { return .failure(.routeUnavailable) }
    if route.isTunnel { return .success(route) }
    let linkLocal: Bool
    let multicast: Bool
    if let v4 {
      linkLocal = v4[0] == 169 && v4[1] == 254
      multicast = (224...239).contains(v4[0])
    } else {
      linkLocal = bytes[0] == 254 && bytes[1] & 0xc0 == 0x80
      multicast = bytes[0] == 255
    }
    return !localNetwork && (route.isDirect || linkLocal || multicast)
      ? .failure(.localNetworkRequired) : .success(route)
  }

  package static func normalizeHost(_ raw: String) throws -> String {
    var host = raw.lowercased()
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    guard !host.contains("%") else {
      throw ExecutionEnvironmentError.invalidConfiguration("Scoped addresses are not accepted")
    }
    if let bytes = addressBytes(host) {
      var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      let result = bytes.withUnsafeBytes {
        inet_ntop(
          bytes.count == 4 ? AF_INET : AF_INET6, $0.baseAddress!, &buffer, socklen_t(buffer.count))
      }
      guard result != nil else {
        throw ExecutionEnvironmentError.invalidConfiguration("Invalid numeric host")
      }
      let canonical = String(cString: buffer)
      guard bytes.count != 4 || canonical == host else {
        throw ExecutionEnvironmentError.invalidConfiguration("Noncanonical IPv4 address")
      }
      return canonical
    }
    if host.hasSuffix(".") { host.removeLast() }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard !host.isEmpty, host.utf8.count <= 253, !host.contains(":"), !host.contains("%"),
      !host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
      labels.allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
          && label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
          )
      })
    else { throw ExecutionEnvironmentError.invalidConfiguration("Invalid destination hostname") }
    // getaddrinfo accepts legacy IPv4 spellings. Never send these through its hostname parser.
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST
    var result: UnsafeMutablePointer<addrinfo>?
    if getaddrinfo(host, nil, &hints, &result) == 0 {
      if let result { freeaddrinfo(result) }
      throw ExecutionEnvironmentError.invalidConfiguration("Noncanonical numeric address")
    }
    return host
  }

  private static func matches(_ host: String, patterns: [String]) -> Bool {
    patterns.contains { pattern in
      pattern.hasPrefix("*.")
        ? host.hasSuffix(String(pattern.dropFirst())) && host != String(pattern.dropFirst(2))
        : host == pattern
    }
  }

  private static func addressBytes(_ text: String) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: 16)
    if inet_pton(AF_INET, text, &bytes) == 1 { return Array(bytes.prefix(4)) }
    if inet_pton(AF_INET6, text, &bytes) == 1 { return bytes }
    return nil
  }
}
