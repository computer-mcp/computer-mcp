import Darwin
import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

package enum GatewaySocketError: Error, Equatable, LocalizedError, Sendable {
  case alreadyRunning(String)
  case backpressureExceeded(Int)
  case authenticationFailed(String)
  case authenticationTimedOut
  case credentialUnavailable(String)
  case invalidConfiguration(String)
  case invalidSocket(String)
  case ioError(operation: String, code: Int32)
  case messageTooLarge(actual: Int, maximum: Int)
  case notConnected
  case peerUserMismatch(expected: uid_t, actual: uid_t)
  case socketUserMismatch(expected: uid_t, actual: uid_t)

  package var errorDescription: String? {
    switch self {
    case .alreadyRunning(let path):
      "A local gateway is already listening at \(path)."
    case .backpressureExceeded(let limit):
      "The local gateway connection exceeded its \(limit)-message receive buffer."
    case .authenticationFailed(let message):
      "Local gateway socket authentication failed: \(message)"
    case .authenticationTimedOut:
      "Local gateway socket authentication timed out."
    case .credentialUnavailable(let message):
      message
    case .invalidConfiguration(let message):
      "Invalid local gateway socket configuration: \(message)"
    case .invalidSocket(let message):
      "Invalid local gateway socket: \(message)"
    case .ioError(let operation, let code):
      "\(operation) failed with POSIX error \(code): \(String(cString: strerror(code)))."
    case .messageTooLarge(let actual, let maximum):
      "Local gateway message is \(actual) bytes; the maximum is \(maximum) bytes."
    case .notConnected:
      "The local gateway socket transport is not connected."
    case .peerUserMismatch(let expected, let actual):
      "Local gateway peer user \(actual) does not match expected user \(expected)."
    case .socketUserMismatch(let expected, let actual):
      "Local gateway socket owner \(actual) does not match expected user \(expected)."
    }
  }
}

package struct GatewaySocketConfiguration: Equatable, Sendable {
  package static let defaultMaximumFrameBytes = 16 * 1_024 * 1_024
  package static let defaultBufferedMessages = 64

  package var socketURL: URL
  package var expectedUserID: uid_t
  package var tunnelCredentialFile: URL?
  package var clientIdentity: GatewaySocketClientIdentity
  package var maximumFrameBytes: Int
  package var maximumBufferedMessages: Int
  package var backlog: Int32

  package init(
    socketURL: URL,
    expectedUserID: uid_t = getuid(),
    tunnelCredentialFile: URL? = nil,
    clientIdentity: GatewaySocketClientIdentity = .localMCP,
    maximumFrameBytes: Int = Self.defaultMaximumFrameBytes,
    maximumBufferedMessages: Int = Self.defaultBufferedMessages,
    backlog: Int32 = 128
  ) {
    self.socketURL = socketURL
    self.expectedUserID = expectedUserID
    self.tunnelCredentialFile = tunnelCredentialFile
    self.clientIdentity = clientIdentity
    self.maximumFrameBytes = maximumFrameBytes
    self.maximumBufferedMessages = maximumBufferedMessages
    self.backlog = backlog
  }

  func validate() throws {
    guard socketURL.isFileURL else {
      throw GatewaySocketError.invalidConfiguration("socketURL must be a file URL")
    }
    guard !socketURL.path.isEmpty else {
      throw GatewaySocketError.invalidConfiguration("socket path must not be empty")
    }
    if let tunnelCredentialFile {
      guard tunnelCredentialFile.isFileURL, !tunnelCredentialFile.path.isEmpty else {
        throw GatewaySocketError.invalidConfiguration(
          "tunnelCredentialFile must be a non-empty file URL"
        )
      }
    }
    guard maximumFrameBytes > 0, maximumFrameBytes <= Int(UInt32.max) else {
      throw GatewaySocketError.invalidConfiguration(
        "maximumFrameBytes must be between 1 and \(UInt32.max)"
      )
    }
    guard maximumBufferedMessages > 0 else {
      throw GatewaySocketError.invalidConfiguration(
        "maximumBufferedMessages must be greater than zero"
      )
    }
    guard backlog > 0 else {
      throw GatewaySocketError.invalidConfiguration("backlog must be greater than zero")
    }
  }
}

