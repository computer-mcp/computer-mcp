import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPSandbox
import ComputerMCPWorktrees
import Foundation
import GRDB
import Testing

@testable import ComputerMCPEgress
@testable import ComputerMCPGateway
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite struct ExecutionRevocationCoordinatorTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
  func reconciliationFailureDuringCancellationPreservesItsCause(
    ownershipFailure: Bool, failureFirst: Bool
  ) async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    var executions: [UUID: DurableTestOwnership] = [:]
    var contexts: [PreparedExecutionContext] = []
    defer { withExtendedLifetime(contexts) {} }
    for _ in 0..<2 {
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let context = try await coordinator.prepare(authorizationID: id, context: f.context)
      executions[context.executionID] = try #require(
        try await f.start(context) as? DurableTestOwnership)
      try context.finishAdmission()
      contexts.append(context)
    }
    try await coordinator.reconcile()
    let targetID = try f.paths.store.readWithDatabase { database, _ in
      let records = try ExecutionRuntimeRecord.all(database)
      return try #require((failureFirst ? records.first : records.last)?.id)
    }
    let target = try #require(executions[targetID])
    let unrelated = try #require(executions.first { $0.key != targetID }?.value)
    let entered = ReconciliationTestGate()
    await entered.release()
    let background = ReconciliationTestGate()
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    target.setCancellation { _ in
      let first = !(await entered.entered)
      if first {
        #expect(ContinuousClock.now < deadline)
        await entered.wait()
        try await Task.sleep(until: deadline, clock: .continuous)
      }
      if ownershipFailure {
        throw ExecutionCompletionFailure(
          ownership: target, members: [], reasons: ["Ownership evidence was lost"],
          bestEffort: false)
      }
      if first { throw ExecutionWaitExpired(ownership: target) }
      await background.wait()
    }
    defer {
      target.setCancellation(nil)
      target.complete()
      Task { await background.release() }
    }
    try f.paths.store.transactionWithDatabase { _, ledger in
      try ledger.terminateExecution(targetID)
    }
    let attempt = Task { try await coordinator.reconcile(until: deadline) }
    while !(await entered.entered), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(
      await entered.entered,
      "Cancellation deadlines: \(target.cancellationDeadlines), expected: \(deadline), ended: \(target.ended)"
    )
    // The bounded caller can return before the shared pass. Join its error
    // classification before checking admission and unrelated resources.
    let classification = Task { try await coordinator.reconcile() }
    await #expect(throws: (any Error).self) { try await attempt.value }
    if ownershipFailure {
      await #expect(throws: ExecutionCompletionFailure.self) { try await classification.value }
    } else {
      let retryDeadline = ContinuousClock.now.advanced(by: .seconds(2))
      while !(await background.entered), ContinuousClock.now < retryDeadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      try #require(await background.entered)
    }
    #expect(unrelated.ended == ownershipFailure)
    #expect(unrelated.cancellationDeadlines.isEmpty == !ownershipFailure)
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    if ownershipFailure {
      await #expect(throws: ExecutionEnvironmentError.self) {
        _ = try await coordinator.prepare(authorizationID: id, context: f.context)
      }
    } else {
      let next = try await coordinator.prepare(authorizationID: id, context: f.context)
      try next.finishAdmission()
    }
    target.setCancellation(nil)
    await background.release()
    if !ownershipFailure { try await classification.value }
    try? await coordinator.reconcile()
    try await coordinator.stopExecutions(Set(executions.keys))
  }

  @Test func expiredReconciliationBudgetDoesNotRevokeUnrelatedExecutions() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let context = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(context)
    try context.finishAdmission()
    await #expect(throws: WorktreeError.self) {
      try await coordinator.reconcile(until: .now)
    }
    // Join the expired pass, then check that ordinary reconciliation and
    // admission remain usable while the unrelated execution is still live.
    try? await coordinator.reconcile()
    try await coordinator.reconcile()
    #expect(f.platform.owners.allSatisfy { !$0.ended })
    let nextID = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let next = try await coordinator.prepare(authorizationID: nextID, context: f.context)
    try next.finishAdmission()
    try await coordinator.stopExecutions([context.executionID, next.executionID])
  }

  @Test(arguments: [false, true])
  func worktreeTerminationDeadlineBoundsCallerWhileCleanupContinues(expire: Bool) async throws {
    let f = try ExecutionFixture()
    let admission = try f.worktreeAdmission()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    for _ in 0..<3 {
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let context = try await coordinator.prepare(
        authorizationID: id, context: f.context, worktreeAdmission: admission)
      _ = try await f.start(context)
      try context.finishAdmission()
    }
    for owner in f.platform.owners {
      owner.setCancellation { deadline in
        if expire {
          try await Task.sleep(
            until: min(deadline, .now.advanced(by: .milliseconds(300))), clock: .continuous)
          throw ExecutionWaitExpired(ownership: owner)
        }
      }
    }
    let operation = UUID()
    let start = ContinuousClock.now
    let deadline = start.advanced(by: expire ? .milliseconds(200) : .seconds(2))
    if expire {
      await #expect(throws: (any Error).self) {
        try await coordinator.terminateWorktreeWriters(
          admission, operationID: operation, until: deadline)
      }
      #expect(start.duration(to: .now) < .milliseconds(700))
      #expect(f.platform.owners.contains { !$0.cancellationDeadlines.isEmpty })
      #expect(throws: WorktreeError.self) { try admission.requireDrained(operationID: operation) }
      #expect(throws: WorktreeError.self) {
        try admission.reserve(ownerID: UUID(), executionID: UUID())
      }
    } else {
      try await coordinator.terminateWorktreeWriters(
        admission, operationID: operation, until: deadline)
      #expect(f.platform.owners.allSatisfy { $0.ended })
      try admission.requireDrained(operationID: operation)
    }
    for owner in f.platform.owners {
      owner.setCancellation(nil)
      owner.complete()
    }
    // A monitoring pass may still be joining an injected cancellation failure.
    if expire { try? await coordinator.reconcile() }
    try await coordinator.reconcile()
  }

  @Test func worktreeDeadlineBoundsWaitingForUnrelatedReconciliation() async throws {
    let f = try ExecutionFixture()
    let admission = try f.worktreeAdmission()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let context = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(context)
    try context.finishAdmission()
    let gate = ReconciliationTestGate()
    let owner = try #require(f.platform.owners.first)
    owner.setCancellation { _ in await gate.wait() }
    let writerID = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let writer = try await coordinator.prepare(
      authorizationID: writerID, context: f.context, worktreeAdmission: admission)
    _ = try await f.start(writer)
    try writer.finishAdmission()
    try f.paths.store.transactionWithDatabase { _, ledger in
      try ledger.terminateExecution(context.executionID)
    }
    let recovery = Task { try await coordinator.reconcile() }
    let entryDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await gate.entered), ContinuousClock.now < entryDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await gate.entered)
    let release = Task {
      try await Task.sleep(for: .seconds(1))
      await gate.release()
    }
    let start = ContinuousClock.now
    let operation = UUID()
    await #expect(throws: WorktreeError.self) {
      try await coordinator.terminateWorktreeWriters(
        admission, operationID: operation, until: start.advanced(by: .milliseconds(100)))
    }
    #expect(start.duration(to: .now) < .milliseconds(700))
    #expect(throws: WorktreeError.self) { try admission.requireDrained(operationID: operation) }
    await gate.release()
    release.cancel()
    try await recovery.value
    try await coordinator.reconcile()
    try admission.requireDrained(operationID: operation)
  }

  @Test func worktreeClosureDrainsInvocationAndDeniesLaunchAndInput() async throws {
    let f = try ExecutionFixture()
    let admission = try f.worktreeAdmission()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    var contexts: [PreparedExecutionContext] = []
    for _ in 0..<2 {
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let context = try await coordinator.prepare(
        authorizationID: id, context: f.context, worktreeAdmission: admission)
      _ = try await f.start(context)
      contexts.append(context)
    }
    let operation = UUID()
    await #expect(throws: WorktreeError.self) {
      try await coordinator.terminateWorktreeWriters(
        admission, operationID: operation, until: .now.advanced(by: .milliseconds(100)))
    }
    #expect(f.platform.owners.allSatisfy { $0.ended })
    #expect(throws: WorktreeError.self) { try admission.requireDrained(operationID: operation) }
    await #expect(throws: (any Error).self) { try await f.start(contexts[0]) }
    #expect(throws: (any Error).self) {
      try contexts[1].accessExecution(contexts[1].executionID, operation: .writeInput)
    }
    for context in contexts { try context.finishAdmission() }
    try await coordinator.terminateWorktreeWriters(
      admission, operationID: operation, until: .now.advanced(by: .seconds(2)))
    try admission.requireDrained(operationID: operation)
    try await coordinator.terminateWorktreeWriters(
      admission, operationID: operation, until: .now.advanced(by: .seconds(2)))
  }

  @Test func foreignWorktreeOwnerAndRestartKeepAdmissionClosed() async throws {
    let f = try ExecutionFixture()
    let admission = try f.worktreeAdmission()
    let foreign = try admission.reserve(ownerID: UUID(), executionID: UUID())
    let operation = UUID()
    do {
      let coordinator = try f.coordinator()
      try await coordinator.recover()
      await #expect(throws: WorktreeError.self) {
        try await coordinator.terminateWorktreeWriters(
          admission, operationID: operation, until: .now.advanced(by: .seconds(1)))
      }
    }
    let restored = try JSONDecoder().decode(
      WorktreeAdmission.self, from: JSONEncoder().encode(admission))
    #expect(throws: WorktreeError.self) { try restored.requireOpen(foreign) }
    #expect(throws: WorktreeError.self) { try restored.requireDrained(operationID: operation) }
    try restored.acknowledge(foreign)
    try restored.requireDrained(operationID: operation)
  }

  @Test(arguments: [ComputerMCPPermissions.ExecutionMode.sandbox, .fullAccess(.standing)])
  func downloadAdmissionKeepsProjectWriteAndDefersHostClassificationToTheProxy(
    mode: ComputerMCPPermissions.ExecutionMode
  ) throws {
    let f = try DurablePathFixture()
    let paths = try f.store.readWithDatabase { _, ledger in try #require(ledger.environment.paths) }
    let resolver = GatewayToolRequirementResolver(
      configuration: .init(), origins: [:], paths: paths)
    let descriptor = CapabilityDescriptor(
      id: "file.download", risk: .destructive,
      requirement: .init(access: .projectWrite, paths: [.init("path", .write)], networkURL: "url"),
      projectRequirement: .required, usesNetwork: true)
    let (requirements, _, _) = try resolver.resolve(
      descriptor: descriptor,
      arguments: ["url": .string("https://download.example.com/file"), "path": .string("result")],
      projectID: "derived", mode: mode)
    #expect(requirements.networks.isEmpty)
    #expect(
      requirements.actions.contains {
        $0.requirement == (try? PermissionRequirement(.project("project"), .write))
      })
    #expect(
      requirements.paths == [
        .init(
          path: try CanonicalPath(f.derived.appendingPathComponent("result").path),
          operation: .write)
      ])
    #expect(throws: GatewayToolError.self) {
      try resolver.resolve(
        descriptor: descriptor,
        arguments: ["url": .string("file:///tmp/file"), "path": .string("result")],
        projectID: "derived", mode: mode)
    }
  }

  @Test(
    arguments: [PermissionAnswer.onlyThisTime, .always], ["api.example.com", "127.example.com"])
  func proxyNeedsKeepRunningGrantsAndRequireAnExactExplicitRetry(
    answer: PermissionAnswer, host: String
  )
    async throws
  {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let callbacks = RuntimeDenialCallbacks()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      callbacks.install(id, policy: policy, handler: onDenial)
      return try await EgressProxy.start(
        executionID: id.uuidString, policy: policy, routing: ExecutionTestRouting(),
        limits: .init(), onDenial: onDenial)
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    #expect(callbacks.policy(prepared.executionID)?.access == EgressAccess.none)
    callbacks.emit(prepared.executionID, host: host)
    let requests = try prepared.permissionRequests(prepared.executionID)
    #expect(requests.count == 1)
    let proof = try f.paths.store.readWithDatabase { _, ledger in
      try #require(ledger.authorizations[id])
    }
    #expect(requests.first?.invocation == proof.invocation)
    #expect(f.platform.started == 1)
    let metadata = GatewayExecutionPermissionMetadata.attach(
      to: .object([
        "isError": .bool(false),
        "structuredContent": .object([
          "session_id": .string("retained"), "exit_code": .integer(13),
          "gateway_execution": .object(["execution_id": .string(prepared.executionID.uuidString)]),
        ]),
      ]), groups: [.init(executionID: prepared.executionID, requests: requests)])
    #expect(metadata.objectValue?["isError"] == .bool(false))
    #expect(
      metadata.objectValue?["structuredContent"]?.objectValue?["session_id"] == .string("retained"))
    #expect(metadata.objectValue?["structuredContent"]?.objectValue?["exit_code"] == .integer(13))
    let group = try #require(
      metadata.objectValue?["_meta"]?.objectValue?["computer_mcp"]?
        .objectValue?["permission_requests"]?.arrayValue?.first?.objectValue)
    #expect(group["original_call"]?.objectValue?["tool"] == .string(proof.invocation.tool))
    #expect(
      group["retry"]?.objectValue?["instructions"]?.stringValue?.contains("Earlier operations")
        == true)
    let providerError = GatewayToolError.executionFailed("Provider failure after partial output")
    let failed = GatewayExecutionPermissionFailure(
      underlying: providerError,
      groups: [.init(executionID: prepared.executionID, requests: requests)])
    let errorEnvelope = GatewayRuntime.executionErrorEnvelope(
      failed, context: .init(caller: .localCLI, profileID: .localAdmin),
      capabilityID: proof.invocation.tool)
    #expect(errorEnvelope.objectValue?["isError"] == .bool(true))
    let failure = try #require(
      errorEnvelope.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
    #expect(
      failure["code"]
        == .string(GatewayRuntime.auditErrorCode(for: providerError) ?? "gateway.execution_failed"))
    #expect(
      failure["message"]?.stringValue?.contains("Provider failure after partial output") == true)
    #expect(
      errorEnvelope.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
        .objectValue?["permission_requests"]?.arrayValue?.count == 1)
    #expect(
      GatewayRuntime.auditDecision(for: failed) == GatewayRuntime.auditDecision(for: providerError))
    let refusal = try PluginCompatibilityRefusal(
      pluginID: "fixture", version: PluginVersion("1.0.0"), reason: .hostUpdateRequired,
      requirement: .pluginAPI(declared: 2, supported: .supported))
    let underlyingErrors: [any Error] = [GatewayToolError.disabled("fixture"), refusal]
    for underlying in underlyingErrors {
      let wrapped = GatewayExecutionPermissionFailure(
        underlying: underlying,
        groups: [.init(executionID: prepared.executionID, requests: requests)])
      let expected = try ControlToolResponse.errorPayload(underlying).objectValue
      let actual = try ControlToolResponse.errorPayload(wrapped).objectValue
      #expect(actual?["code"] == expected?["code"])
      #expect(actual?["message"] == expected?["message"])
      #expect(actual?["refusal"] == expected?["refusal"])
      #expect(
        actual?["permission_requests"]?.arrayValue?.first?.objectValue?["execution_id"]
          == .string(prepared.executionID.uuidString))
      #expect(
        ControlToolResponse.auditDisposition(for: wrapped).decision
          == ControlToolResponse.auditDisposition(for: underlying).decision)
      #expect(
        ControlToolResponse.auditDisposition(for: wrapped).code
          == ControlToolResponse.auditDisposition(for: underlying).code)
    }
    let retried = try f.paths.store.transactionWithDatabase { _, ledger in
      for request in requests { try ledger.answer(request.id, with: answer, now: Date()) }
      #expect(ledger.authorizations[id]?.requirements == proof.requirements)
      #expect(throws: PermissionModelError.retryMismatch) {
        try ledger.authorize(
          invocation: .init(
            principal: proof.invocation.principal, tool: proof.invocation.tool,
            projectID: proof.invocation.projectID, argumentsDigest: "different"),
          requirements: proof.requirements, retryIDs: Set(requests.map(\.id)), now: Date())
      }
      guard
        case .allowed(let retry) = try ledger.authorize(
          invocation: proof.invocation, requirements: proof.requirements,
          retryIDs: Set(requests.map(\.id)), now: Date())
      else { throw PermissionModelError.invalidAuthorization }
      return retry
    }
    #expect(f.platform.started == 1)
    #expect(callbacks.policy(prepared.executionID)?.admits(host: host) == false)
    let retry = try await coordinator.prepare(authorizationID: retried.id, context: f.context)
    #expect(callbacks.policy(retry.executionID)?.admits(host: host) == true)
    #expect(callbacks.policy(retry.executionID)?.admits(host: "other.example.com") == false)
    _ = try await f.start(retry)
    #expect(f.platform.started == 2)
    try prepared.finishAdmission()
    try retry.finishAdmission()
    for owner in f.platform.owners { owner.complete() }
    try await f.untilFinished(prepared.executionID, coordinator)
    try await f.untilFinished(retry.executionID, coordinator)
  }

  @Test(arguments: [PermissionAnswer.onlyThisTime, .always])
  func attributedReadsRequestFoldersWhileFixedBoundariesDoNot(answer: PermissionAnswer) async throws
  {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    let owner = try #require(f.platform.owners.first)
    // Program output has no route into this host-only callback.
    #expect(try prepared.permissionRequests(prepared.executionID).isEmpty)
    for (operation, path) in [
      ("file-write-create", f.paths.root.appendingPathComponent("downloads/write").path),
      ("file-read-unknown", f.paths.root.appendingPathComponent("downloads/unknown").path),
      ("file-read-data", f.paths.root.appendingPathComponent("host/token").path),
      ("file-read-data", f.paths.project.appendingPathComponent("inner/secret").path),
    ] {
      owner.report(.init(operation: operation, path: path))
    }
    #expect(try prepared.permissionRequests(prepared.executionID).isEmpty)
    owner.report(
      .init(
        operation: "file-read-data",
        path: f.paths.root.appendingPathComponent("downloads/report").path))
    let requests = try prepared.permissionRequests(prepared.executionID)
    #expect(requests.count == 1)
    guard case .permission(let content) = try #require(requests.first).content else {
      throw PermissionModelError.invalidAuthorization
    }
    #expect(content.requirement.permission == .filesAndFolders(.downloads))
    #expect(f.platform.started == 1)
    try f.paths.store.transactionWithDatabase { _, ledger in
      let proof = try #require(ledger.authorizations[id])
      for request in requests { try ledger.answer(request.id, with: answer, now: Date()) }
      #expect(ledger.authorizations[id]?.requirements == proof.requirements)
      guard
        case .allowed(let retry) = try ledger.authorize(
          invocation: proof.invocation, requirements: proof.requirements,
          retryIDs: Set(requests.map(\.id)), now: Date())
      else { throw PermissionModelError.invalidAuthorization }
      #expect(
        retry.requirements.paths.contains(
          .init(
            path: try CanonicalPath(f.paths.root.appendingPathComponent("downloads/report").path),
            operation: .read)))
    }
    try prepared.finishAdmission()
    owner.complete()
    try await f.untilFinished(prepared.executionID, coordinator)
    owner.report(
      .init(
        operation: "file-read-metadata",
        path: f.paths.root.appendingPathComponent("downloads/late").path))
    let continuationID = try f.paths.store.transactionWithDatabase { _, ledger in
      guard
        case .allowed(let proof) = try ledger.authorize(
          invocation: .init(
            principal: f.paths.principal, tool: "process.read", projectID: nil,
            argumentsDigest: "read"),
          requirements: .init(), now: Date())
      else { throw PermissionModelError.invalidAuthorization }
      return proof.id
    }
    let continuation = try coordinator.continuation(authorizationID: continuationID)
    _ = try continuation.accessExecution(prepared.executionID, operation: .readResult)
    let current = try prepared.permissionRequests(prepared.executionID)
    #expect(
      try continuation.currentPermissionRequestGroups().flatMap(\.requests).map(\.id)
        == current.map(\.id))
    if case .onlyThisTime = answer { #expect(!current.isEmpty) }
  }

  @Test func expiredRetentionOmitsMetadataWhileRevokedAuthorityStillFails() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let callbacks = RuntimeDenialCallbacks()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      callbacks.install(id, policy: policy, handler: onDenial)
      return try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(), limits: .init(), onDenial: onDenial)
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    callbacks.emit(prepared.executionID, host: "expired.example")
    #expect(try prepared.currentPermissionRequestGroups().count == 1)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    try f.paths.store.transactionWithDatabase { _, ledger in
      try ledger.finishExecution(prepared.executionID, retainUntil: .distantPast)
    }
    let groups = try prepared.currentPermissionRequestGroups()
    #expect(groups.isEmpty)
    let result = JSONValue.object([
      "isError": .bool(false),
      "structuredContent": .object([
        "session_id": .string("retained-call-result"), "exit_code": .integer(0),
      ]),
    ])
    #expect(GatewayExecutionPermissionMetadata.attach(to: result, groups: groups) == result)
    try f.revoke()
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try prepared.currentPermissionRequestGroups()
    }
  }

  @Test func managedNetworkCeilingsDoNotProduceRuntimeRequests() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    try f.paths.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.limits[f.paths.principal] = ManagedLimits(sources: [
        .managedPreferences: .available(ManagedPolicy(network: .none))
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let callbacks = RuntimeDenialCallbacks()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      callbacks.install(id, policy: policy, handler: onDenial)
      return try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(), limits: .init(), onDenial: onDenial)
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    callbacks.emit(prepared.executionID, host: "limited.example.com")
    #expect(try prepared.permissionRequests(prepared.executionID).isEmpty)
    #expect(try f.paths.store.readWithDatabase { _, ledger in ledger.requests.isEmpty })
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
  }

  @Test func interleavedRuntimeReportsKeepTheRequestableGroupRetryable() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let hosts = (0..<5).map { "host-\($0).example" }
    try f.paths.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.limits[f.paths.principal] = ManagedLimits(sources: [
        .managedPreferences: .available(
          ManagedPolicy(network: .custom(hosts: Set(hosts), includesTrusted: false)))
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let callbacks = RuntimeDenialCallbacks()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      callbacks.install(id, policy: policy, handler: onDenial)
      return try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(), limits: .init(), onDenial: onDenial)
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    callbacks.emit(prepared.executionID, host: hosts[0])
    #expect(try prepared.permissionRequests(prepared.executionID).count == 1)
    await withTaskGroup(of: Void.self) { group in
      for index in 1..<hosts.count {
        group.addTask {
          callbacks.emit(prepared.executionID, host: hosts[index])
          callbacks.emit(prepared.executionID, host: "excluded-\(index).example")
          callbacks.emit(prepared.executionID, host: hosts[0])
        }
      }
    }
    let requests = try prepared.permissionRequests(prepared.executionID)
    #expect(requests.count == hosts.count)
    #expect(requests.allSatisfy { $0.status == .pending })
    #expect(
      Set(
        requests.compactMap { request -> String? in
          if case .network(let content) = request.content { return content.host }
          return nil
        }) == Set(hosts))
    try f.paths.store.transactionWithDatabase { database, ledger in
      let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      #expect(record.permissionRequestIDs == Set(requests.map(\.id)))
      #expect(record.permissionNeeds?.count == 9)
      let proof = try #require(ledger.authorizations[id])
      for request in requests { try ledger.answer(request.id, with: .onlyThisTime, now: Date()) }
      guard
        case .allowed(let retry) = try ledger.authorize(
          invocation: proof.invocation, requirements: proof.requirements,
          retryIDs: Set(requests.map(\.id)), now: Date())
      else { throw PermissionModelError.invalidAuthorization }
      #expect(Set(retry.requirements.networks.map(\.host)) == Set(hosts))
      #expect(retry.requestIDs.count == hosts.count + 1)
      #expect(ledger.authorizations[id] == proof)
    }
    #expect(callbacks.policy(prepared.executionID)?.access == EgressAccess.none)
    #expect(f.platform.started == 0)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
  }

  @Test func runtimeRequestStormsAndUnrequestableNetworkFailuresAreBounded() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let callbacks = RuntimeDenialCallbacks()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      callbacks.install(id, policy: policy, handler: onDenial)
      return try await EgressProxy.start(
        executionID: id.uuidString, policy: policy, routing: ExecutionTestRouting(),
        limits: .init(), onDenial: onDenial)
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    for reason in [
      EgressDenial.Reason.loopback, .invalidDestination, .routeUnavailable, .routeChanged, .revoked,
      .connectionLimit,
    ] {
      callbacks.emit(prepared.executionID, host: "blocked.example", reason: reason)
    }
    callbacks.emit(prepared.executionID, host: "127.0.0.1")
    callbacks.emit(prepared.executionID, host: "forged.example", claimedID: UUID())
    #expect(try prepared.permissionRequests(prepared.executionID).isEmpty)
    for index in 0..<1000 { callbacks.emit(prepared.executionID, host: "host-\(index).example") }
    let requests = try prepared.permissionRequests(prepared.executionID)
    #expect(requests.count == ExecutionPermissionDiscovery.maximumNeeds)
    #expect(f.platform.started == 0)
    try f.paths.store.readWithDatabase { database, ledger in
      let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      #expect(record.permissionNeeds?.count == ExecutionPermissionDiscovery.maximumNeeds)
      #expect(ledger.requests.values.filter { $0.status == .pending }.count == requests.count)
      let count = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM auditEvents WHERE capabilityID='execution.permission_required'")
      #expect(count == ExecutionPermissionDiscovery.maximumNeeds)
    }
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
  }

  @Test(arguments: ["work.completed", "admission.closed"])
  func confirmedCompletionIsRetriedByTheCoordinatorWithoutReplayingWork(action: String) async throws
  {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    let cancelled = ExecutionProxyBox()
    let work =
      action == "work.completed" ? try prepared.retainWork { cancelled.markReleased() } : nil
    if work != nil { try prepared.finishAdmission() }
    try f.paths.store.transactionWithDatabase { database, _ in
      try database.execute(
        sql:
          "CREATE TRIGGER fail_completion_audit BEFORE INSERT ON auditEvents WHEN NEW.capabilityID = ? BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END"
          .replacingOccurrences(of: "?", with: "'execution.\(action)'"))
    }
    #expect(throws: (any Error).self) {
      if let work { try work.finish() } else { try prepared.finishAdmission() }
    }
    try f.paths.store.transactionWithDatabase { database, _ in
      try database.execute(sql: "DROP TRIGGER fail_completion_audit")
    }
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(f.platform.started == 0)
    #expect(!cancelled.released)
    try f.paths.store.readWithDatabase { database, ledger in
      let current = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      #expect(current.completed && current.admissionFinished && (current.workIDs?.isEmpty ?? true))
      #expect(ledger.executions[prepared.executionID]?.isRunning == false)
      let count = try Int.fetchOne(
        database, sql: "SELECT count(*) FROM auditEvents WHERE capabilityID = ?",
        arguments: ["execution." + action])
      #expect(count == 1)
    }
  }

  @Test func transientReconciliationFailureReopensOnlyAfterOwnedWorkJoins() async throws {
    let f = try ExecutionFixture()
    let failure = ReconciliationFailureSwitch()
    let coordinator = try ExecutionRevocationCoordinator(
      store: f.paths.store,
      launcher: ExecutionLauncher(platform: f.platform), directory: f.directory,
      refreshPolicy: { try failure.check() })
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    let cancelled = ExecutionProxyBox()
    let work = try prepared.retainWork { cancelled.markReleased() }
    try prepared.finishAdmission()
    failure.set(true)
    await #expect(throws: (any Error).self) { try await coordinator.reconcile() }
    let pending = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    await #expect(throws: (any Error).self) {
      try await coordinator.prepare(authorizationID: pending, context: f.context)
    }
    for _ in 0..<100 {
      if cancelled.released { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(cancelled.released)
    failure.set(false)
    try await coordinator.reconcile()
    await #expect(throws: (any Error).self) {
      try await coordinator.prepare(authorizationID: pending, context: f.context)
    }
    try work.finish()
    try await f.untilFinished(prepared.executionID, coordinator)
    let resumed = try await coordinator.prepare(authorizationID: pending, context: f.context)
    try resumed.finishAdmission()
    try await f.untilFinished(resumed.executionID, coordinator)
  }

  @Test func unrecordedScratchIsQuarantinedWithoutDeletingItsContents() async throws {
    let f = try ExecutionFixture()
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let orphan = f.directory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
    let sentinel = orphan.appendingPathComponent("owner-file")
    try Data("preserve".utf8).write(to: sentinel)
    let coordinator = try f.coordinator()
    do {
      try await coordinator.recover()
      Issue.record("Unowned scratch did not close execution admission")
    } catch {
      #expect(
        (error as? ExecutionEnvironmentError)?.description.contains(
          "quarantined for local owner review") == true)
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
  }

  @Test func remoteServiceAuthorityCannotStartAHostProgram() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let scratch = f.directory.appendingPathComponent(id.uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let prepared = try await coordinator.prepare(
      authorizationID: id,
      context: .init(
        directory: SandboxPath(scratch.path),
        temporaryDirectory: SandboxPath(scratch.path), purpose: .remoteService,
        privateWorkingDirectory: true))
    #expect(!prepared.permitsProgramLaunch)
    await #expect(throws: (any Error).self) { try await f.start(prepared) }
    #expect(f.platform.started == 0)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
  }

  @Test(arguments: [false, true])
  func retainedLogicalRequestOutlivesAdmissionAndJoinsRevocation(auditUnavailable: Bool)
    async throws
  {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    let cancelled = ExecutionProxyBox()
    let work = try prepared.retainWork { cancelled.markReleased() }
    try prepared.finishAdmission()
    try await coordinator.reconcile()
    #expect(try f.execution(prepared.executionID).isRunning)
    _ = try prepared.accessExecution(prepared.executionID, operation: .writeInput)
    if auditUnavailable {
      try f.paths.store.transactionWithDatabase { database, _ in
        try database.execute(
          sql:
            "CREATE TRIGGER fail_revocation_audit BEFORE INSERT ON auditEvents WHEN NEW.capabilityID = 'execution.revoked' BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END"
        )
      }
    }
    try f.revoke()
    for _ in 0..<100 {
      do { try await coordinator.reconcile() } catch { #expect(auditUnavailable) }
      if cancelled.released { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(cancelled.released)
    let pending = try f.paths.store.readWithDatabase { database, _ in
      try ExecutionRuntimeRecord.load(prepared.executionID, database)?.completed
    }
    #expect(pending == false)
    if auditUnavailable {
      try f.paths.store.transactionWithDatabase { database, _ in
        try database.execute(sql: "DROP TRIGGER fail_revocation_audit")
      }
    }
    try work.finish()
    try work.finish()
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(throws: (any Error).self) {
      try prepared.accessExecution(prepared.executionID, operation: .readResult)
    }
  }

  @Test func emptyInvocationReclaimsOnlyItsOwnedScratchDirectory() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let scratch = f.directory.appendingPathComponent(id.uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let sibling = f.directory.appendingPathComponent("retained")
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let prepared = try await coordinator.prepare(
      authorizationID: id,
      context: .init(
        directory: SandboxPath(f.paths.project.path),
        temporaryDirectory: SandboxPath(scratch.path)))
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(!FileManager.default.fileExists(atPath: scratch.path))
    #expect(FileManager.default.fileExists(atPath: sibling.path))
  }

  @Test(arguments: ["prepared", "reserved", "bound", "older-record"])
  func restoredRuntimeRecordReleasesProxyAfterEveryReservationSettles(stage: String) async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    try f.paths.store.transactionWithDatabase { _, ledger in
      _ = try ledger.setSandboxSettings(
        .init(network: .full), for: .init(principal: f.paths.principal, projectID: "project"),
        expectedRevision: ledger.revision)
    }
    let box = ExecutionProxyBox()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      let proxy = try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(onCancel: { box.markReleased() }), limits: .init(),
        onDenial: onDenial)
      box.set(proxy)
      return proxy
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    let pending = UUID()
    let unbound = stage == "reserved" || stage == "older-record"
    if unbound { try prepared.authority.reserveChild(pending) }
    if stage == "bound" { _ = try await f.start(prepared) }
    try f.paths.store.transactionWithDatabase { database, _ in
      if stage == "older-record" {
        var record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
        record.children.removeAll()
        record.admissionFinished = true
        try record.save(database)
      } else {
        try database.execute(sql: "DELETE FROM permissionRuntimeExecutions")
      }
    }
    try await coordinator.reconcile()
    #expect(throws: (any Error).self) { try prepared.authority.reserveChild(UUID()) }
    if unbound {
      #expect(!box.released)
      prepared.authority.launchFailed(pending)
    }
    for _ in 0..<100 {
      try await coordinator.reconcile()
      if box.released { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(box.released)
    #expect(f.platform.owners.allSatisfy { $0.ended })
  }

  @Test func consumedRetryOwnsChildrenAndCannotStartTwice() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    let first = try await f.start(prepared)
    let second = try await f.start(prepared)
    #expect(f.platform.started == 2)
    await #expect(throws: (any Error).self) {
      try await coordinator.prepare(authorizationID: id, context: f.context)
    }
    try prepared.finishAdmission()
    await #expect(throws: (any Error).self) { try await f.start(prepared) }
    _ = try await first.cancel()
    try await coordinator.reconcile()
    #expect(try f.execution(prepared.executionID).isRunning)
    _ = try await second.cancel()
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(
      try prepared.accessExecution(prepared.executionID, operation: .readResult).outputBytes
        == 8_388_608)
    #expect(throws: (any Error).self) {
      try prepared.accessExecution(prepared.executionID, operation: .writeInput)
    }
    try f.revoke()
    try await coordinator.reconcile()
    #expect(throws: (any Error).self) {
      try prepared.accessExecution(prepared.executionID, operation: .readResult)
    }
  }

  @Test func cancelQueuesEveryChildWithoutRevokingRetainedResults() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    _ = try await f.start(prepared)
    try prepared.finishAdmission()
    _ = try prepared.accessExecution(prepared.executionID, operation: .cancel)
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(f.platform.owners.allSatisfy { $0.ended })
    _ = try prepared.accessExecution(prepared.executionID, operation: .readResult)
  }

  @Test func ownerStopJoinsOnlySelectedExecutionsAndLeavesSharedAdmissionOpen() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let firstID = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let selected = try await coordinator.prepare(authorizationID: firstID, context: f.context)
    _ = try await f.start(selected)
    _ = try await f.start(selected)
    let selectedOwners = f.platform.owners
    let otherID = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let other = try await coordinator.prepare(authorizationID: otherID, context: f.context)
    _ = try await f.start(other)
    let otherOwner = try #require(f.platform.owners.last)

    try await coordinator.stopExecutions([selected.executionID])
    #expect(selectedOwners.allSatisfy { $0.ended })
    #expect(!otherOwner.ended)
    #expect(try f.execution(selected.executionID).isRunning == false)
    #expect(try f.execution(other.executionID).isRunning)
    #expect(throws: (any Error).self) { try selected.authority.reserveChild(UUID()) }
    #expect(throws: (any Error).self) { try selected.retainWork {} }
    #expect(throws: (any Error).self) {
      try selected.accessExecution(selected.executionID, operation: .writeInput)
    }
    _ = try selected.accessExecution(selected.executionID, operation: .readResult)
    _ = try await f.start(other)
    #expect(f.platform.started == 4)
    try await f.untilFinished(selected.executionID, coordinator)
    try f.paths.store.readWithDatabase { database, ledger in
      let record = try #require(try ExecutionRuntimeRecord.load(selected.executionID, database))
      #expect(record.admissionFinished && record.completed)
      #expect(record.children.values.allSatisfy { $0.completed && $0.released })
      var validation = ledger
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try validation.invocationAccess(firstID)
      }
      #expect(
        validation.executionAccess(
          selected.executionID, principal: f.paths.principal, operation: .readResult, now: Date())
          == .allowed)
    }
    try await coordinator.stopExecutions([other.executionID])
    try await f.untilFinished(other.executionID, coordinator)
    #expect(f.platform.owners.allSatisfy { $0.ended })
  }

  @Test(arguments: ["admission-audit", "runtime-write", "revocation-audit"])
  func ownerStopRetriesStorageFailureAfterJoiningNativeChildren(failure: String) async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    let owner = try #require(f.platform.owners.first)
    let cancelled = ExecutionProxyBox()
    let work = try prepared.retainWork { cancelled.markReleased() }
    let trigger: String
    if failure == "runtime-write" {
      trigger = """
        CREATE TRIGGER fail_owner_stop BEFORE UPDATE ON permissionRuntimeExecutions
        BEGIN SELECT RAISE(ABORT, 'fixture runtime write failure'); END
        """
    } else {
      let action = failure == "admission-audit" ? "admission.closed" : "revoked"
      trigger = """
        CREATE TRIGGER fail_owner_stop BEFORE INSERT ON auditEvents
        WHEN NEW.capabilityID = 'execution.\(action)'
        BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END
        """
    }
    try f.paths.store.transactionWithDatabase { database, _ in
      try database.execute(sql: trigger)
    }
    await #expect(throws: (any Error).self) {
      try await coordinator.stopExecutions([prepared.executionID])
    }
    #expect(owner.ended)
    #expect(throws: (any Error).self) { try prepared.authority.reserveChild(UUID()) }
    #expect(throws: (any Error).self) {
      try prepared.accessExecution(prepared.executionID, operation: .writeInput)
    }
    for _ in 0..<100 {
      if cancelled.released { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(cancelled.released)
    if failure == "runtime-write" {
      for _ in 0..<100 {
        if try f.execution(prepared.executionID).interruptedAt != nil { break }
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    if failure != "revocation-audit" {
      try f.paths.store.readWithDatabase { database, ledger in
        let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
        #expect(!record.admissionFinished && !record.completed)
        let execution = try #require(ledger.executions[prepared.executionID])
        if failure == "runtime-write" {
          #expect(!execution.isRunning && execution.interruptedAt != nil)
          #expect(ledger.pendingExecutionTerminations.contains(prepared.executionID))
        } else {
          #expect(execution.isRunning)
        }
      }
    }
    try f.paths.store.transactionWithDatabase { database, _ in
      try database.execute(sql: "DROP TRIGGER fail_owner_stop")
    }
    try work.finish()
    try await f.untilFinished(prepared.executionID, coordinator)
    try f.paths.store.readWithDatabase { database, ledger in
      let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      #expect(record.admissionFinished && record.completed && (record.workIDs?.isEmpty ?? true))
      #expect(record.children.values.allSatisfy { $0.completed && $0.released })
      #expect(ledger.executions[prepared.executionID]?.isRunning == false)
      #expect(!ledger.pendingExecutionTerminations.contains(prepared.executionID))
    }
    #expect(f.platform.started == 1)
  }

  @Test func ownerStopKeepsAnUnpublishedReservationUntilItSettles() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    let child = UUID()
    try prepared.authority.reserveChild(child)
    try await coordinator.stopExecutions([prepared.executionID])
    try f.paths.store.readWithDatabase { database, ledger in
      let record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      #expect(record.admissionFinished && !record.completed)
      #expect(record.children[child]?.completed == false)
      #expect(ledger.pendingExecutionTerminations.contains(prepared.executionID))
    }
    #expect(throws: (any Error).self) { try prepared.authority.reserveChild(UUID()) }
    prepared.authority.launchFailed(child)
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(f.platform.started == 0)
  }

  @Test(arguments: [false, true]) func failedLaunchDoesNotResurrectRetry(afterBinding: Bool)
    async throws
  {
    let f = try ExecutionFixture()
    f.platform.fail = afterBinding ? .afterBinding : .beforeBinding
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    await #expect(throws: (any Error).self) { try await f.start(prepared) }
    try await f.untilFinished(prepared.executionID, coordinator)
    await #expect(throws: (any Error).self) {
      try await coordinator.prepare(authorizationID: id, context: f.context)
    }
    #expect(
      try f.paths.store.readWithDatabase { _, ledger in ledger.authorizations[id]?.executionID }
        == prepared.executionID)
  }

  @Test func revocationStopsChildrenAndClosesProxy() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    try f.paths.store.transactionWithDatabase { _, ledger in
      _ = try ledger.setSandboxSettings(
        .init(network: .full), for: .init(principal: f.paths.principal, projectID: "project"),
        expectedRevision: ledger.revision)
    }
    let box = ExecutionProxyBox()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      let proxy = try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(), limits: .init())
      box.set(proxy)
      return proxy
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    _ = try await f.start(prepared)
    try prepared.finishAdmission()
    let proxy = try #require(box.value)
    _ = try await proxy.sandboxPorts()
    try f.revoke()
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(f.platform.owners.allSatisfy { $0.ended })
    await #expect(throws: (any Error).self) { try await proxy.sandboxPorts() }
    #expect(throws: (any Error).self) {
      try prepared.accessExecution(prepared.executionID, operation: .readResult)
    }
  }

  @Test(arguments: [false, true]) func connectionLifetime(connectionLimited: Bool) async throws {
    let f = try ExecutionFixture()
    let id = try f.authorizeConnection(limited: connectionLimited)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(
      authorizationID: id,
      context: connectionLimited ? f.programContext : f.context, connectionID: "first")
    let owner = try await f.start(prepared)
    try prepared.finishAdmission()
    try f.paths.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.endedConnections.insert("first")
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    try await coordinator.reconcile()
    if connectionLimited {
      try await f.untilFinished(prepared.executionID, coordinator)
      #expect(f.platform.owners.allSatisfy { $0.ended })
    } else {
      #expect(try f.execution(prepared.executionID).isRunning)
      let next = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let scope = try coordinator.continuation(authorizationID: next)
      _ = try scope.accessExecution(prepared.executionID, operation: .readResult)
      try f.paths.store.transactionWithDatabase { _, ledger in try ledger.finishInvocation(next) }
      #expect(throws: (any Error).self) {
        try scope.accessExecution(prepared.executionID, operation: .readResult)
      }
      _ = try await owner.cancel()
      try await f.untilFinished(prepared.executionID, coordinator)
    }
  }

  @Test(arguments: [
    "reserve", "child", "bind", "finish", "release", "ack", "epoch", "database-rollback",
  ])
  func crashBoundariesRecoverWithoutRestoringPermission(stage: String) async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let execution = try f.paths.store.transactionWithDatabase { _, ledger in
      try ledger.startExecution(owner: f.paths.principal, authorizationIDs: [id])
    }
    let child = UUID()
    let owner = f.platform.makeOwner()
    let recovery = try owner.recoveryState()
    var record = ExecutionRuntimeRecord(id: execution.id, ownerID: UUID(), boot: "boot")
    let admission = try f.worktreeAdmission()
    let use = try admission.reserve(ownerID: record.ownerID, executionID: execution.id)
    let operation = UUID()
    _ = try admission.close(operationID: operation)
    record.worktreeUse = use
    record.worktreeDurable = true
    record.invocationInFlight = stage != "ack"
    if stage != "reserve" {
      record.children[child] = .init(
        recovery: stage == "child" ? nil : recovery,
        completed: ["finish", "release", "ack"].contains(stage),
        released: ["release", "ack"].contains(stage))
    }
    if ["finish", "release", "ack"].contains(stage) { owner.complete() }
    if stage == "ack" {
      record.completed = true
      record.admissionFinished = true
    }
    try f.paths.store.transactionWithDatabase { database, ledger in
      try record.save(database)
      if stage == "database-rollback" {
        try database.execute(sql: "DELETE FROM permissionRuntimeExecutions")
      }
    }
    if ["epoch", "database-rollback"].contains(stage) { f.paths.counter.forget() }
    if !["reserve", "child"].contains(stage) {
      let journal = try ExecutionRecoveryJournal(
        directory: f.directory.appendingPathComponent("ownership"))
      try journal.save(
        .init(
          child: child, execution: execution.id, owner: record.ownerID,
          boot: "boot", recovery: recovery, worktreeUse: use,
          completed: owner.ended, released: stage == "ack"))
    }
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    try admission.requireDrained(operationID: operation)
    #expect(throws: WorktreeError.self) {
      try admission.reserve(ownerID: UUID(), executionID: UUID())
    }
    if !["reserve", "child"].contains(stage) { #expect(owner.ended) }
    if !["epoch", "database-rollback"].contains(stage) {
      #expect(try f.execution(execution.id).interruptedAt != nil || stage == "ack")
      #expect(
        try f.paths.store.readWithDatabase { _, ledger in
          !ledger.pendingExecutionTerminations.contains(execution.id)
        })
      await #expect(throws: (any Error).self) {
        try await coordinator.prepare(authorizationID: id, context: f.context)
      }
    } else {
      #expect(
        try f.paths.store.readWithDatabase { _, ledger in
          ledger.suspendedAuthority != nil || ledger.pendingEpochRecovery != nil
        })
    }
  }

  @Test func tighteningLimitsUpdatesObserversAndEndsUnsupportedMemoryUse() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    try prepared.finishAdmission()
    try f.limits(
      .init(outputBytes: 16, memoryBytes: 1024, retentionSeconds: 1, retainedOutputBytes: 32))
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(prepared.limits.outputBytes == 16)
    #expect(prepared.limits.memoryBytes == 1024)
    #expect(prepared.limits.retentionSeconds == 1)
    #expect(prepared.limits.retainedOutputBytes == 32)
    #expect(prepared.limitEndReason == .memoryLimitUnavailable)
  }

  @Test func tighteningElapsedTimeEndsExecution() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    try prepared.finishAdmission()
    try await Task.sleep(for: .milliseconds(20))
    try f.limits(.init(timeMilliseconds: 1))
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(prepared.limitEndReason == .timeLimit)
  }
}

