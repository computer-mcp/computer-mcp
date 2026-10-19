import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// File descriptor access and callback/task ownership are serialized by lock. Nonblocking reads
/// let shutdown drain a finite pipe without waiting on a descendant that retained stdout.
///
/// One read source watches the descriptor for the reader's lifetime. It is suspended while a
/// chunk is consumed, and the descriptor is closed only by its cancel handler, after the
/// source no longer monitors it.
internal final class ProcessOutputReader: @unchecked Sendable {
  private let handle: FileHandle
  private let consume: @Sendable (Data) async throws -> Void
  private let onError: @Sendable (Error) async -> Void
  private let completion = AsyncStream<Void>.makeStream()
  private let queue = DispatchQueue(label: "computer-mcp.process-output")
  private let lock = NSLock()
  private var stopped = false
  private var source: DispatchSourceRead?
  private var suspended = false
  /// The read source was cancelled, or the descriptor closed without one.
  private var finished = false
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

  deinit {
    if !finished { finishSourceLocked() }
  }

  func start() {
    lock.withLock {
      guard !stopped, !finished, source == nil else { return }
      let source = DispatchSource.makeReadSource(
        fileDescriptor: handle.fileDescriptor, queue: queue)
      source.setEventHandler { [weak self] in self?.consumeAvailableData() }
      source.setCancelHandler { [handle] in try? handle.close() }
      self.source = source
      source.resume()
    }
  }

  /// Wait for EOF, including writers inherited by descendants, and join the final consumer.
  func waitForEnd() async {
    for await _ in completion.stream {}
    await stop(drainRemainingOutput: false)
  }

  func stop(drainRemainingOutput: Bool) async {
    let task = lock.withLock { () -> Task<Void, Never>? in
      guard !stopped else { return consumptionTask }
      stopped = true
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
      finishSourceLocked()
      completion.continuation.finish()
      return consumptionTask
    }
    await task?.value
  }

  private func resume() {
    lock.withLock {
      guard !stopped, suspended, let source else { return }
      suspended = false
      source.resume()
    }
  }

  private func consumeAvailableData() {
    lock.withLock {
      guard !stopped, let source else { return }
      guard let data = readChunkLocked() else { return }
      guard !data.isEmpty else {
        stopped = true
        finishSourceLocked()
        completion.continuation.finish()
        return
      }
      source.suspend()
      suspended = true
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
        self?.resume()
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
      finishSourceLocked()
      completion.continuation.finish()
    }
  }

  /// Cancels the read source; its cancel handler closes the descriptor. A suspended source
  /// delivers its cancellation only after it resumes. Without a source, closes directly.
  private func finishSourceLocked() {
    guard !finished else { return }
    finished = true
    guard let source else {
      try? handle.close()
      return
    }
    self.source = nil
    if suspended {
      suspended = false
      source.resume()
    }
    source.cancel()
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
