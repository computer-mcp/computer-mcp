import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPPlatformDarwin

/// Captures construction only; each router receives the original scoped native client.
final class MCPInvocationScopedClientCapture: DownstreamMCPClient, @unchecked Sendable {
  struct Scope: Sendable {
    let client: MCPProxyClient
    let host: MCPHostContext
  }

  private let base: MCPProxyClient
  private let projectID: String
  private let discoveryGate: MCPInvocationDiscoverySelectionGate?
  private let lock = NSLock()
  private var observed: [Scope] = []

  init(
    base: MCPProxyClient, projectID: String,
    discoveryGate: MCPInvocationDiscoverySelectionGate? = nil
  ) {
    self.base = base
    self.projectID = projectID
    self.discoveryGate = discoveryGate
  }

  var scopes: [Scope] { lock.withLock { observed } }

  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient {
    var scopedHost = hostContext
    if let discoveryGate, var host = hostContext as? MCPHostContext,
      let source = host.providerSource
    {
      host.providerSource = { server in
        let original = try source(server)
        return MCPProviderExecutionSource(digest: original.digest) { replacement, caller in
          if let replacement { try discoveryGate.willPrepareReplacement(replacement) }
          return try original.prepareDiscovery(replacement, caller)
        }
      }
      scopedHost = host
    }
    let client = base.makeScopedClient(
      workingDirectory: workingDirectory, environment: environment, hostContext: scopedHost)
    if let host = scopedHost as? MCPHostContext,
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
  private let discoveryClient: MCPProxyClient
  private let server: MCPServerConfig
  private let childID: UUID
  private let scratch: String

  private init(
    runtime: GatewayPermissionRuntime, authorization: InvocationAuthorization,
    prepared: PreparedExecutionContext, host: MCPHostContext, session: GatewayControlSession,
    process: DarwinProcessIdentity, childID: UUID, scratch: String,
    discoveryClient: MCPProxyClient, server: MCPServerConfig
  ) {
    self.runtime = runtime
    self.authorization = authorization
    self.prepared = prepared
    self.host = host
    self.session = session
    self.discoveryClient = discoveryClient
    self.server = server
    self.process = process
    self.childID = childID
    self.scratch = scratch
  }

  static func start(
    runtime: GatewayRuntime, database: GatewayDatabase, session: GatewayControlSession,
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
        .init(
          requirement: .init(.project(metadata.project.id), .read),
          scope: .project(metadata.project.id)),
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
      let configuration = try database.configurationState()
      let registration = try #require(configuration.projects.first { $0.id == metadata.project.id })
      let bookmarks = try #require(runtime.permissionRuntime.service.projectBookmarks)
      let access = try bookmarks.resolve(registration)
      try runtime.requirePreparedProject(id: registration.id, root: access.rootIdentity)
      let project = try GatewayProviderProject(
        registration: .init(
          id: registration.id, root: ProjectPathResolver.canonicalProject(access.rootURL).path,
          registeredAt: registration.createdAt),
        access: access,
        wasDerived: configuration.derivedProjects.contains { $0.projectID == registration.id })
      authority = try await runtime.permissionRuntime.prepareProvider(
        review: GatewayProviderReview(server: server, configuration: configuration),
        registrationID: server.id, authorization: authorization,
        directory: scope.host.projectRoot, connectionID: session.id,
        auditContext: caller, project: project)
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
          try scope.client.callTool(
            server: server, name: "replay", arguments: .object([:]),
            context: .init(session: session, executionAuthority: prepared))
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
        #expect(execution.authorizationIDs == prepared.provider?.authorizationIDs)
        #expect(execution.authorizationIDs.contains(authorization.id))
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
        process: receipt.0, childID: receipt.1, scratch: receipt.2,
        discoveryClient: scope.client, server: server)
    } catch {
      await runtime.shutdown()
      try? prepared.finishAdmission()
      try? await runtime.permissionRuntime.coordinator.stopExecutions([prepared.executionID])
      try? await runtime.permissionRuntime.coordinator.reconcile()
      throw error
    }
  }

  func listIndependentDiscovery() throws -> [MCPTool] {
    try discoveryClient.listTools(server: server, context: .empty)
  }

  func finishRetainedWork() throws -> JSONValue {
    try prepared.withValue {
      try discoveryClient.callTool(
        server: server, name: "finish", arguments: .object([:]),
        context: .init(session: session, executionAuthority: prepared))
    }
  }

  func cachedDiscovery() throws -> [MCPTool]? {
    try discoveryClient.cachedTools(server: server, context: .empty)
  }

  func discoveryChanges() -> AsyncStream<Void> { discoveryClient.toolChanges() }

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
        #expect(proof.requirements.execution.timeMilliseconds == 600_000)
      }
      let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      #expect(record.children.count == 1)
      let child = try #require(record.children[childID])
      #expect(child.recovery?.root.processID == process.pid)
      #expect(child.recovery?.root.identity == process.uniqueID)
      #expect(!child.completed && !record.completed)
    }
  }

  /// Advances only the ledger's existing deadline reconciliation; actual calls and
  /// their separately admitted provider keep their original, longer authority.
  func expireDiscoveryPreservingActualAuthority(inFlightPID: Int32? = nil) throws -> [UUID] {
    try runtime.store.transactionWithDatabase { database, ledger in
      let discoveries = ledger.executions.values.filter { execution in
        execution.isRunning
          && execution.authorizationIDs.contains {
            ledger.authorizations[$0]?.invocation.tool == "provider.discovery"
              && ledger.authorizations[$0]?.invocation.projectID == nil
          }
      }
      #expect(!discoveries.isEmpty)
      if let inFlightPID {
        let pids = try discoveries.flatMap { execution in
          try ExecutionRuntimeRecord.load(execution.id, database)?.children.values.compactMap {
            $0.recovery?.root.processID
          } ?? []
        }
        #expect(pids.contains(inFlightPID))
      }
      let deadlines = try discoveries.map { discovery in
        let milliseconds = try #require(discovery.limits.timeMilliseconds)
        #expect(milliseconds == 120_000)
        return discovery.startedAt.addingTimeInterval(Double(milliseconds) / 1000 + 0.001)
      }
      let now = try #require(deadlines.max())
      let calls = ledger.authorizations.values.filter {
        $0.requirements.execution.timeMilliseconds == 600_000
      }
      #expect(!calls.isEmpty && calls.allSatisfy { !$0.revoked })
      let liveCalls = ledger.executions.values.filter {
        $0.isRunning && $0.limits.timeMilliseconds == 600_000
      }.map(\.id)
      let result = ledger.reconcileExecutionLimits(now: now)
      for discovery in discoveries {
        #expect(result.executionsToTerminate.contains(discovery.id))
        #expect(ledger.executions[discovery.id]?.limitEndReason == .timeLimit)
      }
      let provider = try #require(ledger.executions[prepared.executionID])
      #expect(provider.isRunning && !provider.revoked)
      #expect(provider.limits.timeMilliseconds == 900_000)
      #expect(!result.executionsToTerminate.contains(provider.id))
      #expect(ledger.authorizations[authorization.id]?.revoked == false)
      for id in liveCalls {
        #expect(ledger.executions[id]?.isRunning == true)
        #expect(!result.executionsToTerminate.contains(id))
      }
      for proof in calls { #expect(ledger.authorizations[proof.id]?.revoked == false) }
      return discoveries.map(\.id)
    }
  }

  struct DiscoveryExpiryEvidence: Sendable {
    let before: AuthorizedExecution
    let after: AuthorizedExecution
    let proof: InvocationAuthorization
    let proofAfter: InvocationAuthorization
  }

  func expireSelectedDiscovery(_ id: UUID) throws -> DiscoveryExpiryEvidence {
    try runtime.store.transactionWithDatabase { _, ledger in
      let before = try #require(ledger.executions[id])
      let proofs = before.authorizationIDs.compactMap { ledger.authorizations[$0] }
      let proof = try #require(proofs.first)
      guard before.isRunning, proofs.count == 1, proof.invocation.tool == "provider.discovery",
        proof.invocation.projectID == nil, before.owner == proof.invocation.principal,
        before.delegatedTo == nil, before.limits.timeMilliseconds == 120_000
      else { throw PermissionModelError.invalidAuthorization }
      let liveCalls = ledger.executions.values.filter {
        $0.isRunning && $0.limits.timeMilliseconds == 600_000
      }.map(\.id)
      guard !liveCalls.isEmpty else { throw PermissionModelError.invalidAuthorization }
      let otherRunning = ledger.executions.values.filter { $0.id != id && $0.isRunning }
      let expiry = before.startedAt.addingTimeInterval(120.001)
      let otherDiscoveries = ledger.executions.values.filter { execution in
        execution.id != id && execution.isRunning
          && execution.authorizationIDs.contains {
            ledger.authorizations[$0]?.invocation.tool == "provider.discovery"
          }
      }
      guard
        otherDiscoveries.allSatisfy({ execution in
          guard let milliseconds = execution.limits.timeMilliseconds else { return true }
          return execution.startedAt.addingTimeInterval(Double(milliseconds) / 1000) > expiry
        })
      else { throw PermissionModelError.invalidAuthorization }
      let result = ledger.reconcileExecutionLimits(now: expiry)
      let after = try #require(ledger.executions[id])
      guard result.executionsToTerminate.contains(id), after.limitEndReason == .timeLimit,
        let fixed = ledger.executions[prepared.executionID], fixed.isRunning, !fixed.revoked,
        fixed.limits.timeMilliseconds == 900_000,
        !result.executionsToTerminate.contains(fixed.id),
        otherRunning.allSatisfy({ execution in
          ledger.executions[execution.id]?.isRunning == true
            && ledger.executions[execution.id]?.revoked == execution.revoked
        }),
        liveCalls.allSatisfy({
          ledger.executions[$0]?.isRunning == true
            && !result.executionsToTerminate.contains($0)
        })
      else { throw PermissionModelError.invalidAuthorization }
      let proofAfter = try #require(ledger.authorizations[proof.id])
      return DiscoveryExpiryEvidence(
        before: before, after: after, proof: proof, proofAfter: proofAfter)
    }
  }

  struct CallerExpiryEvidence: Sendable {
    let before: AuthorizedExecution
    let after: AuthorizedExecution
  }

  func expireCaller(_ id: UUID) throws -> CallerExpiryEvidence {
    try runtime.store.transactionWithDatabase { _, ledger in
      let before = try #require(ledger.executions[id])
      guard before.isRunning, before.limits.timeMilliseconds == 600_000,
        id != prepared.executionID
      else { throw PermissionModelError.invalidAuthorization }
      let otherCalls = ledger.executions.values.filter {
        $0.id != id && $0.isRunning && $0.limits.timeMilliseconds == 600_000
      }
      guard otherCalls.isEmpty else { throw PermissionModelError.invalidAuthorization }
      let result = ledger.reconcileExecutionLimits(
        now: before.startedAt.addingTimeInterval(600.001))
      let after = try #require(ledger.executions[id])
      let fixed = try #require(ledger.executions[prepared.executionID])
      guard result.executionsToTerminate.contains(id), after.limitEndReason == .timeLimit,
        !after.isRunning, fixed.isRunning, !fixed.revoked,
        !result.executionsToTerminate.contains(fixed.id)
      else { throw PermissionModelError.invalidAuthorization }
      return CallerExpiryEvidence(before: before, after: after)
    }
  }

  func revokeDiscoveryProofs(_ ids: Set<UUID>) {
    runtime.coordinator.revokeInvocations(ids)
  }

  func discoveryExecutions() throws -> Set<UUID> {
    try runtime.store.readWithDatabase { _, ledger in
      Set(
        ledger.executions.values.filter { execution in
          execution.authorizationIDs.contains {
            ledger.authorizations[$0]?.invocation.tool == "provider.discovery"
          }
        }.map(\.id))
    }
  }

  func discoveryDecisionAfterRejection(_ evidence: DiscoveryExpiryEvidence) throws
    -> PermissionDecision
  {
    var ledger = try runtime.store.readWithDatabase { _, ledger in ledger }
    return ledger.executionAccess(
      evidence.before.id, principal: evidence.before.owner, operation: .writeInput,
      connectionID: nil, authorizingInvocation: nil, now: Date())
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

/// Arms only after warmup; the callback runs after the pool has returned its selection.
final class MCPInvocationDiscoverySelectionGate: @unchecked Sendable {
  struct Selection: Sendable {
    let serverID: String
    let connectionID: UUID
    let executionID: UUID
    let evidence: MCPInvocationBackgroundProvider.DiscoveryExpiryEvidence?
  }

  private let lock = NSLock()
  private let pauseCondition = NSCondition()
  private var pauseReached = false
  private var pauseReleased = false
  private var pauseFirstExpiry = false
  private var provider: MCPInvocationBackgroundProvider?
  private var remaining = 0
  private var revokeReplacement = false
  private var expireReplacementCaller = false
  private var expiredCaller: MCPInvocationBackgroundProvider.CallerExpiryEvidence?
  private var replacementCaller: UUID?
  private var replacements = 0
  private var observed: [Selection] = []

  func arm(
    _ provider: MCPInvocationBackgroundProvider, expiries: Int, revokeReplacement: Bool = false,
    expireReplacementCaller: Bool = false, pauseFirstExpiry: Bool = false
  ) {
    lock.withLock {
      self.provider = provider
      remaining = expiries
      self.revokeReplacement = revokeReplacement
      self.expireReplacementCaller = expireReplacementCaller
      self.pauseFirstExpiry = pauseFirstExpiry
      expiredCaller = nil
      replacementCaller = nil
      replacements = 0
      observed = []
    }
  }

  var isPaused: Bool { pauseCondition.withLock { pauseReached } }

  func releaseSelection() {
    pauseCondition.lock()
    pauseReleased = true
    pauseCondition.broadcast()
    pauseCondition.unlock()
  }

  var replacementCount: Int { lock.withLock { replacements } }
  var replacementCallerID: UUID? { lock.withLock { replacementCaller } }
  var selections: [Selection] { lock.withLock { observed } }
  var callerExpiry: MCPInvocationBackgroundProvider.CallerExpiryEvidence? {
    lock.withLock { expiredCaller }
  }

  func willPrepareReplacement(_ replacement: GatewayDiscoveryReplacement) throws {
    let action = lock.withLock { () -> (MCPInvocationBackgroundProvider, Bool, Bool)? in
      guard let provider else { return nil }
      replacements += 1
      replacementCaller = replacement.caller.executionID
      return (provider, revokeReplacement, expireReplacementCaller)
    }
    guard let (owner, revoke, expireCaller) = action else { return }
    if revoke { owner.revokeDiscoveryProofs(replacement.selected.authorizationIDs) }
    if expireCaller {
      let id = try #require(replacement.caller.executionID)
      let evidence = try owner.expireCaller(id)
      lock.withLock { expiredCaller = evidence }
    }
  }

  func finish() -> [Selection] {
    lock.withLock {
      provider = nil
      return observed
    }
  }

  func didSelect(serverID: String, connectionID: UUID, executionID: UUID) throws {
    let action = lock.withLock { () -> (MCPInvocationBackgroundProvider, Bool)? in
      guard let provider else { return nil }
      let expire = remaining > 0
      if expire { remaining -= 1 }
      return (provider, expire)
    }
    guard let (provider, expire) = action else { return }
    guard serverID == "provider" else { throw PermissionModelError.invalidAuthorization }
    let evidence = try expire ? provider.expireSelectedDiscovery(executionID) : nil
    let shouldPause = lock.withLock { () -> Bool in
      observed.append(
        Selection(
          serverID: serverID, connectionID: connectionID, executionID: executionID,
          evidence: evidence))
      guard expire && pauseFirstExpiry else { return false }
      pauseFirstExpiry = false
      return true
    }
    if shouldPause {
      pauseCondition.lock()
      pauseReached = true
      while !pauseReleased { pauseCondition.wait() }
      pauseCondition.unlock()
    }
  }
}

/// Process-side barriers for a paginated first request and the replacement's startup and request.
struct MCPInvocationBudgetLatch: Sendable {
  private let prefix = "discovery-budget-" + UUID().uuidString

  var initializePython: String {
    """
            import time
            root = os.path.join(os.environ["HOME"], \(String(reflecting: prefix)))
            if os.path.exists(root + ".startup-arm"):
                os.unlink(root + ".startup-arm")
                with open(root + ".startup-entered", "w") as marker:
                    marker.write(str(os.getpid()))
                while not os.path.exists(root + ".startup-release"):
                    time.sleep(0.01)

    """
  }

  var listPython: String {
    """
            import time
            root = os.path.join(os.environ["HOME"], \(String(reflecting: prefix)))
            for stage in ("old", "new"):
                if os.path.exists(root + "." + stage + "-arm"):
                    os.unlink(root + "." + stage + "-arm")
                    with open(root + "." + stage + "-entered", "w") as marker:
                        marker.write(str(os.getpid()))
                    while not os.path.exists(root + "." + stage + "-release"):
                        time.sleep(0.01)
                    if stage == "old":
                        send(request["id"], {"tools": [], "nextCursor": "next"})
                        break
            else:
                stage = None
            if stage == "old":
                continue

    """
  }

  func arm(_ stage: String, home: URL) throws {
    try Data().write(to: home.appendingPathComponent(prefix + "." + stage + "-arm"))
  }
  func release(_ stage: String, home: URL) throws {
    try Data().write(to: home.appendingPathComponent(prefix + "." + stage + "-release"))
  }
  func waitFor(_ stage: String, home: URL) async throws -> Int32 {
    let marker = home.appendingPathComponent(prefix + "." + stage + "-entered")
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if let value = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(value) {
        return pid
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw GatewayToolError.executionFailed("Discovery budget checkpoint \(stage) was not reached")
  }
}

/// Holds one background reconciliation before its ledger snapshot, while other policy reads pass.
final class MCPInvocationPolicyBarrier: ManagedPolicyReading, @unchecked Sendable {
  private let base = TestManagedPolicyReader()
  private let condition = NSCondition()
  private var armed = false
  private var reached = false
  private var released = false

  func arm() { condition.withLock { armed = true } }
  var entered: Bool { condition.withLock { reached } }
  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
  func canonicalPolicyPath(_ path: String) throws -> String {
    try base.canonicalPolicyPath(path)
  }
  func readSources() -> [ManagedPolicySourceSnapshot] {
    condition.lock()
    if armed {
      armed = false
      reached = true
      while !released { condition.wait() }
    }
    condition.unlock()
    return base.readSources()
  }
}

/// Injects uncertain cancellation only for the selected, genuinely owned discovery child.
final class MCPInvocationCleanupGate: @unchecked Sendable {
  private let lock = NSLock()
  private var target: UUID?
  private var failures = 0
  private var starts: [UUID] = []

  func hold(_ executionID: UUID) { lock.withLock { target = executionID } }
  func release() { lock.withLock { target = nil } }
  var failureCount: Int { lock.withLock { failures } }
  var startedExecutions: [UUID] { lock.withLock { starts } }
  func recordStart(_ id: UUID?) { if let id { lock.withLock { starts.append(id) } } }
  func shouldFail(_ id: UUID?) -> Bool {
    lock.withLock {
      guard let id, id == target else { return false }
      return true
    }
  }
  func recordFailure() { lock.withLock { failures += 1 } }
}

final class MCPInvocationNotificationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func record() { lock.withLock { value += 1 } }
}

struct MCPInvocationCleanupPlatform: ExecutionPlatform {
  let base: DarwinExecutionPlatform
  let gate: MCPInvocationCleanupGate

  var supportsRecovery: Bool { base.supportsRecovery }
  var supportsBestEffortOwnership: Bool { base.supportsBestEffortOwnership }
  var bootSessionID: String? { base.bootSessionID }
  var hostSystemReadPaths: [SandboxPath] { base.hostSystemReadPaths }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool {
    base.supportsDurableOwnership(sandboxed: sandboxed)
  }
  func interrupt(_ members: [ExecutionMember]) async throws { try await base.interrupt(members) }
  func releaseRecovery(_ state: ExecutionRecoveryState) throws { try base.releaseRecovery(state) }
  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    try await base.recover(state)
  }
  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    let id = try PreparedExecutionContext.current()?.executionID
    gate.recordStart(id)
    let owner = try await base.start(
      command, sandbox: sandbox, method: method, input: input, output: output, error: error,
      bindOwnership: { owner in
        bindOwnership(MCPInvocationCleanupOwnership(base: owner, executionID: id, gate: gate))
      })
    return MCPInvocationCleanupOwnership(base: owner, executionID: id, gate: gate)
  }
}

