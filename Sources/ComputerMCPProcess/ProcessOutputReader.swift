import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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
    let (task, stopping) = lock.withLock { () -> (Task<Void, Never>?, Bool) in
      guard !stopped else { return (consumptionTask, false) }
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
      completion.continuation.finish()
      return (consumptionTask, true)
    }
    if stopping { closeAfterHandlers() }
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
        // This handler is running on the readability source that closing waits for.
        DispatchQueue.global(qos: .utility).async { self.closeAfterHandlers() }
        completion.continuation.finish()
        return
      }
      enqueueLocked(data)
    }
  }

  private func readChunkLocked() -> Data? {
    var bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = readDescriptor(handle.fileDescriptor, &bytes, bytes.count)
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
    let stopping = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      stopped = true
      handle.readabilityHandler = nil
      completion.continuation.finish()
      return true
    }
    if stopping { closeAfterHandlers() }
  }

  /// Closing a handle can wait for a readability handler that is still running, and the
  /// handler takes `lock`, so close only outside the lock and off the handler's queue.
  private func closeAfterHandlers() {
    try? handle.close()
  }
}

/// `read(2)`; the libc module name differs between platforms.
private func readDescriptor(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int)
  -> Int
{
  #if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
  #else
    Glibc.read(descriptor, buffer, count)
  #endif
}
