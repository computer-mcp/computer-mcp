import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Darwin
import Foundation

/// Directory watching survives atomic file replacement; unchanged fingerprints suppress events.
package final class DirectoryEventFileChangeMonitor: FileChangeMonitor, @unchecked Sendable {
  package let changes: AsyncStream<Void>
  private let source: DispatchSourceFileSystemObject
  private let timer: DispatchSourceTimer
  private let continuation: AsyncStream<Void>.Continuation
  private let stopped: Task<Void, Never>
  private let fileURL: URL
  private let lock = NSLock()
  private var fingerprint: FileFingerprint?

  package init(fileURL: URL) throws {
    self.fileURL = fileURL
    let descriptor = open(fileURL.deletingLastPathComponent().path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.changes = changes
    self.continuation = continuation
    let (closed, finished) = AsyncStream<Void>.makeStream()
    stopped = Task { for await _ in closed {} }
    let cleanup = DispatchGroup()
    cleanup.enter()
    cleanup.enter()
    let queue = DispatchQueue(label: "com.showxu.computer-mcp.file-watch", qos: .utility)
    fingerprint = FileFingerprint.current(of: fileURL)
    source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
      queue: queue)
    timer = DispatchSource.makeTimerSource(queue: queue)
    source.setEventHandler { [weak self] in self?.check() }
    source.setCancelHandler {
      Darwin.close(descriptor)
      cleanup.leave()
    }
    // Directory events do not cover every in-place file write or replaced parent.
    // This fallback reads metadata only; notifications still require a changed fingerprint.
    timer.schedule(
      deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(250))
    timer.setEventHandler { [weak self] in self?.check() }
    timer.setCancelHandler { cleanup.leave() }
    cleanup.notify(queue: queue) {
      continuation.finish()
      finished.finish()
    }
    source.resume()
    timer.resume()
    // A previous listener may have stopped before an editor saved this file.
    continuation.yield(())
  }

  deinit {
    source.cancel()
    timer.cancel()
  }

  package func close() async {
    source.cancel()
    timer.cancel()
    await stopped.value
  }

  private func check() {
    let current = FileFingerprint.current(of: fileURL)
    let changed = lock.withLock {
      guard current != fingerprint else { return false }
      fingerprint = current
      return true
    }
    if changed { continuation.yield(()) }
  }
}
