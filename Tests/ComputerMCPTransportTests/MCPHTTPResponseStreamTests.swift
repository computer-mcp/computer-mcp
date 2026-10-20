import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPTransport

#if canImport(FoundationNetworking)
  import FoundationNetworking

  @Suite(.nativeIntegration, .timeLimit(.minutes(1)))
  struct MCPHTTPResponseStreamTests {
    @Test
    func cancelledOpenDoesNotCreateADataTask() async throws {
      let session = Self.session()
      MCPHTTPResponseStream.invalidateAndCancel(session)
      let opening = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try await MCPHTTPResponseStream.open(
          for: URLRequest(url: URL(string: "http://127.0.0.1:1/")!), session: session)
      }
      await #expect(throws: CancellationError.self) { try await opening.value }
    }

    @Test
    func invalidatedSessionRejectsANewExchange() async throws {
      let session = Self.session()
      MCPHTTPResponseStream.invalidateAndCancel(session)
      await #expect(throws: (any Error).self) {
        _ = try await MCPHTTPResponseStream.open(
          for: URLRequest(url: URL(string: "http://127.0.0.1:1/")!), session: session)
      }
    }

    @Test
    func invalidationCancelsOpensWaitingForCacheLookup() async throws {
      let cache = DelayedURLCache()
      let session = Self.session(cache: cache)
      defer { MCPHTTPResponseStream.invalidateAndCancel(session) }
      try await Self.withTimeout(.seconds(2)) {
        try await withThrowingTaskGroup(of: Void.self) { group in
          for _ in 0..<2 {
            group.addTask {
              await #expect(throws: URLError(.cancelled)) {
                _ = try await MCPHTTPResponseStream.open(
                  for: URLRequest(url: URL(string: "http://127.0.0.1:1/")!), session: session)
              }
            }
          }
          var lookups = cache.lookups.makeAsyncIterator()
          var replies: [DelayedURLCache.Reply] = []
          defer {
            for reply in replies { reply(nil) }
          }
          for _ in 0..<2 {
            replies.append(try #require(await lookups.next()))
          }
          MCPHTTPResponseStream.invalidateAndCancel(session)
          try await group.waitForAll()
        }
      }
    }

    @Test
    func stalledConsumerFailsAndCancelsNearTheQueueBound() async throws {
      try await HTTPStreamProcessFixture.withFixture { fixture in
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        try await Self.withTimeout {
          let (bytes, response) = try await MCPHTTPResponseStream.open(
            for: Self.request("stalled", fixture: fixture), session: session)
          defer { bytes.task.cancel() }
          #expect((response as? HTTPURLResponse)?.statusCode == 200)

          while bytes.buffer.peakQueuedBytes <= MCPHTTPResponseStream.maximumQueuedBytes
            || bytes.task.state == .running
          {
            try await Task.sleep(for: .milliseconds(10))
          }
          let peak = bytes.buffer.peakQueuedBytes
          print("Linux HTTP stalled consumer peak queued bytes: \(peak)")
          #expect(peak > 32 * 1_024 * 1_024)
          #expect(peak <= 33 * 1_024 * 1_024)

          let result = try await Self.consume(bytes)
          #expect(result.error == .consumerTooSlow)
          #expect(result.count == peak)
          #expect(bytes.task.state == .canceling || bytes.task.state == .completed)

          let closed = fixture.root.appendingPathComponent("closed-streams")
          while (try? String(contentsOf: closed, encoding: .utf8).contains("bytes\n")) != true {
            try await Task.sleep(for: .milliseconds(10))
          }
        }
      }
    }

    @Test
    func keepingUpConsumerReceivesEveryByteInOrderBeyondTheQueueBound() async throws {
      try await HTTPStreamProcessFixture.withFixture { fixture in
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        try await Self.withTimeout {
          let (bytes, _) = try await MCPHTTPResponseStream.open(
            for: Self.request("ordered", fixture: fixture), session: session)
          defer { bytes.task.cancel() }
          let result = try await Self.consume(
            bytes, receipt: fixture.root.appendingPathComponent("received-blocks"))
          print("Linux HTTP keeping-up consumer peak queued bytes: \(bytes.buffer.peakQueuedBytes)")
          #expect(result.error == nil)
          #expect(result.count == 33 * 1_024 * 1_024)
          #expect(bytes.buffer.peakQueuedBytes <= 256 * 1_024)
        }
      }
    }

    private static func session(cache: URLCache? = nil) -> URLSession {
      let configuration = URLSessionConfiguration.ephemeral
      if let cache { configuration.urlCache = cache }
      configuration.timeoutIntervalForRequest = 5
      configuration.timeoutIntervalForResource = 45
      return URLSession(
        configuration: configuration, delegate: MCPHTTPRedirectPolicy(), delegateQueue: nil)
    }

    private static func request(_ path: String, fixture: HTTPStreamProcessFixture) -> URLRequest {
      var request = URLRequest(
        url: fixture.endpoint.deletingLastPathComponent().appendingPathComponent("bytes/\(path)"))
      request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
      return request
    }

    private static func consume(_ bytes: MCPHTTPResponseStream.Bytes, receipt: URL? = nil)
      async throws -> (count: Int, error: MCPHTTPTransportError?)
    {
      let blockSize = 256 * 1_024
      let pattern = Data((0..<blockSize).map { UInt8(truncatingIfNeeded: $0) })
      var count = 0
      var block = Data()
      var expected = pattern
      expected.replaceSubrange(0..<8, with: Data(count: 8))
      var failure: MCPHTTPTransportError?
      do {
        for try await byte in bytes {
          block.append(byte)
          count += 1
          if block.count == blockSize {
            #expect(block == expected)
            if let receipt {
              try String(count / blockSize).write(to: receipt, atomically: true, encoding: .utf8)
            }
            block.removeAll(keepingCapacity: true)
            var index = UInt64(count / blockSize).bigEndian
            withUnsafeBytes(of: &index) { expected.replaceSubrange(0..<8, with: $0) }
          }
        }
      } catch let error as MCPHTTPTransportError {
        failure = error
      }
      #expect(block == expected.prefix(block.count))
      return (count, failure)
    }

    private static func withTimeout<T: Sendable>(
      _ timeout: Duration = .seconds(45),
      _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
      try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
          try await Task.sleep(for: timeout)
          throw HTTPStreamTestError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
    }
  }

  // Subclass state is immutable; AsyncStream synchronizes the cache callback handoff.
  private final class DelayedURLCache: URLCache, @unchecked Sendable {
    typealias Reply = @Sendable (CachedURLResponse?) -> Void

    let lookups: AsyncStream<Reply>
    private let pendingLookups: AsyncStream<Reply>.Continuation

    init() {
      (lookups, pendingLookups) = AsyncStream<Reply>.makeStream()
      super.init(memoryCapacity: 1_024, diskCapacity: 0, diskPath: nil)
    }

    override func getCachedResponse(
      for dataTask: URLSessionDataTask, completionHandler: @escaping Reply
    ) {
      pendingLookups.yield(completionHandler)
    }
  }
#endif
