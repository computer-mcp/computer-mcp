import Darwin
import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

package final class GatewaySocketServer: @unchecked Sendable {
  package typealias ServerFactory =
    @Sendable (GatewaySocketConnectionIdentity) async throws -> MCP.Server
  package typealias SessionFactory =
    @Sendable (GatewaySocketConnectionIdentity) async throws -> GatewaySocketServerSession
  package typealias ResponseObserver =
    @Sendable (Data, GatewaySocketConnectionIdentity) async -> Void

  private let configuration: GatewaySocketConfiguration
  private let logger: Logger
  private let sessionFactory: SessionFactory
  private let responseObserver: ResponseObserver?
  private let state = GatewaySocketServerState()

  package init(
    configuration: GatewaySocketConfiguration,
    logger: Logger = Logger(label: "computer-mcp.gateway-socket.server"),
    responseObserver: ResponseObserver? = nil,
    serverFactory: @escaping ServerFactory
  ) {
    self.configuration = configuration
    self.logger = logger
    self.responseObserver = responseObserver
    self.sessionFactory = { identity in
      GatewaySocketServerSession(server: try await serverFactory(identity))
    }
  }

  package init(
    configuration: GatewaySocketConfiguration,
    logger: Logger = Logger(label: "computer-mcp.gateway-socket.server"),
    responseObserver: ResponseObserver? = nil,
    sessionFactory: @escaping SessionFactory
  ) {
    self.configuration = configuration
    self.logger = logger
    self.responseObserver = responseObserver
    self.sessionFactory = sessionFactory
  }

  package func start() async throws {
    try configuration.validate()
    try await state.beginStarting()

    do {
      try GatewaySocketServerSecurity.prepareSocketPath(configuration: configuration)
    } catch {
      await state.failStart()
      throw error
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount))
    do {
      let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: configuration.backlog)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
        .childChannelOption(
          ChannelOptions.writeBufferWaterMark,
          value: ChannelOptions.Types.WriteBufferWaterMark(
            low: 64 * 1_024,
            high: 256 * 1_024
          )
        )
        .childChannelInitializer { channel in
          do {
            try GatewaySocketSecurity.validatePeer(
              channel: channel,
              expectedUserID: self.configuration.expectedUserID
            )
          } catch {
            return channel.eventLoop.makeFailedFuture(error)
          }

          let handler = GatewaySocketFrameHandler(
            configuration: self.configuration,
            maximumFrameBytes: self.configuration.maximumFrameBytes,
            maximumBufferedMessages: self.configuration.maximumBufferedMessages,
            activationHandler: { channel, handler in
              Task {
                await self.runConnection(channel: channel, handler: handler)
              }
            }
          )
          return channel.pipeline.addHandler(handler)
        }

      let listener = try await bootstrap.bind(
        unixDomainSocketPath: configuration.socketURL.path
      ).get()
      try GatewaySocketServerSecurity.secureBoundSocket(configuration: configuration)
      let identity = try GatewaySocketServerSecurity.identity(
        at: configuration.socketURL.path
      )
      try await state.markRunning(
        listener: listener,
        eventLoopGroup: group,
        socketIdentity: identity
      )
      logger.info(
        "Local gateway socket is listening",
        metadata: ["path": "\(configuration.socketURL.path)"]
      )
    } catch {
      await state.failStart()
      try? await group.shutdownGracefully()
      GatewaySocketServerSecurity.removeSocketIfOwned(
        configuration: configuration,
        expectedIdentity: nil
      )
      throw error
    }
  }

  package func waitUntilClosed() async {
    guard let listener = await state.listener() else {
      return
    }
    try? await listener.closeFuture.get()
  }

  package func stop() async {
    guard let snapshot = await state.beginStopping() else {
      return
    }

    if snapshot.listener.isActive {
      try? await snapshot.listener.close()
    }
    for session in snapshot.sessions {
      if session.channel.isActive {
        try? await session.channel.close()
      }
      await session.server.stop()
      await session.shutdown()
    }
    try? await snapshot.eventLoopGroup.shutdownGracefully()
    GatewaySocketServerSecurity.removeSocketIfOwned(
      configuration: configuration,
      expectedIdentity: snapshot.socketIdentity
    )
    await state.markStopped()
  }

  package func connectionCount() async -> Int {
    await state.connectionCount()
  }

  private func runConnection(
    channel: Channel,
    handler: GatewaySocketFrameHandler
  ) async {
    let identifier = UUID()
    do {
      let identity = try await connectionIdentity(from: handler)
      let session = try await sessionFactory(identity)
      let server = session.server
      let transport = GatewaySocketTransport(
        acceptedChannel: channel,
        frameHandler: handler,
        configuration: configuration,
        logger: logger,
        outboundObserver: { [responseObserver] data in
          await responseObserver?(data, identity)
        }
      )
      let normalizationTransport = MCPInitializeNormalizationTransport(
        wrapping: transport,
        logger: logger
      )

      guard
        await state.register(
          identifier: identifier,
          session: session,
          channel: channel
        )
      else {
        await transport.disconnect()
        await session.shutdown()
        return
      }

      do {
        try await server.start(transport: normalizationTransport)
        await server.waitUntilCompleted()
      } catch {
        logger.warning(
          "Local gateway socket connection ended with an error",
          metadata: ["error": "\(error)"]
        )
      }
      await server.stop()
      if let removed = await state.remove(identifier: identifier) {
        await removed.shutdown()
      }
    } catch {
      handler.finish(throwing: error)
    }

    if channel.isActive {
      try? await channel.close()
    }
  }

  private func connectionIdentity(
    from handler: GatewaySocketFrameHandler
  ) async throws -> GatewaySocketConnectionIdentity {
    try await withThrowingTaskGroup(
      of: GatewaySocketConnectionIdentity.self
    ) { group in
      group.addTask {
        var iterator = handler.connectionIdentities.makeAsyncIterator()
        guard let identity = try await iterator.next() else {
          throw GatewaySocketError.authenticationFailed(
            "The connection closed before authentication."
          )
        }
        return identity
      }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw GatewaySocketError.authenticationTimedOut
      }
      guard let identity = try await group.next() else {
        throw GatewaySocketError.authenticationFailed(
          "The connection closed before authentication."
        )
      }
      group.cancelAll()
      return identity
    }
  }
}

