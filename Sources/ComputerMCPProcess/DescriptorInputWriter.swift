import ComputerMCPCore
import Foundation
import NIOConcurrencyHelpers

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Owns a nonblocking input descriptor. Close and write are serialized under the lock;
/// cancellation only retires admission, so an outstanding poll cannot write to a reused FD.
internal final class DescriptorInputWriter: ChildProcessInputWriting, Sendable {
  private struct State {
    var cancelled = false
    var closed = false
  }
  private let state = NIOLockedValueBox(State())
  private let handle: FileHandle
  private let blocking = BlockingOperationExecutor(label: "execution.input")

  init(handle: FileHandle) throws {
    self.handle = handle
    let flags = fcntl(handle.fileDescriptor, F_GETFL)
    guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  func cancel() { state.withLockedValue { $0.cancelled = true } }

  func write(_ bytes: [UInt8]) async throws -> Int {
    try await blocking.perform {
      var offset = 0
      while offset < bytes.count {
        let count: Int
        do {
          count = try self.state.withLockedValue { state -> Int in
            guard !state.cancelled, !state.closed else { throw CancellationError() }
            return try bytes.withUnsafeBytes { buffer in
              let count = systemWrite(
                self.handle.fileDescriptor, buffer.baseAddress!.advanced(by: offset),
                bytes.count - offset)
              if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
              }
              return count
            }
          }
        } catch {
          if offset > 0 { return offset }
          throw error
        }
        if count > 0 {
          offset += count
        } else {
          var descriptor = pollfd(
            fd: self.handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
          _ = poll(&descriptor, 1, 50)
        }
      }
      return offset
    }
  }

  func finish() async throws {
    try state.withLockedValue { state in
      guard !state.closed else { return }
      state.closed = true
      try handle.close()
    }
  }
}

#if canImport(Darwin)
  private let systemWrite = Darwin.write
#else
  private let systemWrite = Glibc.write
#endif
