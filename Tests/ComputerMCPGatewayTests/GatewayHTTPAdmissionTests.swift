import ComputerMCPAuthorization
import ComputerMCPConfiguration
import ComputerMCPCore
import Foundation
import MCP
import Testing

@testable import ComputerMCPGateway

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite(.timeLimit(.minutes(1)))
struct GatewayHTTPAdmissionTests {
  @Test func unauthorizedMCPRejectsAnIncompleteLargeBodyAtTheHead() async throws {
    let runtime = try makeRuntime()
    try await runtime.startListening()
    do {
      let client = try OAuthTestHTTPConnection(port: #require(await runtime.boundPort()))
      defer { client.close() }
      try client.send(
        "POST /mcp HTTP/1.1\r\nHost: gateway.example\r\nContent-Length: 9000000\r\n\r\nx")
      let response = try client.response()
      #expect(response.hasPrefix("HTTP/1.1 401"))
      #expect(response.contains("WWW-Authenticate: Bearer resource_metadata="))
      #expect(response.contains("Connection: close"))
      #expect(await runtime.activeSessionCount() == 0)
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func oauthBodyLimitRejectsBeforeCompletion(chunked: Bool) async throws {
    let runtime = try makeRuntime()
    try await runtime.startListening()
    do {
      let client = try OAuthTestHTTPConnection(port: #require(await runtime.boundPort()))
      defer { client.close() }
      let body = String(repeating: "x", count: GatewayHTTPLimits.v1.maxOAuthBodyBytes + 1)
      let framing =
        chunked
        ? "Transfer-Encoding: chunked\r\n\r\n4001\r\n" + body : "Content-Length: 16385\r\n\r\nx"
      try client.send("POST /oauth/token HTTP/1.1\r\nHost: gateway.example\r\n" + framing)
      let response = try client.response()
      #expect(response.hasPrefix("HTTP/1.1 413"))
      #expect(response.contains("request_body_too_large"))
      #expect(response.contains("Connection: close"))
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test(arguments: ["/oauth/token", "/mcp", ""])
  func incompleteRequestsHaveADeadline(path: String) async throws {
    let runtime = try makeRuntime(limits: .init(requestBodyTimeout: 0.1))
    try await runtime.startListening()
    do {
      let client = try OAuthTestHTTPConnection(port: #require(await runtime.boundPort()))
      defer { client.close() }
      if !path.isEmpty {
        try client.send(
          "POST \(path) HTTP/1.1\r\nHost: gateway.example\r\nAuthorization: Bearer fixture\r\nContent-Length: 100\r\n\r\nx"
        )
      }
      let response = try client.response()
      #expect(response.hasPrefix("HTTP/1.1 408"))
      #expect(response.contains("Connection: close"))
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test func unauthenticatedConnectionsAreCappedAndAuthenticationReleasesCapacity() async throws {
    let runtime = try makeRuntime(limits: .init(maxUnauthenticatedConnections: 1))
    try await runtime.startListening()
    do {
      let port = try #require(await runtime.boundPort())
      let first = try OAuthTestHTTPConnection(port: port)
      defer { first.close() }
      try first.send("GET /health HTTP/1.1\r\nHost: gateway.example\r\n\r\n")
      #expect(try first.response().hasPrefix("HTTP/1.1 200"))
      let excess = try OAuthTestHTTPConnection(port: port)
      defer { excess.close() }
      #expect(try excess.response().hasPrefix("HTTP/1.1 503"))
      // The authenticated head and its complete body arrive in one TCP write.
      try first.send(
        "POST /mcp HTTP/1.1\r\nHost: gateway.example\r\nAuthorization: Bearer fixture\r\nContent-Length: 2\r\n\r\n{}"
      )
      #expect(try first.response().hasPrefix("HTTP/1.1 400"))
      let next = try OAuthTestHTTPConnection(port: port)
      defer { next.close() }
      try next.send("GET /health HTTP/1.1\r\nHost: gateway.example\r\n\r\n")
      #expect(try next.response().hasPrefix("HTTP/1.1 200"))
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func admittedBodiesAndPipelinedHeadsKeepTheirReadBoundaries(chunked: Bool) async throws {
    let runtime = try makeRuntime()
    try await runtime.startListening()
    do {
      let client = try OAuthTestHTTPConnection(port: #require(await runtime.boundPort()))
      defer { client.close() }
      let body = String(repeating: " ", count: 1_024 * 1_024) + "{}"
      let framing =
        chunked
        ? "Transfer-Encoding: chunked\r\n\r\n\(String(body.utf8.count, radix: 16));fixture=1\r\n"
          + body + "\r\n0\r\n\r\n" : "Content-Length: \(body.utf8.count)\r\n\r\n" + body
      try client.send(
        "POST /mcp HTTP/1.1\r\nHost: gateway.example\r\nAuthorization: Bearer fixture\r\n" + framing
          + "POST /mcp HTTP/1.1\r\nHost: gateway.example\r\nContent-Length: 9000000\r\n\r\nx")
      let admitted = try client.response()
      #expect(admitted.hasPrefix("HTTP/1.1 400"))
      #expect(!admitted.contains("body_before_admission"))
      let rejected = try client.response()
      #expect(rejected.hasPrefix("HTTP/1.1 401"))
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test func oauthRateLimitIsAppliedBeforeReadingAnIncompleteBody() async throws {
    let server = try makeServer()
    for _ in 0..<Int(OAuthLimits.addressCapacity) {
      try await server.checkRate(address: "198.51.100.8")
    }
    let runtime = try makeRuntime(server: server)
    try await runtime.startListening()
    do {
      let client = try OAuthTestHTTPConnection(port: #require(await runtime.boundPort()))
      defer { client.close() }
      try client.send(
        "POST /oauth/token HTTP/1.1\r\nHost: gateway.example\r\nCF-Connecting-IP: 198.51.100.8\r\nContent-Length: 100\r\n\r\nx"
      )
      let response = try client.response()
      #expect(response.hasPrefix("HTTP/1.1 429"))
      #expect(response.contains("temporarily_unavailable"))
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func listenersWithoutEnabledOAuthKeepSynchronousAuthentication(adapterPresent: Bool) async throws
  {
    let server = try makeServer()
    for _ in 0..<Int(OAuthLimits.addressCapacity) {
      try await server.checkRate(address: "198.51.100.8")
    }
    let runtime = try makeRuntime(server: server, enabled: false, adapterPresent: adapterPresent)
    try await runtime.startListening()
    do {
      let port = try #require(await runtime.boundPort())
      let client = try OAuthTestHTTPConnection(port: port)
      defer { client.close() }
      try client.send(
        "POST /mcp HTTP/1.1\r\nHost: gateway.example\r\nCF-Connecting-IP: 198.51.100.8\r\nContent-Length: 9000000\r\n\r\nx"
      )
      let response = try client.response()
      #expect(response.hasPrefix("HTTP/1.1 401"))
      #expect(response.contains("WWW-Authenticate: Bearer\r\n"))
      #expect(!response.contains("resource_metadata"))
      let discovery = try OAuthTestHTTPConnection(port: port)
      defer { discovery.close() }
      try discovery.send(
        "GET /.well-known/oauth-authorization-server HTTP/1.1\r\nHost: gateway.example\r\n\r\n")
      #expect(try discovery.response().hasPrefix("HTTP/1.1 404"))
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  private func makeServer() throws -> OAuthAuthorizationServer {
    OAuthAuthorizationServer(
      configuration: .init(tunnelID: "tunnel", tunnelName: "named", hostname: "gateway.example"),
      store: try GatewayDatabase(inMemory: ()))
  }
  private func makeRuntime(
    server: OAuthAuthorizationServer? = nil, limits: GatewayHTTPLimits = .v1, enabled: Bool = true,
    adapterPresent: Bool = true
  ) throws -> GatewayHTTPRuntime {
    let server = try server ?? makeServer()
    return GatewayHTTPRuntime(
      configuration: .init(), registry: AdmissionRegistry(), host: "127.0.0.1", port: 0,
      publicBaseURL: "https://gateway.example", accessToken: "fixture", limits: limits,
      oauth: adapterPresent
        ? GatewayOAuthHTTP(
          server: server, currentConfiguration: { enabled ? server.configuration : nil }) : nil)
  }
}

private struct AdmissionRegistry: GatewayToolServing {
  func listTools(context: InvocationContext) throws -> [MCPTool] { [] }
  func callTool(name: String, arguments: JSONValue?, context: InvocationContext) throws -> JSONValue
  { .null }
}

/// Loopback-only wire fixture. A finite receive timeout makes missing head responses fail.
final class OAuthTestHTTPConnection {
  private var descriptor: Int32
  private var received = Data()
  init(port: Int) throws {
    #if canImport(Darwin)
      descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #else
      descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw SocketFailure.io }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    #if canImport(Darwin)
      var noSignal: Int32 = 1
      _ = setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    #endif
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      close()
      throw SocketFailure.io
    }
  }
  deinit { close() }
  func close() {
    if descriptor >= 0 {
      #if canImport(Darwin)
        _ = Darwin.close(descriptor)
      #else
        _ = Glibc.close(descriptor)
      #endif
      descriptor = -1
    }
  }
  func send(_ text: String) throws {
    let bytes = Array(text.utf8)
    try bytes.withUnsafeBytes { buffer in
      var sent = 0
      while sent < buffer.count {
        #if canImport(Darwin)
          let result = Darwin.send(descriptor, buffer.baseAddress! + sent, buffer.count - sent, 0)
        #else
          let result = Glibc.send(
            descriptor, buffer.baseAddress! + sent, buffer.count - sent, Int32(MSG_NOSIGNAL))
        #endif
        guard result > 0 else { throw SocketFailure.io }
        sent += result
      }
    }
  }
  func response() throws -> String {
    while true {
      let text = String(decoding: received, as: UTF8.self)
      if let boundary = text.range(of: "\r\n\r\n") {
        let head = String(text[..<boundary.lowerBound])
        let length =
          head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
          .flatMap {
            Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
          } ?? 0
        let total = text[..<boundary.upperBound].utf8.count + length
        if received.count >= total {
          let result = String(decoding: received.prefix(total), as: UTF8.self)
          received.removeFirst(total)
          return result
        }
      }
      guard try receiveMore() else { throw SocketFailure.io }
    }
  }
  func streamEnded() throws -> Bool {
    while true {
      let text = String(decoding: received, as: UTF8.self)
      if text.hasPrefix("0\r\n\r\n") || text.contains("\r\n0\r\n\r\n") { return true }
      if try !receiveMore() { return true }
    }
  }
  private func receiveMore() throws -> Bool {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = recv(descriptor, &buffer, buffer.count, 0)
    if count == 0 { return false }
    guard count > 0 else { throw SocketFailure.io }
    received.append(contentsOf: buffer.prefix(count))
    return true
  }
  private enum SocketFailure: Error { case io }
}