private final class ExecutionFixture: @unchecked Sendable {
  let paths: DurablePathFixture
  let platform = DurableTestPlatform()
  var directory: URL { paths.root.appendingPathComponent("runtime") }
  var context: GatewaySandboxContext {
    .init(
      directory: try! SandboxPath(paths.project.path),
      temporaryDirectory: try! SandboxPath(paths.derived.path))
  }
  var programContext: GatewaySandboxContext {
    .init(
      directory: try! SandboxPath(paths.project.path),
      temporaryDirectory: try! SandboxPath(paths.derived.path), purpose: .projectProgram)
  }
  init() throws { paths = try DurablePathFixture() }
  func worktreeAdmission() throws -> WorktreeAdmission {
    let directory = paths.root.appendingPathComponent("admission")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let identity = try WorktreeDirectory(directory).identity
    let generation = UUID()
    let state: [String: Any] = [
      "projectID": "derived", "generation": generation.uuidString, "writers": [],
    ]
    try JSONSerialization.data(withJSONObject: state).write(
      to: directory.appendingPathComponent("state.json"))
    let identityJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
    return try JSONDecoder().decode(
      WorktreeAdmission.self,
      from: JSONSerialization.data(withJSONObject: [
        "projectID": "derived", "generation": generation.uuidString, "directory": identityJSON,
      ]))
  }
  func coordinator(
    launcher: ExecutionLauncher? = nil,
    proxyFactory: ExecutionRevocationCoordinator.ProxyFactory? = nil
  ) throws -> ExecutionRevocationCoordinator {
    try .init(
      store: paths.store, launcher: launcher ?? ExecutionLauncher(platform: platform),
      directory: directory, proxyFactory: proxyFactory)
  }
  func start(_ prepared: PreparedExecutionContext) async throws -> any ExecutionOwnership {
    try await prepared.withValue {
      try await ExecutionLauncher(platform: platform).start(
        executable: .init("/bin/true"), arguments: [],
        directory: .init(paths.project.path), environment: prepared.environment, mode: .fullAccess)
    }
  }
  func execution(_ id: UUID) throws -> AuthorizedExecution {
    try paths.store.readWithDatabase { _, ledger in try #require(ledger.executions[id]) }
  }
  func untilFinished(_ id: UUID, _ coordinator: ExecutionRevocationCoordinator) async throws {
    for _ in 0..<100 {
      try await coordinator.reconcile()
      let completed = try paths.store.readWithDatabase { database, ledger in
        try ExecutionRuntimeRecord.load(id, database)?.completed == true
          && !ledger.pendingExecutionTerminations.contains(id)
      }
      if completed { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Execution did not finish")
  }
  func revoke() throws {
    try paths.store.transactionWithDatabase { _, ledger in
      _ = try ledger.revoke(
        principal: paths.principal, permission: .project("project"),
        expectedRevision: ledger.revision)
    }
  }
  func limits(_ limits: ExecutionLimitCeilings) throws {
    try paths.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.limits[paths.principal] = ManagedLimits(sources: [
        .managedPreferences: .available(ManagedPolicy(executionLimits: limits))
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }
  func authorizeConnection(limited: Bool) throws -> UUID {
    _ = try paths.authorize(paths.project, operation: .read, once: false)
    return try paths.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      let mode: ComputerMCPPermissions.ExecutionMode =
        limited ? .fullAccess(.connection("first")) : .sandbox
      let consent = limited ? ledger.consent(for: paths.principal, mode: mode) : nil
      environment.connections["first"] = .init(
        principal: paths.principal, consent: consent, attenuation: .init())
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      let decision = try ledger.authorize(
        invocation: .init(
          principal: paths.principal, tool: "shell.spawn", projectID: "project",
          argumentsDigest: "call"),
        requirements: .init(
          paths: [.init(path: CanonicalPath(paths.project.path), operation: .read)], mode: mode,
          sandboxProjectID: "project"), connectionID: "first", now: Date())
      guard case .allowed(let proof) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      return proof.id
    }
  }
}

private final class DurableTestPlatform: ExecutionPlatform, @unchecked Sendable {
  enum Failure { case beforeBinding, afterBinding }
  private let lock = NSLock()
  private var values: [DurableTestOwnership] = []
  var fail: Failure?
  var owners: [DurableTestOwnership] { lock.withLock { values } }
  var started: Int { owners.count }
  var supportsRecovery: Bool { true }
  var bootSessionID: String? { "boot" }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool { true }
  func makeOwner() -> DurableTestOwnership {
    lock.withLock {
      let owner = DurableTestOwnership(
        member: .init(processID: Int32(values.count + 100), identity: UInt64(values.count + 100)))
      values.append(owner)
      return owner
    }
  }
  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    if fail == .beforeBinding { throw CancellationError() }
    let owner = makeOwner()
    bindOwnership(owner)
    do {
      try owner.admit()
      if fail == .afterBinding { throw CancellationError() }
      return owner
    } catch {
      owner.complete()
      throw error
    }
  }
  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    try #require(owners.first { $0.member == state.root })
  }
}

private final class DurableTestOwnership: ExecutionOwnership, @unchecked Sendable {
  let member: ExecutionMember
  private let lock = NSLock()
  private var handlers: [@Sendable (ExecutionMember) throws -> Void] = []
  private var cancellations: [@Sendable () -> Void] = []
  private var reports: [@Sendable (ExecutionSandboxViolation) -> Void] = []
  private var finished = false
  private var cancellation: (@Sendable (ContinuousClock.Instant) async throws -> Void)?
  private var deadlines: [ContinuousClock.Instant] = []
  var cancellationDeadlines: [ContinuousClock.Instant] { lock.withLock { deadlines } }
  func setCancellation(_ action: (@Sendable (ContinuousClock.Instant) async throws -> Void)?) {
    lock.withLock { cancellation = action }
  }
  var ended: Bool { lock.withLock { finished } }
  init(member: ExecutionMember) { self.member = member }
  func recoveryState() throws -> ExecutionRecoveryState {
    .init(root: member, sandboxed: true, backend: "test")
  }
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
    lock.withLock { handlers.append(handler) }
  }
  func admit() throws {
    let pending = lock.withLock {
      let pending = handlers
      handlers.removeAll()
      return pending
    }
    for handler in pending { try handler(member) }
  }
  func onSandboxViolation(_ handler: @escaping @Sendable (ExecutionSandboxViolation) -> Void) {
    lock.withLock { reports.append(handler) }
  }
  func report(_ violation: ExecutionSandboxViolation) {
    for handler in lock.withLock({ reports }) { handler(violation) }
  }
  func complete() {
    lock.withLock {
      finished = true
      handlers.removeAll()
    }
  }
  func members() async throws -> [ExecutionMember] { ended ? [] : [member] }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {
    lock.withLock { cancellations.append(handler) }
  }
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    let action = lock.withLock {
      deadlines.append(deadline)
      return cancellation
    }
    try await action?(deadline)
    for handler in lock.withLock({ cancellations }) { handler() }
    complete()
    return .init(status: 0)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    while !ended {
      if ContinuousClock.now >= deadline {
        throw ExecutionWaitExpired(ownership: self)
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    return .init(status: 0)
  }
}

private actor ReconciliationTestGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private(set) var entered = false
  func wait() async {
    entered = true
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

private final class ExecutionProxyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var proxy: EgressProxy?
  private var didRelease = false
  var value: EgressProxy? { lock.withLock { proxy } }
  var released: Bool { lock.withLock { didRelease } }
  func markReleased() { lock.withLock { didRelease = true } }
  func set(_ proxy: EgressProxy) { lock.withLock { self.proxy = proxy } }
}

private struct ExecutionTestRouting: EgressRouting {
  let onCancel: @Sendable () -> Void
  init(onCancel: @escaping @Sendable () -> Void = {}) { self.onCancel = onCancel }
  func observeChanges(_ handler: @escaping @Sendable (EgressRouteEvent) -> Void) throws
    -> any EgressRouteObservation
  { ExecutionTestObservation(onCancel: onCancel) }
  func route(to numericAddress: String) throws -> EgressRoute {
    .init(interface: "en0", interfaceIndex: 1, isTunnel: false, isDirect: false)
  }
}

private struct ExecutionTestObservation: EgressRouteObservation {
  let onCancel: @Sendable () -> Void
  func cancel() { onCancel() }
}

#if os(macOS)
  @Suite(.nativeIntegration, .serialized) struct AuthorizedProcessIntegrationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [PermissionAnswer.onlyThisTime, .always])
    func nativeFolderDenialBecomesAnExplicitRetry(answer: PermissionAnswer) async throws {
      let f = try ExecutionFixture()
      let target = f.paths.root.appendingPathComponent("downloads/report")
      try Data("folder-retry-evidence\n".utf8).write(to: target)
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      // Repeated root-process reads exercise delivery after stream attachment;
      // this does not assert capture of the first denial or an unseen descendant.
      let script =
        "for ((i=0;i<100;i++)); do if IFS= read -r value < \"$1\"; then printf '%s' \"$value\"; exit 0; fi; /bin/sleep .1; done; exit 13"
      let owner = try await prepared.withValue {
        try await launcher.start(
          executable: .init("/bin/bash"), arguments: ["-c", script, "fixture", target.path],
          directory: .init(f.paths.project.path), environment: prepared.environment,
          mode: prepared.mode)
      }
      var requests: [PermissionRequest] = []
      let deadline = ContinuousClock.now + .seconds(12)
      while requests.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
        requests = try prepared.permissionRequests(prepared.executionID)
      }
      _ = try await owner.cancel()
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      let request = try #require(requests.first, "No attributable kernel folder denial arrived")
      guard case .permission(let content) = request.content else {
        Issue.record("Expected a folder permission request")
        return
      }
      #expect(content.requirement.permission == .filesAndFolders(.downloads))
      let retryID = try f.paths.store.transactionWithDatabase { _, ledger in
        let proof = try #require(ledger.authorizations[id])
        _ = try ledger.answer(request.id, with: answer, now: Date())
        guard
          case .allowed(let retry) = try ledger.authorize(
            invocation: proof.invocation,
            requirements: proof.requirements, retryIDs: [request.id], now: Date())
        else {
          throw PermissionModelError.invalidAuthorization
        }
        return retry.id
      }
      let retry = try await coordinator.prepare(authorizationID: retryID, context: f.context)
      let cli = CLIProcessExecution(launcher: launcher)
      let result = try await retry.withValue {
        try await cli.launchAsync(
          executable: "/bin/bash",
          invocation: .init(
            arguments: ["-c", script, "fixture", target.path], standardInput: Data()),
          cwd: f.paths.project, environment: [:], timeoutMilliseconds: 3000, maxOutputBytes: 1024)
      }
      #expect(result.stdout.base64 == Data("folder-retry-evidence".utf8).base64EncodedString())
      try retry.finishAdmission()
      try await f.untilFinished(retry.executionID, coordinator)
      await cli.shutdown()
    }

    @Test(arguments: [ExecutionLaunchMethod.subprocess, .foundation, .posixSpawn], [false, true])
    func failedNativeLaunchReleasesResourcesAndAllowsNextExecution(
      method: ExecutionLaunchMethod, beforeSpawn: Bool
    ) async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      try f.paths.store.transactionWithDatabase { _, ledger in
        _ = try ledger.setSandboxSettings(
          .init(network: .full), for: .init(principal: f.paths.principal, projectID: "project"),
          expectedRevision: ledger.revision)
      }
      let box = ExecutionProxyBox()
      let coordinator = try f.coordinator(
        launcher: launcher,
        proxyFactory: { id, policy, onDenial in
          let proxy = try await EgressProxy.start(
            executionID: id.uuidString, policy: policy,
            routing: ExecutionTestRouting(onCancel: { box.markReleased() }), limits: .init(),
            onDenial: onDenial)
          box.set(proxy)
          return proxy
        })
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let owners = FailedLaunchOwnerships()
      if beforeSpawn { try FileManager.default.removeItem(at: f.paths.project) }
      await #expect(throws: (any Error).self) {
        try await prepared.withValue {
          try await launcher.start(
            executable: .init("/usr/bin/true"), arguments: [],
            directory: .init(f.paths.project.path),
            environment: prepared.environment, mode: prepared.mode, method: method,
            bindOwnership: { owner in
              owners.bind(owner)
              if !beforeSpawn {
                owner.beforeStart { _ in
                  throw ExecutionEnvironmentError.launchFailed("Admission failed")
                }
              }
            })
        }
      }
      if beforeSpawn {
        #expect(owners.value == nil)
      } else {
        let owner = try #require(owners.value)
        _ = try await owner.waitForExit()
        _ = try await owner.cancel()
      }
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      #expect(box.released)
      let children = try f.paths.store.readWithDatabase { database, _ in
        try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database)).children
      }
      #expect(children.count == (beforeSpawn ? 0 : 1))
      #expect(children.values.allSatisfy { $0.completed && $0.released })
      await #expect(throws: (any Error).self) {
        try await coordinator.prepare(authorizationID: id, context: f.context)
      }
      if beforeSpawn {
        try FileManager.default.createDirectory(
          at: f.paths.project, withIntermediateDirectories: true)
      }
      let nextID = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let next = try await coordinator.prepare(authorizationID: nextID, context: f.context)
      let nextOwner = try await next.withValue {
        try await launcher.start(
          executable: .init("/usr/bin/true"), arguments: [], directory: .init(f.paths.project.path),
          environment: next.environment, mode: next.mode, method: method)
      }
      try next.finishAdmission()
      #expect(try await nextOwner.waitForExit().status == 0)
      try await f.untilFinished(next.executionID, coordinator)
    }

    @Test func proxyRefusesUnsupportedLaunchAndRevokedAuthority() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let marker = f.paths.project.appendingPathComponent("unconfined-launch")
      let server = MCPServerConfig(
        id: "authorized", transport: .stdio, command: "/bin/sh",
        args: ["-c", "printf unconfined > \"$1\"", "fixture", marker.path],
        startupTimeoutMs: 1000, requestTimeoutMs: 1000)
      let client = MCPProxyClient(launcher: launcher, workingDirectory: f.paths.project)
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let calls = BlockingOperationExecutor(label: "test.authorized-proxy")
      // Stdio supervision needs a verified server context and inherited host handles.
      // Until that context is supported, the real proxy must refuse sandbox startup.
      await #expect(throws: (any Error).self) {
        try await prepared.withValue {
          try await calls.perform { try client.listTools(server: server, context: .empty) }
        }
      }
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      try prepared.finishAdmission()
      try f.revoke()
      try await f.untilFinished(prepared.executionID, coordinator)
      await #expect(throws: (any Error).self) {
        try await prepared.withValue {
          try await client.callToolAsync(
            server: server, name: "inspect", arguments: .object([:]), requestID: nil,
            context: .empty)
        }
      }
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      let completed = try f.paths.store.readWithDatabase { database, _ in
        try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      }
      #expect(completed.completed)
      #expect(completed.children.values.allSatisfy { $0.completed && $0.released })
      await client.shutdown()
    }

    @Test func proxyRejectsAuthorityWithoutPreparedLaunchContext() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let scope = try coordinator.continuation(authorizationID: id)
      let client = MCPProxyClient(launcher: launcher, workingDirectory: f.paths.project)
      let server = MCPServerConfig(
        id: "unprepared", transport: .stdio, command: "/bin/cat", startupTimeoutMs: 1000)
      let calls = BlockingOperationExecutor(label: "test.unprepared-proxy")
      do {
        _ = try await InvocationExecution.$current.withValue(scope) {
          try await calls.perform { try client.listTools(server: server, context: .empty) }
        }
        Issue.record("Unprepared authority launched a downstream server")
      } catch {
        #expect(String(describing: error).contains("prepared launch context"))
      }
      await client.shutdown()
    }

    @Test func cliBlockingBridgeKeepsPreparedModeAndLimits() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      try f.limits(.init(outputBytes: 4))
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let cli = CLIProcessExecution(launcher: launcher)
      let result = try await prepared.withValue {
        try await cli.launchAsync(
          executable: "/usr/bin/printf",
          invocation: .init(arguments: ["12345678"], standardInput: Data()), cwd: f.paths.project,
          environment: [:], timeoutMilliseconds: 2000, maxOutputBytes: 1024)
      }
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      #expect(result.executionID == prepared.executionID)
      #expect(result.stdout.base64 == Data("5678".utf8).base64EncodedString())
      #expect(result.droppedBytes == 4)
      await cli.shutdown()
    }

    @Test func oneTimeShellOutputSurvivesCompletionAndTighteningButNotRevocation() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let runtime = ShellSessionRuntime(launcher: launcher)
      let blocking = BlockingOperationExecutor(label: "test.authorized-shell", serial: false)
      let result = try await prepared.withValue {
        try await blocking.perform {
          try runtime.run(
            request: .init(
              mode: .argv, executable: "/bin/sh", argv: ["-c", "printf 1234; printf 5678 >&2"]),
            defaultShell: "/bin/sh", defaultWorkingDirectory: f.paths.project,
            timeoutMilliseconds: 2000, maxOutputBytes: 1024, maxSessions: 1)
        }
      }
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      try f.limits(.init(outputBytes: 3))
      try await coordinator.reconcile()
      let retained = try prepared.withValue {
        try runtime.read(
          sessionID: result.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
          encoding: .utf8)
      }
      #expect(
        (retained.stdout.text?.utf8.count ?? 0) + (retained.stderr.text?.utf8.count ?? 0) == 3)
      #expect(retained.droppedBytes == 5)
      try f.revoke()
      try await coordinator.reconcile()
      #expect(throws: (any Error).self) {
        try prepared.withValue {
          try runtime.read(
            sessionID: result.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
            encoding: .utf8)
        }
      }
      await runtime.shutdown()
    }

    @Test func asyncShellWriteRechecksAuthorityAndRevocationReleasesBlockedWriter() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let runtime = ShellSessionRuntime(launcher: launcher)
      let blocking = BlockingOperationExecutor(label: "test.authorized-spawn", serial: false)
      let sessionID = try await prepared.withValue {
        try await blocking.perform {
          try runtime.spawn(
            request: .init(mode: .argv, executable: "/bin/sleep", argv: ["60"]),
            defaultShell: "/bin/sh", defaultWorkingDirectory: f.paths.project,
            timeoutMilliseconds: nil, maxOutputBytes: 1024, maxSessions: 1)
        }
      }
      try prepared.finishAdmission()
      await #expect(throws: (any Error).self) {
        try await runtime.writeAsync(sessionID: sessionID, data: Data("denied".utf8), close: false)
      }
      let writer = Task {
        try await prepared.withValue {
          try await runtime.writeAsync(
            sessionID: sessionID, data: Data(repeating: 65, count: 1_048_576), close: false)
        }
      }
      try await Task.sleep(for: .milliseconds(50))
      try f.revoke()
      try await coordinator.reconcile()
      await #expect(throws: (any Error).self) { try await writer.value }
      await runtime.shutdown()
    }

    @Test func unsupportedFullAccessIsRefusedBeforeReservation() async throws {
      let f = try ExecutionFixture()
      let id = try f.paths.authorize(
        f.paths.project, operation: .read, once: false, fullAccess: true)
      let coordinator = try f.coordinator(launcher: testExecutionLauncher())
      try await coordinator.recover()
      await #expect(throws: ExecutionEnvironmentError.self) {
        try await coordinator.prepare(authorizationID: id, context: f.programContext)
      }
      #expect(
        try f.paths.store.readWithDatabase { _, ledger in ledger.authorizations[id]?.executionID }
          == nil)
    }
  }
