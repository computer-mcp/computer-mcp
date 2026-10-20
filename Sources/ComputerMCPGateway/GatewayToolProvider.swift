import ComputerMCPCore
import Foundation
import NIOConcurrencyHelpers

internal final class GatewayProviderRouter: GatewayToolServing, Sendable {
  private struct State {
    var snapshot: GatewayToolCatalogSnapshot
    var retainedContinuations: [String: GatewayToolCatalogSnapshot.Route] = [:]
    var monitors: [Task<Void, Never>] = []
    var stopped = false
    var shutdownTask: Task<Void, Never>?
    var lastRefreshError: String?
  }

  private let state: NIOLockedValueBox<State>
  private let source: @Sendable () throws -> [any GatewayToolProvider]
  private let reservedToolNames: Set<String>
  private let shutdownSource: @Sendable () async -> Void
  private let mcpPolicyResolver:
    (@Sendable (MCPToolReference, InvocationContext) throws -> MCPToolAdmissionPolicy)?
  private let retainsContinuation: @Sendable (MCPToolReference) -> Bool
  private let refreshCoordinator = GatewayCatalogRefreshCoordinator()
  private let changes = GatewayToolChangeBroadcaster()

  internal convenience init(providers: [any GatewayToolProvider]) throws {
    try self.init(source: { providers })
  }

