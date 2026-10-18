import Darwin
import Foundation
import Logging
import MCP

/// A private inherited socket carries standard newline-delimited MCP messages.
/// It owns its descriptor; it never opens a pathname, listener or privileged socket.
actor MCPInheritedSocketTransport: Transport {
  nonisolated let logger = Logger(
    label: "mcp.inherited-socket", factory: { _ in SwiftLogNoOpLogHandler() })
  private let handle: FileHandle
  private let maximumMessageBytes: Int
  private let maximumQueuedMessages: Int
  private let writeTimeout: Duration
  private let stream: AsyncThrowingStream<Data, Error>
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private var connected = false
  private var closed = false
  private var pending = Data()
  private var reader: Task<Void, Never>?
  private var writer: Task<Void, Error>?
  private var queuedWrites = 0

  init(
    takingOwnershipOf handle: FileHandle, maximumMessageBytes: Int = 1_048_576,
    maximumQueuedMessages: Int = 32, writeTimeout: Duration = .seconds(30)
  ) throws {
    guard (1...16_777_216).contains(maximumMessageBytes),
      (1...256).contains(maximumQueuedMessages), writeTimeout > .zero
    else { throw MCPError.invalidParams("Invalid inherited transport bounds.") }
    let descriptor = handle.fileDescriptor
    var info = stat()
    var type: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    var address = sockaddr_storage()
    var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let peerResult = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getpeername(descriptor, $0, &addressLength)
      }
    }
    guard descriptor >= 3, fstat(descriptor, &info) == 0,
      info.st_mode & S_IFMT == S_IFSOCK,
      getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) == 0,
      type == SOCK_STREAM, peerResult == 0, Int32(address.ss_family) == AF_UNIX
    else { throw MCPError.invalidParams("Host transport requires a connected Unix stream socket.") }
    let flags = fcntl(descriptor, F_GETFL)
    let fdFlags = fcntl(descriptor, F_GETFD)
    var noSigpipe: Int32 = 1
    guard flags >= 0, fdFlags >= 0,
      fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
      fcntl(descriptor, F_SETFD, fdFlags | FD_CLOEXEC) == 0,
      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, length) == 0
    else { throw MCPError.transportError(POSIXError(.EIO)) }
    self.handle = handle
    self.maximumMessageBytes = maximumMessageBytes
    self.maximumQueuedMessages = maximumQueuedMessages
    self.writeTimeout = writeTimeout
    (stream, continuation) = AsyncThrowingStream.makeStream(
      bufferingPolicy: .bufferingOldest(maximumQueuedMessages))
  }

  static func makePair() throws -> (FileHandle, FileHandle) {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw MCPError.transportError(POSIXError(.EMFILE))
    }
    let pair = (
      FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
      FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    )
    for descriptor in descriptors {
      let flags = fcntl(descriptor, F_GETFD)
      guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
        try? pair.0.close()
        try? pair.1.close()
        throw MCPError.transportError(POSIXError(.EIO))
      }
    }
    return pair
  }

  func connect() async throws {
    guard !closed else { throw MCPError.connectionClosed }
    guard !connected else { return }
    connected = true
    reader = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, await self.readAvailable() else { break }
        do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
      }
    }
  }

  func receive() -> AsyncThrowingStream<Data, Error> { stream }

  func send(_ message: Data) async throws {
    try Task.checkCancellation()
    guard connected, !closed else { throw MCPError.connectionClosed }
    guard !message.isEmpty, message.count <= maximumMessageBytes,
      !message.contains(0x0A), String(data: message, encoding: .utf8) != nil
    else { throw MCPError.invalidRequest("Invalid inherited MCP frame.") }
    guard queuedWrites < maximumQueuedMessages else {
      finish(throwing: MCPError.transportError(POSIXError(.ENOBUFS)))
      throw MCPError.connectionClosed
    }
    queuedWrites += 1
    defer { queuedWrites -= 1 }
    let predecessor = writer
    var line = message
    line.append(0x0A)
    let payload = line
    let deadline = ContinuousClock.now + writeTimeout
    let task = Task { [weak self] in
      _ = await predecessor?.result
      try Task.checkCancellation()
      guard let self else { throw MCPError.connectionClosed }
      try await self.write(payload, deadline: deadline)
    }
    writer = task
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func disconnect() async {
    finish()
    let reading = reader
    let writing = writer
    reader = nil
    writer = nil
    reading?.cancel()
    writing?.cancel()
    await reading?.value
    _ = await writing?.result
  }

  private func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {
    var offset = 0
    do {
      while offset < data.count {
        try Task.checkCancellation()
        guard connected, !closed else { throw MCPError.connectionClosed }
        guard ContinuousClock.now < deadline else {
          throw MCPError.transportError(POSIXError(.ETIMEDOUT))
        }
        let count = data.withUnsafeBytes {
          Darwin.send(
            handle.fileDescriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
        }
        if count > 0 {
          offset += count
        } else if count < 0 && errno == EINTR {
          continue
        } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
          try await Task.sleep(for: .milliseconds(5))
        } else {
          throw MCPError.transportError(POSIXError(.EPIPE))
        }
      }
    } catch {
      // A partly transmitted request cannot be retried on this byte stream.
      finish(throwing: error)
      throw error
    }
  }

  private func readAvailable() -> Bool {
    guard connected, !closed else { return false }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    let count = recv(handle.fileDescriptor, &buffer, buffer.count, 0)
    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return true }
    guard count > 0 else {
      finish(throwing: count == 0 && pending.isEmpty ? nil : MCPError.connectionClosed)
      return false
    }
    pending.append(contentsOf: buffer.prefix(count))
    while let newline = pending.firstIndex(of: 0x0A) {
      let message = Data(pending[..<newline])
      pending.removeSubrange(...newline)
      guard !message.isEmpty, message.count <= maximumMessageBytes,
        String(data: message, encoding: .utf8) != nil
      else {
        finish(throwing: MCPError.parseError("Invalid inherited MCP frame."))
        return false
      }
      switch continuation.yield(message) {
      case .enqueued: break
      case .dropped, .terminated:
        finish(throwing: MCPError.transportError(POSIXError(.ENOBUFS)))
        return false
      @unknown default:
        finish(throwing: MCPError.connectionClosed)
        return false
      }
    }
    guard pending.count <= maximumMessageBytes else {
      finish(throwing: MCPError.parseError("Inherited MCP message exceeds its byte limit."))
      return false
    }
    return true
  }

  private func finish(throwing error: Error? = nil) {
    guard !closed else { return }
    connected = false
    closed = true
    pending.removeAll(keepingCapacity: false)
    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
    try? handle.close()
  }
}