private struct MCPInvocationCleanupOwnership: ExecutionOwnership {
  let base: any ExecutionOwnership
  let executionID: UUID?
  let gate: MCPInvocationCleanupGate

  func recoveryState() throws -> ExecutionRecoveryState { try base.recoveryState() }
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
    base.beforeStart(handler)
  }
  func onSandboxViolation(_ handler: @escaping @Sendable (ExecutionSandboxViolation) -> Void) {
    base.onSandboxViolation(handler)
  }
  func members() async throws -> [ExecutionMember] { try await base.members() }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) { base.onCancellation(handler) }
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    if gate.shouldFail(executionID) {
      gate.recordFailure()
      throw ExecutionEnvironmentError.unavailable("Fixture cannot confirm cleanup")
    }
    return try await base.cancel(until: deadline)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    try await base.wait(until: deadline)
  }
  func wait() async throws -> ExecutionExit { try await base.wait() }
}

/// A process-side tools/list latch under this provider's verified private HOME.
/// The marker includes the native PID, so the test cannot mistake a tool effect
/// on the fixed provider for the independent projectless discovery request.
struct MCPInvocationDiscoveryLatch: Sendable {
  private let prefix = "discovery-expiry-" + UUID().uuidString

  var python: String {
    """
            import time
            latch = os.path.join(os.environ["HOME"], \(String(reflecting: prefix)))
            if os.path.exists(latch + ".arm"):
                os.unlink(latch + ".arm")
                with open(latch + ".entered", "w") as marker:
                    marker.write(str(os.getpid()))
                while not os.path.exists(latch + ".release"):
                    time.sleep(0.01)

    """
  }

