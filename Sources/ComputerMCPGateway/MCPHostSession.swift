import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPersistence
import ComputerMCPProcess
import ComputerMCPTransport
import Foundation
import MCP

/// Weak routing avoids extending the authority/lifetime of the originating gateway.
package final class MCPHostToolDirectory: @unchecked Sendable {
  private struct Entry {
    let invocation: MCPHostInvocation
    let store: HostCallRecordStore?
    var requestLeaseIDs: Set<UUID>
    var workLeaseIDs: Set<UUID> = []
  }
  private let lock = NSLock()
  private weak var runtime: GatewayRuntime?
  private var invocations: [UUID: Entry] = [:]

  func attach(_ runtime: GatewayRuntime?) {
    lock.withLock {
      self.runtime = runtime
      if runtime == nil {
        for entry in invocations.values {
          try? Self.replaceLeases(entry, requests: [], work: [])
        }
        invocations.removeAll()
      }
    }
  }

  /// Persist before publishing the in-process lease or entering the provider.
  func begin(_ invocation: MCPHostInvocation, store: HostCallRecordStore?) throws {
    try lock.withLock {
      guard invocations.values.lazy.filter({ !$0.requestLeaseIDs.isEmpty }).count < 256,
        invocations[invocation.id] == nil
      else {
        throw MCPError.serverError(code: -32000, message: "Host invocation capacity reached.")
      }
      if let admission = invocation.admission {
        guard let store else { throw HostCallRecordError.unavailable }
        try store.begin(admission, requestLeaseID: invocation.requestLeaseID)
      }
      invocations[invocation.id] = Entry(
        invocation: invocation, store: store,
        requestLeaseIDs: [invocation.requestLeaseID])
    }
  }
  func end(_ invocation: MCPHostInvocation?) {
    guard let invocation else { return }
    release(invocation.id, leaseID: invocation.requestLeaseID, work: false)
  }

  func retain(id: UUID, projectID: String, origin: String) throws -> InvocationLease {
    try retain(id: id, projectID: projectID, origin: origin, work: false)
  }

  /// The provider work ledger bounds and owns these references separately from active requests.
  func retainWork(id: UUID, projectID: String, origin: String) throws -> InvocationLease {
    try retain(id: id, projectID: projectID, origin: origin, work: true)
  }

  private func retain(id: UUID, projectID: String, origin: String, work: Bool) throws
    -> InvocationLease
  {
    let leaseID = UUID()
    try lock.withLock {
      guard runtime != nil, var entry = invocations[id],
        entry.invocation.context.projectID == projectID,
        entry.invocation.reference.serverID == origin,
        entry.requestLeaseIDs.count + entry.workLeaseIDs.count < 1024
      else { throw MCPError.invalidParams("No matching active host invocation.") }
      var requests = entry.requestLeaseIDs
      var workers = entry.workLeaseIDs
      if work { workers.insert(leaseID) } else { requests.insert(leaseID) }
      try Self.replaceLeases(entry, requests: requests, work: workers)
      entry.requestLeaseIDs = requests
      entry.workLeaseIDs = workers
      invocations[id] = entry
    }
    return InvocationLease(directory: self, id: id, leaseID: leaseID, work: work)
  }

  private func release(_ id: UUID, leaseID: UUID, work: Bool) {
    lock.withLock {
      guard var entry = invocations[id],
        (work ? entry.workLeaseIDs : entry.requestLeaseIDs).contains(leaseID)
      else { return }
      let previous = entry
      if work { entry.workLeaseIDs.remove(leaseID) } else { entry.requestLeaseIDs.remove(leaseID) }
      // A failed journal write cannot retain live authority. The stale saved row
      // will fail exact lease comparison and cannot recreate this process's lease.
      try? Self.replaceLeases(previous, requests: entry.requestLeaseIDs, work: entry.workLeaseIDs)
      if entry.requestLeaseIDs.isEmpty && entry.workLeaseIDs.isEmpty {
        invocations.removeValue(forKey: id)
      } else {
        invocations[id] = entry
      }
    }
  }

  private static func replaceLeases(_ entry: Entry, requests: Set<UUID>, work: Set<UUID>) throws {
    if let admission = entry.invocation.admission {
      guard let store = entry.store else { throw HostCallRecordError.unavailable }
      try store.replaceLeases(
        admission, expectedRequest: entry.requestLeaseIDs,
        expectedWork: entry.workLeaseIDs, requestLeaseIDs: requests, workLeaseIDs: work)
    }
  }

  /// IDs received over MCP only select a directory entry. The directory supplies
  /// the live lease set and compares all durable admission facts before use.
  func requireRecord(_ invocation: MCPHostInvocation) throws {
    try lock.withLock { try requireRecordLocked(invocation, requiresActiveRequest: false) }
  }

  /// Lock order for a mutation is session, directory, then database. No subprocess
  /// runs here; release and runtime shutdown wait for this short commit boundary.
  func withActiveRecord<Result>(
    _ invocation: MCPHostInvocation,
    operation: () throws -> Result
  ) throws -> Result {
    try lock.withLock {
      try requireRecordLocked(invocation, requiresActiveRequest: true)
      return try operation()
    }
  }

  private func requireRecordLocked(
    _ invocation: MCPHostInvocation,
    requiresActiveRequest: Bool
  ) throws {
    guard runtime != nil, let entry = invocations[invocation.id],
      !requiresActiveRequest || !entry.requestLeaseIDs.isEmpty,
      entry.invocation.admission == invocation.admission,
      let admission = invocation.admission, let store = entry.store,
      admission.id == invocation.id,
      admission.reference == invocation.reference,
      admission.action == invocation.admittedCapability.hostServiceAction,
      admission.upstreamName == invocation.upstreamName,
      admission.projectID == invocation.context.projectID,
      admission.profileID == invocation.context.profileID,
      admission.caller == invocation.context.caller,
      admission.verifiedClientID == invocation.context.trustedPrincipalID,
      admission.requestID == invocation.context.requestID,
      admission.authorizationRevision == invocation.authorizationRevision,
      admission.controlSessionID == invocation.context.controlSession?.id,
      admission.argumentsDigest == (try MCPHostInvocation.argumentsDigest(invocation.arguments))
    else { throw HostCallRecordError.mismatch }
    try store.requireLive(
      admission, requestLeaseIDs: entry.requestLeaseIDs,
      workLeaseIDs: entry.workLeaseIDs)
  }

  func active(
    projectID: String, origin: String, includingRetainedWork: Bool = false,
    provider: PreparedExecutionContext? = nil
  )
    -> [MCPHostInvocation]
  {
    let authority = provider.flatMap { try? MCPProviderSessionAuthority($0) }
    guard provider == nil || authority != nil else { return [] }
    return lock.withLock {
      invocations.values.filter { includingRetainedWork || !$0.requestLeaseIDs.isEmpty }
        .map(\.invocation).filter {
          $0.context.projectID == projectID && $0.reference.serverID == origin
            && (authority == nil
              || $0.providerExecution.flatMap {
                try? MCPProviderSessionAuthority($0)
              } == authority)
        }
    }
  }

  func resolve() throws -> GatewayRuntime {
    guard let runtime = lock.withLock({ runtime }) else { throw MCPError.connectionClosed }
    return runtime
  }

  /// Downstream requests can outlive the RPC that returned their started receipt.
  final class InvocationLease: @unchecked Sendable {
    private let directory: MCPHostToolDirectory
    private let id: UUID
    private let leaseID: UUID
    private let work: Bool
    private let lock = NSLock()
    private var finished = false
    fileprivate init(directory: MCPHostToolDirectory, id: UUID, leaseID: UUID, work: Bool) {
      self.directory = directory
      self.id = id
      self.leaseID = leaseID
      self.work = work
    }
    func finish() {
      lock.withLock {
        guard !finished else { return }
        finished = true
        directory.release(id, leaseID: leaseID, work: work)
      }
    }
    deinit { finish() }
  }
}

