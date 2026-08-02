import CryptoKit
import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

internal struct GatewayHTTPLimits: Sendable {
  static let v1 = GatewayHTTPLimits(
    maxHeaderBytes: 16 * 1_024,
    maxBodyBytes: 8 * 1_024 * 1_024,
    maxSessions: 128,
    sessionIdleTimeout: 15 * 60,
    cleanupInterval: 60
  )

  let maxHeaderBytes: Int
  let maxBodyBytes: Int
  let maxSessions: Int
  let sessionIdleTimeout: TimeInterval
  let cleanupInterval: TimeInterval

  init(
    maxHeaderBytes: Int = GatewayHTTPLimits.v1.maxHeaderBytes,
    maxBodyBytes: Int = GatewayHTTPLimits.v1.maxBodyBytes,
    maxSessions: Int = GatewayHTTPLimits.v1.maxSessions,
    sessionIdleTimeout: TimeInterval = GatewayHTTPLimits.v1.sessionIdleTimeout,
    cleanupInterval: TimeInterval = GatewayHTTPLimits.v1.cleanupInterval
  ) {
    precondition(maxHeaderBytes > 0)
    precondition(maxBodyBytes > 0)
    precondition(maxSessions > 0)
    precondition(sessionIdleTimeout > 0)
    precondition(cleanupInterval > 0)
    self.maxHeaderBytes = maxHeaderBytes
    self.maxBodyBytes = maxBodyBytes
    self.maxSessions = maxSessions
    self.sessionIdleTimeout = sessionIdleTimeout
    self.cleanupInterval = cleanupInterval
  }
}

internal final class GatewayHTTPRuntime: @unchecked Sendable {
  private let configuration: GatewayConfiguration
  private let registry: any GatewayToolServing
  private let host: String
  private let port: Int
  private let publicBaseURL: String?
  private let logger: Logger
  private let app: GatewayHTTPApp

  internal init(
    configuration: GatewayConfiguration,
    registry: any GatewayToolServing,
    host: String,
    port: Int,
    publicBaseURL: String?,
    accessToken: String? = nil,
    logger: Logger? = nil,
    limits: GatewayHTTPLimits = .v1
  ) {
    self.configuration = configuration
    self.registry = registry
    self.host = host
    self.port = port
    self.publicBaseURL = publicBaseURL
    let resolvedLogger = logger ?? Logger(label: "computer-mcp.http")
    self.logger = resolvedLogger
    self.app = GatewayHTTPApp(
      configuration: configuration,
      registry: registry,
      listeningPort: port,
      publicBaseURL: publicBaseURL,
      accessToken: accessToken,
      logger: resolvedLogger,
      limits: limits
    )
  }

  internal func start() async throws {
    try await startListening()
    await waitUntilClosed()
  }

  internal func startListening() async throws {
    try await app.startListening(host: host, port: port)
  }

  internal func waitUntilClosed() async {
    await app.waitUntilClosed()
  }

  internal func stop() async {
    await app.stop()
  }

  internal func activeSessionCount() async -> Int {
    await app.activeSessionCount()
  }
}