  var listCountingPython: String {
    """
            with open(os.path.join(os.environ["HOME"], \(String(reflecting: prefix + ".lists"))), "a") as lists:
                lists.write(str(os.getpid()) + "\\n")

    """
  }

  func listInputs(home: URL) throws -> [Int32] {
    let file = home.appendingPathComponent(prefix + ".lists")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
      try #require(Int32($0))
    }
  }

  var backgroundPython: String {
    """
                with open(os.path.join(os.environ["HOME"], \(String(reflecting: prefix + ".effects"))), "a") as effects:
                    effects.write(json.dumps({"pid": os.getpid(), "invocation": invocation, "work_invocation": params["_meta"]["io.github.computer-mcp/work-invocation"]}) + "\\n")

    """
  }

  func effects(home: URL) throws -> [JSONValue] {
    let file = home.appendingPathComponent(prefix + ".effects")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
  }

  func arm(home: URL) throws { try Data().write(to: home.appendingPathComponent(prefix + ".arm")) }
  func release(home: URL) throws {
    try Data().write(to: home.appendingPathComponent(prefix + ".release"))
  }

  func waitUntilEntered(home: URL) async throws -> Int32 {
    let marker = home.appendingPathComponent(prefix + ".entered")
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if let value = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(value) {
        return pid
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The independent discovery process never entered tools/list")
    throw PermissionModelError.invalidAuthorization
  }
}

