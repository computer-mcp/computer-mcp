// Connection lifecycle adapted from anthropics/sandbox-runtime, Apache-2.0.
// Revision aceba124fd725f4a43d7016ed3f5651d61f83115, src/sandbox/http-proxy.ts and socks-proxy.ts.
// Modified: per-execution dual-stack port leases, pinned system resolution, bounded demand-driven socket relay.
// See THIRD_PARTY_NOTICES.md and Licenses/sandbox-runtime-Apache-2.0.txt.
import ComputerMCPSandbox
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package struct EgressLimits: Sendable {
  package let connections: Int
  package let bufferBytes: Int
  package let handshakeTimeout: TimeAmount
  package let connectTimeout: TimeAmount
  package let idleTimeout: TimeAmount

  package init(
    connections: Int = 32, bufferBytes: Int = 32_768,
    handshakeTimeout: TimeAmount = .seconds(10), connectTimeout: TimeAmount = .seconds(15),
    idleTimeout: TimeAmount = .seconds(120)
  ) throws {
    guard (1...1024).contains(connections), (1024...1_048_576).contains(bufferBytes),
      [handshakeTimeout, connectTimeout, idleTimeout].allSatisfy({ $0.nanoseconds > 0 })
    else {
      throw ExecutionEnvironmentError.invalidConfiguration("Invalid egress resource limits")
    }
    self.connections = connections
    self.bufferBytes = bufferBytes
    self.handshakeTimeout = handshakeTimeout
    self.connectTimeout = connectTimeout
    self.idleTimeout = idleTimeout
  }
}