private actor GatewayHTTPApp {
  private struct SessionContext {
    let server: MCP.Server
    let transport: StatefulHTTPServerTransport
    var lastAccessedAt: Date
  }

  private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
  }

  private let configuration: GatewayConfiguration
  private let registry: any GatewayToolServing
  private let authenticator: HTTPBearerAuthenticator
  private let listeningPort: Int
  private let effectivePublicBaseURL: String?
  private let logger: Logger
  private let limits: GatewayHTTPLimits
  private var channel: Channel?
  private var eventLoopGroup: MultiThreadedEventLoopGroup?
  private var sessions: [String: SessionContext] = [:]
  private var pendingSessionIDs = Set<String>()
  private var cleanupTask: Task<Void, Never>?
  private var isStopping = false

  init(
    configuration: GatewayConfiguration,
    registry: any GatewayToolServing,
    listeningPort: Int,
    publicBaseURL: String?,
    accessToken: String?,
    logger: Logger,
    limits: GatewayHTTPLimits
  ) {
    self.configuration = configuration
    self.registry = registry
    self.listeningPort = listeningPort
    self.effectivePublicBaseURL = publicBaseURL ?? configuration.server.http.publicBaseURL
    self.authenticator = HTTPBearerAuthenticator(
      configuration: configuration.server.http,
      accessToken: accessToken
    )
    self.logger = logger
    self.limits = limits
  }

  func startListening(host: String, port: Int) async throws {
    guard channel == nil else {
      throw ConfigurationError.invalid("The HTTP gateway is already listening.")
    }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    eventLoopGroup = group
    let decoderLimits: NIOHTTPDecoderLimitConfiguration = {
      var configuration = NIOHTTPDecoderLimitConfiguration()
      configuration.maxHeaderFieldSize = limits.maxHeaderBytes
      configuration.maxHeaderListSize = limits.maxHeaderBytes
      configuration.maxHeaderFieldCount = 128
      return configuration
    }()
    let ingressPolicy = GatewayHTTPIngressPolicy(
      mcpPath: configuration.server.http.path,
      healthPath: configuration.server.http.healthPath,
      authenticator: authenticator,
      limits: limits
    )
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 256)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline(
          withDecoderLimitConfiguration: decoderLimits
        ).flatMap {
          channel.pipeline.addHandler(
            GatewayHTTPHandler(app: self, ingressPolicy: ingressPolicy)
          )
        }
      }
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

    logger.info(
      "Starting computer-mcp HTTP gateway",
      metadata: ["host": "\(host)", "port": "\(port)", "path": "\(configuration.server.http.path)"]
    )
    do {
      channel = try await bootstrap.bind(host: host, port: port).get()
      isStopping = false
      startCleanupTask()
    } catch {
      eventLoopGroup = nil
      try? await group.shutdownGracefully()
      throw error
    }
  }

  func waitUntilClosed() async {
    guard let bound = channel else { return }
    try? await bound.closeFuture.get()
    channel = nil
    cleanupTask?.cancel()
    cleanupTask = nil
    await stopAllSessions()
    if let group = eventLoopGroup {
      eventLoopGroup = nil
      try? await group.shutdownGracefully()
    }
  }

  func stop() async {
    isStopping = true
    cleanupTask?.cancel()
    cleanupTask = nil
    let activeChannel = channel
    channel = nil
    if activeChannel?.isActive == true {
      try? await activeChannel?.close()
    }
    await stopAllSessions()
    if let group = eventLoopGroup {
      eventLoopGroup = nil
      try? await group.shutdownGracefully()
    }
  }

  func handle(_ request: HTTPRequest) async -> HTTPResponse {
    let path = normalizedHTTPPath(request.path ?? "/")
    let http = configuration.server.http

    if request.method.uppercased() == "OPTIONS" {
      return cors(.ok(headers: [:]), request: request)
    }

    if path == http.healthPath {
      return cors(json(["ok": true, "name": configuration.server.name]), request: request)
    }

    guard path == normalizedHTTPPath(http.path) else {
      return cors(.error(statusCode: 404, .invalidRequest("Not Found")), request: request)
    }

    if let authError = authenticator.authorizationError(for: request) {
      return cors(authError, request: request)
    }

    let response = await handleMCP(request)
    return cors(response, request: request)
  }

  private func handleMCP(_ request: HTTPRequest) async -> HTTPResponse {
    await reapIdleSessions(at: Date())
    let sessionID = request.header(HTTPHeaderName.sessionID)

    if let sessionID, var session = sessions[sessionID] {
      session.lastAccessedAt = Date()
      sessions[sessionID] = session
      let response = await session.transport.handleRequest(request)
      if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
        await removeSession(sessionID)
      }
      return response
    }

    if request.method.uppercased() == "POST", isInitializeRequest(request.body) {
      return await createSessionAndHandle(request)
    }

    if sessionID != nil {
      return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
    }
    return .error(
      statusCode: 400,
      .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
    )
  }

  private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
    let sessionID = UUID().uuidString
    guard sessions.count + pendingSessionIDs.count < limits.maxSessions else {
      return gatewayHTTPError(
        statusCode: 429,
        code: "session_capacity_exceeded",
        extraHeaders: ["Retry-After": "60"]
      )
    }
    pendingSessionIDs.insert(sessionID)
    let transport = StatefulHTTPServerTransport(
      sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
      validationPipeline: makeValidationPipeline(),
      retryInterval: 1_000,
      logger: logger
    )
    let server = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: configuration,
      registry: registry
    )
    let normalizationTransport = MCPInitializeNormalizationTransport(wrapping: transport)

    do {
      try await server.start(transport: normalizationTransport)
    } catch {
      pendingSessionIDs.remove(sessionID)
      return .error(statusCode: 500, .internalError(error.localizedDescription))
    }

    pendingSessionIDs.remove(sessionID)
    guard !isStopping, channel != nil else {
      await server.stop()
      return gatewayHTTPError(statusCode: 503, code: "server_stopping")
    }
    sessions[sessionID] = SessionContext(
      server: server,
      transport: transport,
      lastAccessedAt: Date()
    )
    return await transport.handleRequest(request)
  }

  func activeSessionCount() -> Int {
    sessions.count
  }

  func removeSession(_ sessionID: String) async {
    guard let session = sessions.removeValue(forKey: sessionID) else {
      return
    }
    await session.server.stop()
  }

  private func stopAllSessions() async {
    let activeSessions = Array(sessions.values)
    sessions.removeAll(keepingCapacity: false)
    pendingSessionIDs.removeAll(keepingCapacity: false)
    for session in activeSessions {
      await session.server.stop()
    }
  }

  private func reapIdleSessions(at now: Date) async {
    let expiredIDs = sessions.compactMap { sessionID, session in
      now.timeIntervalSince(session.lastAccessedAt) >= limits.sessionIdleTimeout
        ? sessionID : nil
    }
    for sessionID in expiredIDs.sorted() {
      await removeSession(sessionID)
    }
  }

  private func startCleanupTask() {
    cleanupTask?.cancel()
    let intervalNanoseconds = UInt64(limits.cleanupInterval * 1_000_000_000)
    cleanupTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
        guard !Task.isCancelled else { return }
        await self?.reapIdleSessions(at: Date())
      }
    }
  }

  private func makeValidationPipeline() -> StandardValidationPipeline {
    StandardValidationPipeline(validators: [
      OriginValidator(
        allowedHosts: allowedHostPatterns(),
        allowedOrigins: allowedOriginPatterns()
      ),
      AcceptHeaderValidator(mode: .sseRequired),
      ContentTypeValidator(),
      ProtocolVersionValidator(),
      SessionValidator(),
    ])
  }

  private func allowedHostPatterns() -> [String] {
    var hosts = [
      "127.0.0.1:\(listeningPort)",
      "localhost:\(listeningPort)",
      "[::1]:\(listeningPort)",
    ]
    if let publicBaseURL = publicBaseURLHostPattern() {
      hosts.append(publicBaseURL)
    }
    return Array(Set(hosts)).sorted()
  }

  private func allowedOriginPatterns() -> [String] {
    var origins = [
      "http://127.0.0.1:\(listeningPort)",
      "http://localhost:\(listeningPort)",
      "http://[::1]:\(listeningPort)",
    ]
    if let origin = publicBaseURLOrigin() {
      origins.append(origin)
    }
    origins.append(contentsOf: configuration.server.http.allowedOrigins)
    return Array(Set(origins)).sorted()
  }

  private func publicBaseURLHostPattern() -> String? {
    guard let origin = publicBaseURLOrigin(),
      let components = URLComponents(string: origin),
      let host = components.host
    else {
      return nil
    }
    if let port = components.port {
      return "\(host):\(port)"
    }
    return host
  }

  private func publicBaseURLOrigin() -> String? {
    guard let base = effectivePublicBaseURL,
      let components = URLComponents(string: base),
      let scheme = components.scheme,
      let host = components.host
    else {
      return nil
    }
    var origin = "\(scheme)://\(host)"
    if let port = components.port {
      origin += ":\(port)"
    }
    return origin
  }

  private func cors(_ response: HTTPResponse, request: HTTPRequest) -> HTTPResponse {
    var headers = response.headers
    if let origin = request.header(HTTPHeaderName.origin),
      configuration.server.http.allowedOrigins.isEmpty
        || configuration.server.http.allowedOrigins.contains(origin)
    {
      headers["Access-Control-Allow-Origin"] = origin
      headers["Vary"] = "Origin"
      headers["Access-Control-Allow-Headers"] =
        "Authorization, Content-Type, Accept, MCP-Protocol-Version, MCP-Session-Id"
      headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
      headers["Access-Control-Expose-Headers"] = "MCP-Session-Id"
    }
    return response.replacingHeaders(headers)
  }
}