#endif

@Suite struct AuthorizedOutputRecoveryTests {
  @Test func identicalOriginalCallsKeepIndependentProcessListRetryGroups() async throws {
    let f = try ExecutionFixture()
    let callbacks = RuntimeDenialCallbacks()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      callbacks.install(id, policy: policy, handler: onDenial)
      return try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(), limits: .init(), onDenial: onDenial)
    })
    try await coordinator.recover()
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    var contexts: [PreparedExecutionContext] = []
    var records: [TerminalSessionJournal.Record] = []
    var proofs: [UUID: InvocationAuthorization] = [:]
    for host in ["first.example", "second.example"] {
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      contexts.append(prepared)
      proofs[prepared.executionID] = try f.paths.store.readWithDatabase { _, ledger in
        try #require(ledger.authorizations[id])
      }
      let owner = try await f.start(prepared)
      callbacks.emit(prepared.executionID, host: host)
      try prepared.finishAdmission()
      _ = try await owner.cancel()
      try await f.untilFinished(prepared.executionID, coordinator)
      records.append(
        record(
          prepared, scope: scope, stdout: "partial", stderr: "", offset: -1,
          order: [.init(stdout: true, count: 7)], registered: true))
    }
    #expect(Set(proofs.values.map(\.invocation)).count == 1)
    let directory = f.paths.root.appendingPathComponent("output")
    try save(records, to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    let processes = ManagedProcessRegistry(launcher: launcher, shellManager: runtime)
    let continuationID = try f.paths.store.transactionWithDatabase { _, ledger in
      guard
        case .allowed(let proof) = try ledger.authorize(
          invocation: .init(
            principal: f.paths.principal, tool: "process.list", projectID: nil,
            argumentsDigest: "list"),
          requirements: .init(), now: Date())
      else { throw PermissionModelError.invalidAuthorization }
      return proof.id
    }
    let continuation = try coordinator.continuation(authorizationID: continuationID)
    let listed = try InvocationExecution.$current.withValue(continuation) { try processes.list() }
    #expect(listed.count == 2)
    let groups = try continuation.currentPermissionRequestGroups()
    #expect(groups.count == 2)
    #expect(Set(groups.map(\.executionID)) == Set(contexts.map(\.executionID)))
    let envelope = GatewayExecutionPermissionMetadata.attach(
      to: .object([
        "isError": .bool(false),
        "structuredContent": .object(["processes": .array(listed.map(\.json))]),
      ]), groups: groups)
    let serialized = try #require(
      envelope.objectValue?["_meta"]?.objectValue?["computer_mcp"]?
        .objectValue?["permission_requests"]?.arrayValue)
    #expect(serialized.count == 2)
    #expect(
      Set(serialized.compactMap { $0.objectValue?["request_group_id"]?.stringValue })
        == Set(contexts.map { $0.executionID.uuidString }))
    #expect(f.platform.started == 2)
    for group in groups {
      let proof = try #require(proofs[group.executionID])
      let retried = try f.paths.store.transactionWithDatabase { _, ledger in
        for request in group.requests {
          try ledger.answer(request.id, with: .onlyThisTime, now: Date())
        }
        guard
          case .allowed(let retry) = try ledger.authorize(
            invocation: proof.invocation,
            requirements: proof.requirements, retryIDs: Set(group.requests.map(\.id)), now: Date())
        else { throw PermissionModelError.invalidAuthorization }
        return retry
      }
      let host = try #require(
        group.requests.compactMap { request -> String? in
          if case .network(let content) = request.content { return content.host }
          return nil
        }.first)
      let retry = try await coordinator.prepare(authorizationID: retried.id, context: f.context)
      #expect(callbacks.policy(retry.executionID)?.admits(host: host) == true)
      #expect(
        callbacks.policy(retry.executionID)?.admits(
          host: host == "first.example" ? "second.example" : "first.example") == false)
      let owner = try await f.start(retry)
      try retry.finishAdmission()
      _ = try await owner.cancel()
      try await f.untilFinished(retry.executionID, coordinator)
    }
    #expect(f.platform.started == 4)
    await runtime.shutdown()
  }

  @Test(arguments: ["unchanged", "revoked", "tightened"])
  func optionalRequestMetadataFailurePreservesResultsAndFinalAuthority(change: String) async throws
  {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    let record = record(
      prepared, scope: scope, stdout: "12345678", stderr: "", offset: -1,
      order: [.init(stdout: true, count: 8)])
    try save([record], to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    let authority = FailingRequestMetadataAuthority(prepared: prepared) {
      if change == "revoked" { try f.revoke() }
      if change == "tightened" { try f.limits(.init(outputBytes: 3)) }
    }
    let read = {
      try InvocationExecution.$current.withValue(authority) {
        try runtime.read(
          sessionID: record.snapshot.sessionID, stdoutCursor: 0, stderrCursor: 0,
          maxReadBytes: 1024, encoding: .utf8)
      }
    }
    if change == "revoked" {
      #expect(throws: PermissionModelError.self) { try read() }
    } else {
      let value = try read()
      #expect(value.sessionID == record.snapshot.sessionID)
      #expect(value.executionID == prepared.executionID)
      #expect(value.stdout.text == (change == "tightened" ? "678" : "12345678"))
      #expect(value.droppedBytes == (change == "tightened" ? 5 : 0))
      #expect(value.permissionRequestIDs == nil)
      #expect(!value.isRunning && value.exitCode == 0)
    }
    await runtime.shutdown()
  }

  @Test func retainedProcessOutputIncludesOriginalCallRequestsWithoutLosingStatus() async throws {
    let f = try ExecutionFixture()
    let callbacks = RuntimeDenialCallbacks()
    let coordinator = try f.coordinator(proxyFactory: { id, policy, onDenial in
      callbacks.install(id, policy: policy, handler: onDenial)
      return try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(), limits: .init(), onDenial: onDenial)
    })
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    callbacks.emit(prepared.executionID, host: "output.example.com")
    let requests = try prepared.permissionRequests(prepared.executionID)
    #expect(requests.count == 1)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    let record = record(
      prepared, scope: scope, stdout: "partial", stderr: "", offset: -1,
      order: [.init(stdout: true, count: 7)])
    try save([record], to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    let value = try prepared.withValue {
      try runtime.read(
        sessionID: record.snapshot.sessionID, stdoutCursor: 0, stderrCursor: 0,
        maxReadBytes: 1024, encoding: .utf8)
    }
    #expect(value.permissionRequestIDs == requests.map(\.id))
    #expect(value.executionID == prepared.executionID)
    #expect(value.stdout.text == "partial")
    #expect(!value.isRunning && value.exitCode == 0)
    #expect(value.json.objectValue?["permission_request_ids"]?.arrayValue?.count == 1)
    await runtime.shutdown()
  }

  @Test func finalAuthorityCheckRebuildsOutputAfterTightening() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    let record = record(
      prepared, scope: scope, stdout: "12345678", stderr: "", offset: -1,
      order: [.init(stdout: true, count: 8)])
    try save([record], to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    let authority = TighteningReadAuthority(prepared: prepared) {
      try f.limits(.init(outputBytes: 3))
    }
    let value = try InvocationExecution.$current.withValue(authority) {
      try runtime.read(
        sessionID: record.snapshot.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
        encoding: .utf8)
    }
    #expect(value.stdout.text == "678")
    #expect(value.droppedBytes == 5)
    #expect(value.permissionLimits?.outputBytes == 3)
  }

  @Test func staleInitialCallbackCannotWidenRetainedLimits() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    let original = prepared.limits
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    let record = record(
      prepared, scope: scope, stdout: "12345678", stderr: "", offset: -1,
      order: [.init(stdout: true, count: 8)])
    try save([record], to: directory)
    try f.limits(.init(outputBytes: 3, retentionSeconds: 60, retainedOutputBytes: 32))
    try await coordinator.reconcile()
    let tightened = prepared.limits
    prepared.applyLimits(original)
    #expect(prepared.limits == tightened)
    let storage = GatewayTerminalSessions()
    try storage.enablePersistence(
      at: directory, launcher: ExecutionLauncher(platform: f.platform),
      authority: ReorderedRecoveryAuthority(original: original, tightened: tightened))
    let saved = try JSONDecoder().decode(
      TerminalSessionJournal.Record.self,
      from: Data(contentsOf: directory.appendingPathComponent(record.snapshot.sessionID + ".json")))
    #expect(saved.snapshot.permissionLimits == tightened)
    #expect(saved.snapshot.stdout.base64 == Data("678".utf8).base64EncodedString())
  }

  @Test func recoveredInterleavedOutputTightensInArrivalOrder() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    let record = record(
      prepared, scope: scope, stdout: "abcd", stderr: "efgh", offset: -1,
      order: [
        .init(stdout: true, count: 2), .init(stdout: false, count: 4),
        .init(stdout: true, count: 2),
      ])
    try save([record], to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(
      launcher: launcher, sessions: storage, scope: scope, recoveryKey: { nil })
    try f.limits(.init(outputBytes: 3))
    try await coordinator.reconcile()
    let value = try prepared.withValue {
      try runtime.read(
        sessionID: record.snapshot.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
        encoding: .utf8)
    }
    #expect(value.stdout.text == "cd")
    #expect(value.stderr.text == "h")
    #expect(value.droppedBytes == 5)
    #expect(value.permissionLimits?.outputBytes == 3)
    #expect(throws: (any Error).self) {
      try runtime.read(
        sessionID: record.snapshot.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
        encoding: .utf8)
    }
  }

  @Test func retainedOutputEvictsOldestWithoutKeepingSmallerOlderResults() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    try f.limits(.init(retainedOutputBytes: 20))
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    var records: [TerminalSessionJournal.Record] = []
    var contexts: [PreparedExecutionContext] = []
    for (index, count) in [5, 15, 10].enumerated() {
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      records.append(
        record(
          prepared, scope: scope, stdout: String(repeating: "x", count: count), stderr: "",
          offset: Double(index - 3), order: [.init(stdout: true, count: count)]))
      contexts.append(prepared)
    }
    let directory = f.paths.root.appendingPathComponent("output")
    try save(records, to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    let visible = try contexts[2].withValue { try runtime.list() }
    #expect(visible.map(\.sessionID) == [records[2].snapshot.sessionID])
  }

  @Test func epochRetiredResultIsRemovedWithoutBlockingStoreRestoration() async throws {
    let f = try ExecutionFixture()
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    do {
      let coordinator = try f.coordinator()
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      try save(
        [
          record(
            prepared, scope: scope, stdout: "retired", stderr: "", offset: -1,
            order: [.init(stdout: true, count: 7)])
        ], to: directory)
    }
    f.paths.counter.forget()
    // The monitor has no resource lease after the final execution/context releases it.
    try await Task.sleep(for: .milliseconds(300))
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    #expect(
      try f.paths.store.readWithDatabase { _, ledger in
        ledger.pendingEpochRecovery == nil && ledger.suspendedAuthority != nil
      })
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    #expect(try runtime.list().isEmpty)
  }

  private func save(_ records: [TerminalSessionJournal.Record], to directory: URL) throws {
    let journal = try TerminalSessionJournal(directory: directory, bootSessionID: "boot")
    for record in records { try journal.save(record) }
  }

  private func record(
    _ prepared: PreparedExecutionContext, scope: GatewayTerminalSessions.Scope,
    stdout: String, stderr: String, offset: Double, order: [ShellOutputSegment],
    registered: Bool = false
  ) -> TerminalSessionJournal.Record {
    func stream(_ text: String) -> ShellStreamRead {
      .init(
        requestedCursor: 0, startCursor: 0, nextCursor: Int64(text.utf8.count),
        endCursor: Int64(text.utf8.count), missedBytes: false, truncated: false, encoding: .base64,
        text: nil, base64: Data(text.utf8).base64EncodedString())
    }
    return .init(
      recoveryKey: nil, bootSessionID: "boot", scope: scope, isRegisteredProcess: registered,
      snapshot: .init(
        sessionID: UUID().uuidString, processID: nil, isRunning: false, exitCode: 0,
        signal: nil, timedOut: false, cancelled: false,
        startedAt: Date().addingTimeInterval(offset - 1),
        finishedAt: Date().addingTimeInterval(offset), launchError: nil, streamErrors: [],
        stdout: stream(stdout), stderr: stream(stderr), executionID: prepared.executionID,
        permissionLimits: prepared.limits),
      members: [], outputOrder: order)
  }
}

