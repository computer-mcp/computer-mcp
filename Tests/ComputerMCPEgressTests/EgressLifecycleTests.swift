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

@Suite struct EgressLifecycleTests {
  #if canImport(Darwin)
    @Test(arguments: ["direct", "interface", "address", "missing"])
    func routeEventsDisconnectOnlyAffectedConnections(change: String) async throws {
      let origin = try await LocalOrigin.start()
      let routes = MutableRoutes()
      let events = Events()
      let proxy = try await EgressProxy.start(
        executionID: "routes", policy: .init(access: .full),
        routing: routes, resolver: HostResolver(), limits: .init(),
        dial: { _, route, loop in
          try EgressSocket.connect(to: origin.address, route: route, on: loop)
        }, onDenial: events.append)
      let port = try await proxy.sandboxPorts().http
      let affected = try TestSocket(port: port)
      let unaffected = try TestSocket(port: port)
      defer {
        affected.close()
        unaffected.close()
      }
      try establish(affected, host: "changed.test")
      try establish(unaffected, host: "stable.test")
      let count = routes.queries
      routes.emit()
      try await routes.waitForQueries(count + 2)
      try unaffected.write(Array("still-open".utf8))
      #expect(String(decoding: try unaffected.read(), as: UTF8.self) == "still-open")
      routes.change(change, address: "198.18.0.1")
      #expect(try affected.read().isEmpty)
      try unaffected.write(Array("unchanged".utf8))
      #expect(String(decoding: try unaffected.read(), as: UTF8.self) == "unchanged")
      #expect(events.values.count == 1)
      #expect(events.values.first?.host == "changed.test")
      #expect(
        events.values.first?.reason
          == (change == "direct"
            ? .localNetworkRequired : change == "missing" ? .routeUnavailable : .routeChanged))
      try await proxy.releaseAfterExecutionEnds()
      #expect(routes.cancelled)
      try await origin.stop()
    }

    @Test func monitorFailureClosesStreamsAndRefusesNewConnections() async throws {
      let origin = try await LocalOrigin.start()
      let routes = MutableRoutes()
      let events = Events()
      let proxy = try await EgressProxy.start(
        executionID: "monitor", policy: .init(access: .full),
        routing: routes, resolver: HostResolver(), limits: .init(),
        dial: { _, route, loop in
          try EgressSocket.connect(to: origin.address, route: route, on: loop)
        }, onDenial: events.append)
      let port = try await proxy.sandboxPorts().http
      let client = try TestSocket(port: port)
      defer { client.close() }
      try establish(client)
      routes.emit(.unavailable)
      #expect(try client.read().isEmpty)
      let next = try TestSocket(port: port)
      defer { next.close() }
      #expect(try next.read().isEmpty)
      #expect(events.values.allSatisfy { $0.reason == .routeUnavailable })
      try await proxy.releaseAfterExecutionEnds()
      try await origin.stop()
    }

    @Test func dnsChangesAreCheckedForEachConnection() async throws {
      let origin = try await LocalOrigin.start()
      let resolver = ChangingResolver()
      let events = Events()
      let proxy = try await EgressProxy.start(
        executionID: "dns", policy: .init(access: .full),
        routing: MutableRoutes(), resolver: resolver, limits: .init(),
        dial: { address, route, loop in
          #expect(address.ipAddress == "198.18.0.1")
          return try EgressSocket.connect(to: origin.address, route: route, on: loop)
        }, onDenial: events.append)
      let port = try await proxy.sandboxPorts().http
      let original = try TestSocket(port: port)
      defer { original.close() }
      try establish(original)
      resolver.set("127.0.0.1")
      let changed = try TestSocket(port: port)
      defer { changed.close() }
      try changed.write(Array("CONNECT changed.test:443 HTTP/1.1\r\n\r\n".utf8))
      #expect(String(decoding: try changed.read(), as: UTF8.self).contains("403 changed.test"))
      #expect(events.values.first?.reason == .loopback)
      try original.write(Array("pinned".utf8))
      #expect(String(decoding: try original.read(), as: UTF8.self) == "pinned")
      try await proxy.releaseAfterExecutionEnds()
      try await origin.stop()
    }

    @Test func idleTimeoutAndDelayedConnectAreBounded() async throws {
      let origin = try await LocalOrigin.start()
      let proxy = try await EgressProxy.start(
        executionID: "idle", policy: .init(access: .full),
        routing: MutableRoutes(), resolver: HostResolver(),
        limits: .init(idleTimeout: .milliseconds(100)),
        dial: { _, route, loop in
          try EgressSocket.connect(to: origin.address, route: route, on: loop)
        })
      let client = try TestSocket(port: try await proxy.sandboxPorts().http)
      defer { client.close() }
      try establish(client)
      #expect(try client.read().isEmpty)
      try await proxy.releaseAfterExecutionEnds()
      let streams = StreamProbe()
      let delayed = try await EgressProxy.start(
        executionID: "connect", policy: .init(access: .full),
        routing: MutableRoutes(), resolver: HostResolver(),
        limits: .init(connectTimeout: .milliseconds(40)),
        dial: { _, _, loop in
          let stream = PendingStream(loop: loop)
          streams.append(stream)
          return stream
        })
      let pending = try TestSocket(port: try await delayed.sandboxPorts().http)
      defer { pending.close() }
      try pending.write(Array("CONNECT changed.test:443 HTTP/1.1\r\n\r\n".utf8))
      #expect(try pending.read().isEmpty)
      try await delayed.releaseAfterExecutionEnds()
      #expect(streams.values.count == 1)
      #expect(streams.values.first?.didClose == true)
      try await origin.stop()
    }

    @Test(arguments: [false, true])
    func largeResponseWithSlowReaderAndHalfClose(smallReceiveWindow: Bool) async throws {
      let size = smallReceiveWindow ? 256 * 1024 : 4 * 1024 * 1024
      let origin = try await LocalOrigin.start(responseBytes: size)
      let proxy = try await EgressProxy.start(
        executionID: "large", policy: .init(access: .full),
        routing: MutableRoutes(), resolver: HostResolver(), limits: .init(bufferBytes: 32_768),
        dial: { _, route, loop in
          try EgressSocket.connect(to: origin.address, route: route, on: loop)
        })
      let client = try TestSocket(
        port: try await proxy.sandboxPorts().http, receiveBuffer: smallReceiveWindow ? 1024 : nil)
      defer { client.close() }
      try establish(client)
      try client.write([1])
      client.halfClose()
      try await Task.sleep(for: .milliseconds(300))
      var received = 0
      while true {
        let bytes = try client.read()
        if bytes.isEmpty { break }
        #expect(bytes.allSatisfy { $0 == 37 })
        received += bytes.count
        try await Task.sleep(for: .milliseconds(2))
      }
      #expect(received == size)
      try await proxy.releaseAfterExecutionEnds()
      try await origin.stop()
    }

    @Test func revokeBackpressuredStreamClosesWithoutWaitingForReader() async throws {
      let origin = try await LocalOrigin.start(responseBytes: 8 * 1024 * 1024)
      let proxy = try await EgressProxy.start(
        executionID: "blocked-writer", policy: .init(access: .full),
        routing: MutableRoutes(), resolver: HostResolver(), limits: .init(bufferBytes: 32_768),
        dial: { _, route, loop in
          try EgressSocket.connect(to: origin.address, route: route, on: loop)
        })
      let client = try TestSocket(port: try await proxy.sandboxPorts().http, receiveBuffer: 1024)
      defer { client.close() }
      try establish(client)
      try client.write([1])
      try await Task.sleep(for: .milliseconds(300))
      let started = ContinuousClock.now
      try await proxy.revoke()
      #expect(started.duration(to: .now) < .seconds(2))
      try await proxy.releaseAfterExecutionEnds()
      try await origin.stop()
    }

    @Test func largeUploadWithSlowReaderAndHalfClose() async throws {
      let size = 4 * 1024 * 1024
      let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      let origin = try await ServerBootstrap(group: group)
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .childChannelOption(ChannelOptions.autoRead, value: false)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .childChannelOption(
          ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384)
        )
        .childChannelInitializer { channel in channel.pipeline.addHandler(SlowUploadHandler()) }
        .bind(host: "127.0.0.1", port: 0).get()
      let destination = try #require(origin.localAddress)
      let proxy = try await EgressProxy.start(
        executionID: "upload", policy: .init(access: .full),
        routing: MutableRoutes(), resolver: HostResolver(), limits: .init(bufferBytes: 32_768),
        dial: { _, route, loop in try EgressSocket.connect(to: destination, route: route, on: loop)
        })
      let client = try TestSocket(port: try await proxy.sandboxPorts().http)
      defer { client.close() }
      try establish(client)
      try client.write(Array(repeating: 37, count: size))
      client.halfClose()
      var response = [UInt8]()
      while true {
        let bytes = try client.read()
        if bytes.isEmpty { break }
        response += bytes
      }
      #expect(String(decoding: response, as: UTF8.self) == "received:\(size)")
      try await proxy.releaseAfterExecutionEnds()
      try await origin.close()
      try await group.shutdownGracefully()
    }

    @Test(arguments: [false, true])
    func bindsCheckedInterface(ipv6: Bool) async throws {
      let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      let origin = try await ServerBootstrap(group: group)
        .bind(host: ipv6 ? "::1" : "127.0.0.1", port: 0).get()
      let destination = try #require(origin.localAddress)
      let binding = group.next().makePromise(of: Int32.self)
      let proxy = try await EgressProxy.start(
        executionID: "bound", policy: .init(access: .full),
        routing: MutableRoutes(),
        resolver: FakeResolver(addresses: [ipv6 ? "2001:db8::1" : "198.18.0.1"]), limits: .init(),
        dial: { _, route, loop in
          let socket = try EgressSocket.connect(to: destination, route: route, on: loop)
          socket.connected.flatMap {
            socket.socketOption(
              level: ipv6 ? IPPROTO_IPV6 : IPPROTO_IP, name: ipv6 ? IPV6_BOUND_IF : IP_BOUND_IF)
          }.cascade(to: binding)
          return socket
        })
      let client = try TestSocket(port: try await proxy.sandboxPorts().http)
      defer { client.close() }
      try establish(client)
      #expect(try await binding.futureResult.get() == Int32(if_nametoindex("lo0")))
      try await proxy.releaseAfterExecutionEnds()
      try await origin.close()
      try await group.shutdownGracefully()
    }
  #endif

  @Test(arguments: ["fallback", "release", "revoke"])
  func failedConnectionCleanupPrecedesFallbackAndShutdown(operation: String) async throws {
    let streams = StreamProbe()
    let proxy = try await EgressProxy.start(
      executionID: "failed-connect", policy: .init(access: .full),
      routing: MutableRoutes(), resolver: FakeResolver(addresses: ["198.18.0.1", "198.18.0.2"]),
      limits: .init(),
      dial: { _, _, loop in
        if let previous = streams.values.first { #expect(previous.didClose) }
        let stream = PendingStream(
          loop: loop, connectFails: true, closesAutomatically: !streams.values.isEmpty)
        streams.append(stream)
        return stream
      })
    let client = try TestSocket(port: try await proxy.sandboxPorts().http)
    defer { client.close() }
    try client.write(Array("CONNECT changed.test:443 HTTP/1.1\r\n\r\n".utf8))
    for _ in 0..<200 {
      if streams.values.first?.closeRequested == true { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let stream = try #require(streams.values.first)
    #expect(stream.closeRequested)
    #expect(streams.values.count == 1)
    if operation != "fallback" {
      let completed = TestCounter()
      let shutdown = Task {
        if operation == "release" {
          try await proxy.releaseAfterExecutionEnds()
        } else {
          try await proxy.revoke()
        }
        completed.increment()
      }
      #expect(try client.read().isEmpty)
      try await Task.sleep(for: .milliseconds(20))
      #expect(completed.value == 0)
      stream.completeClose()
      try await shutdown.value
      #expect(completed.value == 1)
      #expect(streams.values.count == 1)
      if operation == "revoke" { try await proxy.releaseAfterExecutionEnds() }
    } else {
      stream.completeClose()
      #expect(String(decoding: try client.read(), as: UTF8.self).contains("502"))
      try await proxy.releaseAfterExecutionEnds()
      #expect(streams.values.count == 2)
    }
    #expect(stream.didClose)
  }

  @Test(arguments: [EMFILE, ENFILE, ENOBUFS])
  func exhaustedAcceptRetriesAreBounded(failure: Int32) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let attempts = TestCounter()
    let listener = try EgressListener(
      address: SocketAddress(ipAddress: "127.0.0.1", port: 0), on: group.next(),
      acceptSocket: { descriptor in
        attempts.increment()
        if attempts.value <= 3 {
          errno = failure
          return -1
        }
        return acceptDescriptor(descriptor)
      }, accept: closeDescriptor)
    let started = ContinuousClock.now
    let client = try TestSocket(port: listener.port)
    defer { client.close() }
    #expect(try client.read().isEmpty)
    #expect(started.duration(to: .now) >= .milliseconds(140))
    #expect(attempts.value == 4)
    listener.close()
    try await listener.closed.get()
    try await group.shutdownGracefully()
  }

  @Test func exhaustedAcceptCanCloseWhilePaused() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let attempts = TestCounter()
    let listener = try EgressListener(
      address: SocketAddress(ipAddress: "127.0.0.1", port: 0), on: group.next(),
      acceptSocket: { _ in
        attempts.increment()
        errno = EMFILE
        return -1
      }, accept: closeDescriptor)
    let client = try TestSocket(port: listener.port)
    defer { client.close() }
    for _ in 0..<100 {
      if attempts.value > 0 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    listener.close()
    try await listener.closed.get()
    let count = attempts.value
    #expect(count > 0)
    try await Task.sleep(for: .milliseconds(100))
    #expect(attempts.value == count)
    try await group.shutdownGracefully()
  }

  @Test func timedOutDnsRetainsItsReservation() async throws {
    let resolver = BlockedResolver()
    let proxy = try await EgressProxy.start(
      executionID: "dns-bound", policy: .init(access: .full),
      routing: MutableRoutes(), resolver: resolver,
      limits: .init(connections: 1, connectTimeout: .milliseconds(40)),
      dial: { _, _, _ in
        Issue.record("Expired DNS request must not dial")
        throw EgressConnectionError.resolutionFailed
      })
    let port = try await proxy.sandboxPorts().http
    let first = try TestSocket(port: port)
    defer { first.close() }
    try first.write(Array("CONNECT changed.test:443 HTTP/1.1\r\n\r\n".utf8))
    #expect(try first.read().isEmpty)
    let second = try TestSocket(port: port)
    defer { second.close() }
    try second.write(Array("CONNECT changed.test:443 HTTP/1.1\r\n\r\n".utf8))
    #expect(String(decoding: try second.read(), as: UTF8.self).contains("502"))
    #expect(resolver.calls == 1)
    resolver.release.signal()
    try await proxy.releaseAfterExecutionEnds()
  }

  private func establish(_ client: TestSocket, host: String = "changed.test") throws {
    try client.write(Array("CONNECT \(host):443 HTTP/1.1\r\n\r\n".utf8))
    #expect(String(decoding: try client.read(), as: UTF8.self).contains("200"))
  }
}

private final class MutableRoutes: EgressRouting, EgressRouteObservation, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (EgressRouteEvent) -> Void)?
  private var changes = [String: String]()
  private var count = 0
  private var stopped = false
  var queries: Int { lock.withLock { count } }
  var cancelled: Bool { lock.withLock { stopped } }
  func route(to address: String) throws -> EgressRoute {
    try lock.withLock {
      count += 1
      let change = changes[address]
      if change == "missing" { throw EgressConnectionError.resolutionFailed }
      return EgressRoute(
        interface: "lo0", interfaceIndex: change == "interface" ? 2 : 1,
        interfaceAddresses: change == "address" ? ["198.18.0.8"] : ["198.18.0.7"],
        isTunnel: change != "direct", isDirect: change == "direct")
    }
  }
  func observeChanges(_ handler: @escaping @Sendable (EgressRouteEvent) -> Void)
    -> any EgressRouteObservation
  {
    lock.withLock { self.handler = handler }
    return self
  }
  func cancel() {
    lock.withLock {
      handler = nil
      stopped = true
    }
  }
  func emit(_ event: EgressRouteEvent = .changed) { lock.withLock { handler }?(event) }
  func change(_ kind: String, address: String) {
    lock.withLock { changes[address] = kind }
    emit()
  }
  func waitForQueries(_ expected: Int) async throws {
    for _ in 0..<200 {
      if queries >= expected { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Route event did not trigger a comparison")
  }
}

private struct HostResolver: EgressResolving {
  func resolve(host: String, port: UInt16) throws -> [SocketAddress] {
    [
      try SocketAddress(
        ipAddress: host == "stable.test" ? "198.18.0.2" : "198.18.0.1", port: Int(port))
    ]
  }
}

private final class ChangingResolver: EgressResolving, @unchecked Sendable {
  private let lock = NSLock()
  private var address = "198.18.0.1"
  func set(_ address: String) { lock.withLock { self.address = address } }
  func resolve(host: String, port: UInt16) throws -> [SocketAddress] {
    try lock.withLock { [try SocketAddress(ipAddress: address, port: Int(port))] }
  }
}

private final class BlockedResolver: EgressResolving, @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0
  var calls: Int { lock.withLock { count } }
  func resolve(host: String, port: UInt16) throws -> [SocketAddress] {
    lock.withLock { count += 1 }
    _ = release.wait(timeout: .now() + 3)
    return [try SocketAddress(ipAddress: "198.18.0.1", port: Int(port))]
  }
}

