import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTransport
import Foundation
import MCP

/// Proxies configured downstream servers through persistent MCP SDK sessions.
package final class MCPProxyClient: DownstreamMCPClient, @unchecked Sendable {
  private let launcher: ExecutionLauncher
  private let pool: MCPConnectionPool
  private let changes: GatewayToolChangeBroadcaster
  private let secretStore: (any SecretStore)?
  private let processOwnershipRoot: URL?
  private let journal: MCPExecutionJournal
  private let catalogs: MCPResolvedCatalogCache
  private let onDiscoverySelection: (@Sendable (String, UUID, UUID) throws -> Void)?
  private let calls = BlockingOperationExecutor(label: "computer-mcp.mcp-calls", serial: false)

  package init(
    launcher: ExecutionLauncher,
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    hostContext: (any MCPHostEnvironment)? = nil,
    secretStore: (any SecretStore)? = nil,
    processOwnershipRoot: URL? = nil,
    executionDatabase: GatewayDatabase? = nil, executionScope: String? = nil,
    onDiscoverySelection: (@Sendable (String, UUID, UUID) throws -> Void)? = nil
  ) {
    // Gateway connections need journal, retained-work and host-tool authority.
    // The nonthrowing factory defers unsupported host environments to connection admission.
    self.launcher = launcher
    self.onDiscoverySelection = onDiscoverySelection
    let gatewayContext = hostContext as? MCPHostContext
    let hostContextError: GatewayToolError? =
      hostContext != nil && gatewayContext == nil
      ? .executionFailed("Gateway MCP connections require a gateway host environment.") : nil
    let catalogs = MCPResolvedCatalogCache()
    self.catalogs = catalogs
    let changes = GatewayToolChangeBroadcaster()
    self.changes = changes
    self.secretStore = secretStore
    self.processOwnershipRoot = processOwnershipRoot
    let scope =
      executionScope ?? hostContext.map {
        MCPExecutionRecord.digest(
          .array([
            .string($0.launchMetadata.principalID), .string($0.launchMetadata.profileID.rawValue),
            .string($0.launchMetadata.project.id),
          ]))
      } ?? UUID().uuidString
    let journal = MCPExecutionJournal(
      database: executionDatabase ?? gatewayContext?.executionDatabase, scope: scope)
    self.journal = journal
    var hostContext = gatewayContext
    if hostContext?.processOwnershipRoot == nil {
      hostContext?.processOwnershipRoot = processOwnershipRoot
    }
    self.pool = MCPConnectionPool(
      launcher: launcher, workingDirectory: workingDirectory.standardizedFileURL,
      environment: environment,
      hostContext: hostContext, hostContextError: hostContextError,
      secretStore: secretStore, journal: journal,
      toolsChanged: {
        catalogs.removeAll()
        changes.send()
      })
  }

  package func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  )
    -> any DownstreamMCPClient
  {
    MCPProxyClient(
      launcher: launcher, workingDirectory: workingDirectory, environment: environment,
      hostContext: hostContext,
      secretStore: secretStore, processOwnershipRoot: processOwnershipRoot,
      onDiscoverySelection: onDiscoverySelection)
  }

  package func toolChanges() -> AsyncStream<Void> { changes.stream() }

  package func shutdown() async {
    changes.finish()
    await pool.shutdown().value
  }

  deinit {
    changes.finish()
    _ = pool.shutdown()
  }

  package func cachedTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool]?
  {
    try catalogs.tools(for: server, source: pool.catalogIdentity(for: server))
  }

  package func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    let source = try pool.catalogIdentity(for: server)
    let caller = GatewayDiscoveryCaller(context: context)
    do {
      var replacement: GatewayDiscoverySelection?
      var acquired: [MCPTool]?
      for attempt in 0..<2 {
        try caller.check()
        do {
          acquired = try run(
            server: server, notifyToolsOnConnect: false, context: context, discovery: true,
            discoveryReplacement: replacement, discoveryCaller: caller
          ) { connection in
            try await connection.listTools(caller: caller)
          }
          break
        } catch let expired as GatewayDiscoveryExpired {
          try caller.check()
          guard attempt == 0 else { throw PermissionModelError.invalidAuthorization }
          replacement = expired.selection
        }
      }
      guard let tools = acquired, try pool.catalogIdentity(for: server) == source else {
        throw PermissionModelError.invalidAuthorization
      }
      try caller.check()
      catalogs.save(tools, for: server, source: source)
      changes.send()
      return tools
    } catch let stopped as GatewayDiscoveryCallerStopped {
      if stopped.underlying is GatewayDiscoveryExpired {
        throw PermissionModelError.invalidAuthorization
      }
      throw stopped.underlying
    } catch is GatewayDiscoveryExpired {
      throw PermissionModelError.invalidAuthorization
    }
  }

  package func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws
    -> JSONValue
  {
    try callTool(server: server, name: name, arguments: arguments, requestID: nil, context: context)
  }

  package func callTool(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String?, context: InvocationContext
  ) throws -> JSONValue {
    try callTool(
      server: server, name: name, arguments: arguments, requestID: requestID, cancellation: nil,
      context: context)
  }

  package func callToolAsync(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?,
    context: InvocationContext
  ) async throws -> JSONValue {
    let cancellation = MCPCallCancellation(
      deliveryTimeout: .milliseconds(server.requestTimeoutMs ?? 30_000))
    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let result = try await calls.perform {
          try cancellation.checkCancellation()
          return try self.callTool(
            server: server, name: name, arguments: arguments, requestID: requestID,
            cancellation: cancellation, context: context)
        }
        await cancellation.finish()
        try Task.checkCancellation()
        return result
      } catch {
        await cancellation.finish()
        if error is CancellationError {
          try Task.checkCancellation()
          try cancellation.checkCancellation()
          // An upstream MCP server suppresses replies for caller cancellation. A
          // retired downstream request must instead settle its still-waiting caller.
          throw GatewayToolError.executionFailed(
            "[mcp.request_cancelled] Downstream request was cancelled; its execution outcome may be unknown."
          )
        }
        throw error
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?,
    cancellation: MCPCallCancellation?, context: InvocationContext
  ) throws -> JSONValue {
    guard let object = arguments.objectValue else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP tool arguments must be an object."
      )
    }

    guard let execution = context.executionAuthority as? PreparedExecutionContext else {
      throw PermissionModelError.invalidAuthorization
    }
    let retainsResult = requestID != nil
    let continuation = context.continuationTarget
    if continuation != nil {
      _ = try pool.connection(for: server, continuation: continuation, context: context)
    }
    let requestID = requestID ?? UUID().uuidString
    if retainsResult {
      guard !requestID.isEmpty else {
        throw GatewayToolError.invalidArguments("Downstream MCP request id must not be empty.")
      }
      let reservation = try journal.reserve(
        server: server, tool: name, arguments: arguments, requestID: requestID,
        executionID: try preparedExecutionID(context: context))
      if !reservation.inserted {
        try requireExecutionAccess(reservation.record, operation: .readResult, context: context)
        guard reservation.record.state == .succeeded || reservation.record.state == .failed,
          reservation.record.outputExpiresAt.map({ $0 > Date() }) == true,
          reservation.record.retainedByteCount == reservation.record.outputByteCount,
          let output = reservation.record.outputJSON
        else {
          throw GatewayToolError.invalidArguments(
            "[request.already_started] Query mcp.requests.read for this execution; it was not replayed."
          )
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
      }
    }
    let host = context.admission?.hostDispatch(for: server, tool: name)
    do {
      return try run(server: server, context: context) { connection in
        try await connection.callTool(
          name: name, arguments: object, gatewayRequestID: requestID, cancellation: cancellation,
          retainsResult: retainsResult, execution: execution,
          host: host,
          continuation: continuation,
          cancellationDeliveryFailed: {
            self.pool.invalidate(server: server, connection: connection)
          })
      }
    } catch {
      if retainsResult {
        try journal.update(serverID: server.id, requestID: requestID) {
          if !$0.isTerminal {
            $0.state = .outcomeUnknown
            $0.completedAt = Date()
          }
        }
      }
      throw error
    }
  }

  package func startToolCall(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String, context: InvocationContext
  ) throws -> JSONValue {
    guard let object = arguments.objectValue else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP tool arguments must be an object."
      )
    }
    guard !requestID.isEmpty else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP request id must not be empty."
      )
    }

    let continuation = context.continuationTarget
    if continuation != nil {
      _ = try pool.connection(for: server, continuation: continuation, context: context)
    }
    guard let prepared = context.executionAuthority as? PreparedExecutionContext else {
      throw PermissionModelError.invalidAuthorization
    }
    let reservation = try journal.reserve(
      server: server, tool: name, arguments: arguments, requestID: requestID,
      executionID: try preparedExecutionID(context: context))
    if !reservation.inserted {
      try requireExecutionAccess(reservation.record, operation: .readResult, context: context)
      return try reservation.record.snapshot(instance: journal.instanceID)
    }
    let host = context.admission?.hostDispatch(for: server, tool: name)
    do {
      return try run(server: server, context: context) { connection in
        try await connection.startToolCall(
          name: name, arguments: object, gatewayRequestID: requestID,
          host: host, continuation: continuation,
          execution: prepared)
      }
    } catch {
      try journal.update(serverID: server.id, requestID: requestID) {
        $0.state = .outcomeUnknown
        $0.completedAt = Date()
      }
      throw error
    }
  }

  package func readRequest(
    server: MCPServerConfig, requestID: String, offset: Int, maxBytes: Int,
    context: InvocationContext
  ) throws -> JSONValue {
    let record = try journal.read(serverID: server.id, requestID: requestID)
    try requireExecutionAccess(record, operation: .readResult, context: context)
    if let target = context.continuationTarget {
      guard
        let connection = pool.existingConnection(
          for: server, continuation: target, context: context)
      else { throw MCPContinuationTarget.unavailable() }
      try runExisting(server: server, connection: connection, context: context) { connection in
        try await connection.requireActiveRequest(requestID, executionID: record.executionID)
      }
    }
    return try record.snapshot(instance: journal.instanceID, offset: offset, maxBytes: maxBytes)
  }

  private func preparedExecutionID(context: InvocationContext) throws -> UUID {
    guard let prepared = context.executionAuthority as? PreparedExecutionContext else {
      throw PermissionModelError.invalidAuthorization
    }
    _ = try prepared.accessExecution(prepared.executionID, operation: .readResult)
    return prepared.executionID
  }

  private func executionAccess(context: InvocationContext) throws -> any ExecutionAccessChecking {
    guard let access = context.executionAuthority as? any ExecutionAccessChecking else {
      throw PermissionModelError.invalidAuthorization
    }
    return access
  }

  private func requireExecutionAccess(
    _ record: MCPExecutionRecord, operation: ExecutionOperation, context: InvocationContext
  ) throws {
    guard let executionID = record.executionID else {
      throw PermissionModelError.invalidAuthorization
    }
    _ = try executionAccess(context: context).accessExecution(executionID, operation: operation)
  }

  package func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  {
    try run(server: server, context: context) { connection in
      try await connection.listResources(cursor: cursor)
    }
  }

  package func listResourceTemplates(
    server: MCPServerConfig, cursor: String?, context: InvocationContext
  ) throws -> JSONValue {
    try run(server: server, context: context) { connection in
      try await connection.listResourceTemplates(cursor: cursor)
    }
  }

  package func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  {
    try run(server: server, context: context) { connection in
      try await connection.readResource(uri: uri)
    }
  }

  package func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  {
    try run(server: server, context: context) { connection in
      try await connection.listPrompts(cursor: cursor)
    }
  }

  package func getPrompt(
    server: MCPServerConfig,
    name: String,
    arguments: [String: String]?, context: InvocationContext
  ) throws -> JSONValue {
    try run(server: server, context: context) { connection in
      try await connection.getPrompt(name: name, arguments: arguments)
    }
  }

  package func connectionStatus(server: MCPServerConfig, context: InvocationContext) throws
    -> JSONValue
  {
    guard server.enabled else { return .object(["state": .string("disabled")]) }
    guard
      let connection = pool.existingConnection(
        for: server, continuation: context.continuationTarget, context: context)
    else {
      return .object([
        "state": .string(pool.inactiveState(serverID: server.id)),
        "persistent_session": .bool(true),
        "active_requests": .number(0),
        "latest_event_cursor": .number(0),
      ])
    }
    return try runExisting(server: server, connection: connection, context: context) { connection in
      await connection.status()
    }
  }

  package func readEvents(
    server: MCPServerConfig,
    afterCursor: Int,
    maxResults: Int, context: InvocationContext
  ) throws -> JSONValue {
    try readEvents(
      server: server, afterCursor: afterCursor, maxResults: maxResults, sessionID: nil,
      context: context)
  }

  package func readEvents(
    server: MCPServerConfig, afterCursor: Int, maxResults: Int, sessionID: String?,
    context: InvocationContext
  ) throws -> JSONValue {
    guard afterCursor >= 0, (1...500).contains(maxResults), sessionID?.isEmpty != true else {
      throw GatewayToolError.invalidArguments(
        "after_cursor must be nonnegative, max_results must be 1...500, and session_id must not be empty."
      )
    }
    guard
      let connection = pool.existingConnection(
        for: server, continuation: context.continuationTarget, context: context)
    else {
      guard afterCursor == 0, sessionID == nil else {
        throw GatewayToolError.invalidArguments(
          "[cursor.session_unavailable] The original MCP event session is unavailable. No connection was started and the missing event count is unknown."
        )
      }
      let state = pool.inactiveState(serverID: server.id)
      return .object([
        "server": .string(server.id), "state": .string(state),
        "session_id": .null, "session_verified": .bool(false),
        "cursor_state": .string(state == "not_started" ? "not_started" : "unavailable"),
        "reset_required": .bool(false),
        "after_cursor": .number(0), "next_cursor": .number(0),
        "oldest_available_cursor": .null, "latest_event_cursor": .null,
        "events": .array([]), "has_more": .bool(false), "missed_events": .null,
        "persistent_session": .bool(true),
      ])
    }
    return try runExisting(server: server, connection: connection, context: context) { connection in
      try await connection.readEvents(
        afterCursor: afterCursor, maxResults: maxResults, sessionID: sessionID)
    }
  }

  package func activeRequests(server: MCPServerConfig, context: InvocationContext) throws
    -> JSONValue
  {
    let access = try executionAccess(context: context)
    let connections = pool.existingConnections(
      for: server, continuation: context.continuationTarget)
    var requests: [JSONValue] = []
    for connection in connections {
      let value = try runExisting(server: server, connection: connection, context: context) {
        connection in
        await connection.activeRequestsJSON(access: access)
      }
      requests += value.objectValue?["requests"]?.arrayValue ?? []
    }
    return .object([
      "server": .string(server.id),
      "requests": .array(
        requests.sorted {
          ($0.objectValue?["request_id"]?.stringValue ?? "")
            < ($1.objectValue?["request_id"]?.stringValue ?? "")
        }), "persistent_session": .bool(true),
    ])
  }

  package func closeConnection(server: MCPServerConfig, context: InvocationContext) throws
    -> JSONValue
  {
    guard let target = context.continuationTarget, target.selectedOwnershipID != nil,
      target.reference == .init(serverID: server.id, toolName: "mcp.connections.close"),
      let connection = pool.existingConnection(
        for: server, continuation: context.continuationTarget, context: context)
    else { throw MCPContinuationTarget.unavailable() }
    let result = try runExisting(server: server, connection: connection, context: context) {
      connection in
      try await connection.closeSelected(target)
    }
    // Failed selection must leave the original pool entry intact. Teardown and the
    // pool's existing predecessor barrier remain authoritative for future admission.
    pool.invalidate(server: server, connection: connection)
    return result
  }

  package func cancelRequest(
    server: MCPServerConfig,
    requestID: String,
    reason: String?, context: InvocationContext
  ) throws -> JSONValue {
    let access = try executionAccess(context: context)
    if let target = context.continuationTarget {
      guard
        let connection = pool.existingConnection(
          for: server, continuation: target, context: context)
      else { throw MCPContinuationTarget.unavailable() }
      return try runExisting(server: server, connection: connection, context: context) {
        connection in
        try await connection.cancelRequest(
          gatewayRequestID: requestID,
          reason: reason ?? "Cancelled by computer-mcp caller.", access: access)
      }
    }
    let record = try journal.read(serverID: server.id, requestID: requestID)
    try requireExecutionAccess(record, operation: .requestCancellation, context: context)
    let connections = pool.existingConnections(
      for: server, continuation: context.continuationTarget)
    let matching = try connections.filter { connection in
      try runExisting(server: server, connection: connection, context: context) { connection in
        await connection.ownsRequest(requestID, executionID: record.executionID)
      }
    }
    guard matching.count == 1, let connection = matching.first else {
      throw PermissionModelError.invalidAuthorization
    }
    return try runExisting(server: server, connection: connection, context: context) { connection in
      try await connection.cancelRequest(
        gatewayRequestID: requestID,
        reason: reason ?? "Cancelled by computer-mcp caller.", access: access
      )
    }
  }

  private func run<T: Sendable>(
    server: MCPServerConfig,
    notifyToolsOnConnect: Bool = true,
    context: InvocationContext, discovery: Bool = false,
    discoveryReplacement: GatewayDiscoverySelection? = nil,
    discoveryCaller: GatewayDiscoveryCaller? = nil,
    operation: @escaping @Sendable (MCPProxyConnection) async throws -> T
  ) throws -> T {
    try discoveryCaller?.check()
    let connection: MCPProxyConnection
    do {
      connection = try pool.connection(
        for: server, continuation: context.continuationTarget, context: context,
        discovery: discovery, discoveryCaller: discoveryCaller,
        replacement: try discoveryReplacement.map {
          guard let discoveryCaller else { throw PermissionModelError.invalidAuthorization }
          return GatewayDiscoveryReplacement(selected: $0, reuse: nil, caller: discoveryCaller)
        })
    } catch is GatewayDiscoveryExpired {
      throw PermissionModelError.invalidAuthorization
    }
    if discovery, context.continuationTarget == nil,
      let execution = connection.preparedExecution,
      let provider = execution.provider, provider.delegatingAuthorization == nil
    {
      do {
        try onDiscoverySelection?(server.id, connection.connectionID, execution.executionID)
      } catch is GatewayDiscoveryExpired {
        throw PermissionModelError.invalidAuthorization
      }
    }
    let operationContext =
      discovery && connection.preparedExecution != nil
      ? InvocationContext(executionAuthority: connection.preparedExecution) : context
    do {
      try discoveryCaller?.check()
      try runExisting(
        server: server, connection: connection,
        timeoutMilliseconds: server.startupTimeoutMs ?? 30_000,
        phase: "startup", context: operationContext, discoveryCaller: discoveryCaller
      ) { connection in
        try await connection.ensureConnected(
          notifyTools: notifyToolsOnConnect, caller: discoveryCaller)
      }
      try discoveryCaller?.check()
      return try runExisting(
        server: server, connection: connection, context: operationContext,
        discoveryCaller: discoveryCaller, operation: operation)
    } catch let expired as GatewayDiscoveryExpired {
      try discoveryCaller?.check()
      guard discovery, server.transport == .stdio, context.continuationTarget == nil,
        let execution = connection.preparedExecution, let binding = execution.provider,
        execution.authority.authorizationIDs == binding.authorizationIDs,
        GatewayDiscoverySelection(executionID: execution.executionID, binding: binding)
          == expired.selection
      else { throw PermissionModelError.invalidAuthorization }
      pool.invalidate(server: server, connection: connection)
      throw expired
    }
  }

  private func runExisting<T: Sendable>(
    server: MCPServerConfig,
    connection: MCPProxyConnection,
    timeoutMilliseconds: Int? = nil,
    phase: String = "request",
    context: InvocationContext,
    discoveryCaller: GatewayDiscoveryCaller? = nil,
    operation: @escaping @Sendable (MCPProxyConnection) async throws -> T
  ) throws -> T {
    try discoveryCaller?.check()
    let timeout = timeoutMilliseconds ?? server.requestTimeoutMs ?? 30_000
    let box = AsyncOperationBox<T>()
    let selected = context.continuationTarget
    let execution = context.executionAuthority ?? InvocationExecution.current
    let access = HostPathAccess.current ?? execution?.pathAccess
    let task = Task.detached {
      do {
        try Task.checkCancellation()
        try discoveryCaller?.check()
        let result = try await InvocationExecution.$current.withValue(execution) {
          try await HostPathAccess.$current.withValue(access) {
            if let selected { try await connection.validateSelectedOwner(selected) }
            return try await operation(connection)
          }
        }
        box.complete(.success(result))
      } catch {
        box.complete(.failure(error))
      }
    }

    guard box.wait(timeoutMilliseconds: timeout) else {
      try discoveryCaller?.check()
      // Retirement owns cancellation delivery and joins it after closing the transport.
      // Cancelling only this bridge would leave an SDK request or a startup task alive.
      pool.invalidate(server: server, connection: connection)
      task.cancel()
      throw GatewayToolError.executionFailed(
        "MCP server '\(server.id)' \(phase) timed out."
      )
    }

    do {
      return try box.get()
    } catch {
      if error is GatewayDiscoveryCallerStopped { throw error }
      if phase == "startup" || Self.requiresRetirement(error) {
        pool.invalidate(server: server, connection: connection)
      }
      try discoveryCaller?.check()
      if error is GatewayDiscoveryExpired, discoveryCaller == nil {
        throw PermissionModelError.invalidAuthorization
      }
      throw error
    }
  }

  private static func requiresRetirement(_ error: any Error) -> Bool {
    // A rejected or explicitly cancelled request does not revoke other requests
    // on the same session. Startup, timeouts and transport failures still retire it.
    if error is CancellationError { return false }
    if error is PermissionModelError { return false }
    if let error = error as? GatewayToolError, case .invalidArguments = error { return false }
    if let error = error as? MCPError {
      switch error {
      case .methodNotFound, .invalidParams, .serverError, .urlElicitationRequired:
        return false
      case .parseError, .invalidRequest, .internalError, .connectionClosed, .transportError:
        // The pinned SDK also uses internalError for local disconnects. Without
        // provenance, these failures cannot establish a reusable session.
        return true
      }
    }
    return true
  }
}

