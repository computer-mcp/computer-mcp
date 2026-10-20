import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
  import NIOConcurrencyHelpers
#endif

/// Opens headers before consuming the body, with each exchange owning its data task.
enum MCPHTTPResponseStream {
  #if canImport(FoundationNetworking)
    struct Bytes: AsyncSequence, Sendable {
      typealias Element = UInt8

      struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: AsyncThrowingStream<Data, any Error>.Iterator
        private var chunk = Data()
        private var index = 0

        init(chunks: AsyncThrowingStream<Data, any Error>.Iterator) {
          self.chunks = chunks
        }

        mutating func next() async throws -> UInt8? {
          try Task.checkCancellation()
          while index == chunk.endIndex {
            guard let next = try await chunks.next() else {
              try Task.checkCancellation()
              return nil
            }
            chunk = next
            index = chunk.startIndex
          }
          defer { index += 1 }
          return chunk[index]
        }
      }

      let task: URLSessionDataTask
      let chunks: AsyncThrowingStream<Data, any Error>

      func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator())
      }
    }

    static func open(for request: URLRequest, session: URLSession) async throws -> (
      Bytes, URLResponse
    ) {
      let (responses, response) = AsyncThrowingStream<URLResponse, any Error>.makeStream(
        bufferingPolicy: .bufferingOldest(1))
      let (chunks, body) = AsyncThrowingStream<Data, any Error>.makeStream()
      guard let delegate = session.delegate as? MCPHTTPRedirectPolicy else {
        throw MCPHTTPTransportError.invalidResponse
      }
      let task = session.dataTask(with: request)
      let identifier = task.taskIdentifier
      delegate.register(identifier: identifier, response: response, body: body)
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
          return (Bytes(task: task, chunks: chunks), response)
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
    }

    // Registration and cancellation race with callbacks on URLSession's serial delegate queue.
    private let exchanges = NIOLockedValueBox<[Int: Exchange]>([:])

    func register(
      identifier: Int,
      response: AsyncThrowingStream<URLResponse, any Error>.Continuation,
      body: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
      exchanges.withLockedValue { $0[identifier] = Exchange(response: response, body: body) }
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
      exchanges.withLockedValue { $0[dataTask.taskIdentifier] }?.body.yield(data)
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