private struct LocalOrigin: Sendable {
  let group: MultiThreadedEventLoopGroup
  let server: Channel
  var address: SocketAddress { server.localAddress! }
  static func start(responseBytes: Int? = nil) async throws -> LocalOrigin {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group)
      .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .childChannelInitializer { channel in
        channel.pipeline.addHandler(OriginHandler(responseBytes: responseBytes))
      }
      .bind(host: "127.0.0.1", port: 0).get()
    return LocalOrigin(group: group, server: server)
  }
  func stop() async throws {
    try await server.close()
    try await group.shutdownGracefully()
  }
}

private final class OriginHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  var responseBytes: Int?
  init(responseBytes: Int?) { self.responseBytes = responseBytes }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if let count = responseBytes {
      responseBytes = nil
      let channel = context.channel
      channel.writeAndFlush(ByteBuffer(bytes: repeatElement(UInt8(37), count: count))).whenComplete
      { _ in
        channel.close(mode: .output, promise: nil)
      }
    } else {
      context.writeAndFlush(data, promise: nil)
    }
  }
}

private final class PendingStream: EgressStream, @unchecked Sendable {
  let loop: any EventLoop
  let connection: EventLoopPromise<Void>
  let closure: EventLoopPromise<Void>
  private let lock = NSLock()
  private let connectFails: Bool
  private let closesAutomatically: Bool
  private var requested = false
  private var completed = false
  var closeRequested: Bool { lock.withLock { requested } }
  var didClose: Bool { lock.withLock { completed } }
  var connected: EventLoopFuture<Void> { connection.futureResult }
  var closed: EventLoopFuture<Void> { closure.futureResult }
  init(loop: any EventLoop, connectFails: Bool = false, closesAutomatically: Bool = true) {
    self.loop = loop
    self.connectFails = connectFails
    self.closesAutomatically = closesAutomatically
    connection = loop.makePromise()
    closure = loop.makePromise()
    if connectFails { connection.fail(EgressConnectionError.resolutionFailed) }
  }
  func read(maxBytes: Int) -> EventLoopFuture<ByteBuffer> {
    loop.makeFailedFuture(EgressConnectionError.timeout)
  }
  func write(_ bytes: ByteBuffer) -> EventLoopFuture<Void> {
    loop.makeFailedFuture(EgressConnectionError.timeout)
  }
  func finishOutput() -> EventLoopFuture<Void> {
    loop.makeFailedFuture(EgressConnectionError.timeout)
  }
  func close() {
    guard !closeRequested else { return }
    lock.withLock { requested = true }
    if !connectFails { connection.fail(EgressConnectionError.timeout) }
    if closesAutomatically { completeClose() }
  }
  func completeClose() {
    loop.execute {
      guard !self.didClose else { return }
      self.lock.withLock { self.completed = true }
      self.closure.succeed(())
    }
  }
}

private final class StreamProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var streams = [PendingStream]()
  var values: [PendingStream] { lock.withLock { streams } }
  func append(_ stream: PendingStream) { lock.withLock { streams.append(stream) } }
}

private final class TestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

#if canImport(Darwin)
  private final class SlowUploadHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var received = 0
    private var closed = false
    func channelActive(context: ChannelHandlerContext) {
      let channel = context.channel
      channel.eventLoop.scheduleTask(in: .milliseconds(300)) { channel.read() }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      let bytes = unwrapInboundIn(data)
      #expect(bytes.readableBytesView.allSatisfy { $0 == 37 })
      received += bytes.readableBytes
    }
    func channelReadComplete(context: ChannelHandlerContext) {
      let channel = context.channel
      channel.eventLoop.scheduleTask(in: .milliseconds(2)) { if !self.closed { channel.read() } }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
      if let event = event as? ChannelEvent, event == .inputClosed {
        closed = true
        let channel = context.channel
        channel.writeAndFlush(ByteBuffer(string: "received:\(received)")).whenComplete { _ in
          channel.close(promise: nil)
        }
      }
    }
  }
#endif
