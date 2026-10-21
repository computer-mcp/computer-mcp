import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

package struct URLSessionCIMDFetcher: CIMDFetching {
  package init() {}

  package func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
    #if os(macOS)
      guard url.scheme == "https", let host = url.host, url.user == nil, url.password == nil,
        url.fragment == nil, (1...OAuthLimits.metadataMaxBytes).contains(maxBytes), timeout > 0
      else { throw OAuthError.invalidClient }
      let started = Date()
      let port = url.port ?? 443
      let destination = try await Self.resolve(
        host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port,
        timeout: timeout)
      guard CIMDAddressPolicy.isPublic(destination) else { throw OAuthError.invalidClient }
      try Task.checkCancellation()
      let remaining = timeout - Date().timeIntervalSince(started)
      guard remaining > 0 else { throw OAuthError.invalidClient }
      let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      // URLSession owns TLS/SNI and certificate validation. CONNECT pins the checked
      // numeric address, so URLSession cannot resolve the name again after validation.
      let authority = "\(host):\(port)"
      let listener: Channel
      do {
        listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
          channel.eventLoop.scheduleTask(in: .milliseconds(Int64(remaining * 1_000))) {
            channel.close(promise: nil)
          }
          return channel.pipeline.addHandler(
            CIMDConnectHandler(
              destination: destination, authority: authority, timeout: remaining))
        }.bind(host: "127.0.0.1", port: 0).get()
      } catch {
        try? await group.shutdownGracefully()
        throw OAuthError.invalidClient
      }
      do {
        let result = try await Self.download(
          url, proxyPort: listener.localAddress!.port!,
          maxBytes: maxBytes, timeout: remaining)
        try? await listener.close()
        try? await group.shutdownGracefully()
        return result
      } catch {
        try? await listener.close()
        try? await group.shutdownGracefully()
        throw error
      }
    #else
      // Linux has no CIMD network adapter; injected identifiers still exercise the flow.
      throw OAuthError.networkUnavailable
    #endif
  }

  #if os(macOS)
    private static func resolve(host: String, port: Int, timeout: TimeInterval) async throws
      -> SocketAddress
    {
      let resolution = CIMDResolution()
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          resolution.install(continuation)
          DispatchQueue.global().async {
            resolution.complete(
              Result { try SocketAddress.makeAddressResolvingHost(host, port: port) })
          }
          DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            resolution.complete(.failure(OAuthError.invalidClient))
          }
        }
      } onCancel: {
        resolution.complete(.failure(CancellationError()))
      }
    }

    private static func download(_ url: URL, proxyPort: Int, maxBytes: Int, timeout: TimeInterval)
      async throws -> Data
    {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCredentialStorage = nil
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.timeoutIntervalForRequest = timeout
      configuration.timeoutIntervalForResource = timeout
      configuration.connectionProxyDictionary = [
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort,
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
        "ExceptionsList": [], "ExcludeSimpleHostnames": 0,
        "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
      ]
      let session = URLSession(
        configuration: configuration, delegate: CIMDSessionDelegate(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      let timeoutTask = Task {
        try await Task.sleep(for: .seconds(timeout))
        session.invalidateAndCancel()
      }
      defer { timeoutTask.cancel() }
      var request = URLRequest(url: url)
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        response.url == url,
        response.expectedContentLength <= maxBytes,
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";")
          .first?
          .trimmingCharacters(in: .whitespaces) == "application/json"
      else { throw OAuthError.invalidClient }
      var result = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard result.count < maxBytes else { throw OAuthError.invalidClient }
        result.append(byte)
      }
      return result
    }
  #endif
}

#if os(macOS)
  /// A canceled or timed-out DNS lookup can finish later; only one outcome may resume.
  private final class CIMDResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SocketAddress, any Error>?
    private var result: Result<SocketAddress, any Error>?

    func install(_ continuation: CheckedContinuation<SocketAddress, any Error>) {
      let completed: Result<SocketAddress, any Error>? = lock.withLock {
        if let result { return result }
        self.continuation = continuation
        return nil as Result<SocketAddress, any Error>?
      }
      if let completed { continuation.resume(with: completed) }
    }

    func complete(_ result: Result<SocketAddress, any Error>) {
      let continuation = lock.withLock {
        guard self.result == nil else {
          return nil as CheckedContinuation<SocketAddress, any Error>?
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        return continuation
      }
      continuation?.resume(with: result)
    }
  }

  private final class CIMDSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      completionHandler(
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
  }

  /// One CONNECT destination, selected before opening the local proxy. Handler state
  /// belongs to its event loop; no caller can supply a different address or authority.
  private final class CIMDConnectHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let destination: SocketAddress
    private let authority: String
    private let timeout: TimeInterval
    private var buffer = ByteBuffer()
    private var connecting = false
    private var upstream: Channel?

    init(
      destination: SocketAddress, authority: String, timeout: TimeInterval
    ) {
      self.destination = destination
      self.authority = authority
      self.timeout = timeout
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      var bytes = unwrapInboundIn(data)
      if let upstream {
        upstream.writeAndFlush(bytes, promise: nil)
        return
      }
      guard buffer.readableBytes + bytes.readableBytes <= 16 * 1_024 else {
        context.close(promise: nil)
        return
      }
      buffer.writeBuffer(&bytes)
      guard !connecting,
        let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes),
        let boundary = text.range(of: "\r\n\r\n")
      else { return }
      guard text.hasPrefix("CONNECT \(authority) HTTP/1.1\r\n") else {
        context.close(promise: nil)
        return
      }
      buffer.moveReaderIndex(forwardBy: text[..<boundary.upperBound].utf8.count)
      connecting = true
      let inbound = context.channel
      let bootstrap = ClientBootstrap(group: inbound.eventLoop)
        .channelOption(ChannelOptions.autoRead, value: false)
        .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .connectTimeout(.milliseconds(Int64(timeout * 1_000)))
        .channelInitializer { channel in
          channel.pipeline.addHandler(CIMDRelayHandler(peer: inbound))
        }
      bootstrap.connect(to: destination).whenComplete { result in
        switch result {
        case .success(let outbound):
          guard inbound.isActive else {
            outbound.close(promise: nil)
            return
          }
          self.upstream = outbound
          var reply = inbound.allocator.buffer(capacity: 40)
          reply.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
          inbound.writeAndFlush(reply, promise: nil)
          if self.buffer.readableBytes > 0 {
            outbound.writeAndFlush(self.buffer, promise: nil)
            self.buffer.clear()
          }
        case .failure: inbound.close(promise: nil)
        }
      }
    }

    func channelInactive(context: ChannelHandlerContext) { upstream?.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
      context.close(promise: nil)
    }
  }

  private final class CIMDRelayHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    init(peer: Channel) { self.peer = peer }
    func channelActive(context: ChannelHandlerContext) { context.read() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      let channel = context.channel
      peer.writeAndFlush(unwrapInboundIn(data)).whenComplete { result in
        switch result {
        case .success: channel.read()
        case .failure: channel.close(promise: nil)
        }
      }
    }
    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
      context.close(promise: nil)
    }
  }
#endif