/// An official MCP SDK transport carried over a local Unix-domain socket.
///
/// The socket protocol adds only a four-byte big-endian length prefix around each
/// complete MCP message. The payload is the exact JSON data supplied by the MCP SDK.
package actor GatewaySocketTransport: Transport {
  typealias OutboundObserver = @Sendable (Data) async -> Void

  package nonisolated let logger: Logger

  private let configuration: GatewaySocketConfiguration
  private var channel: Channel?
  private var eventLoopGroup: MultiThreadedEventLoopGroup?
  private var frameHandler: GatewaySocketFrameHandler?
  private var isConnected = false
  private let ownsEventLoopGroup: Bool
  private let outboundObserver: OutboundObserver?

  package init(
    configuration: GatewaySocketConfiguration,
    logger: Logger = Logger(label: "computer-mcp.gateway-socket.client")
  ) {
    self.configuration = configuration
    self.logger = logger
    self.ownsEventLoopGroup = true
    self.outboundObserver = nil
  }

  init(
    acceptedChannel: Channel,
    frameHandler: GatewaySocketFrameHandler,
    configuration: GatewaySocketConfiguration,
    logger: Logger,
    outboundObserver: OutboundObserver? = nil
  ) {
    self.configuration = configuration
    self.logger = logger
    self.channel = acceptedChannel
    self.frameHandler = frameHandler
    self.ownsEventLoopGroup = false
    self.outboundObserver = outboundObserver
  }

  package func connect() async throws {
    guard !isConnected else {
      return
    }
    try configuration.validate()

    if let channel, frameHandler != nil {
      guard channel.isActive else {
        throw GatewaySocketError.notConnected
      }
      isConnected = true
      return
    }

    try GatewaySocketSecurity.validateSocketFile(
      at: configuration.socketURL,
      expectedUserID: configuration.expectedUserID
    )

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    eventLoopGroup = group
    let handler = GatewaySocketFrameHandler(
      configuration: configuration,
      maximumFrameBytes: configuration.maximumFrameBytes,
      maximumBufferedMessages: configuration.maximumBufferedMessages
    )

    do {
      let bootstrap = ClientBootstrap(group: group)
        .channelOption(
          ChannelOptions.writeBufferWaterMark,
          value: ChannelOptions.Types.WriteBufferWaterMark(
            low: 64 * 1_024,
            high: 256 * 1_024
          )
        )
        .channelInitializer { channel in
          channel.pipeline.addHandler(handler)
        }

      let connected = try await bootstrap.connect(
        unixDomainSocketPath: configuration.socketURL.path
      ).get()
      try await connected.eventLoop.submit {
        try GatewaySocketSecurity.validatePeer(
          channel: connected,
          expectedUserID: self.configuration.expectedUserID
        )
      }.get()
      channel = connected
      frameHandler = handler
      isConnected = true
      let handshake = try GatewaySocketAuthenticator.clientHandshake(
        identity: configuration.clientIdentity,
        expectedUserID: configuration.expectedUserID
      )
      try await send(handshake)
    } catch {
      handler.finish(throwing: error)
      if let channel, channel.isActive {
        try? await channel.close()
      }
      channel = nil
      frameHandler = nil
      isConnected = false
      eventLoopGroup = nil
      try? await group.shutdownGracefully()
      throw error
    }
  }

  package func disconnect() async {
    guard isConnected || channel != nil || eventLoopGroup != nil else {
      return
    }
    isConnected = false

    let currentChannel = channel
    let currentFrameHandler = frameHandler
    channel = nil
    frameHandler = nil
    currentFrameHandler?.finish()
    if let currentChannel, currentChannel.isActive {
      try? await currentChannel.close()
    }

    if ownsEventLoopGroup, let group = eventLoopGroup {
      eventLoopGroup = nil
      try? await group.shutdownGracefully()
    }
  }

  package func send(_ data: Data) async throws {
    guard isConnected, let channel, channel.isActive else {
      throw GatewaySocketError.notConnected
    }
    guard data.count <= configuration.maximumFrameBytes else {
      throw GatewaySocketError.messageTooLarge(
        actual: data.count,
        maximum: configuration.maximumFrameBytes
      )
    }

    var buffer = channel.allocator.buffer(capacity: MemoryLayout<UInt32>.size + data.count)
    buffer.writeInteger(UInt32(data.count), endianness: .big)
    buffer.writeBytes(data)
    await outboundObserver?(data)
    try await channel.writeAndFlush(buffer)
  }

  package func receive() -> AsyncThrowingStream<Data, Swift.Error> {
    guard isConnected, let frameHandler else {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: GatewaySocketError.notConnected)
      }
    }
    if let terminalError = frameHandler.terminalReceiveError {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: terminalError)
      }
    }
    return frameHandler.messages
  }
}

