import ComputerMCPSandbox
import Darwin
import Foundation

/// RTM_GET asks the kernel for the selected route, including its interface, without invoking a tool.
package struct DarwinEgressRouting: EgressRouting {
  package init() {}

  package func route(to numericAddress: String) throws -> EgressRoute {
    let descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
    guard descriptor >= 0 else { throw routeError() }
    defer { close(descriptor) }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    var destination = sockaddr_in()
    var destination6 = sockaddr_in6()
    let address: Data
    if inet_pton(AF_INET, numericAddress, &destination.sin_addr) == 1 {
      destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      destination.sin_family = sa_family_t(AF_INET)
      address = withUnsafeBytes(of: destination) { Data($0) }
    } else if inet_pton(AF_INET6, numericAddress, &destination6.sin6_addr) == 1 {
      destination6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      destination6.sin6_family = sa_family_t(AF_INET6)
      address = withUnsafeBytes(of: destination6) { Data($0) }
    } else {
      throw routeError()
    }
    var header = rt_msghdr()
    header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + address.count)
    header.rtm_version = UInt8(RTM_VERSION)
    // XNU route_private.h: RTM_GET_SILENT returns only to this socket (as RTM_GET).
    // Route queries must not generate change notifications on our observer.
    header.rtm_type = 0x11
    header.rtm_addrs = RTA_DST
    header.rtm_seq = Int32.random(in: 1...Int32.max)
    header.rtm_pid = getpid()
    let request = withUnsafeBytes(of: header) { Data($0) } + address
    let sent = request.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
    guard sent == request.count else { throw routeError() }
    let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let remaining = (deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000
      let ready = poll(&readiness, 1, Int32(max(1, remaining)))
      if ready < 0, errno == EINTR { continue }
      guard ready > 0 else { throw routeError() }
      var buffer = [UInt8](repeating: 0, count: 16_384)
      let count = read(descriptor, &buffer, buffer.count)
      guard count >= MemoryLayout<rt_msghdr>.size else { throw routeError() }
      let reply = buffer.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
      guard reply.rtm_seq == header.rtm_seq, reply.rtm_pid == header.rtm_pid,
        reply.rtm_type == RTM_GET
      else { continue }
      guard reply.rtm_errno == 0, reply.rtm_index != 0,
        reply.rtm_flags & (RTF_REJECT | RTF_BLACKHOLE) == 0
      else { throw routeError() }
      var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
      guard if_indextoname(UInt32(reply.rtm_index), &name) != nil else { throw routeError() }
      let interface = String(cString: name)
      let tunnel = ["utun", "tun", "ipsec", "ppp", "gif", "stf"].contains(
        where: interface.hasPrefix)
      return EgressRoute(
        interface: interface, interfaceIndex: UInt32(reply.rtm_index),
        interfaceAddresses: try interfaceAddresses(interface), isTunnel: tunnel,
        isDirect: reply.rtm_flags & RTF_GATEWAY == 0)
    }
    throw routeError()
  }

  private func routeError() -> ExecutionEnvironmentError {
    .unavailable("Cannot determine the current destination route")
  }

  package func observeChanges(_ handler: @escaping @Sendable (EgressRouteEvent) -> Void) throws
    -> any EgressRouteObservation
  {
    try DarwinRouteObservation(handler: handler)
  }

  private func interfaceAddresses(_ name: String) throws -> [String] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { throw routeError() }
    defer { freeifaddrs(first) }
    var cursor = first
    var addresses = [String]()
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      guard String(cString: entry.pointee.ifa_name) == name,
        let address = entry.pointee.ifa_addr,
        [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family))
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
          nil, 0, NI_NUMERICHOST) == 0
      else { throw routeError() }
      addresses.append(String(cString: host))
    }
    guard !addresses.isEmpty else { throw routeError() }
    return addresses
  }
}

/// A route socket reports both route and interface-address changes. Any notification triggers
/// comparison: XNU can silently drop messages on a full queue, so filtering by type loses changes.
private final class DarwinRouteObservation: EgressRouteObservation, @unchecked Sendable {
  private let source: any DispatchSourceRead
  private let lock = NSRecursiveLock()
  private var active = true

  init(handler: @escaping @Sendable (EgressRouteEvent) -> Void) throws {
    let descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
    guard descriptor >= 0 else {
      throw ExecutionEnvironmentError.unavailable("Cannot observe route changes")
    }
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
      fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
    else {
      close(descriptor)
      throw ExecutionEnvironmentError.unavailable("Cannot configure route observation")
    }
    source = DispatchSource.makeReadSource(
      fileDescriptor: descriptor,
      queue: DispatchQueue(label: "computer-mcp.egress.routes"))
    source.setCancelHandler { close(descriptor) }
    source.setEventHandler { [weak self] in
      var changed = false
      var bytes = [UInt8](repeating: 0, count: 65_536)
      for _ in 0..<128 {
        let count = recv(descriptor, &bytes, bytes.count, 0)
        if count < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { break }
          if errno == ENOBUFS {
            changed = true
            break
          }
          self?.emit(.unavailable, handler: handler)
          self?.cancel()
          return
        }
        guard count >= 4 else {
          self?.emit(.unavailable, handler: handler)
          self?.cancel()
          return
        }
        if bytes[2] != UInt8(RTM_VERSION) {
          self?.emit(.unavailable, handler: handler)
          self?.cancel()
          return
        }
        changed = true
      }
      if changed { self?.emit(.changed, handler: handler) }
    }
    source.resume()
  }

  private func emit(_ event: EgressRouteEvent, handler: @Sendable (EgressRouteEvent) -> Void) {
    lock.withLock { if active { handler(event) } }
  }

  // Synchronizing cancellation prevents callbacks from enqueueing work on a retired event loop.
  func cancel() {
    lock.withLock {
      active = false
      source.cancel()
    }
  }
  deinit { source.cancel() }
}