private final class FailingRequestMetadataAuthority: ExecutionAccessChecking, @unchecked Sendable {
  let pathAccess: (any HostPathAccessChecking)? = nil
  let prepared: PreparedExecutionContext
  let change: @Sendable () throws -> Void
  private let lock = NSLock()
  private var changed = false

  init(prepared: PreparedExecutionContext, change: @escaping @Sendable () throws -> Void) {
    self.prepared = prepared
    self.change = change
  }

  func accessExecution(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  {
    try prepared.accessExecution(id, operation: operation)
  }

  func permissionRequests(_ id: UUID) throws -> [PermissionRequest] {
    let first = lock.withLock {
      guard !changed else { return false }
      changed = true
      return true
    }
    if first { try change() }
    throw CocoaError(.fileReadUnknown)
  }
}

private final class TighteningReadAuthority: ExecutionAccessChecking, @unchecked Sendable {
  let pathAccess: (any HostPathAccessChecking)? = nil
  let prepared: PreparedExecutionContext
  let tighten: @Sendable () throws -> Void
  private let lock = NSLock()
  private var calls = 0
  init(prepared: PreparedExecutionContext, tighten: @escaping @Sendable () throws -> Void) {
    self.prepared = prepared
    self.tighten = tighten
  }
  func accessExecution(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  {
    let finalCheck = lock.withLock {
      calls += 1
      return calls == 3
    }
    if finalCheck { try tighten() }
    return try prepared.accessExecution(id, operation: operation)
  }
}

private struct ReorderedRecoveryAuthority: ExecutionRecoveryAuthorizing {
  let original: EffectiveExecutionLimits
  let tightened: EffectiveExecutionLimits
  func recoveredExecution(_ id: UUID) throws -> EffectiveExecutionLimits? { original }
  func observeExecutionLimits(
    _ id: UUID, _ observer: @escaping @Sendable (EffectiveExecutionLimits) -> Void
  ) throws {
    observer(tightened)
    observer(original)
  }
}

private final class FailedLaunchOwnerships: @unchecked Sendable {
  private let lock = NSLock()
  private var owner: (any ExecutionOwnership)?
  var value: (any ExecutionOwnership)? { lock.withLock { owner } }
  func bind(_ owner: any ExecutionOwnership) { lock.withLock { self.owner = owner } }
}

private final class ReconciliationFailureSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var failing = false
  func set(_ value: Bool) { lock.withLock { failing = value } }
  func check() throws {
    if lock.withLock({ failing }) { throw PermissionModelError.invalidAuthorization }
  }
}

private final class RuntimeDenialCallbacks: @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks: [UUID: (EgressPolicy, @Sendable (EgressDenial) -> Void)] = [:]

  func install(
    _ id: UUID, policy: EgressPolicy, handler: @escaping @Sendable (EgressDenial) -> Void
  ) {
    lock.withLock { callbacks[id] = (policy, handler) }
  }
  func policy(_ id: UUID) -> EgressPolicy? { lock.withLock { callbacks[id]?.0 } }
  func emit(
    _ id: UUID, host: String, reason: EgressDenial.Reason = .hostNotAllowed, claimedID: UUID? = nil
  ) {
    let handler = lock.withLock { callbacks[id]?.1 }
    handler?(
      .init(executionID: (claimedID ?? id).uuidString, host: host, port: 443, reason: reason))
  }
}