final class GatewaySocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias ActivationHandler =
    @Sendable (Channel, GatewaySocketFrameHandler) -> Void

  let messages: AsyncThrowingStream<Data, Swift.Error>
  let connectionIdentities: AsyncThrowingStream<GatewaySocketConnectionIdentity, Swift.Error>

  private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
  private let identityContinuation:
    AsyncThrowingStream<GatewaySocketConnectionIdentity, Swift.Error>.Continuation
  private let activationHandler: ActivationHandler?
  private let configuration: GatewaySocketConfiguration
  private let maximumFrameBytes: Int
  private let maximumBufferedMessages: Int
  private var inboundBuffer = ByteBuffer()
  private var hasResolvedIdentity = false
  private let finishLock = NSLock()
  private var hasFinished = false
  private var finishError: Error?

  var terminalReceiveError: Error? {
    finishLock.withLock {
      guard hasFinished else {
        return nil
      }
      return finishError ?? GatewaySocketError.notConnected
    }
  }

  init(
    configuration: GatewaySocketConfiguration,
    maximumFrameBytes: Int,
    maximumBufferedMessages: Int,
    activationHandler: ActivationHandler? = nil
  ) {
    self.activationHandler = activationHandler
    self.configuration = configuration
    self.maximumFrameBytes = maximumFrameBytes
    self.maximumBufferedMessages = maximumBufferedMessages

    var capturedContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
    self.messages = AsyncThrowingStream(
      bufferingPolicy: .bufferingOldest(maximumBufferedMessages)
    ) { continuation in
      capturedContinuation = continuation
    }
    self.continuation = capturedContinuation

    var capturedIdentityContinuation:
      AsyncThrowingStream<GatewaySocketConnectionIdentity, Swift.Error>.Continuation!
    self.connectionIdentities = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation in
      capturedIdentityContinuation = continuation
    }
    self.identityContinuation = capturedIdentityContinuation
  }

  func channelActive(context: ChannelHandlerContext) {
    activationHandler?(context.channel, self)
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var incoming = unwrapInboundIn(data)
    inboundBuffer.writeBuffer(&incoming)

    do {
      try emitCompleteFrames(context: context)
    } catch {
      finish(throwing: error)
      context.close(promise: nil)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    finishAfterPeerClosure()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    finish(throwing: error)
    context.close(promise: nil)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    finishAfterPeerClosure()
  }

  private func finishAfterPeerClosure() {
    if activationHandler == nil {
      finish(throwing: GatewaySocketError.notConnected)
    } else {
      finish()
    }
  }

  func finish(throwing error: Error? = nil) {
    finishLock.lock()
    defer { finishLock.unlock() }
    guard !hasFinished else {
      return
    }
    hasFinished = true
    finishError = error
    if let error {
      continuation.finish(throwing: error)
      identityContinuation.finish(throwing: error)
    } else {
      continuation.finish()
      identityContinuation.finish()
    }
  }

  private func emitCompleteFrames(context: ChannelHandlerContext) throws {
    let headerBytes = MemoryLayout<UInt32>.size

    while inboundBuffer.readableBytes >= headerBytes {
      guard
        let length: UInt32 = inboundBuffer.getInteger(
          at: inboundBuffer.readerIndex,
          endianness: .big
        )
      else {
        return
      }
      let frameLength = Int(length)
      guard frameLength <= maximumFrameBytes else {
        throw GatewaySocketError.messageTooLarge(
          actual: frameLength,
          maximum: maximumFrameBytes
        )
      }
      guard inboundBuffer.readableBytes >= headerBytes + frameLength else {
        return
      }

      inboundBuffer.moveReaderIndex(forwardBy: headerBytes)
      let bytes = inboundBuffer.readBytes(length: frameLength) ?? []
      let frame = Data(bytes)
      if !hasResolvedIdentity {
        let resolution = try GatewaySocketAuthenticator.resolve(
          firstFrame: frame,
          expectedCredentialFile: configuration.tunnelCredentialFile,
          expectedUserID: configuration.expectedUserID
        )
        hasResolvedIdentity = true
        _ = identityContinuation.yield(resolution.identity)
        identityContinuation.finish()
        guard let forwarded = resolution.forwardFrame else {
          continue
        }
        try yieldMessage(forwarded, context: context)
        continue
      }
      try yieldMessage(frame, context: context)
    }

    inboundBuffer.discardReadBytes()
  }

  private func yieldMessage(
    _ data: Data,
    context: ChannelHandlerContext
  ) throws {
    switch continuation.yield(data) {
    case .enqueued:
      break
    case .dropped:
      throw GatewaySocketError.backpressureExceeded(maximumBufferedMessages)
    case .terminated:
      context.close(promise: nil)
      return
    @unknown default:
      throw GatewaySocketError.backpressureExceeded(maximumBufferedMessages)
    }
  }
}