internal struct GatewayHTTPIngressPolicy: Sendable {
  let mcpPath: String
  let healthPath: String
  let authenticator: HTTPBearerAuthenticator
  let limits: GatewayHTTPLimits

  func rejection(for head: HTTPRequestHead) -> HTTPResponse? {
    guard headerByteCount(head.headers) <= limits.maxHeaderBytes else {
      return gatewayHTTPError(statusCode: 431, code: "headers_too_large")
    }

    let path = normalizedHTTPPath(head.uri)
    let method = head.method.rawValue.uppercased()
    if path != normalizedHTTPPath(mcpPath),
      path != normalizedHTTPPath(healthPath),
      method != "OPTIONS"
    {
      return gatewayHTTPError(statusCode: 404, code: "not_found")
    }

    if path == normalizedHTTPPath(mcpPath), method != "OPTIONS" {
      guard headerValues(named: HTTPHeaderName.authorization, in: head.headers).count <= 1 else {
        return gatewayHTTPError(statusCode: 400, code: "ambiguous_authorization")
      }
      let request = HTTPRequest(
        method: method,
        headers: Dictionary(
          head.headers.map { ($0.name, $0.value) },
          uniquingKeysWith: { _, newest in newest }
        ),
        path: head.uri
      )
      if let authError = authenticator.authorizationError(for: request) {
        return authError
      }
    }

    let contentLengths = headerValues(named: "Content-Length", in: head.headers)
    guard contentLengths.count <= 1 else {
      return gatewayHTTPError(statusCode: 400, code: "ambiguous_content_length")
    }
    if !contentLengths.isEmpty,
      !headerValues(named: "Transfer-Encoding", in: head.headers).isEmpty
    {
      return gatewayHTTPError(statusCode: 400, code: "ambiguous_body_framing")
    }
    if let contentLength = contentLengths.first {
      guard let byteCount = Int(contentLength), byteCount >= 0 else {
        return gatewayHTTPError(statusCode: 400, code: "invalid_content_length")
      }
      if byteCount > limits.maxBodyBytes {
        return gatewayHTTPError(statusCode: 413, code: "request_body_too_large")
      }
    }
    return nil
  }

