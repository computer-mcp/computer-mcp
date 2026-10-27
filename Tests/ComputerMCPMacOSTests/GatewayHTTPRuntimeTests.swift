import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.serialized)
struct GatewayHTTPRuntimeTests {
  @Test
  func sameCredentialSessionsObserveIndependentCurrentConsent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let value = root.appendingPathComponent("value.txt")
    try Data("original".utf8).write(to: value)
    let database = try GatewayDatabase(inMemory: ())
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate, permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
      fullAccess: true,
      allowedCallers: [.secureTunnel])
    try database.saveProfile(profile.grant)
    let fixture = try fixtureNonGitProject(root: root)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate), profiles: [profile],
      cli: .init(commands: [fixture.git]),
      builtin: .init(enabled: ["file.read", "file.write"]))
    let gateway = try GatewayRuntime(
      configuration: configuration, database: database,
      registeredProjects: [project], platform: fixture.platform)
    let runtime = GatewayHTTPRuntime(
      configuration: configuration, registry: gateway, host: "127.0.0.1", port: 0,
      publicBaseURL: nil, accessToken: "shared-fixture-credential")
    try await runtime.startListening()
    do {
      let port = try #require(await runtime.boundPort())
      let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
      let first = try await GatewayClientSession.connectHTTP(
        endpoint: endpoint, accessToken: "shared-fixture-credential")
      let firstScope = try #require(await runtime.controlSessions().first)
      let second = try await GatewayClientSession.connectHTTP(
        endpoint: endpoint, accessToken: "shared-fixture-credential")
      let secondScope = try #require(
        await runtime.controlSessions().first { $0.id != firstScope.id })
      #expect(firstScope.principalID == secondScope.principalID)
      _ = try await runtime.approveControlSession(
        id: firstScope.id, lifetime: .thisSession, expectedRevision: firstScope.revision,
        expectedTrustRevision: 0)
      _ = try await runtime.approveControlSession(
        id: secondScope.id, lifetime: .thisSession, expectedRevision: secondScope.revision,
        expectedTrustRevision: 0)
      let firstApproved = try #require(
        await runtime.controlSessions().first { $0.id == firstScope.id })
      let restricted = try await runtime.limitControlSession(
        id: firstScope.id,
        to: .init(permissionCeilings: fixturePermissions([.project("fixture"): .granted(.read)])),
        expectedRevision: firstApproved.revision)
      #expect(restricted.revision == firstApproved.revision + 1)
      await #expect(throws: (any Error).self) {
        try await runtime.limitControlSession(
          id: firstScope.id, to: .init(), expectedRevision: firstScope.revision)
      }
      #expect(try await first.listToolNames().contains("file.read"))
      #expect(try await first.listToolNames().contains("file.write"))
      #expect(try await second.listToolNames().contains("file.write"))
      let write: JSONValue = .object([
        "project_id": .string("fixture"), "path": .string("value.txt"),
        "content": .string("authorized"),
      ])
      let denied = try await first.call(toolName: "file.write", arguments: write)
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(try String(contentsOf: value, encoding: .utf8) == "original")
      let allowed = try await second.call(toolName: "file.write", arguments: write)
      #expect(allowed.result.objectValue?["isError"] == .bool(false))
      #expect(try String(contentsOf: value, encoding: .utf8) == "authorized")
      try await runtime.endControlSession(id: firstScope.id, expectedRevision: restricted.revision)
      #expect(try await first.listToolNames().isEmpty)
      let read: JSONValue = .object([
        "project_id": .string("fixture"), "path": .string("value.txt"),
      ])
      #expect(
        try await first.call(toolName: "file.read", arguments: read).result.objectValue?["isError"]
          == .bool(true))
      #expect(
        try await second.call(toolName: "file.read", arguments: read).result.objectValue?["isError"]
          == .bool(false))
      #expect(try database.profiles().first { $0.id == .chatGPTOperate }?.fullAccess == true)
      await first.disconnect()
      #expect(await runtime.controlSessions().map(\.id) == [secondScope.id])
      await second.disconnect()
      #expect(await runtime.controlSessions().isEmpty)
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

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

    let registry = try GatewayRuntime(
      configuration: configuration,
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()))
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
      #expect(tools.contains("project.list"))
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
    let registry = try GatewayRuntime(
      configuration: configuration,
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()))
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
      registry: try GatewayRuntime(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher())),
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
      registry: try GatewayRuntime(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher())),
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
      registry: try GatewayRuntime(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher())),
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
      registry: try GatewayRuntime(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher())),
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
      registry: try GatewayRuntime(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher())),
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
      registry: try GatewayRuntime(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher())),
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
    #expect(await runtime.controlSessions().isEmpty)
    await session.disconnect()
    await runtime.stop()
  }

  @Test
  func testStreamingDisconnectCleansTheAssociatedSession() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher())),
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
    #expect(await runtime.controlSessions().isEmpty)
    await runtime.stop()
  }

  @Test
  func testStopCleansSessionsExactlyOnceAndIsIdempotent() async throws {
    let port = try availableHTTPRuntimeLoopbackPort()
    let configuration = GatewayConfiguration()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: try GatewayRuntime(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher())),
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
