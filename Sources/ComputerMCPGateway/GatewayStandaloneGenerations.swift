import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPTransport
import Foundation

/// A standalone HTTP principal retains execution owners across directory changes.
/// The HTTP connection keeps its own consent and supplies it on every generation.
package actor GatewayStandaloneGenerations: GatewayAsyncToolServing {
  private var current: GatewayRuntime
  private var retired: [GatewayRuntime] = []
  private var retiring: [UUID: Task<Void, Never>] = [:]
  private var pending: Task<GatewayRuntime, any Error>?
  private var closed = false

  package init(_ initial: GatewayRuntime) { current = initial }

  package func makeControlSession() throws -> GatewayControlSession {
    guard !closed else { throw GatewaySocketError.notConnected }
    return try current.makeControlSession()
  }

  private func admitted() async throws -> GatewayRuntime {
    guard !closed else { throw GatewaySocketError.notConnected }
    if let pending { return try await pending.value }
    if try current.hasCurrentProjectInputs() { return current }
    reap()
    guard retired.count + retiring.count < 127 else {
      throw GatewayToolError.disabled("The gateway has reached its owned runtime capacity.")
    }
    let previous = current
    let task = Task {
      do {
        let next = try await previous.refreshedGeneration()
        guard !closed else {
          await next.shutdown()
          throw GatewaySocketError.notConnected
        }
        retired.append(previous)
        current = next
        pending = nil
        reap()
        return next
      } catch {
        pending = nil
        throw error
      }
    }
    pending = task
    return try await task.value
  }

  private func reap() {
    retired.removeAll { runtime in
      guard let cleanup = runtime.beginRetirementIfDrained() else { return false }
      let id = runtime.generationID
      retiring[id] = Task {
        await cleanup.value
        retiring.removeValue(forKey: id)
      }
      return true
    }
  }

  package func listToolsAsync(context: InvocationContext) async throws -> [MCPTool] {
    let runtime = try await admitted()
    let use = try runtime.ownedWork.admitInvocation(projectID: nil, resourceID: "tools/list")
    defer { use.finish() }
    return try await runtime.listToolsAsync(context: context)
  }

  package func refreshTools(context: InvocationContext) async throws {
    try await admitted().refreshTools(context: context)
  }

  package func callToolAsync(name: String, arguments: JSONValue?, context: InvocationContext)
    async throws -> JSONValue
  {
    try await call(name: name, arguments: arguments, context: context, envelope: false)
  }

  package func callToolForMCPAsync(name: String, arguments: JSONValue?, context: InvocationContext)
    async throws -> JSONValue
  {
    try await call(name: name, arguments: arguments, context: context, envelope: true)
  }

  private func call(name: String, arguments: JSONValue?, context: InvocationContext, envelope: Bool)
    async throws -> JSONValue
  {
    guard !closed else { throw GatewaySocketError.notConnected }
    var selected = try retained(name: name, arguments: arguments)
    if selected == nil {
      let runtime = try await admitted()
      selected = try retained(name: name, arguments: arguments) ?? (runtime, nil)
    }
    guard !closed, let (runtime, target) = selected else { throw GatewaySocketError.notConnected }
    let project = target?.projectID ?? arguments?.objectValue?["project_id"]?.stringValue
    let use = try runtime.ownedWork.admitInvocation(projectID: project, resourceID: name)
    defer { use.finish() }
    var scoped = arguments
    if let project = target?.projectID {
      var object = arguments?.objectValue ?? [:]
      if object["project_id"] == nil { object["project_id"] = .string(project) }
      scoped = .object(object)
    }
    let invocation = InvocationContext(
      session: context.session, continuation: context.continuation ?? target)
    return try await GatewayOwnerRouting.$runtimes.withValue([current] + retired) {
      try await GatewayOwnerRouting.$call.withValue({ owner, tool, input in
        try await self.callOwner(owner, name: tool, arguments: input, context: context)
      }) {
        if envelope {
          return try await runtime.callToolForMCPAsync(
            name: name, arguments: scoped, context: invocation)
        }
        return try await runtime.callToolAsync(name: name, arguments: scoped, context: invocation)
      }
    }
  }

  private func callOwner(
    _ owner: GatewayOwnerSelection, name: String, arguments: JSONValue, context: InvocationContext
  ) async throws -> JSONValue {
    guard !closed,
      let runtime = ([current] + retired).first(where: { $0.generationID == owner.runtimeID })
    else {
      throw GatewayOwnerSelection.unavailable()
    }
    return try await runtime.callOwnedTool(
      owner: owner, name: name, arguments: arguments, context: context)
  }

  private func retained(name: String, arguments: JSONValue?) throws -> (
    GatewayRuntime, MCPContinuationTarget?
  )? {
    let generations = [current] + retired
    let projectID =
      arguments?.objectValue?["project_id"]?.stringValue ?? current.unambiguousProjectID
    var lookups: [(GatewayRuntime, GatewayRuntime.ContinuationLookup)] = []
    for runtime in generations {
      for lookup in try runtime.continuationLookups(
        name: name, arguments: arguments, projectID: projectID)
      {
        lookups.append((runtime, lookup))
      }
    }
    if let matches = try MCPContinuationDirectory.uniqueOwner(in: lookups.map { $0.1.observation }),
      let match = matches.first,
      let (runtime, lookup) = lookups.first(where: { $0.1.observation.matches.contains(match) })
    {
      return (
        runtime,
        MCPContinuationTarget(
          projectID: lookup.projectID, reference: lookup.reference,
          connectionID: match.connectionID, instanceID: match.instanceID,
          resources: Dictionary(uniqueKeysWithValues: matches.map { ($0.resource, $0.acquiredBy) }))
      )
    }
    let object = arguments?.objectValue ?? [:]
    let kind: GatewayOwnedWork.Kind
    let key: String
    switch name {
    case "shell.read", "shell.write", "shell.cancel":
      kind = .shell
      key = "session_id"
    case "process.read", "process.write", "process.cancel":
      kind = .shell
      key = "process_id"
    case "mcp.requests.read", "mcp.requests.cancel":
      kind = .mcpRequest
      key = "request_id"
    default: return nil
    }
    guard let id = object[key]?.stringValue else { return nil }
    let owners = generations.filter { runtime in
      runtime.ownedWork.snapshot.contains {
        $0.kind == kind && $0.projectID == projectID && $0.resourceID == id
          && (kind != .mcpRequest || $0.registrationID == object["server"]?.stringValue)
      }
    }
    guard owners.count <= 1 else { throw GatewayOwnerSelection.unavailable() }
    return owners.first.map { ($0, nil) }
  }

  package func shutdown() async {
    guard !closed else { return }
    closed = true
    pending?.cancel()
    if let candidate = try? await pending?.value { await candidate.shutdown() }
    for runtime in [current] + retired { await runtime.shutdown() }
    for task in retiring.values { await task.value }
    retired = []
    retiring = [:]
  }
}
