import Darwin
import Foundation

/// File descriptor access and callback/task ownership are serialized by lock. Nonblocking reads
/// let shutdown drain a finite pipe without waiting on a descendant that retained stdout.
internal final class ProcessOutputReader: @unchecked Sendable {
  private let handle: FileHandle
  private let consume: @Sendable (Data) async throws -> Void
  private let onError: @Sendable (Error) async -> Void
  private let completion = AsyncStream<Void>.makeStream()
  private let lock = NSLock()
  private var stopped = false
  private var consumptionTask: Task<Void, Never>?

  init(
    handle: FileHandle,
    consume: @escaping @Sendable (Data) async throws -> Void,
    onError: @escaping @Sendable (Error) async -> Void
  ) throws {
    self.handle = handle
    self.consume = consume
    self.onError = onError
    let flags = fcntl(handle.fileDescriptor, F_GETFL)
    guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  func start() {
    arm()
  }

  /// Wait for EOF, including writers inherited by descendants, and join the final consumer.
  func waitForEnd() async {
    for await _ in completion.stream {}
    await stop(drainRemainingOutput: false)
  }

  func stop(drainRemainingOutput: Bool) async {
    let task = lock.withLock { () -> Task<Void, Never>? in
      if !stopped {
        stopped = true
        handle.readabilityHandler = nil
        if drainRemainingOutput {
          // A pipe holds fewer bytes than this budget. A concurrent writer cannot make drain infinite.
          var remaining = 1_048_576
          while remaining > 0, let data = readChunkLocked(), !data.isEmpty {
            remaining -= data.count
            enqueueLocked(data)
          }
          if remaining <= 0 {
            let previous = consumptionTask
            consumptionTask = Task { [onError] in
              await previous?.value
              await onError(POSIXError(.EOVERFLOW))
            }
          }
        }
        try? handle.close()
        completion.continuation.finish()
      }
      return consumptionTask
    }
    await task?.value
  }

  private func arm() {
    lock.withLock { armLocked() }
  }

  private func armLocked() {
    guard !stopped else { return }
    handle.readabilityHandler = { [weak self] handle in
      self?.consumeAvailableData(from: handle)
    }
  }

  private func consumeAvailableData(from handle: FileHandle) {
    lock.withLock {
      guard !stopped else { return }
      handle.readabilityHandler = nil
      guard let data = readChunkLocked() else {
        armLocked()
        return
      }
      guard !data.isEmpty else {
        stopped = true
        try? handle.close()
        completion.continuation.finish()
        return
      }
      enqueueLocked(data)
    }
  }

  private func readChunkLocked() -> Data? {
    var bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
      if count >= 0 { return Data(bytes.prefix(count)) }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
      let previous = consumptionTask
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      consumptionTask = Task { [onError] in
        await previous?.value
        await onError(error)
      }
      return Data()
    }
  }

  private func enqueueLocked(_ data: Data) {
    let previous = consumptionTask
    consumptionTask = Task { [weak self, consume, onError] in
      await previous?.value
      do {
        try await consume(data)
        self?.arm()
      } catch {
        await onError(error)
        self?.stopProducing()
      }
    }
  }

  private func stopProducing() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      handle.readabilityHandler = nil
      try? handle.close()
      completion.continuation.finish()
    }
  }
}
