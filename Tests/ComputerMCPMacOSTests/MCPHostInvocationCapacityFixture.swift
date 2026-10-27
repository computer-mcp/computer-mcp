import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPProcess
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPPlatformDarwin

/// Captures construction only; each router receives the original scoped native client.
final class MCPInvocationScopedClientCapture: DownstreamMCPClient, @unchecked Sendable {
  struct Scope: Sendable {
    let client: MCPProxyClient
    let host: MCPHostContext
  }

  private let base: MCPProxyClient
  private let projectID: String
  private let lock = NSLock()
  private var observed: [Scope] = []

  init(base: MCPProxyClient, projectID: String) {
    self.base = base
    self.projectID = projectID
  }

  var scopes: [Scope] { lock.withLock { observed } }

  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient {
    let client = base.makeScopedClient(
      workingDirectory: workingDirectory, environment: environment, hostContext: hostContext)
    if let host = hostContext as? MCPHostContext,
      host.launchMetadata.project.id == projectID, let native = client as? MCPProxyClient
    {
      lock.withLock { observed.append(Scope(client: native, host: host)) }
    }
    return client
  }

  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    try base.listTools(server: server, context: context)
  }

  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    try base.callTool(server: server, name: name, arguments: arguments, context: context)
  }

  func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  {
    try base.listResources(server: server, cursor: cursor, context: context)
  }

  func listResourceTemplates(
    server: MCPServerConfig, cursor: String?, context: InvocationContext
  ) throws -> JSONValue {
    try base.listResourceTemplates(server: server, cursor: cursor, context: context)
  }

  func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  {
    try base.readResource(server: server, uri: uri, context: context)
  }

  func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  {
    try base.listPrompts(server: server, cursor: cursor, context: context)
  }

  func getPrompt(
    server: MCPServerConfig, name: String, arguments: [String: String]?, context: InvocationContext
  ) throws -> JSONValue {
    try base.getPrompt(server: server, name: name, arguments: arguments, context: context)
  }
}

/// A finite, separately admitted owner keeps the fixed provider alive during capacity checks.
final class MCPInvocationBackgroundProvider: Sendable {
  let prepared: PreparedExecutionContext
  let process: DarwinProcessIdentity
  private let runtime: GatewayPermissionRuntime
  private let authorization: InvocationAuthorization
  private let host: MCPHostContext
  private let session: GatewayControlSession
  private let childID: UUID
  private let scratch: String

  private init(
    runtime: GatewayPermissionRuntime, authorization: InvocationAuthorization,
    prepared: PreparedExecutionContext, host: MCPHostContext, session: GatewayControlSession,
    process: DarwinProcessIdentity, childID: UUID, scratch: String
  ) {
    self.runtime = runtime
    self.authorization = authorization
    self.prepared = prepared
    self.host = host
    self.session = session
    self.process = process
    self.childID = childID
    self.scratch = scratch
  }