private final class MCPConnectionPool: @unchecked Sendable {
  private struct Key: Hashable {
    let serverID: String
    let authority: MCPProviderSessionAuthority?

    func sharesDelegation(with other: Self) -> Bool {
      guard serverID == other.serverID else { return false }
      if let authority, let other = other.authority {
        return authority.sharesDelegation(with: other)
      }
      return authority == nil && other.authority == nil
    }
  }
  private struct Entry {
    let configuration: MCPServerConfig
    let connection: MCPProxyConnection
    let execution: PreparedExecutionContext?
  }
  private struct Retirement {
    let id: UUID
    let key: Key
    let task: Task<Bool, Never>
    var failed = false
  }
  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]
  private var stopped = false
  private var retirements: [UUID: Retirement] = [:]
  private var shutdownTask: Task<Void, Never>?
  private let launcher: ExecutionLauncher
  private let workingDirectory: URL
  private let environment: [String: String]
  private let hostContext: MCPHostContext?
  private let hostContextError: GatewayToolError?
  private let secretStore: (any SecretStore)?
  private let journal: MCPExecutionJournal
  private let toolsChanged: @Sendable () -> Void

  init(
    launcher: ExecutionLauncher, workingDirectory: URL, environment: [String: String],
    hostContext: MCPHostContext?, hostContextError: GatewayToolError?,
    secretStore: (any SecretStore)?, journal: MCPExecutionJournal,
    toolsChanged: @escaping @Sendable () -> Void
  ) {
    self.launcher = launcher
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.hostContext = hostContext
    self.hostContextError = hostContextError
    self.secretStore = secretStore
    self.journal = journal
    self.toolsChanged = toolsChanged
  }

  func catalogIdentity(for server: MCPServerConfig) throws -> String? {
    guard server.transport == .stdio else { return nil }
    do {
      return try hostContext?.providerSource?(server).digest
    } catch is GatewayDiscoveryExpired {
      throw PermissionModelError.invalidAuthorization
    }
  }

  func connection(
    for server: MCPServerConfig, continuation: MCPContinuationTarget?,
    context: InvocationContext, discovery: Bool = false,
    discoveryCaller: GatewayDiscoveryCaller? = nil, replacement: GatewayDiscoveryReplacement? = nil
  ) throws -> MCPProxyConnection {
    do {
      return try selectConnection(
        for: server, continuation: continuation, context: context, discovery: discovery,
        discoveryCaller: discoveryCaller, replacement: replacement)
    } catch is GatewayDiscoveryExpired {
      throw PermissionModelError.invalidAuthorization
    }
  }

  private func selectConnection(
    for server: MCPServerConfig, continuation: MCPContinuationTarget?,
    context: InvocationContext, discovery: Bool, discoveryCaller: GatewayDiscoveryCaller?,
    replacement: GatewayDiscoveryReplacement?
  ) throws -> MCPProxyConnection {
    if let hostContextError { throw hostContextError }
    guard server.enabled else {
      throw GatewayToolError.disabled("MCP registration '\(server.id)' is disabled.")
    }
    let source = try server.transport == .stdio ? hostContext?.providerSource?(server) : nil
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else {
      throw GatewayToolError.disabled("The downstream MCP client is stopped.")
    }
    var execution = (context.executionAuthority as? PreparedExecutionContext).flatMap {
      $0.provider == nil ? nil : $0
    }
    if !discovery, source != nil, execution == nil {
      throw PermissionModelError.invalidAuthorization
    }
    if let continuation {
      guard let entry = selectedLocked(server: server, target: continuation) else {
        throw MCPContinuationTarget.unavailable()
      }
      guard source == nil || entry.execution?.provider?.sourceDigest == source?.digest else {
        throw MCPContinuationTarget.unavailable()
      }
      if discovery, entry.execution?.provider?.delegatingAuthorization == nil {
        try entry.execution?.validateProviderLaunch()
      } else {
        try MCPProviderSessionAuthority.requireMatch(admitted: execution, running: entry.execution)
      }
      return entry.connection
    }
    var ownsAdmission = false
    if discovery, let source {
      for (key, entry) in entries where key.serverID == server.id && key.authority?.delegator == nil
      {
        if entry.configuration == server,
          entry.execution?.provider?.sourceDigest == source.digest
        {
          if let replacement, let existing = entry.execution {
            let validated = try source.prepareDiscovery(
              GatewayDiscoveryReplacement(
                selected: replacement.selected, reuse: existing, caller: replacement.caller),
              discoveryCaller)
            guard validated === existing else { throw PermissionModelError.invalidAuthorization }
            return entry.connection
          }
          if (try? entry.execution?.validateProviderLaunch()) != nil { return entry.connection }
        }
        entries.removeValue(forKey: key)
        retireLocked(key: key, connection: entry.connection)
      }
      try replacement?.caller.check()
      execution = try source.prepareDiscovery(replacement, discoveryCaller)
      ownsAdmission = true
    }
    do {
      if let execution {
        guard execution.provider?.registrationID == server.id,
          source == nil || execution.provider?.sourceDigest == source?.digest,
          !discovery || execution.provider?.delegatingAuthorization == nil
        else { throw PermissionModelError.invalidAuthorization }
        try execution.validateProviderLaunch()
      }
      let key = try Key(
        serverID: server.id, authority: execution.map(MCPProviderSessionAuthority.init))
      // A stale process is a predecessor, including one whose cleanup already failed.
      for (oldKey, entry) in entries where oldKey.sharesDelegation(with: key) {
        let valid =
          entry.execution == nil || (try? entry.execution?.validateProviderLaunch()) != nil
        if entry.configuration != server || !valid {
          entries.removeValue(forKey: oldKey)
          retireLocked(key: oldKey, connection: entry.connection)
        }
      }
      if let entry = entries[key], entry.configuration == server {
        if ownsAdmission { try execution?.finishAdmission() }
        return entry.connection
      }
      let predecessors = retirements.values.filter { $0.key.sharesDelegation(with: key) }.map(
        \.task)
      let predecessor: Task<Bool, Never>? =
        predecessors.isEmpty
        ? nil
        : Task {
          var confirmed = true
          for task in predecessors { if !(await task.value) { confirmed = false } }
          return confirmed
        }
      let connection = try MCPProxyConnection(
        launcher: launcher, server: server, workingDirectory: workingDirectory,
        environment: environment, hostContext: hostContext, secretStore: secretStore,
        journal: journal,
        predecessor: predecessor, preparedExecution: execution, ownsAdmission: ownsAdmission,
        onTermination: { [weak self] connection in
          self?.invalidate(server: server, connection: connection)
        }, toolsChanged: toolsChanged)
      entries[key] = Entry(configuration: server, connection: connection, execution: execution)
      return connection
    } catch {
      if ownsAdmission { try? execution?.finishAdmission() }
      throw error
    }
  }

  private func selectedLocked(server: MCPServerConfig, target: MCPContinuationTarget) -> Entry? {
    guard target.reference.serverID == server.id,
      target.projectID == hostContext?.launchMetadata.project.id
    else { return nil }
    return entries.values.first {
      $0.configuration == server && $0.connection.connectionID == target.connectionID
    }
  }

  func existingConnections(for server: MCPServerConfig, continuation: MCPContinuationTarget?)
    -> [MCPProxyConnection]
  {
    lock.withLock {
      guard !stopped else { return [] }
      if let continuation {
        return selectedLocked(server: server, target: continuation).map { [$0.connection] } ?? []
      }
      return entries.values.filter { $0.configuration == server }.map(\.connection)
    }
  }

  func existingConnection(
    for server: MCPServerConfig, continuation: MCPContinuationTarget?, context: InvocationContext
  ) -> MCPProxyConnection? {
    lock.withLock {
      guard !stopped else { return nil }
      if let continuation {
        return selectedLocked(server: server, target: continuation)?.connection
      }
      if let execution = context.executionAuthority as? PreparedExecutionContext,
        let authority = try? MCPProviderSessionAuthority(execution)
      {
        return entries[Key(serverID: server.id, authority: authority)]?.connection
      }
      let matching = entries.filter {
        $0.value.configuration == server
          && ($0.key.authority == nil || $0.key.authority?.delegator == nil)
      }
      .map(\.value)
      return matching.count == 1 ? matching.first?.connection : nil
    }
  }

  func invalidate(server: MCPServerConfig, connection: MCPProxyConnection) {
    lock.withLock {
      guard
        let entry = entries.first(where: {
          $0.value.configuration == server && $0.value.connection === connection
        })
      else { return }
      entries.removeValue(forKey: entry.key)
      retireLocked(key: entry.key, connection: connection)
    }
  }

  private func retireLocked(key: Key, connection: MCPProxyConnection) {
    let id = UUID()
    let task = Task { [weak self] in
      let confirmed = await connection.disconnect()
      self?.finishRetirement(id: id, confirmed: confirmed)
      return confirmed
    }
    retirements[id] = Retirement(id: id, key: key, task: task)
  }

  private func finishRetirement(id: UUID, confirmed: Bool) {
    lock.withLock {
      if confirmed { retirements.removeValue(forKey: id) } else { retirements[id]?.failed = true }
    }
  }

  func inactiveState(serverID: String) -> String {
    lock.withLock {
      let pending = retirements.values.filter { $0.key.serverID == serverID }
      if !pending.isEmpty {
        return pending.contains(where: \.failed) ? "cleanup_failed" : "retiring"
      }
      if entries.keys.contains(where: { $0.serverID == serverID }) { return "selection_required" }
      return stopped ? "stopped" : "not_started"
    }
  }

  func shutdown() -> Task<Void, Never> {
    lock.withLock {
      if let shutdownTask { return shutdownTask }
      stopped = true
      for (key, entry) in entries { retireLocked(key: key, connection: entry.connection) }
      let retired = retirements.values.map(\.task)
      entries.removeAll()
      let task = Task {
        await withTaskGroup(of: Void.self) { group in
          for task in retired { group.addTask { _ = await task.value } }
        }
      }
      shutdownTask = task
      return task
    }
  }
}

