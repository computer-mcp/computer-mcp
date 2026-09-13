import Foundation

/// Definitions, capabilities, and provider ownership are published together.
struct GatewayToolCatalogSnapshot: Sendable {
  struct Route: Sendable {
    let tool: MCPTool
    let capability: CapabilityDescriptor
    let provider: any GatewayToolProvider
  }

  let tools: [MCPTool]
  let routes: [String: Route]
  let providers: [any GatewayToolProvider]

  init(providers: [any GatewayToolProvider], reservedToolNames: Set<String> = []) throws {
    var tools: [MCPTool] = []
    var routes: [String: Route] = [:]
    for provider in providers {
      for tool in try provider.listTools() {
        guard !tool.name.isEmpty, !tool.name.contains("\0"), tool.inputSchema.objectValue != nil,
          tool.outputSchema == nil || tool.outputSchema?.objectValue != nil
        else { throw GatewayProviderRouterError.invalidToolDefinition(tool.name) }
        guard routes[tool.name] == nil, !reservedToolNames.contains(tool.name) else {
          throw GatewayProviderRouterError.duplicateTool(tool.name)
        }
        tools.append(tool)
        routes[tool.name] = Route(
          tool: tool, capability: provider.capability(for: tool), provider: provider)
      }
    }
    self.tools = tools
    self.routes = routes
    self.providers = providers
  }

  func hasSameSurface(as other: Self) -> Bool {
    guard routes.count == other.routes.count else { return false }
    return routes.allSatisfy { name, route in
      guard let otherRoute = other.routes[name] else { return false }
      return route.tool.json == otherRoute.tool.json && route.capability == otherRoute.capability
    }
  }
}

/// Serializes refreshes so an invalidation received during discovery gets a subsequent pass.
actor GatewayCatalogRefreshCoordinator {
  private var task: Task<Void, Error>?
  private var taskID: UUID?
  private var pendingTasks: [UUID: Task<Void, Error>] = [:]
  private var stopped = false

  func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
    guard !stopped else { throw GatewayProviderRouterError.stopped }
    let preceding = task
    let id = UUID()
    let task = Task {
      _ = try? await preceding?.value
      try Task.checkCancellation()
      try await operation()
    }
    self.task = task
    self.taskID = id
    pendingTasks[id] = task
    defer {
      pendingTasks.removeValue(forKey: id)
      if taskID == id {
        self.task = nil
        self.taskID = nil
      }
    }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func stop() async {
    stopped = true
    let pending = Array(pendingTasks.values)
    for task in pending { task.cancel() }
    // Provider teardown must not race an earlier discovery in the serialized chain.
    for task in pending { _ = await task.result }
  }
}
