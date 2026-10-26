import ComputerMCPSandbox
import Foundation
import NIOCore
import Testing

@testable import ComputerMCPEgress

@Suite struct EgressPolicyTests {
  @Test(arguments: EgressPolicy.trustedHosts)
  func trustedCatalog(pattern: String) throws {
    let host = pattern.hasPrefix("*.") ? "download." + pattern.dropFirst(2) : pattern
    #expect(try EgressPolicy(access: .trusted).admits(host: host))
    #expect(try !EgressPolicy(access: .trusted).admits(host: host + ".attacker.test"))
    #expect(try !EgressPolicy(access: .none).admits(host: host))
  }

  @Test func accessLevels() throws {
    #expect(try EgressPolicy(access: .full).admits(host: "example.com"))
    #expect(try !EgressPolicy(access: .trusted).admits(host: "example.com"))
    #expect(
      try EgressPolicy(access: .custom(hosts: ["*.example.com"], includeTrusted: false)).admits(
        host: "one.example.com"))
    #expect(
      try !EgressPolicy(access: .custom(hosts: ["*.example.com"], includeTrusted: false)).admits(
        host: "example.com"))
    #expect(
      try !EgressPolicy(access: .custom(hosts: ["example.com"], includeTrusted: false)).admits(
        host: "github.com"))
    #expect(
      try EgressPolicy(access: .custom(hosts: [], includeTrusted: true)).admits(host: "github.com"))
  }

  @Test(arguments: [
    "127.1", "2130706433", "0x7f000001", "0177.0.0.1", "a..b", "host\r\nX: y", "host/path", "a@b",
    "[::1]:80", "fe80::1%en0",
  ])
  func ambiguousHostsAreRefused(host: String) {
    #expect(throws: (any Error).self) { try EgressPolicy.normalizeHost(host) }
  }

  @Test func normalization() throws {
    #expect(try EgressPolicy.normalizeHost("GITHUB.COM.") == "github.com")
    #expect(try EgressPolicy.normalizeHost("[2001:0db8::1]") == "2001:db8::1")
  }

  @Test(arguments: ["127.0.0.1", "127.4.3.2", "::1", "::ffff:127.0.0.1"])
  func loopbackAlwaysDenied(address: String) throws {
    let destination = try SocketAddress(ipAddress: address, port: 80)
    for granted in [false, true] {
      #expect(
        try EgressPolicy(access: .full, localNetwork: granted).rejection(
          address: destination,
          routing: FixedRoute(tunnel: true, direct: false)) == .loopback)
    }
  }

  @Test(arguments: ["169.254.169.254", "224.0.0.1", "fe80::1", "ff02::1"])
  func localAddressClasses(address: String) throws {
    let destination = try SocketAddress(ipAddress: address, port: 80)
    #expect(
      try EgressPolicy(access: .full).rejection(
        address: destination,
        routing: FixedRoute(tunnel: false, direct: false)) == .localNetworkRequired)
    #expect(
      try EgressPolicy(access: .full, localNetwork: true).rejection(
        address: destination,
        routing: FixedRoute(tunnel: false, direct: false)) == nil)
  }

  @Test(arguments: ["192.168.1.2", "10.0.0.5", "198.18.0.1", "203.0.113.8", "fd12::1"])
  func routingDecidesLocality(address: String) throws {
    let destination = try SocketAddress(ipAddress: address, port: 80)
    let policy = try EgressPolicy(access: .full)
    #expect(
      policy.rejection(address: destination, routing: FixedRoute(tunnel: false, direct: true))
        == .localNetworkRequired)
    #expect(
      policy.rejection(address: destination, routing: FixedRoute(tunnel: true, direct: true)) == nil
    )
    #expect(
      policy.rejection(address: destination, routing: FixedRoute(tunnel: false, direct: false))
        == nil)
  }

  @Test func handshakes() throws {
    var handshake = EgressHandshake()
    var buffer = ByteBuffer(
      string: "CONNECT GITHUB.COM:443 HTTP/1.1\r\nX-Execution-ID: forged\r\n\r\nearly")
    guard case .connect(let target) = try handshake.consume(&buffer) else {
      Issue.record("Expected CONNECT")
      return
    }
    #expect(target == EgressTarget(host: "github.com", port: 443))
    #expect(buffer.readString(length: buffer.readableBytes) == "early")
    #expect(
      String(decoding: handshake.response(host: target.host, success: false), as: UTF8.self)
        .contains("X-Blocked-Host: github.com"))
    var socks = EgressHandshake()
    var greeting = ByteBuffer(bytes: [5, 1, 0])
    guard case .reply(let reply) = try socks.consume(&greeting) else {
      Issue.record("Expected greeting")
      return
    }
    #expect(reply == [5, 0])
    var request = ByteBuffer(bytes: [5, 1, 0, 3, 10] + Array("github.com".utf8) + [1, 187])
    guard case .connect(let socksTarget) = try socks.consume(&request) else {
      Issue.record("Expected SOCKS CONNECT")
      return
    }
    #expect(socksTarget == target)
    let rejection = socks.response(host: target.host, success: false)
    #expect(rejection[1] == 2)
    #expect(String(decoding: rejection.dropFirst(5).dropLast(2), as: UTF8.self) == "github.com")
  }
}

struct FixedRoute: EgressRouting {
  let tunnel: Bool
  let direct: Bool
  func observeChanges(_ handler: @escaping @Sendable (EgressRouteEvent) -> Void) throws
    -> any EgressRouteObservation
  { StaticRouteObservation() }
  func route(to numericAddress: String) throws -> EgressRoute {
    EgressRoute(
      interface: tunnel ? "utun0" : "en0", interfaceIndex: 1, isTunnel: tunnel, isDirect: direct)
  }
}

struct StaticRouteObservation: EgressRouteObservation { func cancel() {} }
