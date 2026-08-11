import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class GatewaySocketTests {
  @Test
  func testParsesStringAndNumericMCPResponseCorrelations() throws {
    let stringResponse = try jsonData([
      "jsonrpc": "2.0",
      "id": "connector-request",
      "result": [
        "structuredContent": [
          "gateway_execution": ["request_id": "gateway-request"]
        ]
      ],
    ])
    #expect(
      (GatewaySocketMCPResponseCorrelation.parse(stringResponse))
        == (GatewaySocketMCPResponseCorrelation(
          mcpRequestID: "connector-request",
          gatewayRequestID: "gateway-request"
        )))

    let numericResponse = try jsonData([
      "jsonrpc": "2.0",
      "id": 42,
      "result": [
        "_meta": [
          "computer_mcp": ["request_id": "gateway-request-2"]
        ]
      ],
    ])
    #expect(
      (GatewaySocketMCPResponseCorrelation.parse(numericResponse))
        == (GatewaySocketMCPResponseCorrelation(
          mcpRequestID: "42",
          gatewayRequestID: "gateway-request-2"
        )))
  }

  @Test
  func testOfficialMCPClientRoundTripsOverUnixSocket() async throws {
    let fixture = try SocketFixture()
    let server = makeServer(configuration: fixture.configuration)
    try await server.start()

    do {
      let transport = GatewaySocketTransport(configuration: fixture.configuration)
      let client = Client(name: "socket-test", version: "1")
      let initialize = try await client.connect(transport: transport)

      #expect((initialize.serverInfo.name) == ("socket-fixture"))
      try await client.ping()
      await client.disconnect()
      try await waitUntil { await server.connectionCount() == 0 }
    } catch {
      await server.stop()
      throw error
    }

    await server.stop()
    #expect(!(FileManager.default.fileExists(atPath: fixture.configuration.socketURL.path)))
  }

  @Test
  func testAuthenticatesSecureTunnelSeparatelyFromOrdinarySameUserClients() async throws {
    let fixture = try SocketFixture()
    let credentialURL = fixture.rootURL.appendingPathComponent("tunnel-auth")
    try GatewaySocketCredentialStore.create(at: credentialURL)
    var serverConfiguration = fixture.configuration
    serverConfiguration.tunnelCredentialFile = credentialURL
    let identities = SocketIdentityProbe()
    let server = GatewaySocketServer(configuration: serverConfiguration) { identity in
      await identities.record(identity)
      return Server(name: "socket-fixture", version: "1")
    }
    try await server.start()

    do {
      let localClient = Client(name: "local-client", version: "1")
      try await localClient.connect(
        transport: GatewaySocketTransport(configuration: serverConfiguration)
      )
      try await localClient.ping()
      await localClient.disconnect()

      var tunnelConfiguration = serverConfiguration
      tunnelConfiguration.clientIdentity = .secureTunnel(
        credentialFile: credentialURL,
        tunnelInstanceID: "tunnel-instance-1",
        tunnelProfileID: "computer-mcp"
      )
      let tunnelClient = Client(name: "tunnel-client", version: "1")
      try await tunnelClient.connect(
        transport: GatewaySocketTransport(configuration: tunnelConfiguration)
      )
      try await tunnelClient.ping()
      await tunnelClient.disconnect()

      try await waitUntil { await identities.values.count == 2 }
      let observed = await identities.values
      #expect((observed.map(\.origin)) == ([.localMCP, .secureTunnel]))
      #expect((observed[0].connectionID) != (observed[1].connectionID))
      #expect((observed[1].tunnelInstanceID) == ("tunnel-instance-1"))
      #expect((observed[1].tunnelProfileID) == ("computer-mcp"))
    } catch {
      await server.stop()
      throw error
    }

    await server.stop()
  }

  @Test
  func testRejectsSecureTunnelHandshakeWithWrongCredential() async throws {
    let fixture = try SocketFixture()
    let credentialURL = fixture.rootURL.appendingPathComponent("tunnel-auth")
    let wrongCredentialURL = fixture.rootURL.appendingPathComponent("wrong-tunnel-auth")
    try GatewaySocketCredentialStore.create(at: credentialURL)
    try GatewaySocketCredentialStore.create(at: wrongCredentialURL)
    var serverConfiguration = fixture.configuration
    serverConfiguration.tunnelCredentialFile = credentialURL
    let server = makeServer(configuration: serverConfiguration)
    try await server.start()

    var clientConfiguration = serverConfiguration
    clientConfiguration.clientIdentity = .secureTunnel(
      credentialFile: wrongCredentialURL,
      tunnelInstanceID: "forged-instance",
      tunnelProfileID: "computer-mcp"
    )
    let transport = GatewaySocketTransport(configuration: clientConfiguration)
    try await transport.connect()
    var iterator = await transport.receive().makeAsyncIterator()
    do {
      _ = try await iterator.next()
      Issue.record("Expected the forged Tunnel credential to be rejected.")
    } catch GatewaySocketError.notConnected {
      // The server closes before accepting any MCP payload.
    }
    await transport.disconnect()

    await server.stop()
  }

  @Test
  func testAcceptsPartialAndCoalescedFramesWithoutChangingMCPPayloads() async throws {
    let fixture = try SocketFixture()
    let server = makeServer(configuration: fixture.configuration)
    try await server.start()

    do {
      let responses = try await runBlocking {
        let socket = try RawUnixSocket(path: fixture.configuration.socketURL.path)
        let first = try jsonData([
          "jsonrpc": "2.0",
          "id": 1,
          "method": "ping",
        ])
        let firstFrame = framed(first)
        try socket.write(Data(firstFrame.prefix(2)))
        try socket.write(Data(firstFrame.dropFirst(2).prefix(3)))
        try socket.write(Data(firstFrame.dropFirst(5)))

        let firstResponse = try decodeObject(socket.readFrame())
        let second = try jsonData([
          "jsonrpc": "2.0",
          "id": 2,
          "method": "ping",
        ])
        let third = try jsonData([
          "jsonrpc": "2.0",
          "id": 3,
          "method": "ping",
        ])
        try socket.write(framed(second) + framed(third))

        let laterResponses = try [socket.readFrame(), socket.readFrame()]
          .map(decodeObject)
        return (
          firstResponse["id"] as? Int,
          firstResponse["result"] != nil,
          Set(laterResponses.compactMap { $0["id"] as? Int })
        )
      }
      #expect((responses.0) == (1))
      #expect(responses.1)
      #expect((responses.2) == ([2, 3]))
    } catch {
      await server.stop()
      throw error
    }

    await server.stop()
  }

  @Test
  func testSupportsConcurrentIndependentMCPConnections() async throws {
    let fixture = try SocketFixture()
    let server = makeServer(configuration: fixture.configuration)
    try await server.start()

    do {
      let firstTransport = GatewaySocketTransport(configuration: fixture.configuration)
      let secondTransport = GatewaySocketTransport(configuration: fixture.configuration)
      let firstClient = Client(name: "first", version: "1")
      let secondClient = Client(name: "second", version: "1")

      async let firstInitialize = firstClient.connect(transport: firstTransport)
      async let secondInitialize = secondClient.connect(transport: secondTransport)
      let initializations = try await [firstInitialize, secondInitialize]
      #expect(initializations.allSatisfy { $0.serverInfo.name == "socket-fixture" })
      try await waitUntil { await server.connectionCount() == 2 }

      async let firstPing: Void = firstClient.ping()
      async let secondPing: Void = secondClient.ping()
      _ = try await (firstPing, secondPing)

      await firstClient.disconnect()
      await secondClient.disconnect()
      try await waitUntil { await server.connectionCount() == 0 }
    } catch {
      await server.stop()
      throw error
    }

    await server.stop()
  }

  @Test
  func testCancellationIsHandledByOfficialMCPServerAndConnectionRemainsUsable() async throws {
    let fixture = try SocketFixture()
    let cancellationProbe = CancellationProbe()
    let server = GatewaySocketServer(configuration: fixture.configuration) { _ in
      let mcpServer = Server(
        name: "socket-fixture",
        version: "1",
        capabilities: .init(tools: .init())
      )
      await mcpServer.withMethodHandler(CallTool.self) { _ in
        do {
          try await Task.sleep(for: .seconds(10))
          return CallTool.Result(
            content: [
              .text(
                text: "unexpected completion",
                annotations: nil,
                _meta: nil
              )
            ]
          )
        } catch is CancellationError {
          await cancellationProbe.markCancelled()
          throw CancellationError()
        }
      }
      return mcpServer
    }
    try await server.start()

    do {
      let socket = try RawUnixSocket(path: fixture.configuration.socketURL.path)
      let request = try jsonData([
        "jsonrpc": "2.0",
        "id": 41,
        "method": "tools/call",
        "params": [
          "name": "slow",
          "arguments": [:],
        ],
      ])
      try await runBlocking {
        try socket.write(framed(request))
      }
      try await Task.sleep(for: .milliseconds(50))

      let cancellation = try jsonData([
        "jsonrpc": "2.0",
        "method": "notifications/cancelled",
        "params": [
          "requestId": 41,
          "reason": "fixture cancellation",
        ],
      ])
      try await runBlocking {
        try socket.write(framed(cancellation))
      }
      try await waitUntil { await cancellationProbe.wasCancelled }

      let ping = try jsonData([
        "jsonrpc": "2.0",
        "id": 42,
        "method": "ping",
      ])
      let responseID = try await runBlocking {
        try socket.write(framed(ping))
        return try decodeObject(socket.readFrame())["id"] as? Int
      }
      #expect((responseID) == (42))
    } catch {
      await server.stop()
      throw error
    }

    await server.stop()
  }

  @Test
  func testDisconnectRemovesConnectionState() async throws {
    let fixture = try SocketFixture()
    let server = makeServer(configuration: fixture.configuration)
    try await server.start()

    let transport = GatewaySocketTransport(configuration: fixture.configuration)
    try await transport.connect()
    try await waitUntil { await server.connectionCount() == 1 }
    await transport.disconnect()
    try await waitUntil { await server.connectionCount() == 0 }

    await server.stop()
  }

  @Test
  func testReceiveAfterPeerClosureReturnsTerminalErrorInsteadOfSpinning() async throws {
    let fixture = try SocketFixture()
    let server = makeServer(configuration: fixture.configuration)
    try await server.start()

    let transport = GatewaySocketTransport(configuration: fixture.configuration)
    try await transport.connect()
    let initialStream = await transport.receive()
    await server.stop()

    var initialIterator = initialStream.makeAsyncIterator()
    _ = try? await initialIterator.next()

    let terminalStream = await transport.receive()
    var terminalIterator = terminalStream.makeAsyncIterator()
    do {
      _ = try await terminalIterator.next()
      Issue.record("Expected a terminal transport error after peer closure.")
    } catch GatewaySocketError.notConnected {
      // Expected: MCP.Client breaks its receive loop instead of replaying a finished stream.
    }

    await transport.disconnect()
  }

  @Test
  func testRecoversOwnedStaleSocketButRefusesActiveListener() async throws {
    let fixture = try SocketFixture(createDirectory: true)
    try createStaleUnixSocket(at: fixture.configuration.socketURL.path)
    #expect(FileManager.default.fileExists(atPath: fixture.configuration.socketURL.path))

    let server = makeServer(configuration: fixture.configuration)
    try await server.start()
    let replacementStatus = try fileStatus(at: fixture.configuration.socketURL.path)
    #expect((replacementStatus.st_uid) == (getuid()))

    let competingServer = makeServer(configuration: fixture.configuration)
    do {
      try await competingServer.start()
      Issue.record("Expected the active listener to be rejected.")
    } catch {
      #expect(error is GatewaySocketError)
    }

    await server.stop()
  }

  @Test
  func testCreatesPrivateDirectoryAndSocketPermissions() async throws {
    let fixture = try SocketFixture()
    let server = makeServer(configuration: fixture.configuration)
    try await server.start()

    let directoryStatus = try fileStatus(
      at: fixture.configuration.socketURL.deletingLastPathComponent().path
    )
    let socketStatus = try fileStatus(at: fixture.configuration.socketURL.path)
    #expect((directoryStatus.st_uid) == (getuid()))
    #expect((directoryStatus.st_mode & 0o777) == (0o700))
    #expect((socketStatus.st_uid) == (getuid()))
    #expect((socketStatus.st_mode & 0o777) == (0o600))

    await server.stop()
  }

  @Test
  func testBoundedReceiveBufferFailsClosedInsteadOfDroppingMessages() async throws {
    let fixture = try SocketFixture()
    let server = makeServer(configuration: fixture.configuration)
    try await server.start()

    do {
      var clientConfiguration = fixture.configuration
      clientConfiguration.maximumBufferedMessages = 2
      let transport = GatewaySocketTransport(configuration: clientConfiguration)
      try await transport.connect()
      for identifier in 1...32 {
        let ping = try jsonData([
          "jsonrpc": "2.0",
          "id": identifier,
          "method": "ping",
        ])
        try? await transport.send(ping)
      }
      try await Task.sleep(for: .milliseconds(250))

      let stream = await transport.receive()
      var iterator = stream.makeAsyncIterator()
      var observedBackpressure = false
      do {
        while try await iterator.next() != nil {}
      } catch GatewaySocketError.backpressureExceeded(let limit) {
        observedBackpressure = limit == 2
      }
      #expect(observedBackpressure)
      await transport.disconnect()
    } catch {
      await server.stop()
      throw error
    }

    await server.stop()
  }

  @Test
  func testStdioBridgePumpsCompleteOfficialMCPMessagesOverRealSocket() async throws {
    let fixture = try SocketFixture()
    let server = makeServer(configuration: fixture.configuration)
    try await server.start()

    do {
      let inMemory = await InMemoryTransport.createConnectedPair()
      try await inMemory.server.connect()
      let socketTransport = GatewaySocketTransport(configuration: fixture.configuration)
      let bridge = Task {
        try await GatewayStdioSocketBridge.run(
          stdioTransport: inMemory.server,
          socketTransport: socketTransport
        )
      }
      try await inMemory.client.connect()

      let ping = try jsonData([
        "jsonrpc": "2.0",
        "id": 91,
        "method": "ping",
      ])
      try await inMemory.client.send(ping)
      let responses = await inMemory.client.receive()
      var iterator = responses.makeAsyncIterator()
      let nextResponse = try await iterator.next()
      let responseData = try #require(nextResponse)
      let response = try decodeObject(responseData)
      #expect((response["id"] as? Int) == (91))

      await inMemory.client.disconnect()
      _ = try await bridge.value
    } catch {
      await server.stop()
      throw error
    }

    await server.stop()
  }

  @Test
  func testControlClientTimesOutWhenOwnedSocketNeverResponds() async throws {
    let fixture = try SocketFixture(createDirectory: true)
    let server = try UnresponsiveUnixSocketServer(path: fixture.configuration.socketURL.path)
    defer { server.close() }
    let client = AppControlPlaneServiceClient(socketURL: fixture.configuration.socketURL)
    let clock = ContinuousClock()
    let startedAt = clock.now

    do {
      _ = try await client.call("readiness", timeout: .milliseconds(100))
      Issue.record("Expected an unresponsive control socket to time out.")
    } catch let error as ControlSocketCallError {
      #expect(error.code == "control.timeout")
    }

    #expect(startedAt.duration(to: clock.now) < .seconds(1))
  }
}

