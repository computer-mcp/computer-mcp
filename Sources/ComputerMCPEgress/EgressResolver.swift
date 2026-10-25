import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

package protocol EgressResolving: Sendable {
  func resolve(host: String, port: UInt16) throws -> [SocketAddress]
}

package struct SystemEgressResolver: EgressResolving {
  package init() {}

  package func resolve(host: String, port: UInt16) throws -> [SocketAddress] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    #if canImport(Darwin)
      hints.ai_socktype = SOCK_STREAM
    #else
      hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #endif
    hints.ai_protocol = Int32(IPPROTO_TCP)
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let first = result else { throw EgressConnectionError.resolutionFailed }
    defer { freeaddrinfo(first) }
    var addresses = [SocketAddress]()
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let entry = cursor {
      defer { cursor = entry.pointee.ai_next }
      guard let raw = entry.pointee.ai_addr else { continue }
      switch entry.pointee.ai_family {
      case AF_INET:
        let value = UnsafeRawPointer(raw).load(as: sockaddr_in.self)
        addresses.append(SocketAddress(value, host: host))
      case AF_INET6:
        let value = UnsafeRawPointer(raw).load(as: sockaddr_in6.self)
        addresses.append(SocketAddress(value, host: host))
      default: continue
      }
      guard addresses.count <= 64 else { throw EgressConnectionError.resolutionFailed }
    }
    guard !addresses.isEmpty else { throw EgressConnectionError.resolutionFailed }
    return addresses
  }
}

enum EgressConnectionError: Error {
  case resolutionFailed
  case resolverBusy
  case malformedRequest
  case bufferLimit
  case timeout
}

/// Bounded even after a client times out: a pending getaddrinfo keeps its reservation until return.
final class EgressResolutionPool: Sendable {
  private let pool = NIOThreadPool(numberOfThreads: 2)
  private let pending = NIOLockedValueBox(0)
  private let limit: Int

  init(limit: Int) {
    self.limit = limit
    pool.start()
  }

  func submit<Value: Sendable>(
    on eventLoop: any EventLoop, _ body: @escaping @Sendable () throws -> Value
  ) -> EventLoopFuture<Value> {
    let admitted = pending.withLockedValue { count in
      guard count < limit else { return false }
      count += 1
      return true
    }
    guard admitted else { return eventLoop.makeFailedFuture(EgressConnectionError.resolverBusy) }
    return pool.runIfActive(eventLoop: eventLoop) {
      defer { self.pending.withLockedValue { $0 -= 1 } }
      return try body()
    }
  }

  func shutdown() async throws { try await pool.shutdownGracefully() }
}
