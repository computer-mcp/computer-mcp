import ComputerMCPSandbox
import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import ComputerMCPEgress

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@Suite struct EgressProxyTests {
  @Test func connectDenialNamesHostAndCannotForgeIdentity() async throws {
    let events = Events()
    let proxy = try await EgressProxy.start(
      executionID: "execution-one", policy: .init(access: .trusted),
      routing: FixedRoute(tunnel: false, direct: false), limits: .init(), onDenial: events.append)
    let ports = try await proxy.sandboxPorts()
    let client = try TestSocket(port: ports.http)
    defer { client.close() }
    try client.write(
      Array("CONNECT example.com:443 HTTP/1.1\r\nX-Execution-ID: execution-two\r\n\r\n".utf8))
    let response = try client.read()
    #expect(String(decoding: response, as: UTF8.self).contains("403 example.com"))
    #expect(String(decoding: response, as: UTF8.self).contains("X-Blocked-Host: example.com"))
    #expect(events.values.first?.executionID == "execution-one")
    #expect(events.values.first?.host == "example.com")
    #expect(events.values.first?.port == 443)
    try await proxy.releaseAfterExecutionEnds()
  }

  @Test func socksDenialAndIPv6Listener() async throws {
    let proxy = try await EgressProxy.start(
      executionID: "socks", policy: .init(),
      routing: FixedRoute(tunnel: false, direct: false), limits: .init())
    let ports = try await proxy.sandboxPorts()
    let client = try TestSocket(port: ports.socks, ipv6: true)
    defer { client.close() }
    try client.write([5, 1, 0])
    #expect(try client.read() == [5, 0])
    try client.write([5, 1, 0, 3, 11] + Array("example.com".utf8) + [0, 80])
    let response = try client.read()
    #expect(response[1] == 2)
    #expect(String(decoding: response.dropFirst(5).dropLast(2), as: UTF8.self) == "example.com")
    try await proxy.releaseAfterExecutionEnds()
  }

  @Test(arguments: ["127.0.0.1", "169.254.169.254", "192.168.1.5", "224.0.0.1"])
  func resolvedAddressGuards(address: String) async throws {
    let events = Events()
    let proxy = try await EgressProxy.start(
      executionID: "addresses", policy: .init(access: .full),
      routing: FixedRoute(tunnel: false, direct: true),
      resolver: FakeResolver(addresses: [address]),
      limits: .init(), onDenial: events.append)
    let ports = try await proxy.sandboxPorts()
    let client = try TestSocket(port: ports.http)
    defer { client.close() }
    try client.write(Array("CONNECT address.test:443 HTTP/1.1\r\n\r\n".utf8))
    #expect(String(decoding: try client.read(), as: UTF8.self).contains("403 address.test"))
    #expect(
      events.values.first?.reason == (address == "127.0.0.1" ? .loopback : .localNetworkRequired))
    try await proxy.releaseAfterExecutionEnds()
  }

  @Test func mixedAnswerRejectedBeforeDial() async throws {
    let proxy = try await EgressProxy.start(
      executionID: "mixed", policy: .init(access: .full),
      routing: FixedRoute(tunnel: false, direct: false),
      resolver: FakeResolver(addresses: ["203.0.113.1", "127.0.0.1"]),
      limits: .init(),
      dial: { _, _, _ in
        Issue.record("Mixed response must not dial")
        throw EgressConnectionError.resolutionFailed
      })
    let ports = try await proxy.sandboxPorts()
    let client = try TestSocket(port: ports.http)
    defer { client.close() }
    try client.write(Array("CONNECT mixed.test:443 HTTP/1.1\r\n\r\n".utf8))
    #expect(String(decoding: try client.read(), as: UTF8.self).contains("403 mixed.test"))
    try await proxy.releaseAfterExecutionEnds()
  }

  #if canImport(Darwin)
    @Test func relayPinsAddressSupportsHalfCloseAndRevocation() async throws {
      let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      let server = try await ServerBootstrap(group: group)
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .childChannelInitializer { channel in channel.pipeline.addHandler(HalfCloseResponder()) }
        .bind(host: "127.0.0.1", port: 0).get()
      let destination = server.localAddress!
      let proxy = try await EgressProxy.start(
        executionID: "relay", policy: .init(access: .full),
        routing: FixedRoute(tunnel: true, direct: false),
        resolver: FakeResolver(addresses: ["198.18.0.1"]),
        limits: .init(),
        dial: { checked, route, loop in
          #expect(checked.ipAddress == "198.18.0.1")
          #expect(checked.port == 443)
          return try EgressSocket.connect(to: destination, route: route, on: loop)
        })
      let ports = try await proxy.sandboxPorts()
      let client = try TestSocket(port: ports.http)
      defer { client.close() }
      try client.write(Array("CONNECT relay.test:443 HTTP/1.1\r\n\r\n".utf8))
      #expect(String(decoding: try client.read(), as: UTF8.self).contains("200"))
      try client.write(Array("payload".utf8))
      client.halfClose()
      #expect(String(decoding: try client.read(), as: UTF8.self) == "received:payload")
      let ongoing = try TestSocket(port: ports.http)
      defer { ongoing.close() }
      try ongoing.write(Array("CONNECT relay.test:443 HTTP/1.1\r\n\r\n".utf8))
      #expect(String(decoding: try ongoing.read(), as: UTF8.self).contains("200"))
      try await proxy.revoke()
      #expect(try ongoing.read().isEmpty)
      await #expect(throws: ExecutionEnvironmentError.self) { try await proxy.sandboxPorts() }
      let replacement = try TestSocket(port: ports.http)
      defer { replacement.close() }
      #expect(try replacement.read().isEmpty)
      try await proxy.releaseAfterExecutionEnds()
      try await server.close()
      try await group.shutdownGracefully()
    }

  #endif

  @Test func resourceBounds() async throws {
    let proxy = try await EgressProxy.start(
      executionID: "bounds", policy: .init(access: .full),
      routing: FixedRoute(tunnel: false, direct: false),
      limits: .init(connections: 1, bufferBytes: 1024, handshakeTimeout: .milliseconds(200)))
    let ports = try await proxy.sandboxPorts()
    let first = try TestSocket(port: ports.http)
    defer { first.close() }
    try first.write(Array("CONNECT".utf8))
    let second = try TestSocket(port: ports.http)
    defer { second.close() }
    #expect(try second.read().isEmpty)
    #expect(try first.read().isEmpty)
    let oversized = try TestSocket(port: ports.http)
    defer { oversized.close() }
    try oversized.write(Array(repeating: 65, count: 2048))
    #expect(try oversized.read().isEmpty)
    try await proxy.releaseAfterExecutionEnds()
  }
}