  static func start(
    runtime: GatewayRuntime, session: GatewayControlSession,
    scope: MCPInvocationScopedClientCapture.Scope, server: MCPServerConfig
  ) async throws -> MCPInvocationBackgroundProvider {
    let metadata = scope.host.launchMetadata
    #expect(metadata.runtimeID == runtime.generationID)
    #expect(metadata.profileID == session.profileID && metadata.caller == session.caller)
    #expect(scope.host.verifiedPrincipalID == session.principalID)
    var caller = ExecutionContext(
      caller: session.caller, profileID: session.profileID, projectID: metadata.project.id,
      trustedPrincipalID: scope.host.verifiedPrincipalID)
    caller.controlSession = session
    let subject = try GatewayPermissionSubject(context: caller)
    let requirements = try InvocationRequirements(
      actions: [
        .init(requirement: .init(.project(metadata.project.id), .read)),
        .init(requirement: .init(.mcpServer(server.id), .read)),
      ], mode: .fullAccess(.standing), sandboxProjectID: metadata.project.id,
      execution: .init(background: true, timeMilliseconds: 900_000))
    let decision = try runtime.permissionRuntime.service.admit(
      subject: subject, tool: "mcp.fixture.provider-host", projectID: metadata.project.id,
      argumentsDigest: MCPExecutionRecord.digest(try .encoded(server)),
      requirements: requirements, connectionID: session.id)
    guard case .allowed(let authorization) = decision else {
      Issue.record("The fixed provider's background hosting request was not admitted")
      throw PermissionModelError.invalidAuthorization
    }
    let authority: any InvocationExecutionAuthority
    do {
      authority = try await runtime.permissionRuntime.prepare(
        authorization: authorization,
        descriptor: .init(
          id: "mcp.fixture.provider-host", risk: .readOnly,
          requirement: .downstream(
            serverID: server.id, readOnly: true, remoteExecution: true, hostAction: nil),
          projectRequirement: .required),
        directory: scope.host.projectRoot, connectionID: session.id, auditContext: caller)
    } catch {
      try? runtime.permissionRuntime.service.finishInvocation(authorization.id)
      throw error
    }
    guard let prepared = authority as? PreparedExecutionContext else {
      try? runtime.permissionRuntime.service.finishInvocation(authorization.id)
      throw PermissionModelError.invalidAuthorization
    }
    do {
      _ = try await BlockingOperationExecutor(label: "test.host-invocation.prime").perform {
        try prepared.withValue {
          try scope.client.listTools(
            server: server, context: .init(session: session, executionAuthority: prepared))
        }
      }
      let receipt = try runtime.permissionRuntime.store.readWithDatabase { database, ledger in
        let proof = try #require(ledger.authorizations[authorization.id])
        let execution = try #require(ledger.executions[prepared.executionID])
        let connection = try #require(ledger.environment.connections[session.id])
        let consent = try #require(connection.consent)
        #expect(connection.principal == subject.principal)
        #expect(consent.mode == .fullAccess(.connection(session.id)))
        #expect(proof.basis.contains(.consent(consent.identity)))
        #expect(
          proof.basis.contains {
            if case .connection(let id, _) = $0 { return id == session.id }
            return false
          })
        #expect(proof.invocation == authorization.invocation)
        #expect(proof.requirements == requirements && proof.executionID == prepared.executionID)
        #expect(execution.owner == subject.principal)
        #expect(execution.authorizationIDs == [authorization.id])
        #expect(execution.limitRequest.background)
        #expect(execution.limitRequest.timeMilliseconds == 900_000)
        #expect(execution.limits.timeMilliseconds == 900_000)
        let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
        #expect(record.children.count == 1)
        let child = try #require(record.children.first)
        let recovery = try #require(child.value.recovery)
        let process = try #require(
          DarwinProcessIdentity.current(pid: recovery.root.processID)?.identity)
        #expect(recovery.root.identity == process.uniqueID)
        #expect(!child.value.completed && !record.admissionFinished && !record.completed)
        return (process, child.key, try #require(record.scratchDirectory))
      }
      return MCPInvocationBackgroundProvider(
        runtime: runtime.permissionRuntime, authorization: authorization,
        prepared: prepared, host: scope.host, session: session,
        process: receipt.0, childID: receipt.1, scratch: receipt.2)
    } catch {
      await runtime.shutdown()
      try? prepared.finishAdmission()
      try? await runtime.permissionRuntime.coordinator.stopExecutions([prepared.executionID])
      try? await runtime.permissionRuntime.coordinator.reconcile()
      throw error
    }
  }

  func assertProviderPID(_ pid: Int64) {
    #expect(pid == Int64(process.pid))
    #expect(DarwinProcessIdentity.current(pid: process.pid)?.identity == process)
  }

  func assertIndependentCalls(_ count: Int) throws {
    try runtime.store.readWithDatabase { database, ledger in
      let records = try Data.fetchAll(database, sql: "SELECT payload FROM hostCallRecords").map {
        try JSONDecoder().decode(HostCallRecord.self, from: $0)
      }.filter {
        $0.admission.reference.serverID == "provider"
          && $0.admission.reference.toolName == "background"
      }
      #expect(records.count == count)
      #expect(Set(records.compactMap { $0.admission.authorizationID }).count == count)
      let consent = try #require(ledger.environment.connections[session.id]?.consent)
      for record in records {
        let admission = record.admission
        #expect(admission.generationID == host.launchMetadata.runtimeID)
        #expect(admission.profileID == session.profileID && admission.caller == session.caller)
        #expect(admission.actingPrincipal == .plugin(.localServer("provider")))
        #expect(admission.verifiedClientID == host.verifiedPrincipalID)
        #expect(admission.projectID == host.launchMetadata.project.id)
        #expect(admission.controlSessionID == session.id)
        #expect(admission.authorizationID != authorization.id)
        let proof = try #require(admission.authorizationID.flatMap { ledger.authorizations[$0] })
        #expect(proof.invocation.principal == authorization.invocation.principal)
        #expect(proof.basis.contains(.consent(consent.identity)))
        #expect(!proof.requirements.execution.background)
        #expect(proof.requirements.execution.timeMilliseconds == nil)
      }
      let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      #expect(record.children.count == 1)
      let child = try #require(record.children[childID])
      #expect(child.recovery?.root.processID == process.pid)
      #expect(child.recovery?.root.identity == process.uniqueID)
      #expect(!child.completed && !record.completed)
    }
  }

  /// Call only after router shutdown, so fixture cleanup cannot hide an unjoined child.
  func finishAfterRuntimeShutdown() async throws {
    #expect(
      DarwinProcessIdentity.current(pid: process.pid, includingZombies: true)?.identity != process,
      "GatewayRuntime.shutdown must join the provider before its separate hosting owner is stopped")
    var failure: (any Error)?
    do { try prepared.finishAdmission() } catch { failure = error }
    do {
      try await runtime.coordinator.stopExecutions([prepared.executionID])
    } catch { failure = failure ?? error }
    do { try await runtime.coordinator.reconcile() } catch { failure = failure ?? error }
    do {
      try runtime.store.readWithDatabase { database, ledger in
        let execution = try #require(ledger.executions[prepared.executionID])
        let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
        #expect(!execution.isRunning)
        #expect(record.completed && record.admissionFinished)
        #expect(record.children.values.allSatisfy { $0.completed && $0.released })
        #expect(record.workIDs?.isEmpty ?? true)
        #expect(record.scratchDirectory == nil)
        #expect(!ledger.pendingExecutionTerminations.contains(prepared.executionID))
        #expect(!FileManager.default.fileExists(atPath: scratch))
      }
    } catch { failure = failure ?? error }
    if let failure { throw failure }
  }
}