/// All mutable state belongs to the single event loop. Every listener belongs to one execution;
/// callers cannot choose identity through headers or SOCKS fields. Both loopback families are leased.
package final class EgressProxy: @unchecked Sendable {
  package let executionID: String
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private let policy: EgressPolicy
  private let routing: any EgressRouting
  private let resolver: any EgressResolving
  private let limits: EgressLimits
  private let onDenial: @Sendable (EgressDenial) -> Void
  private let resolutions: EgressResolutionPool
  private let routeChecks = EgressResolutionPool(limit: 1)
  private var observation: (any EgressRouteObservation)?
  private var routeRevision: UInt64 = 0
  private var checkingRoutes = false
  private var routeRecheckPending = false
  private var routeMonitoringAvailable = true
  private let dial: @Sendable (SocketAddress, EgressRoute, any EventLoop) throws -> any EgressStream
  private var listeners = [EgressListener]()
  private var connections = [ObjectIdentifier: ProxyConnection]()
  private var revoked = false
  private var released = false
  private var ports: SandboxProxyPorts?
  private let shutdownTask = NIOLockedValueBox<Task<Void, any Error>?>(nil)

  private init(
    executionID: String, policy: EgressPolicy, routing: any EgressRouting,
    resolver: any EgressResolving, limits: EgressLimits,
    dial:
      @escaping @Sendable (SocketAddress, EgressRoute, any EventLoop) throws -> any EgressStream,
    onDenial: @escaping @Sendable (EgressDenial) -> Void
  ) {
    self.executionID = executionID
    self.policy = policy
    self.routing = routing
    self.resolver = resolver
    self.limits = limits
    self.onDenial = onDenial
    self.dial = dial
    resolutions = EgressResolutionPool(limit: limits.connections)
  }

  package static func start(
    executionID: String, policy: EgressPolicy, routing: any EgressRouting,
    resolver: any EgressResolving = SystemEgressResolver(), limits: EgressLimits,
    dial:
      @escaping @Sendable (SocketAddress, EgressRoute, any EventLoop) throws -> any EgressStream = {
        try EgressSocket.connect(to: $0, route: $1, on: $2)
      },
    onDenial: @escaping @Sendable (EgressDenial) -> Void = { _ in }
  ) async throws -> EgressProxy {
    let proxy = EgressProxy(
      executionID: executionID, policy: policy, routing: routing,
      resolver: resolver, limits: limits, dial: dial, onDenial: onDenial)
    do {
      proxy.observation = try routing.observeChanges { [weak proxy] event in
        guard let proxy else { return }
        proxy.group.next().execute { proxy.routesChanged(event) }
      }
      try await proxy.bind()
      return proxy
    } catch {
      try? await proxy.releaseAfterExecutionEnds()
      throw error
    }
  }

  package func sandboxPorts() async throws -> SandboxProxyPorts {
    try await group.next().submit {
      guard !self.revoked, let ports = self.ports else {
        throw ExecutionEnvironmentError.unavailable("Execution proxy has been revoked")
      }
      return ports
    }.get()
  }

  /// Bind through the launcher's bindOwnership callback, before any process starts. The callback
  /// closes streams and refuses admissions at cancellation entry while keeping port leases owned.
  package func attach(to ownership: any ExecutionOwnership) {
    ownership.onCancellation { [self] in
      shutdownTask.withLockedValue { task in
        guard task == nil else { return }
        group.next().execute { self.stopServing() }
      }
    }
  }

  private func stopServing() {
    revoked = true
    for connection in Array(connections.values) { connection.close() }
  }

  /// Waits for admitted streams to close while retaining their execution's port leases.
  package func revoke() async throws {
    let closures = try await group.next().submit {
      self.revoked = true
      let connections = Array(self.connections.values)
      for connection in connections { connection.close() }
      return connections.map(\.closed)
    }.get()
    for closure in closures { try await closure.get() }
  }

  /// A failed confirmation leaves listeners and port leases owned by this proxy for retry.
  @discardableResult
  package func releaseAfterExecutionEnds(
    _ ownership: any ExecutionOwnership,
    until deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(120))
  ) async throws -> ExecutionExit {
    attach(to: ownership)
    let exit = try await ownership.wait(until: deadline)
    try await releaseAfterExecutionEnds()
    return exit
  }

  /// The execution owner calls this only after the complete sandbox process tree has ended.
  package func releaseAfterExecutionEnds() async throws {
    let task = shutdownTask.withLockedValue { existing in
      if let existing { return existing }
      let task = Task { try await self.releaseListeners() }
      existing = task
      return task
    }
    try await task.value
  }

  private func releaseListeners() async throws {
    let resources = try await group.next().submit {
      () -> ([EgressListener], [EventLoopFuture<Void>]) in
      guard !self.released else { return ([], []) }
      self.released = true
      self.observation?.cancel()
      self.observation = nil
      self.revoked = true
      let connections = Array(self.connections.values)
      for connection in connections { connection.close() }
      for listener in self.listeners { listener.close() }
      return (self.listeners, connections.map(\.closed))
    }.get()
    for listener in resources.0 { try await listener.closed.get() }
    for connection in resources.1 { try await connection.get() }
    try await resolutions.shutdown()
    try await routeChecks.shutdown()
    try await group.shutdownGracefully()
  }

  private func bind() async throws {
    try await group.next().submit { [self] in
      let loop = self.group.next()
      let accept: @Sendable (Int32) -> Void = { [weak self] descriptor in
        guard let self else {
          closeDescriptor(descriptor)
          return
        }
        guard !self.revoked, self.routeMonitoringAvailable,
          self.connections.count < self.limits.connections
        else {
          self.onDenial(
            EgressDenial(
              executionID: self.executionID, host: "", port: 0,
              reason: self.revoked
                ? .revoked : (self.routeMonitoringAvailable ? .connectionLimit : .routeUnavailable))
          )
          closeDescriptor(descriptor)
          return
        }
        do {
          let socket = try EgressSocket.accept(descriptor: descriptor, on: loop)
          let connection = ProxyConnection(socket: socket, proxy: self, loop: loop)
          self.connections[ObjectIdentifier(connection)] = connection
          connection.start()
        } catch {
          // Stream setup owns descriptor cleanup when it throws.
        }
      }
      let ipv4 = try EgressListener(
        address: SocketAddress(ipAddress: "127.0.0.1", port: 0), on: loop, accept: accept)
      self.listeners.append(ipv4)
      let ipv6 = try EgressListener(
        address: SocketAddress(ipAddress: "::1", port: Int(ipv4.port)), on: loop, accept: accept)
      self.listeners.append(ipv6)
      self.ports = try SandboxProxyPorts(http: ipv4.port, socks: ipv4.port)
    }.get()
  }

  fileprivate func retire(_ connection: ProxyConnection) {
    connections.removeValue(forKey: ObjectIdentifier(connection))
  }

  fileprivate func resolve(_ target: EgressTarget, on eventLoop: any EventLoop) -> EventLoopFuture<
    [SocketAddress]
  > {
    if revoked { return eventLoop.makeFailedFuture(denial(target, .revoked)) }
    guard policy.admits(host: target.host) else {
      return eventLoop.makeFailedFuture(denial(target, .hostNotAllowed))
    }
    return resolutions.submit(on: eventLoop) {
      let addresses = try self.resolver.resolve(host: target.host, port: target.port)
      for address in addresses {
        if let reason = self.policy.rejection(address: address, routing: self.routing) {
          throw self.denial(target, reason)
        }
      }
      return addresses
    }
  }

  fileprivate func validate(
    _ address: SocketAddress, target: EgressTarget, on eventLoop: any EventLoop
  ) -> EventLoopFuture<EgressRoute> {
    if revoked { return eventLoop.makeFailedFuture(denial(target, .revoked)) }
    return resolutions.submit(on: eventLoop) {
      switch self.policy.checkedRoute(address: address, routing: self.routing) {
      case .success(let route): return route
      case .failure(let reason): throw self.denial(target, reason)
      }
    }
  }

  private func routesChanged(_ event: EgressRouteEvent) {
    guard !released else { return }
    routeRevision &+= 1
    if case .unavailable = event {
      routeMonitoringAvailable = false
      for connection in Array(connections.values) {
        if let target = connection.target { report(denial(target, .routeUnavailable)) }
        connection.close()
      }
      return
    }
    recheckRoutes()
  }

  // Local network is a connection-time judgement. Sockets bind to that interface, and route
  // events compare the selected route and its interface addresses. The sandbox cannot mutate
  // host routes; this does not promise atomic enforcement across a host routing change.
  private func recheckRoutes() {
    guard !released, routeMonitoringAvailable else { return }
    if checkingRoutes {
      routeRecheckPending = true
      return
    }
    routeRecheckPending = false
    let revision = routeRevision
    let snapshots = connections.values.compactMap {
      connection -> (ProxyConnection, SocketAddress, EgressRoute)? in
      guard let address = connection.checkedAddress, let route = connection.checkedRoute else {
        return nil
      }
      return (connection, address, route)
    }
    guard !snapshots.isEmpty else { return }
    checkingRoutes = true
    routeChecks.submit(on: group.next()) {
      snapshots.map {
        connection, address, original -> (
          ProxyConnection, SocketAddress, EgressRoute, EgressDenial.Reason?
        ) in
        switch self.policy.checkedRoute(address: address, routing: self.routing) {
        case .success(let current):
          return (connection, address, original, current == original ? nil : .routeChanged)
        case .failure(let reason): return (connection, address, original, reason)
        }
      }
    }.whenComplete { result in
      self.checkingRoutes = false
      switch result {
      case .success(let decisions):
        for (connection, address, original, reason) in decisions where !connection.ended {
          guard connection.checkedAddress == address, connection.checkedRoute == original else {
            continue
          }
          if let reason, let target = connection.target {
            self.report(self.denial(target, reason))
            connection.close()
          }
        }
      case .failure:
        self.routesChanged(.unavailable)
      }
      if revision != self.routeRevision || self.routeRecheckPending { self.recheckRoutes() }
    }
  }

  fileprivate func report(_ denial: EgressDenial) { onDenial(denial) }
  private func denial(_ target: EgressTarget, _ reason: EgressDenial.Reason) -> EgressDenial {
    EgressDenial(executionID: executionID, host: target.host, port: target.port, reason: reason)
  }

  /// Policy, timers and stream demand belong to the proxy's event loop.
  fileprivate final class ProxyConnection: @unchecked Sendable {
    let socket: any EgressStream
    let proxy: EgressProxy
    let loop: any EventLoop
    let closure: EventLoopPromise<Void>
    var closed: EventLoopFuture<Void> { closure.futureResult }
    var handshake = EgressHandshake()
    var buffer = ByteBuffer()
    var target: EgressTarget?
    var upstream: (any EgressStream)?
    var pendingUpstream: (any EgressStream)?
    var connecting = false
    var ended = false
    var readClosed = false
    var upstreamReadClosed = false
    var outputClosed = false
    var upstreamOutputClosed = false
    var pendingToClient = 0
    var pendingToUpstream = 0
    var lastActivity = NIODeadline.now()
    var timeout: Scheduled<Void>?
    var idleCheck: Scheduled<Void>?
    var checkedAddress: SocketAddress?
    var checkedRoute: EgressRoute?

    init(socket: any EgressStream, proxy: EgressProxy, loop: any EventLoop) {
      self.socket = socket
      self.proxy = proxy
      self.loop = loop
      closure = loop.makePromise()
    }

    func start() {
      timeout = loop.scheduleTask(in: proxy.limits.handshakeTimeout) { self.close() }
      readClient()
    }

    func readClient() {
      guard !ended, !readClosed else { return }
      let remaining = proxy.limits.bufferBytes - (upstream == nil ? buffer.readableBytes : 0)
      guard remaining > 0 else {
        close()
        return
      }
      socket.read(maxBytes: remaining).whenComplete { result in
        guard !self.ended else { return }
        switch result {
        case .failure: self.close()
        case .success(var bytes):
          if bytes.readableBytes == 0 {
            self.readClosed = true
            if self.upstream != nil {
              self.finishWrites()
            } else if !self.connecting {
              self.close()
            }
          } else {
            self.lastActivity = .now()
            if let upstream = self.upstream {
              self.relay(bytes, to: upstream, toClient: false)
            } else {
              self.buffer.writeBuffer(&bytes)
              self.consumeHandshake()
            }
          }
        }
      }
    }

    func consumeHandshake() {
      guard !ended else { return }
      do {
        switch try handshake.consume(&buffer) {
        case .more: readClient()
        case .reply(let bytes):
          socket.write(ByteBuffer(bytes: bytes)).whenComplete { result in
            switch result {
            case .success: self.consumeHandshake()
            case .failure: self.close()
            }
          }
        case .connect(let target):
          self.target = target
          connecting = true
          timeout?.cancel()
          timeout = loop.scheduleTask(in: proxy.limits.connectTimeout) { self.close() }
          proxy.resolve(target, on: loop).flatMap { self.connect($0, target: target) }.whenComplete
          { result in
            guard !self.ended else {
              if case .success(let stream) = result { stream.close() }
              return
            }
            switch result {
            case .success(let stream): self.connected(stream, target: target)
            case .failure(let error): self.fail(error, target: target)
            }
          }
        }
      } catch { fail(error, target: EgressTarget(host: "invalid-host", port: 0)) }
    }

    func connect(_ addresses: [SocketAddress], target: EgressTarget) -> EventLoopFuture<
      any EgressStream
    > {
      guard !ended, !proxy.revoked, let address = addresses.first else {
        return loop.makeFailedFuture(EgressConnectionError.resolutionFailed)
      }
      let revision = proxy.routeRevision
      return proxy.validate(address, target: target, on: loop).flatMap {
        route -> EventLoopFuture<any EgressStream> in
        guard !self.ended, !self.proxy.revoked, self.proxy.routeMonitoringAvailable else {
          return self.loop.makeFailedFuture(EgressConnectionError.resolutionFailed)
        }
        self.checkedAddress = address
        self.checkedRoute = route
        if revision != self.proxy.routeRevision { self.proxy.recheckRoutes() }
        do {
          let stream = try self.proxy.dial(address, route, self.loop)
          self.pendingUpstream = stream
          return stream.connected.map { stream }
        } catch { return self.loop.makeFailedFuture(error) }
      }.flatMapError { error in
        let failedStream = self.pendingUpstream
        failedStream?.close()
        // Keep ownership through descriptor/source cleanup before another attempt or shutdown.
        let cleanup = failedStream?.closed ?? self.loop.makeSucceededVoidFuture()
        return cleanup.flatMap {
          self.pendingUpstream = nil
          if error is EgressDenial || addresses.count == 1 {
            return self.loop.makeFailedFuture(error)
          }
          return self.connect(Array(addresses.dropFirst()), target: target)
        }
      }
    }

    func connected(_ stream: any EgressStream, target: EgressTarget) {
      upstream = stream
      pendingUpstream = nil
      connecting = false
      timeout?.cancel()
      socket.write(ByteBuffer(bytes: handshake.response(host: target.host, success: true)))
        .whenComplete { result in
          guard !self.ended else { return }
          switch result {
          case .failure: self.close()
          case .success:
            if self.buffer.readableBytes > 0 {
              let bytes = self.buffer
              self.buffer.clear()
              self.relay(bytes, to: stream, toClient: false)
            } else {
              self.readClient()
            }
            self.readUpstream()
            self.checkIdle()
          }
        }
    }

    func readUpstream() {
      guard !ended, !upstreamReadClosed, let upstream else { return }
      upstream.read(maxBytes: proxy.limits.bufferBytes).whenComplete { result in
        guard !self.ended else { return }
        switch result {
        case .failure: self.close()
        case .success(let bytes):
          if bytes.readableBytes == 0 {
            self.upstreamReadClosed = true
            self.finishWrites()
          } else {
            self.relay(bytes, to: self.socket, toClient: true)
          }
        }
      }
    }

    func checkIdle() {
      let remaining = proxy.limits.idleTimeout - (NIODeadline.now() - lastActivity)
      guard remaining.nanoseconds > 0 else {
        close()
        return
      }
      idleCheck = loop.scheduleTask(in: remaining) {
        guard !self.ended else { return }
        self.checkIdle()
      }
    }

    func relay(_ bytes: ByteBuffer, to destination: any EgressStream, toClient: Bool) {
      guard !ended else { return }
      let count = bytes.readableBytes
      let pending = toClient ? pendingToClient : pendingToUpstream
      guard pending + count <= proxy.limits.bufferBytes else {
        close()
        return
      }
      if toClient { pendingToClient += count } else { pendingToUpstream += count }
      lastActivity = .now()
      destination.write(bytes).whenComplete { result in
        if toClient { self.pendingToClient -= count } else { self.pendingToUpstream -= count }
        guard !self.ended else { return }
        switch result {
        case .success:
          self.lastActivity = .now()
          self.finishWrites()
          if toClient { self.readUpstream() } else { self.readClient() }
        case .failure: self.close()
        }
      }
    }

    func finishWrites() {
      guard !ended, let upstream else { return }
      if readClosed, pendingToUpstream == 0, !upstreamOutputClosed {
        upstreamOutputClosed = true
        upstream.finishOutput().whenFailure { _ in self.close() }
      }
      if upstreamReadClosed, pendingToClient == 0, !outputClosed {
        outputClosed = true
        socket.finishOutput().whenFailure { _ in self.close() }
      }
      if readClosed, upstreamReadClosed, pendingToClient == 0, pendingToUpstream == 0 { close() }
    }

    func fail(_ error: any Error, target: EgressTarget) {
      if let denial = error as? EgressDenial { proxy.report(denial) }
      socket.write(
        ByteBuffer(
          bytes: handshake.response(
            host: target.host, success: false, policyDenied: error is EgressDenial))
      )
      .whenComplete { _ in self.close() }
    }

    func close() {
      guard !ended else { return }
      ended = true
      timeout?.cancel()
      idleCheck?.cancel()
      let streams = [socket, upstream, pendingUpstream].compactMap { $0 }
      for stream in streams { stream.close() }
      EventLoopFuture.andAllSucceed(streams.map(\.closed), on: loop).whenComplete { result in
        self.proxy.retire(self)
        self.closure.completeWith(result)
      }
    }
  }
}
