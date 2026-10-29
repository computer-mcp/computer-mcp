import ComputerMCPSandbox
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// A connected endpoint created by the host, never reconstructed from an FD or
/// launch environment. One launch consumes the endpoint even when startup fails.
package final class ProviderHostServiceChannel: @unchecked Sendable {
  private let lock = NSLock()
  private var child: FileHandle?
  package let metadata: String

  private init(child: FileHandle, metadata: String) {
    self.child = child
    self.metadata = metadata
  }

  package static func make(metadata: String) throws -> (
    host: FileHandle, channel: ProviderHostServiceChannel
  ) {
    guard !metadata.isEmpty, !metadata.contains("\0"), metadata.utf8.count <= 16_384 else {
      throw ExecutionEnvironmentError.invalidConfiguration("Invalid host service launch context")
    }
    #if canImport(Darwin)
      let type = SOCK_STREAM
    #else
      let type = Int32(SOCK_STREAM.rawValue)
    #endif
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, type, 0, &descriptors) == 0 else {
      throw ExecutionEnvironmentError.unavailable("Cannot create the host service channel")
    }
    let handles = descriptors.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) }
    do {
      for descriptor in descriptors {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
          throw ExecutionEnvironmentError.unavailable("Cannot protect the host service channel")
        }
      }
      return (handles[0], ProviderHostServiceChannel(child: handles[1], metadata: metadata))
    } catch {
      for handle in handles { try? handle.close() }
      throw error
    }
  }

  func takeEndpoint() throws -> FileHandle {
    try lock.withLock {
      guard let child else {
        throw ExecutionEnvironmentError.unavailable("The host service channel was already consumed")
      }
      self.child = nil
      return child
    }
  }

  package func close() {
    lock.withLock {
      try? child?.close()
      child = nil
    }
  }

  deinit { close() }
}
