import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
  import Darwin
#endif

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPProviderSessionTests {
  @Test func standingReuseRequiresBothCompleteBasesAndSource() throws {
    let root = try ScopedTemporaryDirectory()
    let a = try SessionAuthority(client: "a")
    let same = try SessionAuthority(client: "a")
    let b = try SessionAuthority(client: "b")
    let project = try SessionAuthority(client: "a", project: "other")
    let source = try SessionAuthority(client: "a", digest: String(repeating: "b", count: 64))
    let revision = try SessionAuthority(client: "a", generation: 2)
    let providerRevision = try SessionAuthority(client: "a", providerGeneration: 2)
    let key = try MCPProviderSessionAuthority(a.prepared(root.url))
    #expect(key == (try MCPProviderSessionAuthority(same.prepared(root.url))))
    for different in [b, project, source, revision, providerRevision] {
      #expect(key != (try MCPProviderSessionAuthority(different.prepared(root.url))))
    }
    let once = try SessionAuthority(client: "a", once: true)
    let retry = try SessionAuthority(binding: once.binding)
    #expect(
      try MCPProviderSessionAuthority(once.prepared(root.url))
        != MCPProviderSessionAuthority(retry.prepared(root.url)))
  }

  @Test func projectGenerationAndCompiledFilesystemModeArePartOfSessionAuthority() throws {
    let folder = try ScopedTemporaryDirectory()
    let replacement = try ScopedTemporaryDirectory()
    let root = try ProjectRootIdentity(folder.url)
    let newRoot = try ProjectRootIdentity(replacement.url)
    let date = Date()
    let authority = try SessionAuthority(client: "a")
    let sibling = try SessionAuthority(client: "a")
    func project(
      _ content: ProviderProjectIdentity.Content, generation: Date = date,
      rootIdentity: ProjectRootIdentity = root
    ) -> ProviderProjectIdentity {
      .init(projectID: "project", registeredAt: generation, root: rootIdentity, content: content)
    }
    let source = try authority.prepared(folder.url, project: project(.source))
    let match = try sibling.prepared(folder.url, project: project(.source))
    try MCPProviderSessionAuthority.requireMatch(admitted: match, running: source)
    for mismatch in [
      project(.registered), project(.source, generation: date + 1),
      project(.source, rootIdentity: newRoot), project(.worktree(UUID())),
    ] {
      let admission = try sibling.prepared(folder.url, project: mismatch)
      #expect(throws: PermissionModelError.self) {
        try MCPProviderSessionAuthority.requireMatch(admitted: admission, running: source)
      }
    }
    let child = project(.worktree(UUID()))
    let read = try authority.prepared(folder.url, project: child)
    let write = try sibling.prepared(folder.url, project: child, readOnly: false)
    #expect(throws: PermissionModelError.self) {
      try MCPProviderSessionAuthority.requireMatch(admitted: read, running: write)
    }
    authority.invalidate()
    #expect(throws: PermissionModelError.self) {
      try MCPProviderSessionAuthority.requireMatch(admitted: match, running: source)
    }
  }

  @Test func uncertainCleanupBlocksOnlyItsDelegationAndLegacyRemainsConservative() throws {
    let root = try ScopedTemporaryDirectory()
    let storage = root.url.appendingPathComponent("ownership")
    let a = try SessionAuthority(client: "a")
    let b = try SessionAuthority(client: "b")
    let owner = try MCPProcessOwnership.acquire(
      root: storage, project: root.url, registration: "provider", provider: a.binding)
    try owner.finish(confirmed: false)
    #expect(throws: (any Error).self) {
      try MCPProcessOwnership.acquire(
        root: storage, project: root.url, registration: "provider", provider: a.binding)
    }
    let independent = try MCPProcessOwnership.acquire(
      root: storage, project: root.url, registration: "provider", provider: b.binding)
    try independent.finish(confirmed: true)
    #expect(
      try MCPProcessOwnership.inspect(
        root: storage, project: root.url, registration: "provider"
      ).count == 1)
    #expect(throws: (any Error).self) {
      try MCPProcessOwnership.acquire(root: storage, project: root.url, registration: "provider")
    }
    let legacyStorage = root.url.appendingPathComponent("legacy")
    let legacy = try MCPProcessOwnership.acquire(
      root: legacyStorage, project: root.url, registration: "provider")
    try legacy.finish(confirmed: false)
    #expect(throws: (any Error).self) {
      try MCPProcessOwnership.acquire(
        root: legacyStorage, project: root.url, registration: "provider", provider: b.binding)
    }
  }

  @Test func callbackDirectoryCannotSelectAnotherClientsOrOneTimeInvocation() throws {
    let root = try ScopedTemporaryDirectory()
    let directory = MCPHostToolDirectory()
    let a = try SessionAuthority(client: "a").prepared(root.url)
    let b = try SessionAuthority(client: "b").prepared(root.url)
    let once = try SessionAuthority(client: "a", once: true).prepared(root.url)
    for execution in [a, b, once] {
      let invocation = MCPHostInvocation(
        id: UUID(), requestLeaseID: UUID(), admission: nil,
        reference: .init(serverID: "provider", toolName: "pid"),
        admittedCapability: .init(id: "fixture", risk: .readOnly, requirement: .none),
        upstreamName: "fixture", arguments: [:],
        context: .init(caller: .localMCP, profileID: .localAdmin, projectID: "project"),
        authorizationRevision: 1, providerExecution: execution)
      try directory.begin(invocation, store: nil)
    }
    for execution in [a, b, once] {
      let selected = directory.active(projectID: "project", origin: "provider", provider: execution)
      #expect(selected.count == 1 && selected.first?.providerExecution === execution)
    }
  }

  #if os(macOS)
    @Test(.nativeIntegration, arguments: [true, false])
    func explicitConnectionSelectionCannotChangePreparedProjectScope(sourceFirst: Bool) async throws
    {
      let fixture = try SessionFixture()
      defer { fixture.remove() }
      let work = GatewayOwnedWork()
      let client = fixture.client(ownedWork: work)
      let authority = try SessionAuthority(client: "a")
      let root = try ProjectRootIdentity(fixture.root)
      let date = Date()
      let child = ProviderProjectIdentity.Content.worktree(UUID())
      let source = ProviderProjectIdentity.Content.source
      func project(_ content: ProviderProjectIdentity.Content) -> ProviderProjectIdentity {
        .init(projectID: "project", registeredAt: date, root: root, content: content)
      }
      do {
        let first = try authority.prepared(
          fixture.root, project: project(sourceFirst ? source : child))
        let pid = try await fixture.call(client, execution: first)
        let owner = try #require(work.snapshot.first { $0.kind == .mcpUnreportedWork })
        let connection = try #require(owner.connectionID)
        let target = MCPContinuationTarget(
          projectID: "project", reference: .init(serverID: "provider", toolName: "pid"),
          connectionID: connection, instanceID: nil, resources: [:], selectedOwnershipID: owner.id)
        let other = try SessionAuthority(client: "a")
        let mismatch = try other.prepared(
          fixture.root, project: project(sourceFirst ? child : source))
        await #expect(throws: PermissionModelError.self) {
          try await fixture.call(client, execution: mismatch, selection: target)
        }
        #expect(other.starts == 0 && other.retained == 0)
        let match = try other.prepared(fixture.root, project: project(sourceFirst ? source : child))
        #expect(try await fixture.call(client, execution: match, selection: target) == pid)
        #expect(try await fixture.call(client, execution: mismatch) != pid)
        await client.shutdown()
      } catch {
        await client.shutdown()
        throw error
      }
    }

    @Test(.nativeIntegration)
    func concurrentCallsReuseMatchingAuthorityAndSeparateClientsAndOneTimeExecutions() async throws
    {
      let f = try SessionFixture()
      defer { f.remove() }
      let a = try SessionAuthority(client: "a")
      let same = try SessionAuthority(client: "a")
      let b = try SessionAuthority(client: "b")
      let once = try SessionAuthority(client: "a", once: true)
      let nextOnce = try SessionAuthority(binding: once.binding)
      let client = f.client()
      do {
        async let first = f.call(client, authority: a)
        async let second = f.call(client, authority: same)
        let (firstPID, secondPID) = try await (first, second)
        #expect(firstPID == secondPID)
        #expect(a.retained == 1 && same.retained == 1)
        let bPID = try await f.call(client, authority: b)
        let oncePID = try await f.call(client, authority: once)
        let nextPID = try await f.call(client, authority: nextOnce)
        #expect(Set([firstPID, bPID, oncePID, nextPID]).count == 4)
        #expect(a.starts + same.starts == 1)
        #expect(b.starts == 1 && once.starts == 1 && nextOnce.starts == 1)
        a.invalidate()
        same.invalidate()
        #expect(try await f.call(client, authority: b) == bPID)
        let replacement = try SessionAuthority(client: "a", generation: 2)
        #expect(try await f.call(client, authority: replacement) != firstPID)
        #expect(kill(firstPID, 0) == -1 && errno == ESRCH)
        #expect(kill(bPID, 0) == 0)
        await client.shutdown()
        #expect([a, same, b, once, nextOnce, replacement].allSatisfy { $0.retained == 0 })
        for pid in [bPID, oncePID, nextPID] { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
      } catch {
        await client.shutdown()
        throw error
      }
    }

    @Test(.nativeIntegration, arguments: [false, true])
    func stoppedWaiterDoesNotRetireSharedDiscoveryStartup(atTimeout: Bool) async throws {
      let f = try SessionFixture(holdStartup: true)
      defer { f.remove() }
      let source = SessionSource(root: f.root, hostVariables: f.server.env)
      let state = SessionDiscoveryWaiters()
      let client = f.client(source: source) { _, connectionID, _ in state.selected(connectionID) }
      let executor = BlockingOperationExecutor(label: "shared-discovery-start", serial: false)
      let first = Task {
        try await executor.perform {
          try client.listTools(
            server: f.server, context: .init(isDiscoveryCancelled: { state.stopped }))
        }
      }
      var second: Task<[MCPTool], any Error>?
      let release = f.root.appendingPathComponent("startup-release")
      do {
        let entered = f.root.appendingPathComponent("startup-entered")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: entered.path) {
          guard ContinuousClock.now < deadline else {
            throw GatewayToolError.executionFailed("Discovery startup did not enter the barrier")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        if atTimeout { try await Task.sleep(for: .seconds(1)) }
        second = Task {
          try await executor.perform { try client.listTools(server: f.server, context: .empty) }
        }
        while state.connections.count < 2 {
          guard ContinuousClock.now < deadline else {
            throw GatewayToolError.executionFailed("The sibling did not select discovery")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(state.connections).count == 1)
        state.stop()
        if !atTimeout { try Data().write(to: release) }
        do {
          _ = try await first.value
          Issue.record("Stopped startup waiter returned a catalog")
        } catch { #expect(error is CancellationError) }
        if atTimeout { try Data().write(to: release) }
        let sibling = try await #require(second).value
        #expect(sibling.map(\.name) == ["pid"])
        #expect(source.preparations == 1 && source.starts == 1)
        let status = try client.connectionStatus(server: f.server, context: .empty)
        #expect(status.objectValue?["state"] == .string("connected"))
        #expect(status.objectValue?["last_error"] == .null)
        let events = try client.readEvents(
          server: f.server, afterCursor: 0, maxResults: 100, context: .empty)
        #expect(
          events.objectValue?["events"]?.arrayValue?.contains {
            $0.objectValue?["kind"] == .string("connection.failed")
          } == false)
        await client.shutdown()
      } catch {
        state.stop()
        try? Data().write(to: release)
        _ = await first.result
        if let second { _ = await second.result }
        await client.shutdown()
        throw error
      }
    }

    @Test(.nativeIntegration, arguments: [false, true])
    func sharedInitializationFailureRetiresEvenWhenWaiterStops(stopOnFailure: Bool) async throws {
      let f = try SessionFixture(holdStartup: true, failStartupOnce: true)
      defer { f.remove() }
      let source = SessionSource(root: f.root, hostVariables: f.server.env)
      let state = SessionDiscoveryWaiters()
      let client = f.client(source: source) { _, connectionID, _ in state.selected(connectionID) }
      let executor = BlockingOperationExecutor(label: "failed-discovery-start", serial: false)
      let failed = f.root.appendingPathComponent("startup-failed")
      let release = f.root.appendingPathComponent("startup-release")
      let first = Task {
        try await executor.perform {
          try client.listTools(
            server: f.server,
            context: .init(isDiscoveryCancelled: {
              stopOnFailure && FileManager.default.fileExists(atPath: failed.path)
            }))
        }
      }
      do {
        let entered = f.root.appendingPathComponent("startup-entered")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: entered.path) {
          guard ContinuousClock.now < deadline else {
            throw GatewayToolError.executionFailed(
              "Failed-start fixture did not enter initialization")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(
          Int32(
            String(contentsOf: entered, encoding: .utf8).trimmingCharacters(
              in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0)
        try Data().write(to: release)
        do {
          _ = try await first.value
          Issue.record("The deliberately invalid initialization unexpectedly succeeded")
        } catch {
          if stopOnFailure {
            #expect(error is CancellationError)
          } else {
            #expect(!(error is CancellationError))
          }
        }
        #expect(FileManager.default.fileExists(atPath: failed.path))
        let status = try client.connectionStatus(server: f.server, context: .empty)
        #expect(status.objectValue?["state"] != .string("connecting"))
        let next = try await executor.perform {
          try client.listTools(server: f.server, context: .empty)
        }
        #expect(next.map(\.name) == ["pid"])
        #expect(source.preparations == 2 && source.starts == 2)
        #expect(state.connections.count == 2 && Set(state.connections).count == 2)
        await client.shutdown()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
      } catch {
        try? Data().write(to: release)
        _ = await first.result
        await client.shutdown()
        throw error
      }
    }

    @Test(.nativeIntegration)
    func startupAndMetadataRequestHaveIndependentTimeoutBudgets() async throws {
      let f = try SessionFixture(holdList: true, holdStartup: true)
      defer { f.remove() }
      let source = SessionSource(root: f.root, hostVariables: f.server.env)
      let client = f.client(source: source)
      let executor = BlockingOperationExecutor(label: "discovery-phase-budgets", serial: false)
      let started = ContinuousClock.now
      let request = Task {
        try await executor.perform { try client.listTools(server: f.server, context: .empty) }
      }
      let startupRelease = f.root.appendingPathComponent("startup-release")
      let listRelease = f.root.appendingPathComponent("list-release")
      do {
        let startup = f.root.appendingPathComponent("startup-entered")
        let enteredList = f.root.appendingPathComponent("list-entered")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: startup.path) {
          guard ContinuousClock.now < deadline else {
            throw GatewayToolError.executionFailed(
              "Startup budget fixture did not enter initialization")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .seconds(2))
        try Data().write(to: startupRelease)
        while !FileManager.default.fileExists(atPath: enteredList.path) {
          guard ContinuousClock.now < deadline else {
            throw GatewayToolError.executionFailed(
              "Startup budget fixture did not enter tools/list")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .seconds(4))
        try Data().write(to: listRelease)
        let tools = try await request.value
        #expect(tools.map(\.name) == ["pid"])
        #expect(started.duration(to: .now) > .seconds(5))
        #expect(source.preparations == 1 && source.starts == 1)
        await client.shutdown()
      } catch {
        try? Data().write(to: startupRelease)
        try? Data().write(to: listRelease)
        _ = await request.result
        await client.shutdown()
        throw error
      }
    }

    @Test(.nativeIntegration)
    func expiredRealCallerCannotPublishAfterMetadataHasReturned() async throws {
      let owner = try WorktreeServiceFixture()
      defer { owner.remove() }
      try await owner.runtime.ready()
      let proof = try owner.runtime.store.transactionWithDatabase { _, ledger in
        let decision = try ledger.authorize(
          invocation: .init(
            principal: .client("discovery-publication-caller"), tool: "fixture.call",
            projectID: nil, argumentsDigest: "publication"),
          requirements: .init(execution: try .init(timeMilliseconds: 600_000)), now: Date())
        guard case .allowed(let proof) = decision else {
          throw PermissionModelError.invalidAuthorization
        }
        return proof
      }
      let temp = owner.root.appendingPathComponent("publication-caller")
      try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
      let prepared = try await owner.runtime.coordinator.prepare(
        authorizationID: proof.id,
        context: .init(
          directory: .init(temp.path), temporaryDirectory: .init(temp.path),
          privateWorkingDirectory: true))
      let f: SessionFixture
      do { f = try SessionFixture(observePublication: true) } catch {
        try? prepared.finishAdmission()
        try? await owner.runtime.coordinator.stopExecutions([prepared.executionID])
        throw error
      }
      defer { f.remove() }
      let gate = SessionPublicationGate()
      let source = SessionSource(root: f.root, hostVariables: f.server.env, publicationGate: gate)
      let client = f.client(source: source)
      let changes = client.toolChanges()
      let notifications = Task { () -> Int in
        var count = 0
        for await _ in changes { count += 1 }
        return count
      }
      let executor = BlockingOperationExecutor(
        label: "expired-discovery-publication", serial: false)
      let request = Task {
        try await executor.perform {
          try client.listTools(server: f.server, context: .init(executionAuthority: prepared))
        }
      }
      do {
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered {
          guard ContinuousClock.now < deadline else {
            throw GatewayToolError.executionFailed(
              "Discovery did not reach the publication boundary")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        let before = try owner.runtime.store.transactionWithDatabase { _, ledger in
          let execution = try #require(ledger.executions[prepared.executionID])
          #expect(execution.isRunning && execution.limits.timeMilliseconds == 600_000)
          _ = ledger.reconcileExecutionLimits(
            now: execution.startedAt.addingTimeInterval(600.001))
          #expect(ledger.executions[execution.id]?.limitEndReason == .timeLimit)
          return execution
        }
        gate.release()
        do {
          _ = try await request.value
          Issue.record("Expired caller published metadata")
        } catch { #expect(error as? PermissionModelError == .invalidAuthorization) }
        #expect(try client.cachedTools(server: f.server, context: .empty) == nil)
        try owner.runtime.store.readWithDatabase { _, ledger in
          let after = try #require(ledger.executions[prepared.executionID])
          #expect(after.id == before.id && after.owner == before.owner)
          #expect(after.startedAt == before.startedAt)
          #expect(after.limits.timeMilliseconds == before.limits.timeMilliseconds)
          #expect(after.authorizationIDs == before.authorizationIDs)
          #expect(!after.isRunning && after.limitEndReason == .timeLimit)
        }
        await client.shutdown()
        #expect(await notifications.value == 0)
        try prepared.finishAdmission()
        try await owner.runtime.coordinator.stopExecutions([prepared.executionID])
      } catch {
        gate.release()
        _ = await request.result
        await client.shutdown()
        _ = await notifications.value
        try? prepared.finishAdmission()
        try? await owner.runtime.coordinator.stopExecutions([prepared.executionID])
        throw error
      }
    }

    @Test(.nativeIntegration)
    func stoppedCallerCannotPublishAfterMetadataHasReturned() async throws {
      let f = try SessionFixture(observePublication: true)
      defer { f.remove() }
      let gate = SessionPublicationGate()
      let source = SessionSource(root: f.root, hostVariables: f.server.env, publicationGate: gate)
      let state = SessionDiscoveryWaiters()
      let client = f.client(source: source)
      let changes = client.toolChanges()
      let notifications = Task { () -> Int in
        var count = 0
        for await _ in changes { count += 1 }
        return count
      }
      let executor = BlockingOperationExecutor(label: "discovery-publication", serial: false)
      let request = Task {
        try await executor.perform {
          try client.listTools(
            server: f.server, context: .init(isDiscoveryCancelled: { state.stopped }))
        }
      }
      do {
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered {
          guard ContinuousClock.now < deadline else {
            throw GatewayToolError.executionFailed(
              "Discovery did not reach the publication boundary")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
          FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent("list-produced").path))
        state.stop()
        gate.release()
        do {
          _ = try await request.value
          Issue.record("Stopped caller published metadata after returning from the provider")
        } catch { #expect(error is CancellationError) }
        #expect(try client.cachedTools(server: f.server, context: .empty) == nil)
        #expect(source.preparations == 1 && source.starts == 1)
        await client.shutdown()
        #expect(await notifications.value == 0)
      } catch {
        state.stop()
        gate.release()
        _ = await request.result
        await client.shutdown()
        _ = await notifications.value
        throw error
      }
    }

    @Test(.nativeIntegration)
    func sourceChangeDuringDiscoveryDoesNotPublishTheOldCatalog() async throws {
      let f = try SessionFixture(holdList: true)
      defer { f.remove() }
      let source = SessionSource(root: f.root, hostVariables: f.server.env)
      let client = f.client(source: source)
      let changes = client.toolChanges()
      let notifications = Task { () -> Int in
        var count = 0
        for await _ in changes { count += 1 }
        return count
      }
      let executor = BlockingOperationExecutor(label: "provider-source-race", serial: false)
      let request = Task {
        try await executor.perform { try client.listTools(server: f.server, context: .empty) }
      }
      let release = f.root.appendingPathComponent("list-release")
      do {
        let entered = f.root.appendingPathComponent("list-entered")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: entered.path) {
          guard ContinuousClock.now < deadline else {
            throw GatewayToolError.executionFailed("Discovery did not reach the list barrier")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        source.replace()
        try Data().write(to: release)
        do {
          _ = try await request.value
          Issue.record("A catalog from a superseded source was published")
        } catch { #expect(error as? PermissionModelError == .invalidAuthorization) }
        #expect(try client.cachedTools(server: f.server, context: .empty) == nil)
        await client.shutdown()
        #expect(await notifications.value == 0)
      } catch {
        try? Data().write(to: release)
        _ = await request.result
        await client.shutdown()
        _ = await notifications.value
        throw error
      }
    }

    @Test(.nativeIntegration)
    func discoveryUsesItsOwnProofAndChangedSourceCannotReturnTheCachedCatalog() async throws {
      let f = try SessionFixture()
      defer { f.remove() }
      let source = SessionSource(root: f.root, hostVariables: f.server.env)
      let client = f.client(source: source)
      let calls = BlockingOperationExecutor(label: "provider-discovery", serial: false)
      do {
        async let first = calls.perform { try client.listTools(server: f.server, context: .empty) }
        async let second = calls.perform { try client.listTools(server: f.server, context: .empty) }
        let catalogs = try await (first, second)
        #expect(catalogs.0.map(\.name) == ["pid"] && catalogs.1.map(\.name) == ["pid"])
        #expect(source.preparations == 1 && source.starts == 1)
        #expect(try client.cachedTools(server: f.server, context: .empty)?.map(\.name) == ["pid"])
        source.replace()
        #expect(try client.cachedTools(server: f.server, context: .empty) == nil)
        _ = try await calls.perform { try client.listTools(server: f.server, context: .empty) }
        #expect(source.preparations == 2 && source.starts == 2)
        #expect(throws: PermissionModelError.invalidAuthorization) {
          try client.callTool(
            server: f.server, name: "pid", arguments: .object([:]), context: .empty)
        }
        await client.shutdown()
      } catch {
        await client.shutdown()
        throw error
      }
    }
  #endif
}

/// Deterministic authority records isolate pool selection from ledger admission tests.
private final class SessionAuthority: ExecutionAuthorizing, @unchecked Sendable {
  static let limits = EffectiveExecutionLimits(
    timeMilliseconds: nil, outputBytes: 65_536, memoryBytes: nil, retentionSeconds: 60,
    retainedOutputBytes: 65_536, sources: [:])
  let executionID = UUID()
  let binding: ProviderExecutionBinding
  var authorizationIDs: Set<UUID> { binding.authorizationIDs }
  private let lock = NSLock()
  private var valid = true
  private var startCount = 0
  private var retainedCount = 0
  var starts: Int { lock.withLock { startCount } }
  var retained: Int { lock.withLock { retainedCount } }

  init(binding: ProviderExecutionBinding) throws { self.binding = binding }

  init(
    client: String? = nil, project: String = "project", generation: UInt64 = 1,
    providerGeneration: UInt64 = 1, digest: String = String(repeating: "a", count: 64),
    once: Bool = false
  ) throws {
    let identity = PluginIdentity.localServer("provider")
    let invocation = InvocationIdentity(
      principal: .plugin(identity), tool: "pid", projectID: client == nil ? nil : project,
      argumentsDigest: "fixture")
    let stable = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let provider = InvocationAuthorization(
      identity: .init(id: UUID(), generation: 1), invocation: invocation, requirements: .init(),
      basis: [.mode(.sandbox), .consent(.init(id: stable, generation: providerGeneration))])
    let caller = try client.map { client in
      let requirement = try PermissionRequirement(.mcpServer("provider"), .all)
      let basis = BasisIdentity(id: stable, generation: generation)
      var evidence: Set<AuthorizationBasis> = [
        .mode(.sandbox),
        .permission(
          .init(
            principal: .client(client), requirement: requirement, scope: .principal,
            pluginPurpose: nil, source: .standing(entry: requirement.permission, id: basis))),
      ]
      if once { evidence.insert(.request(.init(id: stable, generation: 1))) }
      return InvocationAuthorization(
        identity: .init(id: UUID(), generation: 1),
        invocation: .init(
          principal: .client(client), tool: "pid", projectID: project, argumentsDigest: "fixture"),
        requirements: .init(actions: [.init(requirement: requirement)]), basis: evidence)
    }
    binding = try .init(
      identity: identity, registrationID: "provider", sourceDigest: digest,
      providerAuthorization: provider, delegatingAuthorization: caller)
  }

  func prepared(
    _ directory: URL, hostVariables: [String: String] = [:],
    project: ProviderProjectIdentity? = nil, readOnly: Bool = true
  ) throws
    -> PreparedExecutionContext
  {
    let root = try SandboxPath(ProjectPathResolver.canonicalProject(directory).path)
    #if os(macOS)
      let reads = testExecutionLauncher().hostSystemReadPaths
    #else
      let reads: [SandboxPath] = []
    #endif
    let sandbox = try SandboxConfiguration(
      readOnly: readOnly, worktree: root, temporaryDirectory: root, homeDirectory: root,
      cacheDirectory: root, readableRoots: reads, listableAncestors: [.init("/")])
    return try PreparedExecutionContext(
      authority: self, mode: .sandbox(sandbox),
      environment: .init(
        searchPath: [.init("/usr/bin"), .init("/bin")], home: root, temporary: root, cache: root,
        hostVariables: hostVariables),
      limits: Self.limits, provider: binding, providerProject: project)
  }

  func invalidate() { lock.withLock { valid = false } }
  func reserveChild(_ id: UUID) { lock.withLock { startCount += 1 } }
  func bindChild(_ id: UUID, ownership: any ExecutionOwnership) {}
  func launchFailed(_ id: UUID) {}
  func finishAdmission() {}
  func retainWork(cancellation: @escaping @Sendable () async -> Void) throws -> ExecutionWorkLease {
    _ = try access(executionID, operation: .writeInput)
    lock.withLock { retainedCount += 1 }
    return .init { [self] in lock.withLock { retainedCount -= 1 } }
  }
  func access(_ executionID: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  {
    try lock.withLock {
      guard valid else { throw PermissionModelError.invalidAuthorization }
      return Self.limits
    }
  }
}

#if os(macOS)
  private final class SessionSource: @unchecked Sendable {
    let root: URL
    let hostVariables: [String: String]
    let publicationGate: SessionPublicationGate?
    private let lock = NSLock()
    private var revision = "a"
    private var authorities: [SessionAuthority] = []
    init(root: URL, hostVariables: [String: String], publicationGate: SessionPublicationGate? = nil)
    {
      self.root = root
      self.hostVariables = hostVariables
      self.publicationGate = publicationGate
    }
    var preparations: Int { lock.withLock { authorities.count } }
    var starts: Int { lock.withLock { authorities.reduce(0) { $0 + $1.starts } } }
    func replace() {
      lock.withLock {
        revision = "b"
        for authority in authorities { authority.invalidate() }
      }
    }
    func source() -> MCPProviderExecutionSource {
      publicationGate?.waitAfterMetadata(root: root)
      let digest = lock.withLock { String(repeating: revision, count: 64) }
      return .init(
        digest: digest,
        prepareDiscovery: { [self] _, _ in
          let authority = try SessionAuthority(digest: digest)
          lock.withLock { authorities.append(authority) }
          let prepared = try authority.prepared(root, hostVariables: hostVariables)
          let variables = try prepared.environment.variables()
          for (key, value) in hostVariables {
            #expect(variables[key] == value, "Prepared discovery omitted fixture variable \(key)")
          }
          return prepared
        })
    }
  }

  private final class SessionPublicationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var reached = false
    private var released = false
    var entered: Bool { condition.withLock { reached } }
    func waitAfterMetadata(root: URL) {
      guard
        FileManager.default.fileExists(atPath: root.appendingPathComponent("list-produced").path)
      else { return }
      condition.lock()
      reached = true
      while !released { condition.wait() }
      condition.unlock()
    }
    func release() {
      condition.lock()
      released = true
      condition.broadcast()
      condition.unlock()
    }
  }

  private final class SessionDiscoveryWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    private var stoppedValue = false
    var connections: [UUID] { lock.withLock { ids } }
    var stopped: Bool { lock.withLock { stoppedValue } }
    func selected(_ id: UUID) { lock.withLock { ids.append(id) } }
    func stop() { lock.withLock { stoppedValue = true } }
  }

  private struct SessionFixture: Sendable {
    let root: URL
    let server: MCPServerConfig
    init(
      holdList: Bool = false, holdStartup: Bool = false, failStartupOnce: Bool = false,
      observePublication: Bool = false
    ) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let source = root.appendingPathComponent("peer.c")
      let binary = root.appendingPathComponent("peer")
      try #"""
      #include <ctype.h>
      #include <fcntl.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <sys/socket.h>
      #include <unistd.h>
      int main(void) {
        if (!getenv("COMPUTER_MCP_HOST_FD") || strcmp(getenv("COMPUTER_MCP_HOST_FD"), "3")) return 11;
        struct sockaddr addr; socklen_t len = sizeof(addr);
        if (getpeername(3, &addr, &len) || addr.sa_family != AF_UNIX) return 12;
        if (fcntl(3, F_SETFD, FD_CLOEXEC)) return 13;
        char *line = NULL; size_t capacity = 0;
        while (getline(&line, &capacity, stdin) > 0) {
          char *id = strstr(line, "\"id\""); if (!id) continue;
          id = strchr(id, ':') + 1; while (isspace(*id)) id++;
          char *end = id; if (*end == '"') { end++; while (*end && *end != '"') end++; end++; }
          else { while (*end && *end != ',' && *end != '}') end++; }
          printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":", (int)(end-id), id);
          if (strstr(line, "\"initialize\"")) {
            const char *root = getenv("DISCOVERY_START_BARRIER");
            if (root) {
              char entered[4096], temporary[4096], release[4096];
              snprintf(entered, sizeof(entered), "%s/startup-entered", root);
              snprintf(temporary, sizeof(temporary), "%s/startup-entered.tmp", root);
              snprintf(release, sizeof(release), "%s/startup-release", root);
              FILE *marker = fopen(temporary, "w"); if (!marker) return 15;
              fprintf(marker, "%d", getpid()); fclose(marker);
              if (rename(temporary, entered)) return 17;
              while (access(release, F_OK) != 0) usleep(10000);
            }
            const char *failRoot = getenv("DISCOVERY_FAIL_START");
            char failed[4096] = {0};
            if (failRoot) snprintf(failed, sizeof(failed), "%s/startup-failed", failRoot);
            if (failRoot && access(failed, F_OK) != 0) {
              FILE *marker = fopen(failed, "w"); if (!marker) return 16;
              fclose(marker);
              printf("{}");
            } else {
              printf("{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"peer\",\"version\":\"1\"}}");
            }
          }
          else if (strstr(line, "tools/list") || strstr(line, "tools\\/list")) {
            const char *root = getenv("DISCOVERY_BARRIER");
            if (root) {
              char entered[4096], release[4096];
              snprintf(entered, sizeof(entered), "%s/list-entered", root);
              snprintf(release, sizeof(release), "%s/list-release", root);
              FILE *marker = fopen(entered, "w"); if (!marker) return 14;
              fclose(marker);
              while (access(release, F_OK) != 0) usleep(10000);
            }
            const char *publicationRoot = getenv("DISCOVERY_PUBLICATION");
            if (publicationRoot) {
              char produced[4096];
              snprintf(produced, sizeof(produced), "%s/list-produced", publicationRoot);
              FILE *marker = fopen(produced, "w"); if (!marker) return 18;
              fclose(marker);
            }
            printf("{\"tools\":[{\"name\":\"pid\",\"inputSchema\":{\"type\":\"object\"}}]}");
          }
          else printf("{\"content\":[{\"type\":\"text\",\"text\":\"%d\"}]}", getpid());
          puts("}"); fflush(stdout);
        }
        free(line); return 0;
      }
      """#.write(to: source, atomically: true, encoding: .utf8)
      let compiler = Process()
      compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
      compiler.arguments = ["-Wall", "-Werror", source.path, "-o", binary.path]
      compiler.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.path]
      try compiler.run()
      compiler.waitUntilExit()
      try #require(compiler.terminationStatus == 0)
      var variables: [String: String] = [:]
      if observePublication { variables["DISCOVERY_PUBLICATION"] = root.path }
      if holdList { variables["DISCOVERY_BARRIER"] = root.path }
      if holdStartup { variables["DISCOVERY_START_BARRIER"] = root.path }
      if failStartupOnce { variables["DISCOVERY_FAIL_START"] = root.path }
      server = .init(
        id: "provider", transport: .stdio, command: binary.path, env: variables,
        startupTimeoutMs: holdStartup ? 3000 : 5000, requestTimeoutMs: 5000, hostServices: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func client(
      source: SessionSource? = nil, ownedWork: GatewayOwnedWork? = nil,
      onSelection: (@Sendable (String, UUID, UUID) throws -> Void)? = nil
    ) -> MCPProxyClient {
      var host = MCPHostContext(
        runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
        projectID: "project", rootURL: root, readOnly: true, tools: MCPHostToolDirectory(),
        processOwnershipRoot: root.appendingPathComponent("ownership"))
      if let source { host.providerSource = { _ in source.source() } }
      host.ownedWork = ownedWork
      return MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: root, hostContext: host,
        onDiscoverySelection: onSelection)
    }
    func call(_ client: MCPProxyClient, authority: SessionAuthority) async throws -> Int32 {
      try await call(client, execution: authority.prepared(root))
    }
    func call(
      _ client: MCPProxyClient, execution: PreparedExecutionContext,
      selection: MCPContinuationTarget? = nil
    ) async throws -> Int32 {
      let result = try await client.callToolAsync(
        server: server, name: "pid", arguments: .object([:]), requestID: nil,
        context: .init(continuation: selection, executionAuthority: execution))
      return try #require(
        result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?
          .stringValue.flatMap(Int32.init))
    }
  }

#endif
