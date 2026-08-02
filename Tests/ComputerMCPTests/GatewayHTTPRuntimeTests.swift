import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
struct GatewayHTTPRuntimeTests {
  @Test
  func testV1SecurityLimitsAreFixed() {
    #expect(GatewayHTTPLimits.v1.maxHeaderBytes == 16 * 1_024)
    #expect(GatewayHTTPLimits.v1.maxBodyBytes == 8 * 1_024 * 1_024)
    #expect(GatewayHTTPLimits.v1.maxSessions == 128)
    #expect(GatewayHTTPLimits.v1.sessionIdleTimeout == 15 * 60)
    #expect(GatewayHTTPLimits.v1.cleanupInterval == 60)
  }

  @Test
  func testEffectiveListeningPortIsAcceptedByHostValidation() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    #expect(configuration.server.http.port != port)

    let registry = try GatewayRuntime(configuration: configuration)
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: registry,
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil
    )
    try await runtime.startListening()

    do {
      let session = try await GatewayClientSession.connectHTTP(
        endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
      )
      let tools = try await session.listToolNames()
      #expect(tools.contains("workspace.list"))
      await session.disconnect()
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test
  func testStoppedRuntimeReleasesTheListenerAndCanRestart() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let registry = try GatewayRuntime(configuration: configuration)
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: registry,
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil
    )

    try await runtime.startListening()
    await runtime.stop()
    try await runtime.startListening()
    await runtime.stop()
  }

  @Test
  func testUnauthorizedSlowBodyIsRejectedBeforeBodyAccumulation() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(configuration: configuration),
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil,
      accessToken: "expected-token"
    )
    try await runtime.startListening()
    do {
      let response = try rawHTTPResponse(
        port: port,
        request:
          "POST /mcp HTTP/1.1\r\n"
          + "Host: 127.0.0.1:\(port)\r\n"
          + "Content-Type: application/json\r\n"
          + "Content-Length: 1024\r\n"
          + "Connection: close\r\n"
          + "\r\n"
      )

      #expect(response.hasPrefix("HTTP/1.1 401"))
      #expect(response.contains("unauthorized"))
      #expect((await runtime.activeSessionCount()) == 0)
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test
  func testAuthenticatedOversizedBodyReturns413BeforeReadingBody() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(configuration: configuration),
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil,
      accessToken: "expected-token",
      limits: GatewayHTTPLimits(maxBodyBytes: 32)
    )
    try await runtime.startListening()
    do {
      let response = try rawHTTPResponse(
        port: port,
        request:
          "POST /mcp HTTP/1.1\r\n"
          + "Host: 127.0.0.1:\(port)\r\n"
          + "Authorization: Bearer expected-token\r\n"
          + "Content-Type: application/json\r\n"
          + "Content-Length: 33\r\n"
          + "Connection: close\r\n"
          + "\r\n"
      )

      #expect(response.hasPrefix("HTTP/1.1 413"))
      #expect(response.contains("request_body_too_large"))
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test
  func testDuplicateAuthorizationHeadersAreRejectedBeforeBodyAccumulation() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(configuration: configuration),
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil,
      accessToken: "expected-token"
    )
    try await runtime.startListening()
    do {
      let response = try rawHTTPResponse(
        port: port,
        request:
          "POST /mcp HTTP/1.1\r\n"
          + "Host: 127.0.0.1:\(port)\r\n"
          + "Authorization: Bearer expected-token\r\n"
          + "Authorization: Bearer wrong-token\r\n"
          + "Content-Type: application/json\r\n"
          + "Content-Length: 1024\r\n"
          + "Connection: close\r\n"
          + "\r\n"
      )

      #expect(response.hasPrefix("HTTP/1.1 400"))
      #expect(response.contains("ambiguous_authorization"))
      #expect((await runtime.activeSessionCount()) == 0)
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test
  func testChunkedBodyCannotBypassTheConfiguredAccumulatorLimit() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(configuration: configuration),
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil,
      accessToken: "expected-token",
      limits: GatewayHTTPLimits(maxBodyBytes: 32)
    )
    try await runtime.startListening()
    do {
      let body = String(repeating: "x", count: 33)
      let response = try rawHTTPResponse(
        port: port,
        request:
          "POST /mcp HTTP/1.1\r\n"
          + "Host: 127.0.0.1:\(port)\r\n"
          + "Authorization: Bearer expected-token\r\n"
          + "Content-Type: application/json\r\n"
          + "Transfer-Encoding: chunked\r\n"
          + "Connection: close\r\n"
          + "\r\n"
          + "21\r\n\(body)\r\n0\r\n\r\n"
      )

      #expect(response.hasPrefix("HTTP/1.1 413"))
      #expect(response.contains("request_body_too_large"))
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test
  func testSessionCapacityReturns429WithoutStartingAnotherServer() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(configuration: configuration),
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil,
      limits: GatewayHTTPLimits(maxSessions: 1)
    )
    try await runtime.startListening()
    let session = try await GatewayClientSession.connectHTTP(
      endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
      streaming: false
    )
    do {
      #expect((await runtime.activeSessionCount()) == 1)

      let body = #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#
      let response = try rawHTTPResponse(
        port: port,
        request:
          "POST /mcp HTTP/1.1\r\n"
          + "Host: 127.0.0.1:\(port)\r\n"
          + "Accept: application/json, text/event-stream\r\n"
          + "Content-Type: application/json\r\n"
          + "Content-Length: \(body.utf8.count)\r\n"
          + "Connection: close\r\n"
          + "\r\n"
          + body
      )

      #expect(response.hasPrefix("HTTP/1.1 429"))
      #expect(response.contains("session_capacity_exceeded"))
      #expect((await runtime.activeSessionCount()) == 1)
      await session.disconnect()
      await runtime.stop()
    } catch {
      await session.disconnect()
      await runtime.stop()
      throw error
    }
  }

  @Test
  func testIdleSessionExpiresAndStopsItsServer() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(configuration: configuration),
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil,
      limits: GatewayHTTPLimits(
        sessionIdleTimeout: 0.05,
        cleanupInterval: 0.01
      )
    )
    try await runtime.startListening()
    let session = try await GatewayClientSession.connectHTTP(
      endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
      streaming: false
    )
    #expect((await runtime.activeSessionCount()) == 1)

    for _ in 0..<50 where await runtime.activeSessionCount() != 0 {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect((await runtime.activeSessionCount()) == 0)
    await session.disconnect()
    await runtime.stop()
  }

  @Test
  func testStreamingDisconnectCleansTheAssociatedSession() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(configuration: configuration),
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil
    )
    try await runtime.startListening()
    let session = try await GatewayClientSession.connectHTTP(
      endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
    )
    #expect((await runtime.activeSessionCount()) == 1)

    await session.disconnect()
    for _ in 0..<50 where await runtime.activeSessionCount() != 0 {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect((await runtime.activeSessionCount()) == 0)
    await runtime.stop()
  }

  @Test
  func testStopCleansSessionsExactlyOnceAndIsIdempotent() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(configuration: configuration),
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil
    )
    try await runtime.startListening()
    let session = try await GatewayClientSession.connectHTTP(
      endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
      streaming: false
    )
    #expect((await runtime.activeSessionCount()) == 1)

    await runtime.stop()
    await runtime.stop()

    #expect((await runtime.activeSessionCount()) == 0)
    await session.disconnect()
  }
}

