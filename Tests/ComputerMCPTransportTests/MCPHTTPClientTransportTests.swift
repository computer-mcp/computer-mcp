import ComputerMCPTestSupport
import Foundation
import MCP
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPTransport

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct MCPHTTPClientTransportTests {
  @Test
  func sseMessagesArriveBeforeTheServerCompletesTheResponse() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      let incoming = await transport.receive()
      let sending = Task { try await transport.send(Self.request("incremental", id: "chunks")) }
      let reading = Task {
        try await Self.withTimeout {
          var iterator = incoming.makeAsyncIterator()
          let first = try #require(try await iterator.next())
          let notification = try JSONDecoder().decode(JSONValue.self, from: first)
          #expect(notification.objectValue?["method"] == .string("notifications/progress"))
          #expect(notification.objectValue?["params"]?.objectValue?["message"] == .string("正在读取"))
          try Data().write(to: fixture.root.appendingPathComponent("release-chunks"))
          let last = try #require(try await iterator.next())
          let response = try JSONDecoder().decode(JSONValue.self, from: last)
          #expect(response.objectValue?["id"] == .string("chunks"))
          #expect(response.objectValue?["result"]?.objectValue?["completed"] == .bool(true))
        }
      }
      do {
        try await reading.value
        try await sending.value
        await transport.disconnect()
      } catch {
        sending.cancel()
        reading.cancel()
        await transport.disconnect()
        _ = await sending.result
        _ = await reading.result
        throw error
      }
    }
  }

  @Test
  func cancellationAfterAnSSEMessageClosesTheDataTask() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      let incoming = await transport.receive()
      let sending = Task {
        try await transport.send(Self.request("cancel-stream", id: "midstream"))
      }
      let reading = Task { try await Self.collect(incoming, count: 1) }
      do {
        let messages = try await reading.value
        #expect(messages.first?.objectValue?["method"] == .string("notifications/progress"))
        sending.cancel()
        await #expect(throws: (any Error).self) {
          try await sending.value
        }
        try await Self.waitForClosedStream("midstream", fixture: fixture)
        try await transport.send(Self.request("json", id: "after-cancellation"))
        #expect(try fixture.requests().filter { $0["id"] == .string("midstream") }.count == 1)
        await transport.disconnect()
      } catch {
        sending.cancel()
        reading.cancel()
        await transport.disconnect()
        _ = await sending.result
        _ = await reading.result
        throw error
      }
    }
  }

  @Test
  func httpErrorStatusIsReportedBeforeAnOpenBodyCompletes() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      do {
        await #expect(throws: MCPHTTPTransportError.httpStatus(503)) {
          try await Self.withTimeout {
            try await transport.send(Self.request("http-error", id: "unavailable"))
          }
        }
        try await Self.waitForClosedStream("unavailable", fixture: fixture)
        #expect(try fixture.requests().filter { $0["id"] == .string("unavailable") }.count == 1)
        await transport.disconnect()
      } catch {
        await transport.disconnect()
        throw error
      }
    }
  }

  @Test(arguments: ["server-close", "truncated"])
  func serverClosureEndsTheResponseWithoutReposting(method: String) async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      do {
        do {
          try await Self.withTimeout {
            try await transport.send(Self.request(method, id: "closed"))
          }
          Issue.record("The server closed before sending a JSON-RPC response.")
        } catch {
          if method == "server-close" {
            #expect(error as? MCPHTTPTransportError == .incompleteResponse)
          } else {
            #expect(error is URLError || error as? MCPHTTPTransportError == .incompleteResponse)
          }
        }
        #expect(try fixture.requests().filter { $0["id"] == .string("closed") }.count == 1)
        await transport.disconnect()
      } catch {
        await transport.disconnect()
        throw error
      }
    }
  }

  @Test
  func redirectsDoNotReplayRequestsOrForwardCredentials() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = MCPHTTPClientTransport(
        endpoint: fixture.endpoint.deletingLastPathComponent().appendingPathComponent("redirect"),
        streaming: false, bearerToken: { "fixture-token" })
      try await transport.connect()
      await #expect(throws: MCPHTTPTransportError.httpStatus(307)) {
        try await transport.send(Self.request("initialize", id: "redirect"))
      }
      await transport.disconnect()
      #expect(try fixture.requests().count == 1)
    }
  }

  private static func waitForClosedStream(_ id: String, fixture: HTTPStreamProcessFixture)
    async throws
  {
    try await withTimeout {
      let receipt = fixture.root.appendingPathComponent("closed-streams")
      while true {
        let closed =
          (try? String(contentsOf: receipt, encoding: .utf8))?
          .split(separator: "\n").map(String.init) ?? []
        if closed.contains(id) { return }
        try await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  private static func withTimeout<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw HTTPStreamTestError.timeout
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  @Test
  func protocolCancellationClosesItsResponseStreamWithoutEndingTheSession() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      try await transport.send(Self.request("initialize", id: "init"))
      let first = Task { try await transport.send(Self.request("never", id: "first")) }
      let sibling = Task { try await transport.send(Self.request("never", id: "sibling")) }
      do {
        try await fixture.waitForRequest(id: "first")
        try await fixture.waitForRequest(id: "sibling")
        try await transport.send(
          Data(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"first"}}"#
              .utf8))
        switch await first.result {
        case .success: Issue.record("Cancelled response stream unexpectedly completed.")
        case .failure(let error):
          #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        let closed = fixture.root.appendingPathComponent("closed-streams")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var receipts: [String] = []
        while ContinuousClock.now < deadline {
          receipts =
            (try? String(contentsOf: closed, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
          if receipts.contains("first") { break }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(receipts.contains("first"))
        #expect(!receipts.contains("sibling"))
        try await transport.send(Self.request("json", id: "still-connected"))
        let requests = try fixture.requests()
        #expect(requests.filter { $0["id"] == .string("first") }.count == 1)
        #expect(requests.filter { $0["rpc"] == .string("notifications/cancelled") }.count == 1)
        #expect(!requests.contains { $0["method"] == .string("DELETE") })
        sibling.cancel()
        _ = await sibling.result
        await transport.disconnect()
      } catch {
        first.cancel()
        sibling.cancel()
        await transport.disconnect()
        _ = await first.result
        _ = await sibling.result
        throw error
      }
    }
  }

  @Test
  func concurrentDisconnectSendsOneAuthenticatedSessionTermination() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      try await transport.send(Self.request("json", id: "session"))
      async let first: Void = transport.disconnect()
      async let second: Void = transport.disconnect()
      _ = await (first, second)
      await transport.disconnect()
      let deletions = try fixture.requests().filter { $0["method"] == .string("DELETE") }
      #expect(deletions.count == 1)
      #expect(deletions.first?["authorized"] == .bool(true))
      #expect(deletions.first?["session"] == .string("fixture-session"))
      #expect(deletions.first?["protocol"]?.stringValue != nil)
    }
  }

  @Test
  func concurrentPOSTRecoveryAndEventReconnectKeepIndependentCursors() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport()
      try await transport.connect()
      let incoming = await transport.receive()
      let collecting = Task { try await Self.collect(incoming, count: 6) }
      do {
        try await transport.send(Self.request("initialize", id: "init"))
        async let first: Void = transport.send(Self.request("resume", id: "a"))
        async let second: Void = transport.send(Self.request("resume", id: "b"))
        async let json: Void = transport.send(Self.request("json", id: "c"))
        _ = try await (first, second, json)
        let messages = try await collecting.value
        #expect(
          Set(messages.compactMap { $0.objectValue?["id"]?.stringValue }) == [
            "init", "a", "b", "c",
          ])
        #expect(
          messages.filter {
            $0.objectValue?["method"]?.stringValue == "notifications/tools/list_changed"
          }.count == 2)
        let requests = try fixture.requests()
        for id in ["a", "b"] {
          #expect(
            requests.filter { $0["method"] == .string("POST") && $0["id"] == .string(id) }.count
              == 1)
          #expect(
            requests.contains {
              $0["method"] == .string("GET") && $0["cursor"] == .string("request-\(id)")
            })
        }
        #expect(
          requests.contains {
            $0["method"] == .string("GET") && $0["cursor"] == .string("events-1")
          })
        #expect(
          !requests.contains {
            $0["method"] == .string("GET") && $0["cursor"] == .string("request-init")
          })
        #expect(requests.allSatisfy { $0["authorized"] == .bool(true) })
        #expect(
          requests.filter { $0["rpc"] != .string("initialize") }.allSatisfy {
            $0["session"] == .string("fixture-session") && $0["protocol"] == .string("2025-03-26")
          })
        await transport.disconnect()
      } catch {
        collecting.cancel()
        await transport.disconnect()
        _ = await collecting.result
        throw error
      }
    }
  }

  @Test
  func cancellationClosesOnlyTheInFlightExchangeWithoutReposting() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      try await transport.send(Self.request("initialize", id: "init"))
      let pending = Task { try await transport.send(Self.request("never", id: "cancelled")) }
      do {
        try await fixture.waitForRequest(id: "cancelled")
        pending.cancel()
        switch await pending.result {
        case .success: Issue.record("Cancelled exchange unexpectedly completed.")
        case .failure(let error):
          #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        try await transport.send(Self.request("json", id: "still-connected"))
        #expect(try fixture.requests().filter { $0["id"] == .string("cancelled") }.count == 1)
        await transport.disconnect()
      } catch {
        pending.cancel()
        await transport.disconnect()
        _ = await pending.result
        throw error
      }
    }
  }

  @Test
  func rejectedAuthenticationIsReportedWithoutAnAutomaticRetry() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = MCPHTTPClientTransport(endpoint: fixture.endpoint, streaming: false)
      try await transport.connect()
      await #expect(throws: MCPHTTPTransportError.httpStatus(401)) {
        try await transport.send(Self.request("initialize", id: "unauthorized"))
      }
      #expect(try fixture.requests().count == 1)
      await transport.disconnect()
    }
  }

  @Test
  func incompleteWriteResponseWithoutCursorIsNotExecutedAgain() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      try await transport.send(Self.request("initialize", id: "init"))
      await #expect(throws: MCPHTTPTransportError.incompleteResponse) {
        try await transport.send(Self.request("ambiguous", id: "write"))
      }
      #expect(try fixture.requests().filter { $0["id"] == .string("write") }.count == 1)
      await transport.disconnect()
    }
  }

  @Test
  func eventListenerDoesNotKeepAnAbandonedTransportAlive() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      var transport: MCPHTTPClientTransport? = fixture.transport()
      weak var weakTransport: MCPHTTPClientTransport?
      weakTransport = transport
      try await transport?.connect()
      try await transport?.send(Self.request("initialize", id: "init"))
      transport = nil
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while weakTransport != nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(weakTransport == nil)
      await weakTransport?.disconnect()
    }
  }

  private static func request(_ method: String, id: String) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":{}}".utf8)
  }

  private static func collect(_ stream: AsyncThrowingStream<Data, any Error>, count: Int)
    async throws -> [JSONValue]
  {
    try await withThrowingTaskGroup(of: [JSONValue].self) { group in
      group.addTask {
        var result: [JSONValue] = []
        for try await data in stream {
          result.append(try JSONDecoder().decode(JSONValue.self, from: data))
          if result.count == count { return result }
        }
        return result
      }
      group.addTask {
        try await Task.sleep(for: .seconds(10))
        throw HTTPStreamTestError.timeout
      }
      defer { group.cancelAll() }
      return try await group.next() ?? []
    }
  }
}

extension HTTPStreamProcessFixture {
  func transport(streaming: Bool = true) -> MCPHTTPClientTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 15
    return MCPHTTPClientTransport(
      endpoint: endpoint, configuration: configuration, streaming: streaming,
      requestModifier: { request in
        var request = request
        request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        return request
      })
  }

}