private actor MCPProxyConnection {
  nonisolated let connectionID = UUID()

  private struct Event: Sendable {
    let cursor: Int
    let kind: String
    let timestamp: Date
    let requestID: String?

    var json: JSONValue {
      .object([
        "cursor": .integer(Int64(cursor)),
        "kind": .string(kind),
        "timestamp": .number(timestamp.timeIntervalSince1970),
        "request_id": requestID.map(JSONValue.string) ?? .null,
      ])
    }
  }

  private struct ActiveRequest: Sendable {
    let gatewayRequestID: String
    let downstreamRequestID: MCP.ID
    let tool: String
    let startedAt: Date
    let execution: PreparedExecutionContext
    var executionID: UUID { execution.executionID }
    var retainsResult = false
    var cancellationRequested = false

    var json: JSONValue {
      .object([
        "request_id": .string(gatewayRequestID),
        "downstream_request_id": .string(downstreamRequestID.description),
        "tool": .string(tool),
        "started_at": .number(startedAt.timeIntervalSince1970),
        "state": .string(cancellationRequested ? "cancellation_requested" : "running"),
      ])
    }
  }

  private let server: MCPServerConfig
  private let journal: MCPExecutionJournal
  private let onTermination: @Sendable (MCPProxyConnection) -> Void
  private let client: MCP.Client
  private let transport: any MCP.Transport
  // Retain the single initialization attempt until retirement, including a failed attempt.
  private var connectTask: Task<Initialize.Result, Error>?
  private var terminationObserver: Task<Void, Never>?
  private var closeTask: Task<Bool, Never>?
  private let predecessor: Task<Bool, Never>?
  nonisolated let preparedExecution: PreparedExecutionContext?
  private let ownsAdmission: Bool
  private var observers: [MCP.ID: Task<Void, Never>] = [:]
  private var reservedRequestIDs: Set<String> = []
  private var initializeResult: Initialize.Result?
  private var handlersRegistered = false
  private var connected = false
  private var lastError: String?
  private var events: [Event] = []
  private let eventSessionID = UUID().uuidString
  private var nextEventCursor = 1
  private var activeRequests: [String: ActiveRequest] = [:]
  private var logicalRequestIDs: Set<String> = []
  private var pendingWorkCancellation: Set<String> = []
  private let ownedWork: GatewayOwnedWork?
  private let projectID: String?
  private let hostTools: MCPHostToolDirectory?
  private struct RequestOwnership: Sendable {
    let id = UUID()
    let work: GatewayOwnedWork.Lease?
    let invocation: MCPHostToolDirectory.InvocationLease?
    let providerInvocationID: UUID?
  }
  private var requestOwnership: [UUID: RequestOwnership] = [:]
  private var providerWork: MCPProviderWork?
  private var unreportedWork: GatewayOwnedWork.Lease?
  private var unreportedExecutions: [UUID: ExecutionWorkLease] = [:]
  private var workCatalogObserved = false
  private var workObservation: Task<Void, Never>?
  private var workObservationID: UUID?
  private var workDeadline: Task<Void, Never>?
  private var workPoll: Task<Void, Never>?
  private var workRefreshPending = false
  private var workClosed = false
  private let toolsChanged: @Sendable () -> Void

  init(
    launcher: ExecutionLauncher, server: MCPServerConfig, workingDirectory: URL,
    environment: [String: String],
    hostContext: MCPHostContext?,
    secretStore: (any SecretStore)?, journal: MCPExecutionJournal,
    predecessor: Task<Bool, Never>? = nil,
    preparedExecution: PreparedExecutionContext? = nil, ownsAdmission: Bool = false,
    onTermination: @escaping @Sendable (MCPProxyConnection) -> Void,
    toolsChanged: @escaping @Sendable () -> Void
  ) throws {
    self.server = server
    self.journal = journal
    self.predecessor = predecessor
    self.preparedExecution = preparedExecution
    self.ownsAdmission = ownsAdmission
    self.toolsChanged = toolsChanged
    self.onTermination = onTermination
    ownedWork = hostContext?.ownedWork
    projectID = hostContext?.launchMetadata.project.id
    hostTools = hostContext?.tools
    client = MCP.Client(
      name: "computer-mcp-gateway",
      version: ComputerMCPCLI.version
    )
    transport = try Self.makeTransport(
      launcher: launcher, server: server, workingDirectory: workingDirectory,
      environment: environment,
      hostContext: hostContext, secretStore: secretStore, preparedExecution: preparedExecution)
  }

  func listTools(caller: GatewayDiscoveryCaller? = nil) async throws -> [MCPTool] {
    try caller?.check()
    try await ensureConnected(notifyTools: false, caller: caller)
    let tools = try await MCPToolCatalogLoader.load { [client] cursor in
      try await client.listTools(cursor: cursor)
    }
    let catalog = tools.map { tool in
      MCPTool(
        name: tool.name,
        title: tool.title,
        description: tool.description ?? "",
        inputSchema: JSONValue(sdkValue: tool.inputSchema),
        outputSchema: tool.outputSchema.map(JSONValue.init(sdkValue:)),
        annotations: tool.annotations.isEmpty
          ? nil
          : MCPToolAnnotations(
            readOnlyHint: tool.annotations.readOnlyHint,
            destructiveHint: tool.annotations.destructiveHint,
            idempotentHint: tool.annotations.idempotentHint,
            openWorldHint: tool.annotations.openWorldHint
          ),
        meta: tool._meta.map { .object($0.fields.mapValues(JSONValue.init(sdkValue:))) }
      )
    }
    do {
      let advertised = try MCPProviderWork.advertised(by: catalog)
      guard !advertised || initializeResult?.capabilities.resources != nil,
        providerWork == nil || advertised
      else {
        throw GatewayToolError.executionFailed(
          "[mcp.work_unavailable] The provider must retain its advertised work resource for the connection lifetime."
        )
      }
      if advertised && providerWork == nil {
        providerWork = MCPProviderWork(
          work: ownedWork ?? GatewayOwnedWork(), projectID: projectID,
          registrationID: server.id,
          connectionID: connectionID
        )
        refreshProviderWork()
      }
      try providerWork?.declareContinuations(from: catalog)
      workCatalogObserved = true
    } catch {
      providerWork?.observationLost()
      throw error
    }
    return catalog
  }

  func callTool(
    name: String,
    arguments: [String: JSONValue],
    gatewayRequestID: String,
    cancellation: MCPCallCancellation? = nil,
    retainsResult: Bool = false,
    execution: PreparedExecutionContext,
    host: HostServiceDispatch? = nil,
    continuation: MCPContinuationTarget? = nil,
    cancellationDeliveryFailed: @escaping @Sendable () -> Void = {}
  ) async throws -> JSONValue {
    try await ensureConnected()
    try cancellation?.checkCancellation()
    // Reserve before crossing into the SDK actor so concurrent calls cannot
    // dispatch the same gateway identity while its native request is being created.
    guard activeRequests[gatewayRequestID] == nil,
      reservedRequestIDs.insert(gatewayRequestID).inserted
    else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP request id '\(gatewayRequestID)' is already active."
      )
    }
    defer { reservedRequestIDs.remove(gatewayRequestID) }

    let cancel: @Sendable () async -> Void = { [weak self] in
      await self?.cancelRetainedWork(gatewayRequestID: gatewayRequestID)
    }
    let work =
      try execution.provider != nil && continuation?.resources.isEmpty == false
      ? execution.authority.retainContinuation(cancellation: cancel)
      : execution.retainWork(cancellation: cancel)
    logicalRequestIDs.insert(gatewayRequestID)
    defer {
      logicalRequestIDs.remove(gatewayRequestID)
      pendingWorkCancellation.remove(gatewayRequestID)
      try? work.finish()
    }
    let (context, ownership) = try await dispatchTool(
      name: name, arguments: arguments, gatewayRequestID: gatewayRequestID,
      host: host, continuation: continuation, execution: execution)
    var confirmedResponse = false
    defer { settleOwnership(ownership, confirmed: confirmedResponse) }
    guard closeTask == nil else {
      try? await client.cancelRequest(context.requestID, reason: "Downstream MCP session retired.")
      throw MCPError.connectionClosed
    }
    activeRequests[gatewayRequestID] = ActiveRequest(
      gatewayRequestID: gatewayRequestID,
      downstreamRequestID: context.requestID,
      tool: name,
      startedAt: Date(), execution: execution, retainsResult: retainsResult
    )
    if retainsResult {
      try journal.update(serverID: server.id, requestID: gatewayRequestID) {
        $0.state = .running
        $0.downstreamRequestID = context.requestID.description
      }
    }
    cancellation?.install(onDeliveryFailure: cancellationDeliveryFailed) {
      [client, journal, server] in
      if retainsResult {
        try journal.update(serverID: server.id, requestID: gatewayRequestID) {
          $0.cancellation = "requested"
        }
      }
      do {
        try await client.cancelRequest(context.requestID, reason: "Upstream MCP request cancelled.")
        if retainsResult {
          try journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "sent"
          }
        }
      } catch {
        if retainsResult {
          try? journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "failed"
          }
        }
        throw error
      }
    }
    defer {
      if activeRequests[gatewayRequestID]?.downstreamRequestID == context.requestID {
        activeRequests.removeValue(forKey: gatewayRequestID)
      }
    }

    if pendingWorkCancellation.remove(gatewayRequestID) != nil {
      _ = try? await requestCancellation(
        gatewayRequestID: gatewayRequestID, reason: "Execution authority was revoked.")
    }
    let result: CallTool.Result
    do {
      result = try await context.value
      confirmedResponse = true
    } catch {
      confirmedResponse = Self.isResponseError(error)
      throw error
    }
    let value = try JSONValue.sdkToolResult(
      content: result.content,
      structuredContent: result.structuredContent,
      isError: result.isError,
      meta: result._meta
    )
    if retainsResult {
      try journal.update(serverID: server.id, requestID: gatewayRequestID) {
        try $0.finish(result: value, failed: result.isError == true)
      }
    }
    try cancellation?.checkCancellation()
    return value
  }

  func startToolCall(
    name: String,
    arguments: [String: JSONValue],
    gatewayRequestID: String, host: HostServiceDispatch?, continuation: MCPContinuationTarget?,
    execution: PreparedExecutionContext
  ) async throws -> JSONValue {
    try await ensureConnected()
    // Reserve before crossing into the SDK actor so concurrent calls cannot
    // dispatch the same gateway identity while its native request is being created.
    guard activeRequests[gatewayRequestID] == nil,
      reservedRequestIDs.insert(gatewayRequestID).inserted
    else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP request id '\(gatewayRequestID)' is already active."
      )
    }
    defer { reservedRequestIDs.remove(gatewayRequestID) }

    let cancel: @Sendable () async -> Void = { [weak self] in
      await self?.cancelRetainedWork(gatewayRequestID: gatewayRequestID)
    }
    let work =
      try execution.provider != nil && continuation?.resources.isEmpty == false
      ? execution.authority.retainContinuation(cancellation: cancel)
      : execution.retainWork(cancellation: cancel)
    logicalRequestIDs.insert(gatewayRequestID)
    var observing = false
    defer {
      if !observing {
        logicalRequestIDs.remove(gatewayRequestID)
        pendingWorkCancellation.remove(gatewayRequestID)
        try? work.finish()
      }
    }
    let (context, ownership) = try await dispatchTool(
      name: name, arguments: arguments, gatewayRequestID: gatewayRequestID,
      host: host, continuation: continuation, execution: execution)
    guard closeTask == nil else {
      try? await client.cancelRequest(context.requestID, reason: "Downstream MCP session retired.")
      throw MCPError.connectionClosed
    }
    let active = ActiveRequest(
      gatewayRequestID: gatewayRequestID,
      downstreamRequestID: context.requestID,
      tool: name,
      startedAt: Date(), execution: execution, retainsResult: true
    )
    activeRequests[gatewayRequestID] = active
    observers[context.requestID] = Task { [weak self] in
      defer { try? work.finish() }
      var confirmedResponse = false
      do {
        let result = try await context.value
        confirmedResponse = true
        let value = try JSONValue.sdkToolResult(
          content: result.content, structuredContent: result.structuredContent,
          isError: result.isError, meta: result._meta)
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID, downstreamRequestID: context.requestID,
          kind: result.isError == true ? "request.error_result" : "request.completed",
          result: value, failed: result.isError == true,
          ownership: ownership, confirmedResponse: true
        )
      } catch is CancellationError {
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID, downstreamRequestID: context.requestID,
          kind: "request.outcome_unknown", ownership: ownership,
          confirmedResponse: confirmedResponse
        )
      } catch {
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID, downstreamRequestID: context.requestID,
          kind: "request.outcome_unknown", ownership: ownership,
          confirmedResponse: confirmedResponse || Self.isResponseError(error)
        )
      }
    }
    observing = true
    try journal.update(serverID: server.id, requestID: gatewayRequestID) {
      $0.state = .running
      $0.downstreamRequestID = context.requestID.description
    }
    appendEvent(kind: "request.started", requestID: gatewayRequestID)

    if pendingWorkCancellation.remove(gatewayRequestID) != nil {
      _ = try? await requestCancellation(
        gatewayRequestID: gatewayRequestID, reason: "Execution authority was revoked.")
    }

    return .object([
      "server": .string(server.id),
      "tool": .string(name),
      "request_id": .string(gatewayRequestID),
      "downstream_request_id": .string(context.requestID.description),
      "state": .string("running"),
      "wait_for_result": .bool(false),
      "started_at": .number(active.startedAt.timeIntervalSince1970),
    ])
  }

  func listResources(cursor: String?) async throws -> JSONValue {
    try await ensureConnected()
    let result = try await client.listResources(cursor: cursor)
    return .object([
      "resources": .array(try result.resources.map { try JSONValue.encoded($0) }),
      "nextCursor": result.nextCursor.map(JSONValue.string) ?? .null,
    ])
  }

  func listResourceTemplates(cursor: String?) async throws -> JSONValue {
    try await ensureConnected()
    let result = try await client.listResourceTemplates(cursor: cursor)
    return .object([
      "resourceTemplates": .array(try result.templates.map { try JSONValue.encoded($0) }),
      "nextCursor": result.nextCursor.map(JSONValue.string) ?? .null,
    ])
  }

  func readResource(uri: String) async throws -> JSONValue {
    try await ensureConnected()
    let contents = try await client.readResource(uri: uri)
    return .object([
      "contents": .array(try contents.map { try JSONValue.encoded($0) })
    ])
  }

  func listPrompts(cursor: String?) async throws -> JSONValue {
    try await ensureConnected()
    let result = try await client.listPrompts(cursor: cursor)
    return .object([
      "prompts": .array(try result.prompts.map { try JSONValue.encoded($0) }),
      "nextCursor": result.nextCursor.map(JSONValue.string) ?? .null,
    ])
  }

  func getPrompt(name: String, arguments: [String: String]?) async throws -> JSONValue {
    try await ensureConnected()
    let result = try await client.getPrompt(name: name, arguments: arguments)
    return .object([
      "description": result.description.map(JSONValue.string) ?? .null,
      "messages": .array(try result.messages.map { try JSONValue.encoded($0) }),
    ])
  }

  func status() -> JSONValue {
    .object([
      "state": .string(
        connected ? "connected" : connectTask == nil ? "not_connected" : "connecting"
      ),
      "persistent_session": .bool(true),
      "active_requests": .integer(Int64(activeRequests.count)),
      "latest_event_cursor": .integer(Int64(nextEventCursor - 1)),
      "last_error": lastError.map(JSONValue.string) ?? .null,
      "initialize": initializeResult.flatMap { try? JSONValue.encoded($0) } ?? .null,
      "provider_work": providerWork?.status ?? .null,
      "unreported_work": .bool(unreportedWork != nil),
    ])
  }

  func readEvents(afterCursor: Int, maxResults: Int, sessionID: String?) throws -> JSONValue {
    guard afterCursor >= 0 else {
      throw GatewayToolError.invalidArguments("after_cursor must be zero or greater.")
    }
    guard (1...500).contains(maxResults) else {
      throw GatewayToolError.invalidArguments("max_results must be between 1 and 500.")
    }
    guard sessionID == nil || sessionID == eventSessionID else {
      throw GatewayToolError.invalidArguments(
        "[cursor.session_mismatch] This cursor belongs to another MCP session. Read from after_cursor 0 without session_id to obtain the current retained range."
      )
    }
    guard afterCursor < nextEventCursor else {
      throw GatewayToolError.invalidArguments(
        "[cursor.out_of_range] after_cursor exceeds the latest event in this MCP session.")
    }
    let oldestCursor = events.first?.cursor ?? nextEventCursor
    let missedEvents = max(0, oldestCursor - afterCursor - 1)
    let selected = events.filter { $0.cursor > afterCursor }.prefix(maxResults)
    let nextCursor = selected.last?.cursor ?? max(afterCursor, nextEventCursor - 1)
    return .object([
      "server": .string(server.id),
      "session_id": .string(eventSessionID),
      "session_verified": .bool(sessionID != nil),
      "cursor_state": .string(
        missedEvents > 0 ? "truncated" : (sessionID != nil ? "valid" : "unbound")),
      "reset_required": .bool(false),
      "after_cursor": .integer(Int64(afterCursor)),
      "next_cursor": .integer(Int64(nextCursor)),
      "oldest_available_cursor": .integer(Int64(oldestCursor)),
      "latest_event_cursor": .integer(Int64(nextEventCursor - 1)),
      "events": .array(selected.map(\.json)),
      "missed_events": .integer(Int64(missedEvents)),
      "has_more": .bool(nextCursor < nextEventCursor - 1),
      "persistent_session": .bool(true),
    ])
  }

  func ownsRequest(_ requestID: String, executionID: UUID?) -> Bool {
    guard let executionID else { return false }
    return activeRequests[requestID]?.executionID == executionID
  }

  func requireActiveRequest(_ requestID: String, executionID: UUID?) throws {
    guard let executionID, let active = activeRequests[requestID],
      active.executionID == executionID
    else { throw MCPContinuationTarget.unavailable() }
    try MCPProviderSessionAuthority.requireMatch(
      admitted: active.execution, running: preparedExecution)
  }

  func activeRequestsJSON(access: any ExecutionAccessChecking) -> JSONValue {
    .object([
      "server": .string(server.id),
      "requests": .array(
        activeRequests.values.filter {
          (try? access.accessExecution($0.executionID, operation: .readResult)) != nil
        }.sorted { $0.gatewayRequestID < $1.gatewayRequestID }.map(\.json)
      ),
      "persistent_session": .bool(true),
    ])
  }

  func cancelRequest(
    gatewayRequestID: String, reason: String, access: any ExecutionAccessChecking
  ) async throws -> JSONValue {
    guard let active = activeRequests[gatewayRequestID], !active.cancellationRequested
    else {
      throw PermissionModelError.invalidAuthorization
    }
    _ = try access.accessExecution(active.executionID, operation: .requestCancellation)
    try requireActiveRequest(gatewayRequestID, executionID: active.executionID)
    return try await requestCancellation(gatewayRequestID: gatewayRequestID, reason: reason)
  }

  private func cancelRetainedWork(gatewayRequestID: String) async {
    guard logicalRequestIDs.contains(gatewayRequestID) else { return }
    guard activeRequests[gatewayRequestID] != nil else {
      pendingWorkCancellation.insert(gatewayRequestID)
      return
    }
    _ = try? await requestCancellation(
      gatewayRequestID: gatewayRequestID, reason: "Execution authority was revoked.")
  }

  private func requestCancellation(gatewayRequestID: String, reason: String) async throws
    -> JSONValue
  {
    guard var active = activeRequests[gatewayRequestID] else {
      throw GatewayToolError.invalidArguments(
        "Unknown active downstream MCP request id: \(gatewayRequestID)"
      )
    }
    if !active.cancellationRequested {
      let observesResponse = observers[active.downstreamRequestID] != nil
      active.cancellationRequested = true
      activeRequests[gatewayRequestID] = active
      appendEvent(kind: "request.cancellation_requested", requestID: gatewayRequestID)
      do {
        if active.retainsResult {
          try journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "requested"
          }
        }
        if observesResponse {
          // A detached call remains observable after a stop request. A native
          // response can establish its outcome, but notification delivery cannot.
          try await client.notify(
            CancelledNotification.message(
              .init(requestId: active.downstreamRequestID, reason: reason)))
        } else {
          // End the synchronous wait without claiming that remote execution ended.
          try await client.cancelRequest(active.downstreamRequestID, reason: reason)
        }
        if active.retainsResult {
          try journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "sent"
          }
        }
        appendEvent(kind: "request.cancellation_sent", requestID: gatewayRequestID)
      } catch {
        if activeRequests[gatewayRequestID]?.downstreamRequestID == active.downstreamRequestID {
          activeRequests[gatewayRequestID]?.cancellationRequested = false
        }
        appendEvent(kind: "request.cancellation_failed", requestID: gatewayRequestID)
        if active.retainsResult {
          try? journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "failed"
          }
        }
        throw error
      }
    }
    return .object([
      "server": .string(server.id),
      "request_id": .string(gatewayRequestID),
      "cancellation_requested": .bool(true),
      "execution_stopped": .null,
    ])
  }

  private func finishStartedRequest(
    gatewayRequestID: String, downstreamRequestID: MCP.ID, kind: String,
    result: JSONValue? = nil, failed: Bool = false,
    ownership: RequestOwnership?, confirmedResponse: Bool = false
  ) {
    logicalRequestIDs.remove(gatewayRequestID)
    pendingWorkCancellation.remove(gatewayRequestID)
    settleOwnership(ownership, confirmed: confirmedResponse)
    observers.removeValue(forKey: downstreamRequestID)
    // Only the matching native request may end this gateway request's observation.
    guard activeRequests[gatewayRequestID]?.downstreamRequestID == downstreamRequestID else {
      return
    }
    activeRequests.removeValue(forKey: gatewayRequestID)
    do {
      try journal.update(serverID: server.id, requestID: gatewayRequestID) {
        if let result {
          try $0.finish(result: result, failed: failed)
        } else {
          $0.state = .outcomeUnknown
          $0.completedAt = Date()
        }
      }
      appendEvent(kind: kind, requestID: gatewayRequestID)
    } catch {
      lastError = "The execution outcome could not be persisted; do not replay this request."
      appendEvent(kind: "request.storage_failed", requestID: gatewayRequestID)
    }
  }

  func validateSelectedOwner(_ target: MCPContinuationTarget) throws {
    guard let selected = target.selectedOwnershipID else { return }
    guard closeTask == nil, target.connectionID == connectionID,
      target.reference.serverID == server.id, target.projectID == projectID,
      ownedWork?.snapshot.contains(where: {
        $0.id == selected && $0.connectionID == connectionID
          && $0.projectID == projectID && $0.registrationID == server.id
      }) == true
    else { throw MCPContinuationTarget.unavailable() }
  }

  private func dispatchTool(
    name: String, arguments: [String: JSONValue], gatewayRequestID: String,
    host: HostServiceDispatch?, continuation: MCPContinuationTarget?,
    execution: PreparedExecutionContext
  ) async throws -> (RequestContext<CallTool.Result>, RequestOwnership?) {
    if !workCatalogObserved && initializeResult?.capabilities.resources != nil {
      _ = try await listTools()
    }
    guard closeTask == nil else { throw MCPError.connectionClosed }
    if host?.action?.isProjectLifecycle == true {
      // The provider's observed marker gates lifecycle dispatch, before any mutation.
      let observed = await (transport as? MCPChildProcessTransport)?.hostServiceContract
      guard observed == MCPHostServiceContract.identifier else {
        throw MCPHostServiceContractError(observed: observed)
      }
    }
    let hostInvocationID = host?.invocationID
    if let continuation {
      try validateSelectedOwner(continuation)
      guard continuation.reference.toolName == name else {
        throw MCPContinuationTarget.unavailable()
      }
      if continuation.selectedOwnershipID == nil || !continuation.resources.isEmpty {
        guard let providerWork else { throw MCPContinuationTarget.unavailable() }
        try providerWork.validate(continuation, tool: name, arguments: .object(arguments))
      }
    }
    try MCPProviderSessionAuthority.requireMatch(admitted: execution, running: preparedExecution)
    let invocation: MCPHostToolDirectory.InvocationLease?
    if let hostInvocationID {
      guard let hostTools, let projectID else { throw MCPError.connectionClosed }
      invocation = try hostTools.retain(
        id: hostInvocationID, projectID: projectID, origin: server.id)
    } else {
      invocation = nil
    }
    let workContext: MCPHostToolDirectory.InvocationLease?
    if providerWork != nil, let hostInvocationID, let hostTools, let projectID {
      workContext = try hostTools.retainWork(
        id: hostInvocationID, projectID: projectID, origin: server.id)
    } else {
      workContext = nil
    }
    let providerLease: ExecutionWorkLease?
    if execution.provider != nil {
      if providerWork != nil {
        let cancel: @Sendable () async -> Void = { [weak self] in
          _ = await self?.disconnect()
        }
        providerLease =
          try continuation?.resources.isEmpty == false
          ? execution.authority.retainContinuation(cancellation: cancel)
          : execution.retainWork(cancellation: cancel)
      } else {
        if unreportedExecutions[execution.executionID] == nil {
          guard unreportedExecutions.count < MCPProviderWork.maximumResources else {
            throw GatewayToolError.invalidArguments(
              "[mcp.work_capacity] Unreported provider work must stop before admitting more calls.")
          }
          unreportedExecutions[execution.executionID] = try execution.retainWork { [weak self] in
            _ = await self?.disconnect()
          }
        }
        providerLease = nil
      }
    } else {
      providerLease = nil
    }
    let providerInvocationID: UUID?
    do {
      providerInvocationID = try providerWork?.beginInvocation(
        tool: name, hostContext: workContext, executionLease: providerLease,
        execution: execution.provider == nil ? nil : execution)
    } catch {
      try? providerLease?.finish()
      throw error
    }
    // A response from a provider without lifetime reporting cannot prove background work drained.
    if providerWork == nil, unreportedWork == nil {
      unreportedWork = ownedWork?.retain(
        .mcpUnreportedWork, projectID: projectID, registrationID: server.id,
        resourceID: connectionID.uuidString, connectionID: connectionID)
      unreportedWork?.markUncertain()
    }
    let work = ownedWork?.retain(
      .mcpRequest, projectID: projectID, registrationID: server.id,
      resourceID: gatewayRequestID, connectionID: connectionID)
    let ownership =
      work != nil || invocation != nil || providerInvocationID != nil
      ? RequestOwnership(
        work: work, invocation: invocation, providerInvocationID: providerInvocationID) : nil
    if let ownership { requestOwnership[ownership.id] = ownership }
    do {
      var fields: [String: MCP.Value] = [:]
      if let hostInvocationID {
        fields[MCPHostInvocation.metadataKey] = .string(hostInvocationID.uuidString)
      }
      if let operationID = host?.operationID {
        fields[MCPHostServiceContract.operationMetadataKey] = .string(
          operationID.uuidString.lowercased())
      }
      if let providerInvocationID {
        fields[MCPProviderWork.invocationKey] = .string(providerInvocationID.uuidString)
      }
      let meta = fields.isEmpty ? nil : MCP.Metadata(additionalFields: fields)
      return (
        try await client.callTool(
          name: name, arguments: arguments.mapValues(\.sdkValue), meta: meta),
        ownership
      )
    } catch {
      settleOwnership(ownership, confirmed: Self.isResponseError(error))
      throw error
    }
  }

  private func settleOwnership(
    _ ownership: RequestOwnership?, confirmed: Bool, providerResponse: Bool = true
  ) {
    guard let ownership else { return }
    if let id = ownership.providerInvocationID {
      providerWork?.finishInvocation(id, confirmed: confirmed && providerResponse)
      refreshProviderWork()
    }
    if confirmed {
      ownership.work?.finish()
      ownership.invocation?.finish()
      requestOwnership.removeValue(forKey: ownership.id)
    } else {
      ownership.work?.markUncertain()
    }
  }

  private static func isResponseError(_ error: any Error) -> Bool {
    guard let error = error as? MCPError else { return false }
    switch error {
    case .methodNotFound, .invalidParams, .serverError, .urlElicitationRequired: return true
    default: return false
    }
  }

  func closeSelected(_ target: MCPContinuationTarget) async throws -> JSONValue {
    try validateSelectedOwner(target)
    let confirmed = await disconnect()
    let remaining = ownedWork?.snapshot.filter { $0.connectionID == connectionID }.count ?? 0
    let local = transport is MCPChildProcessTransport
    return .object([
      "server": .string(server.id), "connection_id": .string(connectionID.uuidString),
      "transport_closed": .bool(true),
      "managed_process_exit_confirmed": local ? .bool(confirmed) : .null,
      "remaining_owners": .integer(Int64(remaining)),
      "work_cleanup": .string(local && confirmed && remaining == 0 ? "confirmed" : "unknown"),
    ])
  }

  func disconnect() async -> Bool {
    if let closeTask { return await closeTask.value }
    workClosed = true
    workPoll?.cancel()
    workDeadline?.cancel()
    providerWork?.disconnected()
    let workObservation = workObservation
    let startup = connectTask
    let terminationObserver = terminationObserver
    startup?.cancel()
    let requests = Array(activeRequests.values)
    let observers = Array(observers.values)
    let retainedRequests = requests.filter(\.retainsResult)
    connected = false
    for request in retainedRequests {
      do {
        try journal.update(serverID: server.id, requestID: request.gatewayRequestID) {
          $0.state = .outcomeUnknown
          $0.completedAt = Date()
          $0.cleanup = "pending"
        }
      } catch { lastError = "Execution receipt storage failed during disconnect." }
    }
    activeRequests.removeAll()
    let task = Task { [client, transport, predecessor] in
      let cancellation = Task {
        for request in requests {
          try? await client.cancelRequest(
            request.downstreamRequestID, reason: "Downstream MCP session disconnected.")
        }
      }
      // Delivery is acknowledged by the transport write, not an arbitrary delay. A
      // blocked pipe still has a finite flush budget and is unblocked by teardown.
      let deliveryObserver = await Self.waitForCancellationDelivery(cancellation)
      await client.disconnect()
      await transport.disconnect()
      await workObservation?.value
      await terminationObserver?.value
      _ = await startup?.result
      // SDK startup may have been suspended in transport.connect at the first close.
      await client.disconnect()
      await cancellation.value
      await deliveryObserver.value
      for observer in observers { await observer.value }
      let predecessorExited = await predecessor?.value ?? true
      let processExited: Bool
      if let child = transport as? MCPChildProcessTransport {
        processExited = await child.shutdownConfirmed()
      } else {
        processExited = true
      }
      return self.finishDisconnect(
        confirmed: predecessorExited && processExited, retainedRequests: retainedRequests)
    }
    closeTask = task
    return await task.value
  }

  private func finishDisconnect(confirmed initial: Bool, retainedRequests: [ActiveRequest]) -> Bool
  {
    var confirmed = initial
    if confirmed, transport is MCPChildProcessTransport {
      unreportedWork?.finish()
      unreportedWork = nil
    }
    // Closing a remote transport is not evidence that remote execution stopped.
    // A local managed child can release unknown requests only after verified exit.
    for ownership in Array(requestOwnership.values) {
      settleOwnership(
        ownership, confirmed: confirmed && transport is MCPChildProcessTransport,
        providerResponse: false)
    }
    if confirmed, transport is MCPChildProcessTransport {
      do {
        try providerWork?.confirmLocalShutdown()
        for (id, lease) in unreportedExecutions {
          try lease.finish()
          unreportedExecutions.removeValue(forKey: id)
        }
      } catch {
        confirmed = false
        lastError = "Provider execution authority cleanup is unconfirmed."
      }
    }
    for request in retainedRequests {
      do {
        try journal.update(serverID: server.id, requestID: request.gatewayRequestID) {
          $0.cleanup = transport is MCPChildProcessTransport && confirmed ? "confirmed" : "unknown"
        }
      } catch { lastError = "Execution cleanup could not be persisted." }
    }
    connectTask = nil
    self.terminationObserver = nil
    self.observers.removeAll()
    if !confirmed { lastError = "An owned downstream process has not confirmed exit." }
    if ownsAdmission { try? preparedExecution?.finishAdmission() }
    appendEvent(kind: confirmed ? "connection.disconnected" : "connection.cleanup_failed")
    return confirmed
  }

  private static func waitForCancellationDelivery(_ delivery: Task<Void, Never>) async
    -> Task<Void, Never>
  {
    let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let delivered = Task {
      await delivery.value
      continuation.yield(())
    }
    let deadline = Task {
      do {
        try await Task.sleep(for: .milliseconds(250))
        continuation.yield(())
      } catch {}
    }
    for await _ in events { break }
    continuation.finish()
    deadline.cancel()
    await deadline.value
    return delivered
  }

  func ensureConnected(
    notifyTools: Bool = true, caller: GatewayDiscoveryCaller? = nil
  ) async throws {
    try caller?.check()
    try Task.checkCancellation()
    guard closeTask == nil else { throw MCPError.connectionClosed }
    if let predecessor, !(await predecessor.value) {
      try caller?.check()
      throw GatewayToolError.executionFailed(
        "Previous MCP process has not confirmed exit; reconnect is blocked.")
    }
    try caller?.check()
    try preparedExecution?.validateProviderLaunch()
    try Task.checkCancellation()
    guard closeTask == nil else { throw MCPError.connectionClosed }
    if connected {
      return
    }

    if !handlersRegistered {
      await registerNotificationHandlers()
      guard closeTask == nil else { throw MCPError.connectionClosed }
      handlersRegistered = true
    }

    let task: Task<Initialize.Result, Error>
    if let connectTask {
      task = connectTask
    } else {
      let client = client
      let transport = transport
      if let child = transport as? MCPChildProcessTransport {
        // Retiring the exact generation clears stale status and resolves SDK
        // requests after owned cleanup, outside the transport reader.
        let onTermination = onTermination
        terminationObserver = Task { [weak self] in
          for await _ in child.termination {}
          if let self { onTermination(self) }
        }
      }
      task = Task {
        try Task.checkCancellation()
        return try await client.connect(transport: transport)
      }
      connectTask = task
    }

    do {
      let result = try await task.value
      try caller?.check()
      try Task.checkCancellation()
      guard closeTask == nil else { throw MCPError.connectionClosed }
      try preparedExecution?.validateProviderLaunch()
      if ownsAdmission { try preparedExecution?.finishAdmission() }
      if !connected {
        initializeResult = result
        connected = true
        lastError = nil
        appendEvent(kind: "connection.connected")
        // A delegated connection shares the reviewed discovery catalog. Opening
        // its separate kill domain does not change the provider's tool schema.
        if notifyTools && preparedExecution?.provider == nil { toolsChanged() }
      }
    } catch {
      if error is GatewayDiscoveryCallerStopped { throw error }
      connected = false
      lastError = String(describing: error)
      appendEvent(kind: "connection.failed")
      // Shared startup can fail after a stopped waiter has left its blocking bridge.
      onTermination(self)
      throw error
    }
  }

  private func registerNotificationHandlers() async {
    await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
      await self?.receiveToolListChange()
    }
    await client.onNotification(ResourceListChangedNotification.self) { [weak self] _ in
      await self?.appendEvent(kind: ResourceListChangedNotification.name)
    }
    await client.onNotification(ResourceUpdatedNotification.self) { [weak self] notification in
      if notification.params.uri == MCPProviderWork.resourceURI {
        await self?.refreshProviderWork()
      }
    }
    await client.onNotification(PromptListChangedNotification.self) { [weak self] _ in
      await self?.appendEvent(kind: PromptListChangedNotification.name)
    }
  }

  /// Observation never tears down a provider or cancels its work on a read timeout.
  private func refreshProviderWork() {
    guard !workClosed, let providerWork else { return }
    workPoll?.cancel()
    workPoll = nil
    guard workObservation == nil else {
      workRefreshPending = true
      return
    }
    workRefreshPending = false
    let id = UUID()
    workObservationID = id
    let completed = providerWork.completedInvocations
    workObservation = Task { [weak self, client] in
      let result: Result<MCPProviderWork.Report, any Error>
      do {
        result = .success(
          try await MCPProviderWork.Report(
            contents: client.readResource(uri: MCPProviderWork.resourceURI)))
      } catch { result = .failure(error) }
      await self?.finishWorkObservation(id: id, result: result, completed: completed)
    }
    let timeout = min(max(server.requestTimeoutMs ?? 30_000, 100), 30_000)
    workDeadline = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(timeout))
        await self?.workObservationExpired(id: id)
      } catch {}
    }
  }

  private func workObservationExpired(id: UUID) {
    guard !workClosed, workObservationID == id else { return }
    providerWork?.observationLost()
    appendEvent(kind: "work.observation_timed_out")
  }

  private func finishWorkObservation(
    id: UUID, result: Result<MCPProviderWork.Report, any Error>, completed: Set<UUID>
  ) {
    guard workObservationID == id else { return }
    workObservation = nil
    workObservationID = nil
    workDeadline?.cancel()
    workDeadline = nil
    guard !workClosed else { return }
    do {
      try providerWork?.accept(result.get(), covering: completed)
    } catch {
      providerWork?.observationLost()
      appendEvent(kind: "work.observation_failed")
    }
    if workRefreshPending {
      refreshProviderWork()
    } else if providerWork?.needsObservation == true {
      workPoll = Task { [weak self] in
        do {
          try await Task.sleep(for: .seconds(1))
          await self?.refreshProviderWork()
        } catch {}
      }
    }
  }

  private func receiveToolListChange() {
    guard closeTask == nil else { return }
    appendEvent(kind: ToolListChangedNotification.name)
    toolsChanged()
  }

  private func appendEvent(kind: String, requestID: String? = nil) {
    events.append(
      Event(cursor: nextEventCursor, kind: kind, timestamp: Date(), requestID: requestID))
    nextEventCursor += 1
    if events.count > 512 {
      events.removeFirst(events.count - 512)
    }
  }

  private static func makeTransport(
    launcher: ExecutionLauncher, server: MCPServerConfig, workingDirectory: URL,
    environment: [String: String],
    hostContext: MCPHostContext?, secretStore: (any SecretStore)?,
    preparedExecution: PreparedExecutionContext?
  ) throws -> any MCP.Transport {
    try server.authentication?.validate(endpoint: server.url, transport: server.transport)
    switch server.transport {
    case .stdio:
      return try MCPChildProcessTransport(
        launcher: launcher, server: server, workingDirectory: workingDirectory,
        environment: environment,
        hostContext: hostContext, preparedExecution: preparedExecution)

    case .streamableHTTP, .sse, .http:
      guard let urlString = server.url, let url = URL(string: urlString) else {
        throw GatewayToolError.executionFailed(
          "MCP server '\(server.id)' has no valid url."
        )
      }
      return MCPHTTPClientTransport(
        endpoint: url, streaming: server.transport != .http,
        bearerToken: { try await server.authentication?.bearerToken(from: secretStore) })
    }
  }
}

private final class AsyncOperationBox<T: Sendable>: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var result: Result<T, Error>?

  func complete(_ result: Result<T, Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    lock.unlock()
    semaphore.signal()
  }

  func wait(timeoutMilliseconds: Int) -> Bool {
    semaphore.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .success
  }

  func get() throws -> T {
    lock.lock()
    defer { lock.unlock() }
    return try result!.get()
  }
}

private final class MCPResolvedCatalogCache: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: [MCPTool]] = [:]
  private func key(_ server: MCPServerConfig, source: String?) -> String {
    MCPExecutionRecord.digest(
      .array([(try? .encoded(server)) ?? .null, source.map(JSONValue.string) ?? .null]))
  }
  func tools(for server: MCPServerConfig, source: String?) -> [MCPTool]? {
    lock.withLock { values[key(server, source: source)] }
  }
  func save(_ tools: [MCPTool], for server: MCPServerConfig, source: String?) {
    lock.withLock { values[key(server, source: source)] = tools }
  }
  func removeAll() { lock.withLock { values.removeAll() } }
}