private actor CancellationProbe {
  private(set) var wasCancelled = false

  func markCancelled() {
    wasCancelled = true
  }
}

private actor SocketIdentityProbe {
  private(set) var values: [GatewaySocketConnectionIdentity] = []

  func record(_ identity: GatewaySocketConnectionIdentity) {
    values.append(identity)
  }
}

private struct SocketFixture {
  let rootURL: URL
  let configuration: GatewaySocketConfiguration

  init(
    createDirectory: Bool = false,
    maximumBufferedMessages: Int = GatewaySocketConfiguration.defaultBufferedMessages
  ) throws {
    let identifier = UUID().uuidString.prefix(8)
    rootURL = URL(fileURLWithPath: "/tmp/cm-\(identifier)", isDirectory: true)
    if createDirectory {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    configuration = GatewaySocketConfiguration(
      socketURL: rootURL.appendingPathComponent("gateway.sock"),
      maximumBufferedMessages: maximumBufferedMessages
    )
  }
}

private func makeServer(
  configuration: GatewaySocketConfiguration
) -> GatewaySocketServer {
  GatewaySocketServer(configuration: configuration) { _ in
    Server(name: "socket-fixture", version: "1")
  }
}

private func waitUntil(
  timeout: Duration = .seconds(3),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for asynchronous socket state.")
  throw SocketTestError.timedOut
}

private enum SocketTestError: Error {
  case timedOut
}

private func jsonData(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func decodeObject(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func framed(_ payload: Data) -> Data {
  var length = UInt32(payload.count).bigEndian
  var result = withUnsafeBytes(of: &length) { Data($0) }
  result.append(payload)
  return result
}

private func fileStatus(at path: String) throws -> stat {
  var status = stat()
  guard lstat(path, &status) == 0 else {
    throw GatewaySocketError.ioError(operation: "lstat(\(path))", code: errno)
  }
  return status
}

private func createStaleUnixSocket(at path: String) throws {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    throw GatewaySocketError.ioError(operation: "socket", code: errno)
  }
  defer { _ = close(descriptor) }

  var address = try unixSocketAddress(path: path)
  let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(descriptor, $0, addressLength)
    }
  }
  guard result == 0 else {
    throw GatewaySocketError.ioError(operation: "bind(\(path))", code: errno)
  }
}