  internal init(
    source: @escaping @Sendable () throws -> [any GatewayToolProvider],
    invalidations: AsyncStream<Void>? = nil,
    refreshInterval: Duration? = nil,
    reservedToolNames: Set<String> = [],
    mcpPolicyResolver: (
      @Sendable (MCPToolReference, InvocationContext) throws -> MCPToolAdmissionPolicy
    )? = nil,
    retainsContinuation: @escaping @Sendable (MCPToolReference) -> Bool = { _ in false },
    shutdownSource: @escaping @Sendable () async -> Void = {}
  ) throws {
    self.source = source
    self.reservedToolNames = reservedToolNames
    self.shutdownSource = shutdownSource
    self.mcpPolicyResolver = mcpPolicyResolver
    self.retainsContinuation = retainsContinuation
    self.state = NIOLockedValueBox(
      State(
        snapshot: try .init(providers: source(), reservedToolNames: reservedToolNames)))
    if let invalidations {
      let monitor = Task { [weak self] in
        for await _ in invalidations {
          guard !Task.isCancelled else { break }
          // Catalog invalidations have no caller; refresh failures preserve the validated snapshot.
          try? await self?.refreshTools(context: .empty)
        }
      }
      state.withLockedValue { $0.monitors.append(monitor) }
    }
    if let refreshInterval {
      let monitor = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: refreshInterval) } catch { break }
          guard let self else { break }
          // Periodic catalog maintenance has no caller context.
          try? await self.refreshTools(context: .empty)
        }
      }
      state.withLockedValue { $0.monitors.append(monitor) }
    }
  }

  deinit {
    for monitor in state.withLockedValue({ $0.monitors }) { monitor.cancel() }
    changes.finish()
  }

  internal convenience init(
    registry: GatewayToolRegistry,
    reservedToolNames: Set<String> = [],
    retainsContinuation: @escaping @Sendable (MCPToolReference) -> Bool = { _ in false }
  ) throws {
    try self.init(
      source: registry.providers,
      invalidations: registry.invalidations,
      refreshInterval: registry.refreshInterval,
      reservedToolNames: reservedToolNames,
      mcpPolicyResolver: registry.downstreamPolicy,
      retainsContinuation: retainsContinuation,
      shutdownSource: { await registry.shutdown() }
    )
  }

  internal func listTools(context: InvocationContext) throws -> [MCPTool] {
    try state.withLockedValue { state in
      guard !state.stopped else { throw GatewayProviderRouterError.stopped }
      return state.snapshot.tools
    }
  }

  internal func capability(named name: String, context: InvocationContext) throws
    -> CapabilityDescriptor
  {
    try route(named: name, context: context).capability
  }

  /// A private locator survives catalog hiding while native work still owns its binding.
  internal func continuationReference(named name: String) -> MCPToolReference? {
    state.withLockedValue { state in
      guard !state.stopped else { return nil }
      return state.snapshot.routes[name]?.capability.mcpReference
        ?? state.retainedContinuations[name]?.capability.mcpReference
    }
  }

  internal func downstreamPolicy(
    for reference: MCPToolReference, context: InvocationContext
  ) throws -> MCPToolAdmissionPolicy {
    guard let mcpPolicyResolver else { throw GatewayToolError.unknownTool(reference.toolName) }
    return try mcpPolicyResolver(reference, context)
  }

  internal func callTool(name: String, arguments: JSONValue?, context: InvocationContext)
    throws -> JSONValue
  {
    try callTool(name: name, arguments: arguments, expectedCapability: nil, context: context)
  }

  internal func callTool(
    name: String, arguments: JSONValue?, expectedCapability: CapabilityDescriptor?,
    context: InvocationContext
  ) throws -> JSONValue {
    let route = try route(named: name, expectedCapability: expectedCapability, context: context)
    return try route.provider.callTool(
      .init(name: name, arguments: arguments, context: context))
  }

  internal func callToolAsync(
    name: String, arguments: JSONValue?, context: InvocationContext
  ) async throws -> JSONValue {
    try await callToolAsync(
      name: name, arguments: arguments, expectedCapability: nil, context: context)
  }

  internal func callToolAsync(
    name: String, arguments: JSONValue?, expectedCapability: CapabilityDescriptor?,
    context: InvocationContext
  ) async throws -> JSONValue {
    let route = try route(named: name, expectedCapability: expectedCapability, context: context)
    return try await route.provider.callToolAsync(
      .init(name: name, arguments: arguments, context: context))
  }

  private func route(
    named name: String, expectedCapability: CapabilityDescriptor? = nil,
    context: InvocationContext
  ) throws
    -> GatewayToolCatalogSnapshot.Route
  {
    try state.withLockedValue { state in
      guard !state.stopped else { throw GatewayProviderRouterError.stopped }
      let route: GatewayToolCatalogSnapshot.Route?
      if let target = context.continuationTarget,
        let retained = state.retainedContinuations[name],
        retained.capability.mcpReference == target.reference
      {
        route =
          state.snapshot.routes[name]?.capability.mcpReference == target.reference
          ? state.snapshot.routes[name] : retained
      } else {
        route = state.snapshot.routes[name]
      }
      guard let route else { throw GatewayToolError.unknownTool(name) }
      if let expectedCapability, route.capability != expectedCapability {
        throw GatewayProviderRouterError.capabilityChanged(name)
      }
      return route
    }
  }

  internal func toolChanges(context: InvocationContext) -> AsyncStream<Void> {
    changes.stream()
  }

  internal var lastRefreshError: String? { state.withLockedValue { $0.lastRefreshError } }

  internal func refreshTools(context: InvocationContext) async throws {
    try await refreshCoordinator.run { [self] in
      do {
        try Task.checkCancellation()
        let snapshot: GatewayToolCatalogSnapshot = try await withCheckedThrowingContinuation {
          continuation in
          // Existing providers have synchronous discovery; keep it off cooperative executors.
          DispatchQueue.global(qos: .utility).async { [source, reservedToolNames] in
            continuation.resume(
              with: Result {
                try GatewayToolCatalogSnapshot(
                  providers: source(), reservedToolNames: reservedToolNames)
              })
          }
        }
        try Task.checkCancellation()
        let changed = try state.withLockedValue { state in
          guard !state.stopped else { throw GatewayProviderRouterError.stopped }
          let changed = !state.snapshot.hasSameSurface(as: snapshot)
          let previous = state.retainedContinuations.merging(state.snapshot.routes) { _, new in new
          }
          state.retainedContinuations = previous.filter { name, route in
            guard snapshot.routes[name] == nil, let reference = route.capability.mcpReference else {
              return false
            }
            return retainsContinuation(reference)
          }
          state.snapshot = snapshot
          state.lastRefreshError = nil
          return changed
        }
        if changed { changes.send() }
      } catch {
        state.withLockedValue { $0.lastRefreshError = error.localizedDescription }
        throw error
      }
    }
  }

  internal func shutdown() async {
    let task = state.withLockedValue { state -> Task<Void, Never> in
      if let task = state.shutdownTask { return task }
      state.stopped = true
      let monitors = state.monitors
      let providers = state.snapshot.providers
      let task = Task { [changes, refreshCoordinator, shutdownSource] in
        for monitor in monitors { monitor.cancel() }
        changes.finish()
        await refreshCoordinator.stop()
        for monitor in monitors { await monitor.value }
        for provider in providers { await provider.shutdown() }
        await shutdownSource()
      }
      state.shutdownTask = task
      return task
    }
    await task.value
  }
}

internal enum GatewayProviderRouterError: Error, LocalizedError, Equatable {
  case duplicateTool(String)
  case invalidToolDefinition(String)
  case capabilityChanged(String)
  case stopped

  internal var errorDescription: String? {
    switch self {
    case .duplicateTool(let name):
      return "Multiple gateway providers expose tool '\(name)'."
    case .invalidToolDefinition(let name):
      return "Gateway tool '\(name)' has an invalid name or schema shape."
    case .capabilityChanged(let name):
      return
        "[gateway.catalog_changed] Capability '\(name)' changed before dispatch; no operation was executed."
    case .stopped:
      return "The gateway tool catalog is stopped."
    }
  }
}
