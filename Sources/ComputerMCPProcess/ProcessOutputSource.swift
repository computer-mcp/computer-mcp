import Foundation

#if os(Linux)
  import Glibc
#endif

/// Callers serialize lifecycle changes with their reader's lock or queue, apart from exclusive
/// initialization and deinitialization. The cancel handler retains this owner through deregistration and closes
/// the descriptor there. Every owner must cancel, including when it never resumes the source.
final class ProcessOutputSource: @unchecked Sendable {
  private let source: any DispatchSourceProtocol
  private(set) var isSuspended = true
  private var cancelled = false

  init(handle: FileHandle, queue: DispatchQueue, eventHandler: @escaping @Sendable () -> Void) {
    #if os(Linux)
      // Linux libdispatch can unregister an EPOLLHUP source on its target queue while the
      // manager traverses the same muxnote list (swift-corelibs-libdispatch#949). A timer
      // checks the nonblocking pipe without registering its descriptor with epoll.
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
      let descriptor = handle.fileDescriptor
      source.setEventHandler {
        var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        if poll(&readiness, 1, 0) > 0 { eventHandler() }
      }
    #else
      let source = DispatchSource.makeReadSource(
        fileDescriptor: handle.fileDescriptor, queue: queue)
      source.setEventHandler(handler: eventHandler)
    #endif
    self.source = source
    source.setCancelHandler { [self] in
      try? handle.close()
      withExtendedLifetime(self) {}
    }
  }

  func resume() {
    guard !cancelled, isSuspended else { return }
    isSuspended = false
    source.resume()
  }

  func suspend() {
    guard !cancelled, !isSuspended else { return }
    isSuspended = true
    source.suspend()
  }

  func cancel() {
    guard !cancelled else { return }
    cancelled = true
    if isSuspended {
      isSuspended = false
      source.resume()
    }
    source.cancel()
  }
}
