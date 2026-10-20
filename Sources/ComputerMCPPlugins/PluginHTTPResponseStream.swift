import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
  import NIOConcurrencyHelpers
#endif

/// Opens headers before consuming the body; each request owns its cancellation lifetime.
enum PluginHTTPResponseStream {
  #if canImport(FoundationNetworking)
    fileprivate final class Buffer: Sendable {
      private let queued = NIOLockedValueBox(0)
      let limit: Int

      init(limit: Int) { self.limit = limit }

      func enqueue(_ count: Int) -> Bool {
        queued.withLockedValue {
          $0 += count
          return $0 <= limit
        }
      }

      func dequeue(_ count: Int) { queued.withLockedValue { $0 -= count } }
    }

    struct Bytes: AsyncSequence, Sendable {
      typealias Element = UInt8

      struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var chunks: AsyncThrowingStream<Data, any Error>.Iterator
        fileprivate let buffer: Buffer
        fileprivate let lifetime: Lifetime
        private var chunk = Data()
        private var index = 0

        fileprivate init(
          chunks: AsyncThrowingStream<Data, any Error>.Iterator, buffer: Buffer, lifetime: Lifetime
        ) {
          self.chunks = chunks
          self.buffer = buffer
          self.lifetime = lifetime
        }

        mutating func next() async throws -> UInt8? {
          try Task.checkCancellation()
          while index == chunk.endIndex {
            guard let next = try await chunks.next() else {
              try Task.checkCancellation()
              return nil
            }
            buffer.dequeue(next.count)
            chunk = next
            index = chunk.startIndex
          }
          defer { index += 1 }
          return chunk[index]
        }
      }

      let task: URLSessionDataTask
      fileprivate let lifetime: Lifetime
      fileprivate let chunks: AsyncThrowingStream<Data, any Error>
      fileprivate let buffer: Buffer

      func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator(), buffer: buffer, lifetime: lifetime)
      }
    }

    fileprivate final class Lifetime: Sendable {
      let session: URLSession
      let delegate: Delegate

      init(session: URLSession, delegate: Delegate) {
        self.session = session
        self.delegate = delegate
      }

      deinit {
        delegate.finish(URLError(.cancelled))
        session.invalidateAndCancel()
      }
    }

    fileprivate final class Delegate: NSObject, URLSessionDataDelegate, Sendable {
      let policy: GitHubPublicSessionDelegate
      let response: AsyncThrowingStream<URLResponse, any Error>.Continuation
      let body: AsyncThrowingStream<Data, any Error>.Continuation
      let buffer: Buffer
      private let finished = NIOLockedValueBox(false)

      init(
        policy: GitHubPublicSessionDelegate,
        response: AsyncThrowingStream<URLResponse, any Error>.Continuation,
        body: AsyncThrowingStream<Data, any Error>.Continuation, buffer: Buffer
      ) {
        self.policy = policy
        self.response = response
        self.body = body
        self.buffer = buffer
      }

      func finish(_ error: (any Error)?) {
        let first = finished.withLockedValue {
          if $0 { return false }
          $0 = true
          return true
        }
        guard first else { return }
        response.finish(throwing: error)
        body.finish(throwing: error)
      }

      func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
      ) {
        self.response.yield(response)
        self.response.finish()
        completionHandler(.allow)
      }

      func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.enqueue(data.count) else {
          finish(PluginCatalogError.responseTooLarge)
          dataTask.cancel()
          return
        }
        body.yield(data)
      }

      func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
      ) {
        finish(error)
      }

      func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
      ) {
        policy.urlSession(
          session, task: task, willPerformHTTPRedirection: response, newRequest: request,
          completionHandler: completionHandler)
      }

      func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
          @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
      ) {
        policy.urlSession(
          session, task: task, didReceive: challenge, completionHandler: completionHandler)
      }
    }

    static func open(
      for request: URLRequest, session: URLSession, delegate policy: GitHubPublicSessionDelegate,
      maximumBytes: Int
    ) async throws -> (Bytes, URLResponse) {
      try Task.checkCancellation()
      let (responses, response) = AsyncThrowingStream<URLResponse, any Error>.makeStream(
        bufferingPolicy: .bufferingOldest(1))
      let (chunks, body) = AsyncThrowingStream<Data, any Error>.makeStream()
      // A valid body can fit even if the producer finishes before the consumer resumes.
      let buffer = Buffer(limit: maximumBytes + 1)
      let delegate = Delegate(policy: policy, response: response, body: body, buffer: buffer)
      let session = URLSession(
        configuration: session.configuration, delegate: delegate, delegateQueue: nil)
      let task = session.dataTask(with: request)
      let lifetime = Lifetime(session: session, delegate: delegate)
      body.onTermination = { [weak task, weak delegate] _ in
        task?.cancel()
        delegate?.finish(URLError(.cancelled))
      }
      return try await withTaskCancellationHandler {
        do {
          try Task.checkCancellation()
          task.resume()
          var iterator = responses.makeAsyncIterator()
          guard let response = try await iterator.next() else {
            throw PluginCatalogError.invalidResponse
          }
          return (Bytes(task: task, lifetime: lifetime, chunks: chunks, buffer: buffer), response)
        } catch {
          task.cancel()
          delegate.finish(error)
          throw error
        }
      } onCancel: {
        task.cancel()
        delegate.finish(URLError(.cancelled))
      }
    }
  #else
    typealias Bytes = URLSession.AsyncBytes

    static func open(
      for request: URLRequest, session: URLSession, delegate: GitHubPublicSessionDelegate,
      maximumBytes: Int
    ) async throws -> (Bytes, URLResponse) {
      try await session.bytes(for: request, delegate: delegate)
    }
  #endif
}
