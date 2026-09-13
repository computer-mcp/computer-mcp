import Foundation
import os

internal protocol GatewayToolProvider: Sendable {
  var id: String { get }
  func listTools() throws -> [MCPTool]
  func capability(for tool: MCPTool) -> CapabilityDescriptor
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue
  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
  func shutdown() async
}

extension GatewayToolProvider {
  internal func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result {
            try self.callTool(name: name, arguments: arguments)
          })
      }
    }
  }

  internal func shutdown() async {}
}

internal struct GatewayCapabilityCatalog: Sendable {
  internal func descriptor(for tool: MCPTool) -> CapabilityDescriptor {
    let name = tool.name
    let risk: CapabilityRisk
    if name.hasPrefix("shell.") || name == "cli.exec" || name == "process.spawn" {
      risk = .fullShell
    } else if name == "operations.commit" {
      risk = .externalWrite
    } else if name.hasPrefix("mcp.") && name != "mcp.tools.call"
      && name != "mcp.requests.cancel"
    {
      risk = .readOnly
    } else if tool.annotations?.destructiveHint == true {
      risk = .destructive
    } else if tool.annotations?.readOnlyHint == true {
      risk = .readOnly
    } else if name.hasPrefix("file.") || name.hasPrefix("git.")
      || name.hasPrefix("workspace.")
    {
      risk = .workspaceWrite
    } else {
      risk = .externalWrite
    }

    let workspaceRequirement: WorkspaceRequirement
    if name == "workspace.list" || name == "workspace.describe"
      || name.hasPrefix("skills.") || name.hasPrefix("system.")
      || name.hasPrefix("macos.") || name.hasPrefix("network.")
      || name.hasPrefix("mcp.") || name == "cli.list" || name == "cli.status"
      || name == "cli.describe" || name == "cli.help"
    {
      workspaceRequirement = .none
    } else if name.hasPrefix("operations.") {
      workspaceRequirement = .optional
    } else if name.hasPrefix("shell.") {
      workspaceRequirement = .required
    } else if name.hasPrefix("file.") || name.hasPrefix("git.")
      || name.hasPrefix("workspace.") || name.hasPrefix("cli.")
      || name.hasPrefix("process.") || name.hasPrefix("codex.")
    {
      workspaceRequirement = .required
    } else {
      workspaceRequirement = .optional
    }

    return CapabilityDescriptor(
      id: name,
      risk: risk,
      workspaceRequirement: workspaceRequirement,
      localOnly: false,
      usesNetwork: name.hasPrefix("network.") || name.hasPrefix("mcp.")
    )
  }
}

internal struct GatewayDomainToolProvider: GatewayToolProvider, Sendable {
  internal let id: String
  private let registry: GatewayToolRegistry
  private let tools: [MCPTool]

  internal init(
    id: String,
    registry: GatewayToolRegistry,
    tools: [MCPTool]
  ) {
    self.id = id
    self.registry = registry
    self.tools = tools
  }

  internal func listTools() throws -> [MCPTool] {
    tools
  }

  internal func capability(for tool: MCPTool) -> CapabilityDescriptor {
    registry.capability(for: tool)
  }

  internal func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    guard let definition = tools.first(where: { $0.name == name }) else {
      throw GatewayToolError.unknownTool(name)
    }
    return try registry.callTool(definition: definition, arguments: arguments)
  }

  internal func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    guard let definition = tools.first(where: { $0.name == name }) else {
      throw GatewayToolError.unknownTool(name)
    }
    return try await registry.callToolAsync(definition: definition, arguments: arguments)
  }
}

internal enum GatewayToolDomain: String, CaseIterable, Sendable {
  case cli
  case process
  case shell
  case mcp
  case skills
  case workspace
  case file
  case structured
  case git
  case system
  case network
  case macos
  case configured

  fileprivate static func classify(_ name: String) -> GatewayToolDomain {
    if name.hasPrefix("cli.") { return .cli }
    if name.hasPrefix("process.") { return .process }
    if name.hasPrefix("shell.") { return .shell }
    if name.hasPrefix("mcp.") { return .mcp }
    if name.hasPrefix("skills.") { return .skills }
    if name.hasPrefix("workspace.") { return .workspace }
    if name.hasPrefix("file.") || name.hasPrefix("archive.") { return .file }
    if name.hasPrefix("json.") || name.hasPrefix("jsonl.") || name.hasPrefix("toml.")
      || name.hasPrefix("yaml.") || name.hasPrefix("xml.") || name.hasPrefix("plist.")
      || name.hasPrefix("csv.") || name.hasPrefix("sqlite.")
      || name.hasPrefix("structured.") || name.hasPrefix("markdown.")
      || name.hasPrefix("image.") || name.hasPrefix("pdf.") || name.hasPrefix("media.")
    {
      return .structured
    }
    if name.hasPrefix("git.") { return .git }
    if name.hasPrefix("system.") || name.hasPrefix("logs.") || name.hasPrefix("service.")
      || name.hasPrefix("env.")
    {
      return .system
    }
    if name.hasPrefix("network.") { return .network }
    if name.hasPrefix("macos.") { return .macos }
    return .configured
  }
}