  private func headerValues(named name: String, in headers: HTTPHeaders) -> [String] {
    headers.compactMap { header in
      header.name.caseInsensitiveCompare(name) == .orderedSame ? header.value : nil
    }
  }

  private func headerByteCount(_ headers: HTTPHeaders) -> Int {
    headers.reduce(into: 0) { count, header in
      count += header.name.utf8.count + header.value.utf8.count + 4
    }
  }
}

internal struct HTTPBearerAuthenticator: Sendable {
  private let authenticationRequired: Bool
  private let expectedDigest: [UInt8]?

  init(
    configuration: HTTPServerConfig,
    accessToken: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    let explicitToken = accessToken.flatMap { $0.isEmpty ? nil : $0 }
    let environmentToken = configuration.accessTokenEnv.flatMap { environment[$0] }
      .flatMap { $0.isEmpty ? nil : $0 }
    self.authenticationRequired = explicitToken != nil || configuration.accessTokenEnv != nil
    self.expectedDigest = (explicitToken ?? environmentToken).map(Self.digest)
  }

  func authorizationError(for request: HTTPRequest) -> HTTPResponse? {
    guard authenticationRequired else {
      return nil
    }
    let candidateDigest = Self.digest(accessToken(from: request) ?? "")
    guard let expectedDigest,
      Self.constantTimeEqual(candidateDigest, expectedDigest)
    else {
      return unauthorized()
    }
    return nil
  }