struct FakeResolver: EgressResolving {
  let addresses: [String]
  func resolve(host: String, port: UInt16) throws -> [SocketAddress] {
    try addresses.map { try SocketAddress(ipAddress: $0, port: Int(port)) }
  }
}

final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = [EgressDenial]()
  var values: [EgressDenial] { lock.withLock { stored } }
  func append(_ event: EgressDenial) { lock.withLock { stored.append(event) } }
}

/// Blocking test clients run outside the proxy event loop and have a strict socket timeout.
final class TestSocket {
  private var descriptor: Int32
  init(port: UInt16, ipv6: Bool = false, receiveBuffer: Int32? = nil) throws {
    #if canImport(Darwin)
      descriptor = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    #else
      descriptor = socket(ipv6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    if var receiveBuffer {
      setsockopt(
        descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
    }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let address = try SocketAddress(ipAddress: ipv6 ? "::1" : "127.0.0.1", port: Int(port))
    let status = address.withSockAddr { connect(descriptor, $0, socklen_t($1)) }
    if status != 0 {
      close()
      throw POSIXError(.ECONNREFUSED)
    }
  }
  func write(_ bytes: [UInt8]) throws {
    var sent = 0
    while sent < bytes.count {
      let count = bytes.withUnsafeBytes {
        send(descriptor, $0.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
      }
      guard count > 0 else { throw POSIXError(.EIO) }
      sent += count
    }
  }
  func read() throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 65536)
    let count = recv(descriptor, &bytes, bytes.count, 0)
    if count < 0, errno == ECONNRESET { return [] }
    guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return Array(bytes.prefix(count))
  }
  func halfClose() { _ = shutdown(descriptor, Int32(SHUT_WR)) }
  func close() {
    if descriptor >= 0 {
      #if canImport(Darwin)
        Darwin.close(descriptor)
      #else
        Glibc.close(descriptor)
      #endif
      descriptor = -1
    }
  }
  deinit { close() }
}

private final class HalfCloseResponder: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  var bytes = ByteBuffer()
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var value = unwrapInboundIn(data)
    bytes.writeBuffer(&value)
  }
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let event = event as? ChannelEvent, event == .inputClosed {
      var response = ByteBuffer(string: "received:")
      response.writeBuffer(&bytes)
      let channel = context.channel
      channel.writeAndFlush(response).whenComplete { _ in channel.close(promise: nil) }
    }
  }
}