/// Aggregates only unexpanded statement classes and timing; no SQL or arguments are retained.
final class MCPInvocationCapacityMetrics: @unchecked Sendable {
  private struct TransactionPhase {
    var count = 0
    var wallSeconds: TimeInterval = 0
    var sqlSeconds: TimeInterval = 0
    var ledgerSaves = 0
    var ledgerSeconds: TimeInterval = 0
    var runtimeWrites = 0
  }

  private let lock = NSLock()
  private var transactionPhase = "unassigned"
  private var transactionPhases: [String: TransactionPhase] = [:]
  private var phaseName: String?
  private var phaseStarted = ProcessInfo.processInfo.systemUptime
  private var phaseSeconds: [String: TimeInterval] = [:]
  private var transactionStarted: TimeInterval?
  private var transactionSQLSeconds: TimeInterval = 0
  private var transactionCount = 0
  private var rollbackCount = 0
  private var transactionSeconds: TimeInterval = 0
  private var sqlSeconds: TimeInterval = 0
  private var ledgerSaves = 0
  private var ledgerSaveSeconds: TimeInterval = 0
  private var runtimeWrites = 0
  private var runtimeWriteSeconds: TimeInterval = 0
  private var hostCallWrites = 0
  private var hostCallWriteSeconds: TimeInterval = 0

