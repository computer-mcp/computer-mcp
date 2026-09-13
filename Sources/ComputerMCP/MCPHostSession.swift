import Foundation
import MCP

/// Weak routing avoids extending the authority/lifetime of the originating gateway.
package final class MCPHostToolDirectory: @unchecked Sendable {
  private let lock = NSLock()
  private weak var runtime: GatewayRuntime?
  private var invocations: [UUID: MCPHostInvocation] = [:]

  func attach(_ runtime: GatewayRuntime?) { lock.withLock { self.runtime = runtime } }

  func begin(_ invocation: MCPHostInvocation) throws {
    try lock.withLock {
      guard invocations.count < 256 else {
        throw MCPError.serverError(code: -32000, message: "Host invocation capacity reached.")
      }
      invocations[invocation.id] = invocation
    }
  }
  func end(_ invocation: MCPHostInvocation?) {
    guard let invocation else { return }
    _ = lock.withLock { invocations.removeValue(forKey: invocation.id) }
  }
  func active(workspaceID: String, origin: String) -> [MCPHostInvocation] {
    lock.withLock {
      invocations.values.filter {
        $0.context.workspaceID == workspaceID && $0.reference.serverID == origin
      }
    }
  }

  func resolve() throws -> GatewayRuntime {
    guard let runtime = lock.withLock({ runtime }) else { throw MCPError.connectionClosed }
    return runtime
  }
}

/// A borrowed standard MCP session. Ending it never shuts down its parent gateway.
final class MCPHostSession: Sendable {
  let childHandle: FileHandle
  private let transport: MCPInheritedSocketTransport
  private let task: Task<Void, Never>
  private let services: MCPHostSessionServices

  init(context: MCPHostContext, server registration: MCPServerConfig) throws {
    guard registration.hostServices, let directory = context.tools else {
      throw GatewayToolError.executionFailed("Host services are not available for this process.")
    }
    let pair = try MCPInheritedSocketTransport.makePair()
    childHandle = pair.1
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    self.transport = transport
    let workspaceID = context.workspace.id
    let origin = registration.id
    let sessionID = UUID().uuidString
    let services = MCPHostSessionServices(directory: directory, context: context, origin: origin)
    self.services = services
    let admission = MCPHostRequestAdmission()
    task = Task {
      let server = MCP.Server(
        name: "computer-mcp-host", version: ComputerMCPCLI.version,
        capabilities: .init(tools: .init()))
      await server.withMethodHandler(MCP.ListTools.self) { params in
        guard params.cursor == nil else { throw MCPError.invalidParams("Unknown tools cursor.") }
        let tools = try directory.resolve().hostToolCatalog(
          workspaceID: workspaceID, origin: origin)
        return .init(tools: tools.map(\.sdkTool) + (try await services.tools()))
      }
      await server.withMethodHandler(MCP.CallTool.self) { params in
        // Correlation is not authority. IDs and provenance are generated/bound by the host.
        let arguments = (params.arguments ?? [:]).mapValues(JSONValue.init(sdkValue:))
        return try await admission.perform {
          if params.name.hasPrefix("host.") {
            return try await services.call(name: params.name, arguments: arguments)
          }
          let result = try await directory.resolve().callHostTool(
            name: params.name, arguments: arguments, workspaceID: workspaceID,
            origin: origin, requestID: "host:" + sessionID + ":" + UUID().uuidString)
          return try result.sdkCallToolResult()
        }
      }
      do {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
      } catch {}
      await server.stop()
      await services.close()
      await transport.disconnect()
    }
  }

  func close() async {
    try? childHandle.close()
    await transport.disconnect()
    await task.value
    await services.close()
  }

  func shutdownConfirmed() async -> Bool { await services.cleanupConfirmed }
}

/// The SDK may dispatch requests concurrently; do not turn a bounded stream into an unbounded queue.
private actor MCPHostRequestAdmission {
  private var active = 0
  func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    guard active < 16 else {
      throw MCPError.serverError(code: -32000, message: "Host callback capacity reached.")
    }
    active += 1
    defer { active -= 1 }
    return try await operation()
  }
}

/// Gateway construction discovers the plugin catalog before attaching its runtime.
/// Resolve host services only when the established adapter actually uses its callback channel.
private actor MCPHostSessionServices {
  let directory: MCPHostToolDirectory
  let context: MCPHostContext
  let origin: String
  private var bound: MCPBoundHostServices?
  private var closed = false
  init(directory: MCPHostToolDirectory, context: MCPHostContext, origin: String) {
    self.directory = directory
    self.context = context
    self.origin = origin
  }
  func tools() throws -> [MCP.Tool] { try resolve() == nil ? [] : MCPBoundHostServices.tools }
  func call(name: String, arguments: [String: JSONValue]) async throws -> MCP.CallTool.Result {
    guard let services = try resolve() else {
      throw MCPHostServiceError.denied("Host persistence is unavailable.")
    }
    return try await services.call(name: name, arguments: arguments)
  }
  var cleanupConfirmed: Bool {
    get async {
      guard closed else { return false }
      return await bound?.cleanupConfirmed ?? true
    }
  }
  func close() async {
    closed = true
    await bound?.close()
  }
  private func resolve() throws -> MCPBoundHostServices? {
    guard !closed else { throw MCPError.connectionClosed }
    if let bound { return bound }
    bound = try directory.resolve().makeHostServices(context: context, origin: origin)
    return bound
  }
}