internal final class GatewayProviderRouter: GatewayToolServing, Sendable {
  private struct State {
    var snapshot: GatewayToolCatalogSnapshot
    var monitors: [Task<Void, Never>] = []
    var stopped = false
    var shutdownTask: Task<Void, Never>?
    var lastRefreshError: String?
  }

  private let state: OSAllocatedUnfairLock<State>
  private let source: @Sendable () throws -> [any GatewayToolProvider]
  private let reservedToolNames: Set<String>
  private let shutdownSource: @Sendable () async -> Void
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
    shutdownSource: @escaping @Sendable () async -> Void = {}
  ) throws {
    self.source = source
    self.reservedToolNames = reservedToolNames
    self.shutdownSource = shutdownSource
    self.state = OSAllocatedUnfairLock(
      initialState: State(
        snapshot: try .init(providers: source(), reservedToolNames: reservedToolNames)))
    if let invalidations {
      let monitor = Task { [weak self] in
        for await _ in invalidations {
          guard !Task.isCancelled else { break }
          // refreshTools records failures and preserves the validated snapshot.
          try? await self?.refreshTools()
        }
      }
      state.withLock { $0.monitors.append(monitor) }
    }
    if let refreshInterval {
      let monitor = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: refreshInterval) } catch { break }
          guard let self else { break }
          try? await self.refreshTools()
        }
      }
      state.withLock { $0.monitors.append(monitor) }
    }
  }

  deinit {
    for monitor in state.withLock({ $0.monitors }) { monitor.cancel() }
    changes.finish()
  }

  internal convenience init(registry: GatewayToolRegistry) throws {
    try self.init(registry: registry, additionalProviders: [])
  }

  internal convenience init(
    registry: GatewayToolRegistry,
    additionalProviders: [any GatewayToolProvider],
    reservedToolNames: Set<String> = []
  ) throws {
    try self.init(
      source: {
        let tools = try registry.listTools()
        return GatewayToolDomain.allCases.map { domain in
          GatewayDomainToolProvider(
            id: domain.rawValue, registry: registry,
            tools: tools.filter { GatewayToolDomain.classify($0.name) == domain })
        } + (try registry.cliTreeProviders()) + additionalProviders
      },
      invalidations: registry.toolChanges(),
      refreshInterval: registry.hasReexportedMCPServers || registry.hasCLITrees
        ? .seconds(30) : nil,
      reservedToolNames: reservedToolNames,
      shutdownSource: { await registry.shutdown() }
    )
  }

  internal func listTools() throws -> [MCPTool] {
    try state.withLock { state in
      guard !state.stopped else { throw GatewayProviderRouterError.stopped }
      return state.snapshot.tools
    }
  }

  internal func capability(named name: String) throws -> CapabilityDescriptor {
    try route(named: name).capability
  }

  internal func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    try callTool(name: name, arguments: arguments, expectedCapability: nil)
  }

  internal func callTool(
    name: String, arguments: JSONValue?, expectedCapability: CapabilityDescriptor?
  ) throws -> JSONValue {
    let route = try route(named: name, expectedCapability: expectedCapability)
    return try route.provider.callTool(name: name, arguments: arguments)
  }

  internal func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await callToolAsync(name: name, arguments: arguments, expectedCapability: nil)
  }

  internal func callToolAsync(
    name: String, arguments: JSONValue?, expectedCapability: CapabilityDescriptor?
  ) async throws -> JSONValue {
    let route = try route(named: name, expectedCapability: expectedCapability)
    return try await route.provider.callToolAsync(name: name, arguments: arguments)
  }

  private func route(named name: String, expectedCapability: CapabilityDescriptor? = nil) throws
    -> GatewayToolCatalogSnapshot.Route
  {
    try state.withLock { state in
      guard !state.stopped else { throw GatewayProviderRouterError.stopped }
      guard let route = state.snapshot.routes[name] else {
        throw GatewayToolError.unknownTool(name)
      }
      if let expectedCapability, route.capability != expectedCapability {
        throw GatewayProviderRouterError.capabilityChanged(name)
      }
      return route
    }
  }

  internal func toolChanges() -> AsyncStream<Void> { changes.stream() }

  internal var lastRefreshError: String? { state.withLock { $0.lastRefreshError } }

  internal func refreshTools() async throws {
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
        let changed = try state.withLock { state in
          guard !state.stopped else { throw GatewayProviderRouterError.stopped }
          let changed = !state.snapshot.hasSameSurface(as: snapshot)
          state.snapshot = snapshot
          state.lastRefreshError = nil
          return changed
        }
        if changed { changes.send() }
      } catch {
        state.withLock { $0.lastRefreshError = error.localizedDescription }
        throw error
      }
    }
  }

  internal func shutdown() async {
    let task = state.withLock { state -> Task<Void, Never> in
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
