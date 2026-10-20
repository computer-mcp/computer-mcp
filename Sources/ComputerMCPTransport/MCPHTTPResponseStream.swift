import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
  import NIOConcurrencyHelpers
#endif

/// Opens headers before consuming the body, with each exchange owning its data task.
enum MCPHTTPResponseStream {
  #if canImport(FoundationNetworking)
    static let maximumQueuedBytes = 32 * 1_024 * 1_024

    final class Buffer: Sendable {
      private struct State: Sendable {
        var queuedBytes = 0
        var peakQueuedBytes = 0
      }

      private let state = NIOLockedValueBox(State())

      var peakQueuedBytes: Int {
        state.withLockedValue { $0.peakQueuedBytes }
      }

      func enqueue(_ count: Int) -> Bool {
        state.withLockedValue {
          $0.queuedBytes += count
          $0.peakQueuedBytes = max($0.peakQueuedBytes, $0.queuedBytes)
          return $0.queuedBytes > maximumQueuedBytes
        }
      }

      func dequeue(_ count: Int) {
        state.withLockedValue { $0.queuedBytes -= count }
      }
    }

    struct Bytes: AsyncSequence, Sendable {
      typealias Element = UInt8

      struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: AsyncThrowingStream<Data, any Error>.Iterator
        let buffer: Buffer
        private var chunk = Data()
        private var index = 0

        init(chunks: AsyncThrowingStream<Data, any Error>.Iterator, buffer: Buffer) {
          self.chunks = chunks
          self.buffer = buffer
        }

        mutating func next() async throws -> UInt8? {
          try Task.checkCancellation()
          while index == chunk.endIndex {
            guard let next = try await chunks.next() else {
              try Task.checkCancellation()
              return nil
            }
            // The iterator owns the current chunk; only waiting chunks count toward the bound.
            buffer.dequeue(next.count)
            chunk = next
            index = chunk.startIndex
          }
          defer { index += 1 }
          return chunk[index]
        }
      }

      let task: URLSessionDataTask
      let chunks: AsyncThrowingStream<Data, any Error>
      let buffer: Buffer

      func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator(), buffer: buffer)
      }
    }

    static func open(for request: URLRequest, session: URLSession) async throws -> (
      Bytes, URLResponse
    ) {
      let (responses, response) = AsyncThrowingStream<URLResponse, any Error>.makeStream(
        bufferingPolicy: .bufferingOldest(1))
      let (chunks, body) = AsyncThrowingStream<Data, any Error>.makeStream()
      let buffer = Buffer()
      guard let delegate = session.delegate as? MCPHTTPRedirectPolicy else {
        throw MCPHTTPTransportError.invalidResponse
      }
      let task = session.dataTask(with: request)
      let identifier = task.taskIdentifier
      delegate.register(identifier: identifier, response: response, body: body, buffer: buffer)
      body.onTermination = { [weak task, weak delegate] _ in
        task?.cancel()
        delegate?.finish(identifier: identifier, throwing: URLError(.cancelled))
      }
      return try await withTaskCancellationHandler {
        do {
          try Task.checkCancellation()
          task.resume()
          var iterator = responses.makeAsyncIterator()
          guard let response = try await iterator.next() else {
            try Task.checkCancellation()
            throw MCPHTTPTransportError.invalidResponse
          }
          return (Bytes(task: task, chunks: chunks, buffer: buffer), response)
        } catch {
          task.cancel()
          delegate.finish(identifier: identifier, throwing: error)
          throw error
        }
      } onCancel: {
        task.cancel()
        delegate.finish(identifier: identifier, throwing: URLError(.cancelled))
      }
    }
  #else
    typealias Bytes = URLSession.AsyncBytes

    static func open(for request: URLRequest, session: URLSession) async throws -> (
      Bytes, URLResponse
    ) {
      try await session.bytes(for: request)
    }
  #endif
}

/// Redirects must not replay an MCP write or forward credentials to a different endpoint.
final class MCPHTTPRedirectPolicy: NSObject, URLSessionDataDelegate, Sendable {
  #if canImport(FoundationNetworking)
    private struct Exchange: Sendable {
      let response: AsyncThrowingStream<URLResponse, any Error>.Continuation
      let body: AsyncThrowingStream<Data, any Error>.Continuation
      let buffer: MCPHTTPResponseStream.Buffer
    }

    // Registration and cancellation race with callbacks on URLSession's serial delegate queue.
    private let exchanges = NIOLockedValueBox<[Int: Exchange]>([:])

    func register(
      identifier: Int,
      response: AsyncThrowingStream<URLResponse, any Error>.Continuation,
      body: AsyncThrowingStream<Data, any Error>.Continuation,
      buffer: MCPHTTPResponseStream.Buffer
    ) {
      exchanges.withLockedValue {
        $0[identifier] = Exchange(response: response, body: body, buffer: buffer)
      }
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      let exchange = exchanges.withLockedValue { $0[dataTask.taskIdentifier] }
      exchange?.response.yield(response)
      exchange?.response.finish()
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard let exchange = exchanges.withLockedValue({ $0[dataTask.taskIdentifier] }) else {
        return
      }
      let exceeded = exchange.buffer.enqueue(data.count)
      exchange.body.yield(data)
      if exceeded {
        // Finish before cancellation so its callback cannot replace the typed failure.
        finish(identifier: dataTask.taskIdentifier, throwing: MCPHTTPTransportError.consumerTooSlow)
        dataTask.cancel()
      }
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      finish(identifier: task.taskIdentifier, throwing: error)
    }

    func finish(identifier: Int, throwing error: (any Error)?) {
      let exchange = exchanges.withLockedValue { $0.removeValue(forKey: identifier) }
      exchange?.response.finish(throwing: error)
      exchange?.body.finish(throwing: error)
    }
  #endif

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
