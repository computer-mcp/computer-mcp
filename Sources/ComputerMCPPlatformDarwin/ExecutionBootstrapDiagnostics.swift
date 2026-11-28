import ComputerMCPSandbox
import Darwin
import Foundation

/// Drains bootstrap stderr independently of the caller's streams, retaining at most 4 KiB.
/// The bootstrap replaces stderr with the caller's descriptor before executing the target.
final class ExecutionBootstrapDiagnostics: @unchecked Sendable {
  private let pipe = Pipe()
  private let queue = DispatchQueue(label: "execution.bootstrap-diagnostics")
  private let source: any DispatchSourceRead
  private let descriptor: Int32
  private let buffer = Buffer()
  var writer: Int32 { pipe.fileHandleForWriting.fileDescriptor }

  init() throws {
    let handle = pipe.fileHandleForReading
    let descriptor = handle.fileDescriptor
    self.descriptor = descriptor
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot configure bootstrap diagnostics")
    }
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    self.source = source
    source.setEventHandler { [weak self] in
      guard let self else { return }
      if buffer.drain(descriptor) { source.cancel() }
    }
    source.setCancelHandler { try? handle.close() }
    source.resume()
  }

  func didSpawn() { try? pipe.fileHandleForWriting.close() }

  func failure(_ cause: Error, exit: ExecutionExit) -> any Error {
    // Ownership admission errors retain their original type and redaction boundary.
    guard let cause = cause as? ExecutionBootstrapHandshakeFailure else { return cause }
    let excerpt = queue.sync {
      _ = buffer.drain(descriptor)
      return String(decoding: buffer.bytes, as: UTF8.self)
        + (buffer.truncated ? " [truncated]" : "")
    }
    return ExecutionEnvironmentError.bootstrapFailed(
      status: exit.status, signal: exit.signal, reason: cause.reason, standardError: excerpt)
  }

  deinit { source.cancel() }

  /// Accessed only on the collector queue, including the final drain after child exit.
  private final class Buffer: @unchecked Sendable {
    var bytes = Data()
    var truncated = false

    private var finished = false

    func drain(_ descriptor: Int32) -> Bool {
      if finished { return true }
      var chunk = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = read(descriptor, &chunk, chunk.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          if count == 0 { finished = true }
          return finished
        }
        let retained = min(count, 4096 - bytes.count)
        bytes.append(contentsOf: chunk.prefix(retained))
        if retained < count { truncated = true }
      }
    }
  }
}

/// Only launch-channel diagnostics enter the bootstrap error envelope.
struct ExecutionBootstrapHandshakeFailure: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}
