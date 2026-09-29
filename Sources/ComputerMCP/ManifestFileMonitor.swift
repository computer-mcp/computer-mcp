import Darwin
import Foundation

/// Directory watching survives atomic file replacement. Unrelated staging writes
/// do not trigger repeated discovery of the same rejected manifest.
final class ManifestFileMonitor: @unchecked Sendable {
  struct Fingerprint: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
  }

  let changes: AsyncStream<Void>
  private let source: DispatchSourceFileSystemObject
  private let timer: DispatchSourceTimer
  private let continuation: AsyncStream<Void>.Continuation
  private let stopped: Task<Void, Never>
  private let manifestURL: URL
  private let lock = NSLock()
  private var fingerprint: Fingerprint?

  init(manifestURL: URL) throws {
    self.manifestURL = manifestURL
    let descriptor = open(manifestURL.deletingLastPathComponent().path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw AtomicManifestStoreError.posix(operation: "watch manifest directory", code: errno)
    }
    let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.changes = changes
    self.continuation = continuation
    let (closed, finished) = AsyncStream<Void>.makeStream()
    stopped = Task { for await _ in closed {} }
    let cleanup = DispatchGroup()
    cleanup.enter()
    cleanup.enter()
    let queue = DispatchQueue(label: "com.showxu.computer-mcp.manifest-watch", qos: .utility)
    fingerprint = Self.fingerprint(manifestURL)
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
    // This fallback reads metadata only; discovery still runs only on a changed file.
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

  func close() async {
    source.cancel()
    timer.cancel()
    await stopped.value
  }

  private func check() {
    let current = Self.fingerprint(manifestURL)
    let changed = lock.withLock {
      guard current != fingerprint else { return false }
      fingerprint = current
      return true
    }
    if changed { continuation.yield(()) }
  }

  static func fingerprint(_ url: URL) -> Fingerprint? {
    var value = stat()
    guard stat(url.path, &value) == 0 else { return nil }
    return Fingerprint(
      device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
      modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
      changedSeconds: Int64(value.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
  }
}
