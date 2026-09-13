import Foundation
import Testing
import os

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GatewayHTTPLifecycleTests {
  @Test
  func stopJoinsSessionDiscoveryBeforeShuttingDownTheRegistry() async throws {
    let registry = HTTPLifecycleRegistry(pauseDiscovery: true)
    let runtime = GatewayHTTPRuntime(
      configuration: .init(), registry: registry, host: "127.0.0.1", port: 0,
      publicBaseURL: nil)
    try await runtime.startListening()
    let port = try #require(await runtime.boundPort())
    let discovery = registry.discoveryEntered.stream()
    let request = Task {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
      request.timeoutInterval = 5
      request.httpBody = Data(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"lifecycle","version":"1"}}}"#
          .utf8)
      return try await URLSession.shared.data(for: request)
    }
    do {
      try await next(discovery)
      let stopping = Task { await runtime.stop() }
      await waitForListenerRemoval(runtime)
      // A new listener must not reuse the registry while the old discovery owns it.
      await #expect(throws: ConfigurationError.self) { try await runtime.startListening() }
      #expect(registry.shutdownCount == 0)
      registry.releaseDiscovery()
      await stopping.value
      _ = await request.result
      #expect(registry.shutdownCount == 1)
      #expect(!registry.shutdownDuringDiscovery)
      #expect(await runtime.activeSessionCount() == 0)
    } catch {
      registry.releaseDiscovery()
      request.cancel()
      await runtime.stop()
      _ = await request.result
      throw error
    }
  }

  @Test
  func concurrentStopAndListenerWaitJoinOneRegistryShutdown() async throws {
    let registry = HTTPLifecycleRegistry(pauseDiscovery: false)
    let runtime = GatewayHTTPRuntime(
      configuration: .init(), registry: registry, host: "127.0.0.1", port: 0,
      publicBaseURL: nil)
    try await runtime.startListening()
    let shutdown = registry.shutdownEntered.stream()
    let waiting = Task { await runtime.waitUntilClosed() }
    let first = Task { await runtime.stop() }
    do {
      try await next(shutdown)
      let second = Task { await runtime.stop() }
      await #expect(throws: ConfigurationError.self) { try await runtime.startListening() }
      await registry.releaseShutdown()
      await first.value
      await second.value
      await waiting.value
      await runtime.stop()
      #expect(registry.shutdownCount == 1)
      #expect(await runtime.boundPort() == nil)
    } catch {
      await registry.releaseShutdown()
      await first.value
      await waiting.value
      await runtime.stop()
      throw error
    }
  }

  private func next(_ events: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        var iterator = events.makeAsyncIterator()
        guard await iterator.next() != nil else { throw HTTPLifecycleError.timeout }
      }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw HTTPLifecycleError.timeout
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  private func waitForListenerRemoval(_ runtime: GatewayHTTPRuntime) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await runtime.boundPort() != nil, ContinuousClock.now < deadline {
      await Task.yield()
    }
    #expect(await runtime.boundPort() == nil)
  }
}

private enum HTTPLifecycleError: Error { case timeout }

private final class HTTPLifecycleRegistry: GatewayToolServing, Sendable {
  private struct State {
    var discovering = false
    var shutdownCount = 0
    var shutdownDuringDiscovery = false
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let pauseDiscovery: Bool
  private let discoveryGate = DispatchSemaphore(value: 0)
  private let shutdownGate = HTTPShutdownGate()
  let discoveryEntered = GatewayToolChangeBroadcaster()
  let shutdownEntered = GatewayToolChangeBroadcaster()

  init(pauseDiscovery: Bool) { self.pauseDiscovery = pauseDiscovery }
  var shutdownCount: Int { state.withLock { $0.shutdownCount } }
  var shutdownDuringDiscovery: Bool { state.withLock { $0.shutdownDuringDiscovery } }

  func listTools() throws -> [MCPTool] {
    if pauseDiscovery {
      state.withLock { $0.discovering = true }
      defer { state.withLock { $0.discovering = false } }
      discoveryEntered.send()
      guard discoveryGate.wait(timeout: .now() + 5) == .success else {
        throw HTTPLifecycleError.timeout
      }
    }
    return []
  }
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue { .null }
  func releaseDiscovery() { discoveryGate.signal() }
  func releaseShutdown() async { await shutdownGate.release() }
  func shutdown() async {
    state.withLock {
      $0.shutdownCount += 1
      $0.shutdownDuringDiscovery = $0.shutdownDuringDiscovery || $0.discovering
    }
    shutdownEntered.send()
    if !pauseDiscovery { await shutdownGate.wait() }
  }
}

private actor HTTPShutdownGate {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    released = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