package struct GatewaySocketServerSession: Sendable {
  package let server: MCP.Server
  private let shutdownHandler: @Sendable () async -> Void

  package init(
    server: MCP.Server,
    shutdown: @escaping @Sendable () async -> Void = {}
  ) {
    self.server = server
    self.shutdownHandler = shutdown
  }

  package func shutdown() async {
    await shutdownHandler()
  }
}

private actor GatewaySocketServerState {
  struct Session: Sendable {
    let server: MCP.Server
    let channel: Channel
    let shutdown: @Sendable () async -> Void
  }

  struct StopSnapshot: Sendable {
    let listener: Channel
    let eventLoopGroup: MultiThreadedEventLoopGroup
    let socketIdentity: GatewaySocketFileIdentity
    let sessions: [Session]
  }

  private enum Lifecycle {
    case idle
    case starting
    case running
    case stopping
    case stopped
  }

  private var lifecycle = Lifecycle.idle
  private var listenerChannel: Channel?
  private var group: MultiThreadedEventLoopGroup?
  private var socketIdentity: GatewaySocketFileIdentity?
  private var sessions: [UUID: Session] = [:]

  func beginStarting() throws {
    guard lifecycle == .idle || lifecycle == .stopped else {
      throw GatewaySocketError.invalidConfiguration(
        "the local gateway socket server has already been started"
      )
    }
    lifecycle = .starting
  }

  func markRunning(
    listener: Channel,
    eventLoopGroup: MultiThreadedEventLoopGroup,
    socketIdentity: GatewaySocketFileIdentity
  ) throws {
    guard lifecycle == .starting else {
      throw GatewaySocketError.invalidConfiguration(
        "the local gateway socket server was stopped while starting"
      )
    }
    listenerChannel = listener
    group = eventLoopGroup
    self.socketIdentity = socketIdentity
    lifecycle = .running
  }

  func failStart() {
    listenerChannel = nil
    group = nil
    socketIdentity = nil
    lifecycle = .stopped
  }

  func listener() -> Channel? {
    listenerChannel
  }

  func register(
    identifier: UUID,
    session: GatewaySocketServerSession,
    channel: Channel
  ) -> Bool {
    guard lifecycle == .starting || lifecycle == .running else {
      return false
    }
    sessions[identifier] = Session(
      server: session.server,
      channel: channel,
      shutdown: session.shutdown
    )
    return true
  }

  func remove(identifier: UUID) -> Session? {
    sessions.removeValue(forKey: identifier)
  }

  func beginStopping() -> StopSnapshot? {
    guard
      lifecycle == .running,
      let listenerChannel,
      let group,
      let socketIdentity
    else {
      return nil
    }
    lifecycle = .stopping
    let snapshot = StopSnapshot(
      listener: listenerChannel,
      eventLoopGroup: group,
      socketIdentity: socketIdentity,
      sessions: Array(sessions.values)
    )
    sessions.removeAll()
    self.listenerChannel = nil
    self.group = nil
    self.socketIdentity = nil
    return snapshot
  }

  func markStopped() {
    lifecycle = .stopped
  }

  func connectionCount() -> Int {
    sessions.count
  }
}