  private func accessToken(from request: HTTPRequest) -> String? {
    guard let header = request.header(HTTPHeaderName.authorization),
      header.lowercased().hasPrefix("bearer ")
    else {
      return nil
    }
    return String(header.dropFirst("Bearer ".count))
  }

  internal static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    let digestByteCount = 32
    var difference = UInt(lhs.count ^ rhs.count)
    difference |= UInt(lhs.count ^ digestByteCount)
    difference |= UInt(rhs.count ^ digestByteCount)
    for index in 0..<digestByteCount {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      difference |= UInt(left ^ right)
    }
    return difference == 0
  }

  private static func digest(_ value: String) -> [UInt8] {
    Array(SHA256.hash(data: Data(value.utf8)))
  }

  private func unauthorized() -> HTTPResponse {
    let data =
      (try? JSONSerialization.data(
        withJSONObject: ["error": "unauthorized"],
        options: [.sortedKeys])) ?? Data()
    return .data(
      data,
      headers: [
        HTTPHeaderName.contentType: "application/json",
        HTTPHeaderName.wwwAuthenticate: "Bearer",
        HTTPHeaderName.cacheControl: "no-store",
        "X-Computer-MCP-Status": "401",
      ]
    )
  }
}

private final class GatewayHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private struct RequestState {
    var head: HTTPRequestHead
    var body = ByteBuffer()
  }

  private let app: GatewayHTTPApp
  private let ingressPolicy: GatewayHTTPIngressPolicy
  private let allocator = ByteBufferAllocator()
  private var state: RequestState?
  private var rejectedRequest = false

  init(app: GatewayHTTPApp, ingressPolicy: GatewayHTTPIngressPolicy) {
    self.app = app
    self.ingressPolicy = ingressPolicy
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      let writer = SendableChannelContext(context: context)
      if let rejection = ingressPolicy.rejection(for: head) {
        state = nil
        rejectedRequest = true
        write(rejection, writer: writer, version: head.version, closeAfterWrite: true)
        return
      }
      rejectedRequest = false
      state = RequestState(head: head)

    case .body(var body):
      guard !rejectedRequest, var requestState = state else {
        return
      }
      guard
        requestState.body.readableBytes + body.readableBytes
          <= ingressPolicy.limits.maxBodyBytes
      else {
        state = nil
        rejectedRequest = true
        write(
          gatewayHTTPError(statusCode: 413, code: "request_body_too_large"),
          writer: SendableChannelContext(context: context),
          version: requestState.head.version,
          closeAfterWrite: true
        )
        return
      }
      requestState.body.writeBuffer(&body)
      state = requestState

    case .end:
      if rejectedRequest {
        rejectedRequest = false
        state = nil
        return
      }
      guard let state else {
        return
      }
      self.state = nil
      let request = makeRequest(state)
      let writer = SendableChannelContext(context: context)
      let version = state.head.version
      Task {
        let response = await self.app.handle(request)
        self.write(response, writer: writer, version: version)
      }
    }
  }

  private func makeRequest(_ state: RequestState) -> HTTPRequest {
    var body = state.body
    let data = Data(body.readBytes(length: body.readableBytes) ?? [])
    var headers: [String: String] = [:]
    for header in state.head.headers {
      headers[header.name] = header.value
    }
    return HTTPRequest(
      method: state.head.method.rawValue,
      headers: headers,
      body: data,
      path: state.head.uri
    )
  }

  private func write(
    _ response: HTTPResponse,
    writer: SendableChannelContext,
    version: HTTPVersion,
    closeAfterWrite: Bool = false
  ) {
    switch response {
    case .stream(let stream, let headers):
      var responseHeaders = HTTPHeaders()
      for (name, value) in headers {
        responseHeaders.add(name: name, value: value)
      }
      responseHeaders.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
      let head = HTTPResponseHead(
        version: version,
        status: NIOHTTP1.HTTPResponseStatus(statusCode: response.statusCode),
        headers: responseHeaders
      )
      writePart(.head(head), writer: writer)
      Task {
        do {
          for try await data in stream {
            var buffer = self.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            self.writePart(.body(.byteBuffer(buffer)), writer: writer)
          }
        } catch {
          let buffer = self.allocator.buffer(
            string: "event: error\ndata: \(error.localizedDescription)\n\n")
          self.writePart(.body(.byteBuffer(buffer)), writer: writer)
        }
        self.writePart(.end(nil), writer: writer, flush: true)
      }

    default:
      var responseHeaders = HTTPHeaders()
      var rawHeaders = response.headers
      let statusCode =
        rawHeaders.removeValue(forKey: "X-Computer-MCP-Status").flatMap(Int.init)
        ?? response.statusCode
      let status = NIOHTTP1.HTTPResponseStatus(statusCode: statusCode)
      for (name, value) in rawHeaders {
        responseHeaders.add(name: name, value: value)
      }
      let body = response.bodyData ?? Data()
      responseHeaders.replaceOrAdd(name: "Content-Length", value: "\(body.count)")
      let head = HTTPResponseHead(
        version: version,
        status: status,
        headers: responseHeaders
      )
      writePart(.head(head), writer: writer)
      if !body.isEmpty {
        var buffer = allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        writePart(.body(.byteBuffer(buffer)), writer: writer)
      }
      writePart(
        .end(nil),
        writer: writer,
        flush: true,
        closeAfterWrite: closeAfterWrite
      )
    }
  }

  private func writePart(
    _ part: HTTPServerResponsePart,
    writer: SendableChannelContext,
    flush: Bool = false,
    closeAfterWrite: Bool = false
  ) {
    writer.context.eventLoop.execute {
      if flush {
        let future = writer.context.writeAndFlush(self.wrapOutboundOut(part))
        if closeAfterWrite {
          future.whenComplete { _ in
            writer.context.close(promise: nil)
          }
        }
      } else {
        writer.context.write(self.wrapOutboundOut(part), promise: nil)
      }
    }
  }
}