private func availableHTTPRuntimeLoopbackPort() throws -> Int {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw POSIXError(.EIO) }
  defer { close(descriptor) }

  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bindResult == 0 else { throw POSIXError(.EADDRINUSE) }

  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      getsockname(descriptor, $0, &length)
    }
  }
  guard nameResult == 0 else { throw POSIXError(.EIO) }
  return Int(UInt16(bigEndian: address.sin_port))
}

private func rawHTTPResponse(port: Int, request: String) throws -> String {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw POSIXError(.EIO) }
  defer { close(descriptor) }

  var timeout = timeval(tv_sec: 2, tv_usec: 0)
  guard
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    ) == 0
  else {
    throw POSIXError(.EIO)
  }

  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = UInt16(port).bigEndian
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let connectResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard connectResult == 0 else { throw POSIXError(.ECONNREFUSED) }

  let bytes = Array(request.utf8)
  var written = 0
  while written < bytes.count {
    let count = bytes.withUnsafeBytes { buffer in
      Darwin.send(
        descriptor,
        buffer.baseAddress!.advanced(by: written),
        bytes.count - written,
        0
      )
    }
    guard count > 0 else { throw POSIXError(.EIO) }
    written += count
  }

  var response = [UInt8](repeating: 0, count: 8_192)
  let count = Darwin.recv(descriptor, &response, response.count, 0)
  guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
  return String(decoding: response.prefix(count), as: UTF8.self)
}