enum GatewaySocketSecurity {
  static func validatePeer(channel: Channel, expectedUserID: uid_t) throws {
    let peerUserID = try channel.pipeline.syncOperations.withUnsafeTransportIfAvailable(
      of: NIOBSDSocket.Handle.self
    ) { descriptor in
      var effectiveUserID: uid_t = 0
      var effectiveGroupID: gid_t = 0
      guard getpeereid(descriptor, &effectiveUserID, &effectiveGroupID) == 0 else {
        throw GatewaySocketError.ioError(operation: "getpeereid", code: errno)
      }
      return effectiveUserID
    }

    guard let peerUserID else {
      throw GatewaySocketError.invalidSocket(
        "the NIO channel does not expose its Unix socket descriptor"
      )
    }
    guard peerUserID == expectedUserID else {
      throw GatewaySocketError.peerUserMismatch(
        expected: expectedUserID,
        actual: peerUserID
      )
    }
  }

  static func validateSocketFile(at url: URL, expectedUserID: uid_t) throws {
    let status = try fileStatus(at: url.path)
    guard fileType(status.st_mode) == S_IFSOCK else {
      throw GatewaySocketError.invalidSocket("\(url.path) is not a Unix socket")
    }
    guard status.st_uid == expectedUserID else {
      throw GatewaySocketError.socketUserMismatch(
        expected: expectedUserID,
        actual: status.st_uid
      )
    }
    guard status.st_mode & 0o077 == 0 else {
      throw GatewaySocketError.invalidSocket(
        "\(url.path) must not grant group or other permissions"
      )
    }
  }

  static func fileStatus(at path: String) throws -> stat {
    var status = stat()
    guard lstat(path, &status) == 0 else {
      throw GatewaySocketError.ioError(operation: "lstat(\(path))", code: errno)
    }
    return status
  }

  static func fileType(_ mode: mode_t) -> mode_t {
    mode & mode_t(S_IFMT)
  }
}
