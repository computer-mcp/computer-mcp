import Darwin
import Foundation

/// Stops only the process owned by this validation run. Never waits indefinitely for reap.
package enum ValidationProcessCleanup {
  package static func stop(_ process: Process) throws {
    guard process.isRunning else { return }
    process.terminate()
    if waitForExit(process, seconds: 1) { return }
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    guard waitForExit(process, seconds: 2) else {
      throw ValidationProcessError.cleanupFailed(
        primary: nil,
        detail: "Owned process \(process.processIdentifier) did not exit after SIGKILL.")
    }
  }

  private static func waitForExit(_ process: Process, seconds: Int) -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while process.isRunning && ContinuousClock.now < deadline { usleep(10_000) }
    return !process.isRunning
  }
}

/// Nonblocking capture keeps both memory and final drain bounded, even if a descendant retains a pipe.
package final class ValidationPipeCapture: @unchecked Sendable {
  private let handle: FileHandle
  private let limit: Int
  package private(set) var data = Data()
  package private(set) var truncated = false
  package private(set) var reachedEOF = false

  package init(handle: FileHandle, limit: Int) throws {
    self.handle = handle
    self.limit = max(0, limit)
    let flags = fcntl(handle.fileDescriptor, F_GETFL)
    guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw ValidationProcessError.launchFailed("Could not configure validation output pipe.")
    }
  }

  // One owner drains this capture; callers join that owner before closing the handle.
  package func drain() throws {
    guard !reachedEOF else { return }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    for _ in 0..<16 {
      let count = read(handle.fileDescriptor, &buffer, buffer.count)
      if count == 0 {
        reachedEOF = true
        return
      }
      if count < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        if errno == EINTR { continue }
        throw ValidationProcessError.cleanupFailed(
          primary: nil, detail: "Validation output read failed (errno \(errno)).")
      }
      let available = max(0, limit - data.count)
      data.append(contentsOf: buffer.prefix(min(count, available)))
      truncated = truncated || count > available
    }
  }

  package func close() { try? handle.close() }
}