/// A borrowed standard MCP session. Ending it never shuts down its parent gateway.
final class MCPHostSession: MCPHostSessionHandle {
  let childHandle: FileHandle?
  let providerChannel: ProviderHostServiceChannel?
  private let transport: MCPInheritedSocketTransport
  private let task: Task<Void, Never>
  private let services: MCPHostSessionServices

  init(context: MCPHostContext, server registration: MCPServerConfig) throws {
    guard registration.hostServices, let directory = context.tools else {
      throw GatewayToolError.executionFailed("Host services are not available for this process.")
    }
    let host: FileHandle
    if let execution = context.providerExecution {
      try execution.validateProviderLaunch()
      let metadata = String(
        decoding: try JSONEncoder().encode(context.launchMetadata), as: UTF8.self)
      let pair = try ProviderHostServiceChannel.make(metadata: metadata)
      host = pair.host
      providerChannel = pair.channel
      childHandle = nil
    } else {
      let pair = try MCPInheritedSocketTransport.makePair()
      host = pair.0
      childHandle = pair.1
      providerChannel = nil
    }
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: host)
    self.transport = transport
    let projectID = context.launchMetadata.project.id
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
        try context.providerExecution?.validateProviderLaunch()
        guard params.cursor == nil else { throw MCPError.invalidParams("Unknown tools cursor.") }
        let tools = try directory.resolve().hostToolCatalog(
          projectID: projectID, origin: origin)
        return .init(tools: tools.map(\.sdkTool) + (try await services.tools()))
      }
      await server.withMethodHandler(MCP.CallTool.self) { params in
        // Correlation is not authority. IDs and provenance are generated/bound by the host.
        let arguments = (params.arguments ?? [:]).mapValues(JSONValue.init(sdkValue:))
        return try await admission.perform {
          if let execution = context.providerExecution {
            try execution.validateProviderLaunch()
            guard execution.provider?.delegatingAuthorization != nil else {
              throw MCPError.invalidRequest("Discovery cannot delegate host operations.")
            }
          }
          if params.name.hasPrefix("host.") {
            return try await services.call(name: params.name, arguments: arguments)
          }
          let result = try await directory.resolve().callHostTool(
            name: params.name, arguments: arguments, projectID: projectID,
            origin: origin, requestID: "host:" + sessionID + ":" + UUID().uuidString,
            providerExecution: context.providerExecution)
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
    providerChannel?.close()
    try? childHandle?.close()
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
    try context.providerExecution?.validateProviderLaunch()
    if let bound { return bound }
    bound = try directory.resolve().makeHostServices(context: context, origin: origin)
    return bound
  }
}