private struct GatewaySocketFileIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
}

private enum GatewaySocketServerSecurity {
  static func prepareSocketPath(configuration: GatewaySocketConfiguration) throws {
    let directory = configuration.socketURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let directoryStatus = try GatewaySocketSecurity.fileStatus(at: directory.path)
    guard GatewaySocketSecurity.fileType(directoryStatus.st_mode) == S_IFDIR else {
      throw GatewaySocketError.invalidSocket(
        "\(directory.path) is not a directory"
      )
    }
    guard directoryStatus.st_uid == configuration.expectedUserID else {
      throw GatewaySocketError.socketUserMismatch(
        expected: configuration.expectedUserID,
        actual: directoryStatus.st_uid
      )
    }
    guard chmod(directory.path, 0o700) == 0 else {
      throw GatewaySocketError.ioError(
        operation: "chmod(\(directory.path))",
        code: errno
      )
    }

    var existingStatus = stat()
    guard lstat(configuration.socketURL.path, &existingStatus) == 0 else {
      if errno == ENOENT {
        return
      }
      throw GatewaySocketError.ioError(
        operation: "lstat(\(configuration.socketURL.path))",
        code: errno
      )
    }
    guard GatewaySocketSecurity.fileType(existingStatus.st_mode) == S_IFSOCK else {
      throw GatewaySocketError.invalidSocket(
        "refusing to replace non-socket path \(configuration.socketURL.path)"
      )
    }
    guard existingStatus.st_uid == configuration.expectedUserID else {
      throw GatewaySocketError.socketUserMismatch(
        expected: configuration.expectedUserID,
        actual: existingStatus.st_uid
      )
    }
    if try isSocketActive(path: configuration.socketURL.path) {
      throw GatewaySocketError.alreadyRunning(configuration.socketURL.path)
    }
    guard unlink(configuration.socketURL.path) == 0 || errno == ENOENT else {
      throw GatewaySocketError.ioError(
        operation: "unlink(\(configuration.socketURL.path))",
        code: errno
      )
    }
  }

  static func secureBoundSocket(configuration: GatewaySocketConfiguration) throws {
    guard chmod(configuration.socketURL.path, 0o600) == 0 else {
      throw GatewaySocketError.ioError(
        operation: "chmod(\(configuration.socketURL.path))",
        code: errno
      )
    }
    try GatewaySocketSecurity.validateSocketFile(
      at: configuration.socketURL,
      expectedUserID: configuration.expectedUserID
    )
  }

  static func identity(at path: String) throws -> GatewaySocketFileIdentity {
    let status = try GatewaySocketSecurity.fileStatus(at: path)
    return GatewaySocketFileIdentity(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino)
    )
  }

  static func removeSocketIfOwned(
    configuration: GatewaySocketConfiguration,
    expectedIdentity: GatewaySocketFileIdentity?
  ) {
    guard
      let status = try? GatewaySocketSecurity.fileStatus(
        at: configuration.socketURL.path
      ),
      GatewaySocketSecurity.fileType(status.st_mode) == S_IFSOCK,
      status.st_uid == configuration.expectedUserID
    else {
      return
    }
    if let expectedIdentity {
      let actual = GatewaySocketFileIdentity(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino)
      )
      guard actual == expectedIdentity else {
        return
      }
    }
    _ = unlink(configuration.socketURL.path)
  }

  private static func isSocketActive(path: String) throws -> Bool {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw GatewaySocketError.ioError(operation: "socket", code: errno)
    }
    defer { _ = close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maximumPathBytes = MemoryLayout.size(ofValue: address.sun_path) - 1
    guard pathBytes.count <= maximumPathBytes else {
      throw GatewaySocketError.invalidConfiguration(
        "socket path exceeds \(maximumPathBytes) UTF-8 bytes"
      )
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.initializeMemory(as: UInt8.self, repeating: 0)
      destination.copyBytes(from: pathBytes)
    }

    let addressLength = socklen_t(
      MemoryLayout<sa_family_t>.size + pathBytes.count + 1
    )
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength)
      }
    }
    if result == 0 {
      return true
    }
    let code = errno
    if code == ECONNREFUSED || code == ENOENT {
      return false
    }
    throw GatewaySocketError.ioError(operation: "connect(\(path))", code: code)
  }
}