  func phase(_ name: String) {
    lock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      if let phaseName { phaseSeconds[phaseName, default: 0] += now - phaseStarted }
      phaseName = name
      phaseStarted = now
    }
  }

  func observe(_ event: Database.TraceEvent) {
    switch event {
    case .statement(let statement):
      let sql = statement.sql.lowercased()
      if sql.hasPrefix("begin ") {
        lock.withLock {
          transactionStarted = ProcessInfo.processInfo.systemUptime
          transactionPhase = phaseName ?? "unassigned"
          transactionSQLSeconds = 0
        }
      }
    case .profile(let statement, let duration):
      let sql = statement.sql.lowercased()
      lock.withLock {
        guard let started = transactionStarted else { return }
        transactionSQLSeconds += duration
        if sql.hasPrefix("insert into permissionledger") {
          ledgerSaves += 1
          ledgerSaveSeconds += duration
          transactionPhases[transactionPhase, default: TransactionPhase()].ledgerSaves += 1
          transactionPhases[transactionPhase, default: TransactionPhase()].ledgerSeconds += duration
        } else if sql.hasPrefix("insert into permissionruntimeexecutions")
          || sql.hasPrefix("update permissionruntimeexecutions")
          || sql.hasPrefix("delete from permissionruntimeexecutions")
        {
          runtimeWrites += 1
          runtimeWriteSeconds += duration
          transactionPhases[transactionPhase, default: TransactionPhase()].runtimeWrites += 1
        } else if sql.hasPrefix("insert into hostcallrecords")
          || sql.hasPrefix("update hostcallrecords") || sql.hasPrefix("delete from hostcallrecords")
        {
          hostCallWrites += 1
          hostCallWriteSeconds += duration
        }
        let isRollback = sql == "rollback" || sql == "rollback transaction"
        if sql == "commit" || sql == "commit transaction" || isRollback {
          transactionCount += 1
          if isRollback { rollbackCount += 1 }
          let wall = ProcessInfo.processInfo.systemUptime - started
          transactionSeconds += wall
          sqlSeconds += transactionSQLSeconds
          transactionPhases[transactionPhase, default: TransactionPhase()].count += 1
          transactionPhases[transactionPhase, default: TransactionPhase()].wallSeconds += wall
          transactionPhases[transactionPhase, default: TransactionPhase()].sqlSeconds +=
            transactionSQLSeconds
          transactionStarted = nil
        }
      }
    }
  }

  func report() -> String {
    lock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      var phases = phaseSeconds
      if let phaseName { phases[phaseName, default: 0] += now - phaseStarted }
      let phaseParts: [String] = phases.keys.sorted().map {
        "\($0)=\(String(format: "%.3f", phases[$0]!))s"
      }
      let phaseSummary: String = phaseParts.joined(separator: ", ")
      let transactionParts: [String] = transactionPhases.keys.sorted().map { name in
        let value = transactionPhases[name]!
        return
          "\(name):count=\(value.count),wall_s=\(String(format: "%.3f", value.wallSeconds)),sql_s=\(String(format: "%.3f", value.sqlSeconds)),ledger=\(value.ledgerSaves),ledger_sql_s=\(String(format: "%.3f", value.ledgerSeconds)),runtime_writes=\(value.runtimeWrites)"
      }
      let transactionSummary: String = transactionParts.joined(separator: "; ")
      return
        "Capacity metrics: phases=[\(phaseSummary)] transaction_phases=[\(transactionSummary)] "
        + "transactions=\(transactionCount) rollbacks=\(rollbackCount) "
        + "transaction_wall_s=\(String(format: "%.3f", transactionSeconds)) "
        + "transaction_sql_profile_s=\(String(format: "%.3f", sqlSeconds)) "
        + "transaction_open_at_report=\(transactionStarted != nil) "
        + "ledger_save_sql_count=\(ledgerSaves) ledger_save_sql_s=\(String(format: "%.3f", ledgerSaveSeconds)) "
        + "runtime_record_write_sql_count=\(runtimeWrites) runtime_record_write_sql_s=\(String(format: "%.3f", runtimeWriteSeconds)) "
        + "host_call_write_sql_count=\(hostCallWrites) host_call_write_sql_s=\(String(format: "%.3f", hostCallWriteSeconds))"
    }
  }
}
