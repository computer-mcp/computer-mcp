import MCP

/// The SDK server's initialized connection owns this subscription until its receive loop ends.
actor MCPToolCatalogNotifier {
  private let registry: any GatewayToolServing
  private let changes: AsyncStream<Void>
  private let initialCatalog: [String: JSONValue]?
  private var started = false
  private var notificationTask: Task<Void, Never>?
  private var completionTask: Task<Void, Never>?

  init(registry: any GatewayToolServing, changes: AsyncStream<Void>, initialCatalog: [MCPTool]?) {
    self.registry = registry
    self.changes = changes
    self.initialCatalog = initialCatalog.map(Self.fingerprint)
  }

  func start(server: MCP.Server) {
    guard !started else { return }
    started = true
    let surface = GatewayMCPToolSurface(registry: registry)
    notificationTask = Task { [changes, initialCatalog, weak server] in
      var previous = initialCatalog
      for await _ in changes {
        guard !Task.isCancelled else { break }
        let current: [String: JSONValue]
        do { current = Self.fingerprint(try await surface.listToolsAsync()) } catch { continue }
        guard current != previous else { continue }
        guard let server else { break }
        do {
          try await server.notify(ToolListChangedNotification.message())
          previous = current
        } catch {
          // A failed notification must not leave a client on a silently stale catalog.
          await server.stop()
          break
        }
      }
    }
    completionTask = Task { [weak self] in
      await server.waitUntilCompleted()
      await self?.stop()
    }
  }

  func stop() {
    notificationTask?.cancel()
    notificationTask = nil
    completionTask = nil
  }

  private static func fingerprint(_ tools: [MCPTool]) -> [String: JSONValue] {
    Dictionary(tools.map { ($0.name, $0.json) }, uniquingKeysWith: { first, _ in first })
  }

  deinit {
    notificationTask?.cancel()
    completionTask?.cancel()
  }
}
