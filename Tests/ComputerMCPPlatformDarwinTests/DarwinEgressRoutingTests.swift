import ComputerMCPPlatformDarwin
import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@Suite struct DarwinEgressRoutingTests {
  @Test func selectedRouteIncludesInterfaceIdentityAndAddresses() throws {
    let route = try DarwinEgressRouting().route(to: "127.0.0.1")
    #expect(route.interface == "lo0")
    #expect(route.interfaceIndex == if_nametoindex("lo0"))
    #expect(route.interfaceAddresses.contains("127.0.0.1"))
    #expect(route.isDirect)
    #expect(!route.isTunnel)
  }

  @Test func routeSocketObservesNotificationsAndStopsOnCancellation() async throws {
    let events = RouteEventCounter()
    let observation = try DarwinEgressRouting().observeChanges { events.append($0) }
    defer { observation.cancel() }
    // An ordinary RTM_GET broadcasts a notification without changing the host route table.
    // Production lookups use RTM_GET_SILENT so they cannot trigger recursive comparisons.
    try broadcastRouteQuery()
    for _ in 0..<200 {
      if events.changes > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(events.changes > 0)
    #expect(events.failures == 0)
    observation.cancel()
    let count = events.changes
    try broadcastRouteQuery()
    try await Task.sleep(for: .milliseconds(50))
    #expect(events.changes == count)
  }

  private func broadcastRouteQuery() throws {
    let descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    var destination = sockaddr_in()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    inet_pton(AF_INET, "127.0.0.1", &destination.sin_addr)
    var header = rt_msghdr()
    header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + MemoryLayout<sockaddr_in>.size)
    header.rtm_version = UInt8(RTM_VERSION)
    header.rtm_type = UInt8(RTM_GET)
    header.rtm_addrs = RTA_DST
    header.rtm_seq = 1
    header.rtm_pid = getpid()
    let request =
      withUnsafeBytes(of: header) { Data($0) } + withUnsafeBytes(of: destination) { Data($0) }
    let sent = request.withUnsafeBytes { write(descriptor, $0.baseAddress!, $0.count) }
    #expect(sent == request.count)
  }
}

private final class RouteEventCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = 0
  private var failed = 0
  var changes: Int { lock.withLock { changed } }
  var failures: Int { lock.withLock { failed } }
  func append(_ event: EgressRouteEvent) {
    lock.withLock {
      switch event {
      case .changed: changed += 1
      case .unavailable: failed += 1
      }
    }
  }
}
