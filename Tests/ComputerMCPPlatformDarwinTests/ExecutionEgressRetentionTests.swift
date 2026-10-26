import ComputerMCPEgress
import ComputerMCPPlatformDarwin
import ComputerMCPProcess
import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@Suite struct ExecutionEgressRetentionTests {
  @Test(arguments: [false, true])
  func failedCompletionRetainsBothProxyLeasesUntilSuccessfulRetry(lostSentinel: Bool) async throws {
    let fixture = try SimulatedExecution()
    let proxy = try await EgressProxy.start(
      executionID: "completion-retention", policy: .init(), routing: DarwinEgressRouting(),
      limits: .init())
    let ports = try await proxy.sandboxPorts()
    proxy.attach(to: fixture.owner)
    fixture.processes.mutate {
      $0.ignoreKill = true
      $0.sentinelMissing = lostSentinel
    }
    let failure = try await fixture.failure {
      _ = try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(750)))
      return try await proxy.releaseAfterExecutionEnds(fixture.owner)
    }
    #expect(!failure.members.isEmpty)
    try await proxy.revoke()
    _ = try await fixture.failure {
      try await proxy.releaseAfterExecutionEnds(
        failure.ownership, until: .now.advanced(by: .milliseconds(80)))
    }
    #expect(fixture.markerExists)
    for port in [ports.http, ports.socks] {
      for ipv6 in [false, true] { #expect(try bindError(port: port, ipv6: ipv6) == EADDRINUSE) }
    }
    fixture.clear()
    #expect(try await proxy.releaseAfterExecutionEnds(failure.ownership).status == 23)
    #expect(!fixture.markerExists)
    #expect(try await proxy.releaseAfterExecutionEnds(failure.ownership).status == 23)
    for port in [ports.http, ports.socks] {
      for ipv6 in [false, true] { #expect(try bindError(port: port, ipv6: ipv6) == 0) }
    }
  }

  @Test(arguments: [false, true])
  func cancellationRevokesConnectionsBeforeBlockedInspectionReturns(cancelWaiter: Bool) async throws
  {
    let gate = InspectionGate()
    defer { gate.release() }
    let fixture = try SimulatedExecution(configure: { $0.beforeList = { gate.block() } })
    let proxy = try await EgressProxy.start(
      executionID: "cancellation-entry", policy: .init(), routing: DarwinEgressRouting(),
      limits: .init())
    let ports = try await proxy.sandboxPorts()
    proxy.attach(to: fixture.owner)
    let active = try connectedSocket(port: ports.socks)
    defer { close(active) }
    var greeting: [UInt8] = [5, 1, 0]
    #expect(send(active, &greeting, greeting.count, 0) == greeting.count)
    var response = [UInt8](repeating: 0, count: 2)
    #expect(recv(active, &response, 2, MSG_WAITALL) == 2)
    #expect(response == [5, 0])
    fixture.rootExited()
    try await eventually { gate.entered }
    let cancellation = Task {
      try await fixture.failure {
        if cancelWaiter {
          return try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(400)))
        }
        return try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(400)))
      }
    }
    if cancelWaiter { cancellation.cancel() }
    #expect(recv(active, &response, 2, 0) == 0)
    let replacement = try connectedSocket(port: ports.http)
    defer { close(replacement) }
    #expect(recv(replacement, &response, 2, 0) == 0)
    #expect(fixture.processes.state.signals.isEmpty)
    let failure = try await cancellation.value
    #expect(fixture.markerExists)
    await #expect(throws: ExecutionEnvironmentError.self) { try await proxy.sandboxPorts() }
    for ipv6 in [false, true] { #expect(try bindError(port: ports.http, ipv6: ipv6) == EADDRINUSE) }
    fixture.clear()
    gate.release()
    try await eventually { !fixture.markerExists }
    #expect(try await proxy.releaseAfterExecutionEnds(failure.ownership).status == 23)
    #expect(try bindError(port: ports.http, ipv6: true) == 0)
  }

  @Test(arguments: ExecutionLaunchMethod.allCases)
  func cancellationDuringLaunchRevokesBeforeOwnershipReturns(method: ExecutionLaunchMethod)
    async throws
  {
    let files = try SeatbeltFixture()
    defer { files.remove() }
    let configuration = try files.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")],
      home: configuration.homeDirectory, temporary: configuration.temporaryDirectory,
      cache: configuration.cacheDirectory)
    let proxy = try await EgressProxy.start(
      executionID: "startup-cancellation", policy: .init(),
      routing: DarwinEgressRouting(), limits: .init())
    let port = try await proxy.sandboxPorts().socks
    let active = try connectedSocket(port: port)
    defer { close(active) }
    var greeting: [UInt8] = [5, 1, 0]
    #expect(send(active, &greeting, 3, 0) == 3)
    var response = [UInt8](repeating: 0, count: 2)
    #expect(recv(active, &response, 2, MSG_WAITALL) == 2)
    let gate = InspectionGate()
    defer { gate.release() }
    let launcher = try ExecutionLauncher(
      platform: DarwinExecutionPlatform(
        bootstrapExecutable: SeatbeltFixture.executionBootstrap))
    let launch = Task.detached {
      try await launcher.start(
        executable: .init("/bin/sleep"), arguments: ["20"],
        directory: configuration.worktree, environment: environment, mode: .sandbox(configuration),
        method: method,
        bindOwnership: {
          proxy.attach(to: $0)
          gate.block()
        })
    }
    try await eventually { gate.entered }
    launch.cancel()
    #expect(recv(active, &response, 2, 0) == 0)
    await #expect(throws: ExecutionEnvironmentError.self) { try await proxy.sandboxPorts() }
    gate.release()
    do {
      let owner = try await launch.value
      _ = try await owner.cancel()
      Issue.record("Expected cancelled startup")
    } catch is CancellationError {
      // The launcher collected every member before reporting task cancellation.
    } catch let failure as ExecutionCompletionFailure {
      _ = try await failure.ownership.wait()
    }
    try await proxy.releaseAfterExecutionEnds()
  }

  private func connectedSocket(port: UInt16) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if result != 0 { close(descriptor) }
    try #require(result == 0)
    return descriptor
  }

  private func bindError(port: UInt16, ipv6: Bool) throws -> Int32 {
    let descriptor = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let result: Int32
    if ipv6 {
      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = port.bigEndian
      address.sin6_addr = in6addr_loopback
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
      }
    } else {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    return result == 0 ? 0 : errno
  }
}