private func runBlocking<T: Sendable>(
  _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    Thread.detachNewThread {
      autoreleasepool {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

private final class RawUnixSocket: @unchecked Sendable {
  private let descriptor: CInt

  init(path: String) throws {
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw GatewaySocketError.ioError(operation: "socket", code: errno)
    }

    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) {
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        $0,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }

    var address = try unixSocketAddress(path: path)
    let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength)
      }
    }
    guard result == 0 else {
      let code = errno
      _ = close(descriptor)
      throw GatewaySocketError.ioError(operation: "connect(\(path))", code: code)
    }
  }

  deinit {
    _ = close(descriptor)
  }

  func write(_ data: Data) throws {
    var remaining = data
    while !remaining.isEmpty {
      let count = remaining.withUnsafeBytes {
        Darwin.write(descriptor, $0.baseAddress, $0.count)
      }
      guard count > 0 else {
        throw GatewaySocketError.ioError(operation: "write", code: errno)
      }
      remaining.removeFirst(count)
    }
  }

  func readFrame() throws -> Data {
    let header = try readExactly(MemoryLayout<UInt32>.size)
    let length = header.withUnsafeBytes { bytes in
      UInt32(bigEndian: bytes.loadUnaligned(as: UInt32.self))
    }
    return try readExactly(Int(length))
  }

  private func readExactly(_ count: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
      var buffer = [UInt8](repeating: 0, count: count - result.count)
      let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
      guard bytesRead > 0 else {
        throw GatewaySocketError.ioError(operation: "read", code: errno)
      }
      result.append(contentsOf: buffer.prefix(bytesRead))
    }
    return result
  }
}

private final class UnresponsiveUnixSocketServer: @unchecked Sendable {
  private let descriptor: CInt
  private let path: String
  private let lock = NSLock()
  private var isClosed = false

  init(path: String) throws {
    self.path = path
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw GatewaySocketError.ioError(operation: "socket", code: errno)
    }

    var address = try unixSocketAddress(path: path)
    let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, addressLength)
      }
    }
    guard bindResult == 0, chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else {
      let code = errno
      _ = Darwin.close(descriptor)
      throw GatewaySocketError.ioError(operation: "listen(\(path))", code: code)
    }
  }

  deinit {
    close()
  }

  func close() {
    lock.lock()
    guard !isClosed else {
      lock.unlock()
      return
    }
    isClosed = true
    lock.unlock()
    _ = Darwin.close(descriptor)
    _ = Darwin.unlink(path)
  }
}

private func unixSocketAddress(path: String) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
  guard bytes.count <= maximum else {
    throw GatewaySocketError.invalidConfiguration(
      "socket path exceeds \(maximum) UTF-8 bytes"
    )
  }
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.initializeMemory(as: UInt8.self, repeating: 0)
    destination.copyBytes(from: bytes)
  }
  return address
}