private struct SendableChannelContext: @unchecked Sendable {
  let context: ChannelHandlerContext
}

func normalizedHTTPPath(_ path: String) -> String {
  var value = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
  if value.count > 1 && value.hasSuffix("/") {
    value.removeLast()
  }
  return value
}

private func isInitializeRequest(_ body: Data?) -> Bool {
  guard let body,
    let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
    json["method"] as? String == "initialize"
  else {
    return false
  }
  return true
}

private func gatewayHTTPError(
  statusCode: Int,
  code: String,
  extraHeaders: [String: String] = [:]
) -> HTTPResponse {
  let data =
    (try? JSONSerialization.data(
      withJSONObject: ["error": code],
      options: [.sortedKeys]
    )) ?? Data()
  var headers = extraHeaders
  headers[HTTPHeaderName.contentType] = "application/json"
  headers[HTTPHeaderName.cacheControl] = "no-store"
  headers["X-Computer-MCP-Status"] = String(statusCode)
  return .data(data, headers: headers)
}

private func json(_ value: [String: Any]) -> HTTPResponse {
  let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
  return .data(data, headers: [HTTPHeaderName.contentType: "application/json"])
}

extension HTTPResponse {
  fileprivate func replacingHeaders(_ headers: [String: String]) -> HTTPResponse {
    switch self {
    case .accepted:
      return .accepted(headers: headers)
    case .ok:
      return .ok(headers: headers)
    case .data(let data, _):
      return .data(data, headers: headers)
    case .stream(let stream, _):
      return .stream(stream, headers: headers)
    case .error(let statusCode, let error, let sessionID, _):
      return .error(statusCode: statusCode, error, sessionID: sessionID, extraHeaders: headers)
    }
  }
}
