import ComputerMCPConfiguration
import ComputerMCPMacOS
import ComputerMCPPersistence
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct MCPHostInvocationTests {
  @Test(.timeLimit(.minutes(10)))
  func backgroundWorkKeepsExactContextThroughDerivedWorkAndReleasesItAtCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "derive", "finish", "replay"], work: true,
      backgroundProvider: true)
    let runtime = fixture.runtime
    let database = fixture.database
    let context = InvocationContext(session: fixture.session)
    let providerHost = try #require(fixture.providerHost)
    let metrics = MCPInvocationCapacityMetrics()
    try database.configuredPermissionStore().readWithDatabase { database, _ in
      database.trace(options: [.statement, .profile]) { metrics.observe($0) }
    }
    metrics.phase("background calls")
    defer { print(metrics.report()) }
    let loopStarted = ContinuousClock.now
    var completedBackgroundCalls = 0
    var lastCompletionElapsed = Duration.zero
    var loopTimings: [String] = []
    var lastProviderPID: Int64?
    var providerTransitions: [String] = []
    var phase = "background calls"
    defer {
      #expect(
        completedBackgroundCalls == 257,
        "Completed \(completedBackgroundCalls)/257 background calls; last completion at \(lastCompletionElapsed); timings: \(loopTimings.joined(separator: ", ")); stopped during \(phase)."
      )
    }
    do {
      // Retained contexts must not exhaust the independent 256 active-call slots.
      for _ in 0..<257 {
        let response = try await runtime.callToolAsync(
          name: "mcp.tools.call",
          arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
          context: context)
        completedBackgroundCalls += 1
        lastCompletionElapsed = loopStarted.duration(to: .now)
        let providerPID = try #require(
          Self.payload(response).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value)
        providerHost.assertProviderPID(providerPID)
        if providerPID != lastProviderPID {
          providerTransitions.append(
            "call \(completedBackgroundCalls) at \(lastCompletionElapsed): pid \(providerPID)")
          lastProviderPID = providerPID
        }
        if [1, 32, 64, 128, 256, 257].contains(completedBackgroundCalls) {
          loopTimings.append("\(completedBackgroundCalls): \(lastCompletionElapsed)")
        }
      }
      phase = "observing 257 retained resources"
      metrics.phase(phase)
      try await Self.waitForResourceCount(257, runtime: runtime)
      try providerHost.assertIndependentCalls(257)
      phase = "first retained callback"
      metrics.phase(phase)
      let replay = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      let original = try #require(
        Self.payload(replay).objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
      #expect(original["tool"] == .string("background"))
      #expect(original["registration_id"] == .string("provider"))
      #expect(original["host_action"] == .string("diagnostics.snapshot"))
      phase = "derive response"
      metrics.phase(phase)
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "derive"), context: context)
      phase = "derive observation settlement"
      metrics.phase(phase)
      try await Self.waitForResourceCount(1, runtime: runtime, timeout: .seconds(90))
      phase = "verifying derived lineage"
      metrics.phase(phase)
      let derived = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      #expect(
        Self.payload(derived).objectValue?["structuredContent"]?.objectValue?["result"]
          == .object(original))
      let retainedID = try #require(
        original["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
      #expect(
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", id: retainedID
        ).reference.toolName == "background")
      let record = try #require(try database.hostCallRecordStore().record(id: retainedID))
      #expect(record.lifecycle == .retained)
      #expect(record.requestLeaseIDs.isEmpty && !record.workLeaseIDs.isEmpty)
      // Retained work does not extend the active request's mutation window.
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", action: .diagnosticsSnapshot)
      }
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(projectID: "fixture", origin: "other", id: retainedID)
      }
      phase = "finishing retained work"
      metrics.phase(phase)
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "finish"), context: context)
      try await Self.waitForResourceCount(0, runtime: runtime)
      phase = "checking completed invocation replay"
      metrics.phase(phase)
      let expired = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      #expect(Self.payload(expired).objectValue?["isError"] == .bool(true))
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", id: retainedID)
      }
      // The final replay also creates an observation barrier, even when it fails.
      try await Self.waitForResourceCount(0, runtime: runtime)
      let completed = try #require(try database.hostCallRecordStore().record(id: retainedID))
      #expect(completed.lifecycle == .completed)
      #expect(completed.requestLeaseIDs.isEmpty && completed.workLeaseIDs.isEmpty)
    } catch {
      let failedElapsed = loopStarted.duration(to: .now)
      metrics.phase("diagnostic capture")
      let snapshot: String
      do {
        snapshot = try Self.capacityFailureSnapshot(
          database: database, runtime: runtime, connectionID: fixture.session.id)
      } catch let snapshotError {
        snapshot = "Snapshot unavailable: \(snapshotError)"
      }
      Issue.record(
        "Host invocation failed during \(phase) after \(failedElapsed); completed \(completedBackgroundCalls)/257 background calls, last completion at \(lastCompletionElapsed); timings: \(loopTimings.joined(separator: ", ")); provider transitions: \(providerTransitions.joined(separator: ", ")); \(snapshot)"
      )
      print(metrics.report())
      metrics.phase("runtime shutdown including directory detach and lifetime shutdown")
      await runtime.shutdown()
      metrics.phase("provider owner cleanup")
      do { try await providerHost.finishAfterRuntimeShutdown() } catch let cleanupError {
        Issue.record("Background provider cleanup failed: \(cleanupError)")
      }
      throw error
    }
    print(metrics.report())
    metrics.phase("runtime shutdown including directory detach and lifetime shutdown")
    await runtime.shutdown()
    metrics.phase("provider owner cleanup")
    try await providerHost.finishAfterRuntimeShutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  @Test(.timeLimit(.minutes(2)), arguments: [false, true])
  func discoveryExpiryPreservesFixedProviderAndRetainedEffects(inFlight: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    // Only this fixture's tools/list handler observes the latch. Production admission,
    // transport and deadline checks remain on their ordinary native path.
    let latch = MCPInvocationDiscoveryLatch()
    let source = Self.provider.replacingOccurrences(
      of: "elif method == \"tools/list\":", with: "elif method == \"tools/list\":\n" + latch.python
    ).replacingOccurrences(
      of: "if params[\"name\"] == \"background\":",
      with: "if params[\"name\"] == \"background\":\n" + latch.backgroundPython)
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "finish", "replay"], work: true,
      source: source, backgroundProvider: true)
    let runtime = fixture.runtime
    let providerHost = try #require(fixture.providerHost)
    let context = InvocationContext(session: fixture.session)
    let home = URL(
      fileURLWithPath: try fixture.database.prepareProviderContainer(.localServer("provider")).root
        .string
    )
    .appendingPathComponent("home")
    var pending: Task<JSONValue, any Error>?
    var phase = "first retained effect"
    do {
      let first = try await runtime.callToolAsync(
        name: "mcp.tools.call",
        arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
        context: context)
      providerHost.assertProviderPID(
        try #require(
          Self.payload(first).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value))
      try await Self.waitForResourceCount(1, runtime: runtime)
      #expect(try latch.effects(home: home).count == 1)
      phase = inFlight ? "in-flight discovery tools/list" : "between-call discovery expiry"
      var discoveryPID: Int32?
      if inFlight {
        try latch.arm(home: home)
        pending = Task {
          try await runtime.callToolAsync(
            name: "mcp.tools.call",
            arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
            context: context)
        }
        discoveryPID = try await latch.waitUntilEntered(home: home)
        #expect(discoveryPID != providerHost.process.pid)
      }
      let expired = try providerHost.expireDiscoveryPreservingActualAuthority(
        inFlightPID: discoveryPID)
      if inFlight {
        try latch.release(home: home)
      } else {
        pending = Task {
          try await runtime.callToolAsync(
            name: "mcp.tools.call",
            arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
            context: context)
        }
      }
      phase += " after expiring \(expired)"
      let request = try #require(pending)
      let second = try await request.value
      providerHost.assertProviderPID(
        try #require(
          Self.payload(second).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value))
      try await Self.waitForResourceCount(2, runtime: runtime)
      try providerHost.assertIndependentCalls(2)
      let effects = try latch.effects(home: home)
      #expect(effects.count == 2)
      let workInvocationIDs: [String] = effects.compactMap {
        $0.objectValue?["work_invocation"]?.stringValue
      }
      let distinctWorkInvocationIDs = Set(workInvocationIDs)
      #expect(distinctWorkInvocationIDs.count == 2)
      #expect(
        effects.allSatisfy { $0.objectValue?["pid"]?.int64Value == Int64(providerHost.process.pid) }
      )
      phase = "finishing two distinct retained effects"
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "finish"), context: context)
      try await Self.waitForResourceCount(0, runtime: runtime)
    } catch {
      try? latch.release(home: home)
      pending?.cancel()
      if let pending { _ = await pending.result }
      providerHost.assertProviderPID(Int64(providerHost.process.pid))
      // A failed discovery must not dispatch the second mutation or retire the first.
      try await Self.waitForResourceCount(1, runtime: runtime)
      let effects = (try? latch.effects(home: home)) ?? []
      #expect(effects.count == 1)
      #expect(
        effects.allSatisfy { $0.objectValue?["pid"]?.int64Value == Int64(providerHost.process.pid) }
      )
      let snapshot =
        (try? Self.capacityFailureSnapshot(
          database: fixture.database, runtime: runtime, connectionID: fixture.session.id))
        ?? "Snapshot unavailable"
      Issue.record(
        "Discovery expiry failed during \(phase): \(error); effects=\(effects); \(snapshot)")
      await runtime.shutdown()
      try await providerHost.finishAfterRuntimeShutdown()
      #expect(runtime.ownedWork.snapshot.isEmpty)
      throw error
    }
    await runtime.shutdown()
    try await providerHost.finishAfterRuntimeShutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  @Test(.timeLimit(.minutes(2)), arguments: [1, 2, 3])
  func discoveryExpiryAfterSelectionRecoversAtMostOnce(scenario: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let latch = MCPInvocationDiscoveryLatch()
    let gate = MCPInvocationDiscoverySelectionGate()
    let source = Self.provider.replacingOccurrences(
      of: "elif method == \"tools/list\":",
      with: "elif method == \"tools/list\":\n" + latch.listCountingPython
    ).replacingOccurrences(
      of: "if params[\"name\"] == \"background\":",
      with: "if params[\"name\"] == \"background\":\n" + latch.backgroundPython
        + "                if first_background is None:\n                    first_background = invocation\n"
    ).replacingOccurrences(
      of: "previous = None", with: "previous = None\nfirst_background = None"
    ).replacingOccurrences(
      of: "result = describe(previous)", with: "result = describe(first_background)")
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "finish", "replay"], work: true,
      source: source, backgroundProvider: true, discoveryGate: gate)
    let runtime = fixture.runtime
    let providerHost = try #require(fixture.providerHost)
    let context = InvocationContext(session: fixture.session)
    let home = URL(
      fileURLWithPath: try fixture.database.prepareProviderContainer(.localServer("provider")).root
        .string
    ).appendingPathComponent("home")
    do {
      let first = try await runtime.callToolAsync(
        name: "mcp.tools.call",
        arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
        context: context)
      providerHost.assertProviderPID(
        try #require(
          Self.payload(first).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value))
      try await Self.waitForResourceCount(1, runtime: runtime)
      let firstEffects = try latch.effects(home: home)
      #expect(firstEffects.count == 1)
      let firstID = try #require(firstEffects.first?.objectValue?["invocation"]?.stringValue)
      let listInputsBefore = try latch.listInputs(home: home)
      let priorDiscoveries = try providerHost.discoveryExecutions()
      gate.arm(providerHost, expiries: scenario == 2 ? 2 : 1, revokeReplacement: scenario == 3)
      let outcome: Result<JSONValue, any Error>
      do {
        outcome = .success(
          try await runtime.callToolAsync(
            name: "mcp.tools.call",
            arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
            context: context))
      } catch { outcome = .failure(error) }
      let selections = gate.finish()
      #expect(selections.count == (scenario == 3 ? 1 : 2))
      #expect(gate.replacementCount == 1)
      let firstSelection = try #require(selections.first)
      let secondSelection = scenario == 3 ? nil : selections.last
      if let secondSelection {
        #expect(firstSelection.executionID != secondSelection.executionID)
        #expect(firstSelection.connectionID != secondSelection.connectionID)
      }
      let evidence = try #require(firstSelection.evidence)
      #expect(evidence.before.isRunning && !evidence.after.isRunning)
      #expect(evidence.after.limitEndReason == .timeLimit && !evidence.proofAfter.revoked)
      let newDiscoveries = try providerHost.discoveryExecutions().subtracting(priorDiscoveries)
      #expect(newDiscoveries == Set(secondSelection.map { [$0.executionID] } ?? []))
      let effects = try latch.effects(home: home)
      let lists = try latch.listInputs(home: home)
      if scenario == 1 {
        let second = try outcome.get()
        providerHost.assertProviderPID(
          try #require(
            Self.payload(second).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value)
        )
        #expect(secondSelection?.evidence == nil)
        #expect(effects.count == 2 && effects.first == firstEffects.first)
        #expect(
          Set(effects.compactMap { $0.objectValue?["work_invocation"]?.stringValue }).count == 2)
        #expect(lists.count == listInputsBefore.count + 1)
        try await Self.waitForResourceCount(2, runtime: runtime)
        try providerHost.assertIndependentCalls(2)
      } else {
        guard case .failure(let error) = outcome else {
          Issue.record("Two expired discoveries unexpectedly forwarded the actual tool")
          throw PermissionModelError.invalidAuthorization
        }
        #expect(error as? PermissionModelError == .invalidAuthorization)
        if scenario == 2 {
          #expect(secondSelection?.evidence?.after.limitEndReason == .timeLimit)
        }
        #expect(effects == firstEffects && lists == listInputsBefore)
        try await Self.waitForResourceCount(1, runtime: runtime)
      }
      providerHost.assertProviderPID(Int64(providerHost.process.pid))
      let retained = try runtime.requireHostInvocation(
        projectID: "fixture", origin: "provider", id: #require(UUID(uuidString: firstID)))
      #expect(retained.reference.toolName == "background")
      let replay = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      let original = try #require(
        Self.payload(replay).objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
      #expect(original["invocation_id"] == .string(firstID))
      #expect(original["tool"] == .string("background"))
      #expect(try latch.effects(home: home) == effects)
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "finish"), context: context)
      try await Self.waitForResourceCount(0, runtime: runtime)
    } catch {
      _ = gate.finish()
      await runtime.shutdown()
      try await providerHost.finishAfterRuntimeShutdown()
      #expect(runtime.ownedWork.snapshot.isEmpty)
      throw error
    }
    await runtime.shutdown()
    try await providerHost.finishAfterRuntimeShutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  @Test(.timeLimit(.minutes(2)), arguments: [false, true])
  func discoveryReplacementHasIndependentMetadataBudgets(replacementTimesOut: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let gates = MCPInvocationBudgetLatch()
    let latch = MCPInvocationDiscoveryLatch()
    let selection = MCPInvocationDiscoverySelectionGate()
    let policy = MCPInvocationPolicyBarrier()
    let source = Self.provider.replacingOccurrences(
      of: "if method == \"initialize\":",
      with: "if method == \"initialize\":\n" + gates.initializePython
    ).replacingOccurrences(
      of: "elif method == \"tools/list\":",
      with: "elif method == \"tools/list\":\n" + latch.listCountingPython + gates.listPython
    ).replacingOccurrences(
      of: "if params[\"name\"] == \"background\":",
      with: "if params[\"name\"] == \"background\":\n" + latch.backgroundPython)
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "finish", "replay"], work: true,
      source: source, backgroundProvider: true, discoveryGate: selection,
      policyReader: policy, startupTimeoutMs: 5_000)
    let runtime = fixture.runtime
    let host = try #require(fixture.providerHost)
    let home = URL(
      fileURLWithPath: try fixture.database.prepareProviderContainer(.localServer("provider")).root
        .string
    ).appendingPathComponent("home")
    var pending: Task<JSONValue, any Error>?
    var reconciliation: Task<Void, any Error>?
    defer {
      policy.release()
      for stage in ["old", "startup", "new"] { try? gates.release(stage, home: home) }
    }
    do {
      let first = try await runtime.callToolAsync(
        name: "mcp.tools.call",
        arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
        context: .init(session: fixture.session))
      host.assertProviderPID(
        try #require(
          Self.payload(first).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value))
      try await Self.waitForResourceCount(1, runtime: runtime)
      let effectsBefore = try latch.effects(home: home)
      #expect(effectsBefore.count == 1)
      let listsBefore = try latch.listInputs(home: home)
      for stage in ["old", "startup", "new"] { try gates.arm(stage, home: home) }
      policy.arm()
      reconciliation = Task { try await runtime.permissionRuntime.coordinator.reconcile() }
      let deadline = ContinuousClock.now + .seconds(5)
      while !policy.entered {
        guard ContinuousClock.now < deadline else {
          throw GatewayToolError.executionFailed("Budget reconciliation barrier was not reached")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      selection.arm(host, expiries: 0)
      pending = Task {
        try await runtime.callToolAsync(
          name: "mcp.tools.call",
          arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
          context: .init(session: fixture.session))
      }
      let oldPID = try await gates.waitFor("old", home: home)
      let oldEntered = ContinuousClock.now
      let old = try #require(selection.selections.first)
      let callers = try fixture.database.configuredPermissionStore().readWithDatabase { _, ledger in
        Dictionary(
          uniqueKeysWithValues: ledger.executions.values.filter {
            $0.isRunning && $0.limits.timeMilliseconds == 600_000
          }.map { ($0.id, $0) })
      }
      try await Task.sleep(for: .milliseconds(2_700))
      let expired = try host.expireSelectedDiscovery(old.executionID)
      #expect(expired.after.limitEndReason == .timeLimit && expired.before.isRunning)
      try gates.release("old", home: home)
      let firstRequestDelay = oldEntered.duration(to: .now)
      let newPID = try await gates.waitFor("startup", home: home)
      let startupEntered = ContinuousClock.now
      #expect(newPID != oldPID && newPID != host.process.pid)
      #expect(selection.replacementCount == 1 && selection.selections.count == 2)
      let selected = selection.selections
      #expect(selected[0].executionID == old.executionID)
      #expect(selected[1].executionID != old.executionID)
      let callerID = try #require(selection.replacementCallerID)
      let callerBefore = try #require(callers[callerID])
      policy.release()
      try await #require(reconciliation).value
      try await Task.sleep(for: .milliseconds(2_700))
      try gates.release("startup", home: home)
      let startupDelay = startupEntered.duration(to: .now)
      #expect(startupDelay < .seconds(5))
      #expect(firstRequestDelay + startupDelay > .seconds(5))
      #expect(try await gates.waitFor("new", home: home) == newPID)
      let newEntered = ContinuousClock.now
      let callerDuring = try fixture.database.configuredPermissionStore().readWithDatabase {
        _, ledger in try #require(ledger.executions[callerID])
      }
      #expect(callerDuring.isRunning && callerDuring.limitEndReason == nil)
      #expect(callerDuring.startedAt == callerBefore.startedAt)
      #expect(callerDuring.id == callerBefore.id)
      #expect(callerDuring.owner == callerBefore.owner)
      #expect(callerDuring.delegatedTo == callerBefore.delegatedTo)
      #expect(callerDuring.authorizationIDs == callerBefore.authorizationIDs)
      #expect(callerDuring.limits.timeMilliseconds == callerBefore.limits.timeMilliseconds)
      #expect(callerDuring.limitRequest.timeMilliseconds == 600_000)
      #expect(Date() < callerDuring.startedAt.addingTimeInterval(600))
      #expect(try latch.effects(home: home) == effectsBefore)
      try await Task.sleep(for: .milliseconds(replacementTimesOut ? 5_500 : 2_700))
      try gates.release("new", home: home)
      let secondRequestDelay = newEntered.duration(to: .now)
      #expect(firstRequestDelay < .seconds(5))
      #expect(firstRequestDelay + secondRequestDelay > .seconds(5))
      let outcome = try await #require(pending).result
      let callerAfter = try fixture.database.configuredPermissionStore().readWithDatabase {
        _, ledger in try #require(ledger.executions[callerID])
      }
      #expect(callerAfter.startedAt == callerBefore.startedAt)
      #expect(callerAfter.owner == callerBefore.owner)
      #expect(callerAfter.authorizationIDs == callerBefore.authorizationIDs)
      #expect(callerAfter.limits.timeMilliseconds == callerBefore.limits.timeMilliseconds)
      let seen = selection.finish()
      #expect(seen.count == 2 && selection.replacementCount == 1)
      let lists = try latch.listInputs(home: home)
      #expect(lists.count == listsBefore.count + 2)
      #expect(Array(lists.suffix(2)) == [oldPID, newPID])
      if replacementTimesOut {
        guard case .failure(let error) = outcome else {
          Issue.record("Replacement metadata exceeded its request budget and returned")
          throw PermissionModelError.invalidAuthorization
        }
        #expect(
          error as? GatewayToolError == .executionFailed("MCP server 'provider' request timed out.")
        )
        #expect(try latch.effects(home: home) == effectsBefore)
        try await Self.waitForResourceCount(1, runtime: runtime)
      } else {
        #expect(secondRequestDelay < .seconds(5))
        let result = try outcome.get()
        host.assertProviderPID(
          try #require(
            Self.payload(result).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value)
        )
        let effects = try latch.effects(home: home)
        #expect(effects.count == 2 && effects.first == effectsBefore.first)
        try await Self.waitForResourceCount(2, runtime: runtime)
      }
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "finish"),
        context: .init(session: fixture.session))
      try await Self.waitForResourceCount(0, runtime: runtime)
    } catch {
      policy.release()
      for stage in ["old", "startup", "new"] { try? gates.release(stage, home: home) }
      pending?.cancel()
      if let reconciliation { _ = await reconciliation.result }
      if let pending { _ = await pending.result }
      _ = selection.finish()
      await runtime.shutdown()
      try await host.finishAfterRuntimeShutdown()
      #expect(runtime.ownedWork.snapshot.isEmpty)
      throw error
    }
    await runtime.shutdown()
    try await host.finishAfterRuntimeShutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  @Test(.timeLimit(.minutes(2)))
  func discoveryReplacementRefusesUnconfirmedPredecessorCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let cleanup = MCPInvocationCleanupGate()
    let policy = MCPInvocationPolicyBarrier()
    let bootstrap = try nativeGatewayTestExecutable().deletingLastPathComponent()
      .appendingPathComponent("computer-mcp-execution-bootstrap")
    let launcher = ExecutionLauncher(
      platform: MCPInvocationCleanupPlatform(
        base: DarwinExecutionPlatform(bootstrapExecutable: bootstrap), gate: cleanup))
    let latch = MCPInvocationDiscoveryLatch()
    let selections = MCPInvocationDiscoverySelectionGate()
    let source =
      Self.provider.replacingOccurrences(
        of: "elif method == \"tools/list\":",
        with: "elif method == \"tools/list\":\n" + latch.listCountingPython
      ).replacingOccurrences(
        of: "if params[\"name\"] == \"background\":",
        with: "if params[\"name\"] == \"background\":\n" + latch.backgroundPython
      ) + "\nimport time\n"
      + "hold = os.path.join(os.environ[\"HOME\"], \"cleanup-hold-\" + str(os.getpid()))\n"
      + "while os.path.exists(hold):\n    time.sleep(0.01)\n"
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "finish", "replay"], work: true,
      source: source, backgroundProvider: true, discoveryGate: selections,
      launcher: launcher, policyReader: policy)
    let runtime = fixture.runtime
    let providerHost = try #require(fixture.providerHost)
    let home = URL(
      fileURLWithPath: try fixture.database.prepareProviderContainer(.localServer("provider")).root
        .string
    ).appendingPathComponent("home")
    var hold: URL?
    var pending: Task<JSONValue, any Error>?
    var reconciliation: Task<Void, any Error>?
    var notifications: Task<Int, Never>?
    defer {
      cleanup.release()
      policy.release()
      if let hold { try? FileManager.default.removeItem(at: hold) }
    }
    do {
      let first = try await runtime.callToolAsync(
        name: "mcp.tools.call",
        arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
        context: .init(session: fixture.session))
      providerHost.assertProviderPID(
        try #require(
          Self.payload(first).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value))
      try await Self.waitForResourceCount(1, runtime: runtime)
      let firstEffects = try latch.effects(home: home)
      #expect(firstEffects.count == 1)
      let firstID = try #require(firstEffects.first?.objectValue?["invocation"]?.stringValue)
      selections.arm(providerHost, expiries: 0)
      _ = try await BlockingOperationExecutor(label: "predecessor-prime").perform {
        try providerHost.listIndependentDiscovery()
      }
      let oldSelection = try #require(selections.finish().first)
      let priorLists = try latch.listInputs(home: home)
      let catalog = try #require(try providerHost.cachedDiscovery()).map(\.name)
      let ownership = try fixture.database.configuredPermissionStore().readWithDatabase {
        database, ledger in
        let execution = try #require(ledger.executions[oldSelection.executionID])
        #expect(execution.isRunning && execution.owner == .plugin(.localServer("provider")))
        let record = try #require(
          try ExecutionRuntimeRecord.load(oldSelection.executionID, database))
        #expect(record.children.count == 1)
        let child = try #require(record.children.first)
        #expect(!child.value.completed && !child.value.released)
        return (
          child.key, try #require(child.value.recovery), try #require(record.scratchDirectory)
        )
      }
      let pid = ownership.1.root.processID
      #expect(priorLists.last == pid)
      #expect(pid != providerHost.process.pid)
      hold = home.appendingPathComponent("cleanup-hold-\(pid)")
      try Data().write(to: #require(hold))
      cleanup.hold(oldSelection.executionID)
      let counter = MCPInvocationNotificationCounter()
      let changes = providerHost.discoveryChanges()
      notifications = Task {
        for await _ in changes { counter.record() }
        return counter.count
      }
      policy.arm()
      reconciliation = Task { try await runtime.permissionRuntime.coordinator.reconcile() }
      let barrierDeadline = ContinuousClock.now + .seconds(5)
      while !policy.entered {
        guard ContinuousClock.now < barrierDeadline else {
          throw GatewayToolError.executionFailed("Predecessor policy barrier was not reached")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      selections.arm(providerHost, expiries: 1)
      let completed = MCPInvocationNotificationCounter()
      pending = Task {
        defer { completed.record() }
        return try await runtime.callToolAsync(
          name: "mcp.tools.call",
          arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
          context: .init(session: fixture.session))
      }
      let deadline = ContinuousClock.now + .seconds(10)
      while selections.selections.count < 2 || cleanup.failureCount == 0 {
        guard ContinuousClock.now < deadline else {
          throw GatewayToolError.executionFailed("Replacement did not reach unconfirmed cleanup")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      let observed = selections.selections
      #expect(observed.count == 2 && selections.replacementCount == 1)
      #expect(observed[0].executionID == oldSelection.executionID)
      #expect(observed[0].evidence?.after.limitEndReason == .timeLimit)
      #expect(observed[1].executionID != oldSelection.executionID)
      switch try await #require(pending).result {
      case .success:
        Issue.record("Replacement returned while its predecessor cleanup was unconfirmed")
      case .failure(let error):
        #expect(
          error as? GatewayToolError
            == .executionFailed(
              "Previous MCP process has not confirmed exit; reconnect is blocked."))
      }
      #expect(!cleanup.startedExecutions.contains(observed[1].executionID))
      #expect(try latch.listInputs(home: home) == priorLists)
      #expect(try latch.effects(home: home) == firstEffects)
      #expect(try providerHost.cachedDiscovery()?.map(\.name) == catalog)
      #expect(counter.count == 0)
      #expect(completed.count == 1)
      #expect(
        DarwinProcessIdentity.current(pid: pid)?.identity.uniqueID == ownership.1.root.identity)
      providerHost.assertProviderPID(Int64(providerHost.process.pid))
      try fixture.database.configuredPermissionStore().readWithDatabase { database, ledger in
        let execution = try #require(ledger.executions[oldSelection.executionID])
        #expect(!execution.isRunning && execution.limitEndReason == .timeLimit)
        let record = try #require(
          try ExecutionRuntimeRecord.load(oldSelection.executionID, database))
        let child = try #require(record.children[ownership.0])
        #expect(!record.completed && !child.completed && !child.released)
        #expect(child.recovery?.root == ownership.1.root)
        #expect(child.recovery?.sandboxed == ownership.1.sandboxed)
        #expect(child.recovery?.backend == ownership.1.backend)
        #expect(child.recovery?.payload == ownership.1.payload)
        #expect(record.scratchDirectory == ownership.2)
        #expect(FileManager.default.fileExists(atPath: ownership.2))
        let fresh = try #require(ledger.executions[observed[1].executionID])
        #expect(fresh.isRunning && fresh.limits.timeMilliseconds == 120_000)
        #expect(fresh.owner == .plugin(.localServer("provider")) && fresh.delegatedTo == nil)
        #expect(fresh.authorizationIDs.isDisjoint(with: execution.authorizationIDs))
        #expect(fresh.authorizationIDs.count == 1)
        let proofID = try #require(fresh.authorizationIDs.first)
        let proof = try #require(ledger.authorizations[proofID])
        #expect(proof.invocation.tool == "provider.discovery" && proof.invocation.projectID == nil)
        let replacementRecord = try #require(
          try ExecutionRuntimeRecord.load(observed[1].executionID, database))
        #expect(replacementRecord.children.isEmpty)
      }
      cleanup.release()
      try FileManager.default.removeItem(at: #require(hold))
      hold = nil
      policy.release()
      try await #require(reconciliation).value
      _ = selections.finish()
      #expect(try latch.effects(home: home) == firstEffects)
      #expect(try latch.listInputs(home: home) == priorLists)
      #expect(!cleanup.startedExecutions.contains(observed[1].executionID))
      try await Self.waitForResourceCount(1, runtime: runtime)
      try providerHost.assertIndependentCalls(2)
      try fixture.database.configuredPermissionStore().readWithDatabase { database, _ in
        let records = try Data.fetchAll(database, sql: "SELECT payload FROM hostCallRecords").map {
          try JSONDecoder().decode(HostCallRecord.self, from: $0)
        }.filter {
          $0.admission.reference.serverID == "provider"
            && $0.admission.reference.toolName == "background"
        }
        #expect(records.count == 2)
        let firstInvocationID = try #require(UUID(uuidString: firstID))
        let first = try #require(records.first { $0.admission.id == firstInvocationID })
        let refused = try #require(records.first { $0.admission.id != first.admission.id })
        #expect(first.lifecycle == .retained && !first.workLeaseIDs.isEmpty)
        #expect(refused.lifecycle == .completed)
        #expect(refused.requestLeaseIDs.isEmpty && refused.workLeaseIDs.isEmpty)
        #expect(first.admission.authorizationID != refused.admission.authorizationID)
      }
      let retained = try runtime.requireHostInvocation(
        projectID: "fixture", origin: "provider", id: #require(UUID(uuidString: firstID)))
      #expect(retained.reference.toolName == "background")
      try await runtime.permissionRuntime.coordinator.reconcile()
      #expect(
        DarwinProcessIdentity.current(pid: pid, includingZombies: true)?.identity.uniqueID
          != ownership.1.root.identity)
      try fixture.database.configuredPermissionStore().readWithDatabase { database, _ in
        let record = try #require(
          try ExecutionRuntimeRecord.load(oldSelection.executionID, database))
        let child = try #require(record.children[ownership.0])
        #expect(record.completed && child.completed && child.released)
        #expect(record.scratchDirectory == nil)
      }
      _ = try await BlockingOperationExecutor(label: "finish-retained-provider-work").perform {
        try providerHost.finishRetainedWork()
      }
      try await Self.waitForResourceCount(0, runtime: runtime)
      let firstInvocationID = try #require(UUID(uuidString: firstID))
      let finished = try #require(
        try fixture.database.hostCallRecordStore().record(id: firstInvocationID))
      #expect(finished.lifecycle == .completed)
      #expect(finished.requestLeaseIDs.isEmpty && finished.workLeaseIDs.isEmpty)
      #expect(try latch.effects(home: home) == firstEffects)
      providerHost.assertProviderPID(Int64(providerHost.process.pid))
    } catch {
      cleanup.release()
      policy.release()
      if let hold { try? FileManager.default.removeItem(at: hold) }
      pending?.cancel()
      if let reconciliation { _ = await reconciliation.result }
      if let pending { _ = await pending.result }
      _ = selections.finish()
      await runtime.shutdown()
      if let notifications { _ = await notifications.value }
      try await providerHost.finishAfterRuntimeShutdown()
      #expect(runtime.ownedWork.snapshot.isEmpty)
      throw error
    }
    await runtime.shutdown()
    if let notifications { #expect(await notifications.value == 0) }
    try await providerHost.finishAfterRuntimeShutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  @Test(.timeLimit(.minutes(2)))
  func staleDiscoveryFailureDoesNotRetireNewerSelectedConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let latch = MCPInvocationDiscoveryLatch()
    let gate = MCPInvocationDiscoverySelectionGate()
    let source = Self.provider.replacingOccurrences(
      of: "if params[\"name\"] == \"background\":",
      with: "if params[\"name\"] == \"background\":\n" + latch.backgroundPython)
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "finish", "replay"], work: true,
      source: source, backgroundProvider: true, discoveryGate: gate)
    let runtime = fixture.runtime
    let providerHost = try #require(fixture.providerHost)
    let home = URL(
      fileURLWithPath: try fixture.database.prepareProviderContainer(.localServer("provider")).root
        .string
    ).appendingPathComponent("home")
    var pending: Task<JSONValue, any Error>?
    do {
      gate.arm(providerHost, expiries: 1, pauseFirstExpiry: true)
      pending = Task {
        try await runtime.callToolAsync(
          name: "mcp.tools.call",
          arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
          context: .init(session: fixture.session))
      }
      let deadline = ContinuousClock.now + .seconds(5)
      while !gate.isPaused {
        guard ContinuousClock.now < deadline else {
          throw GatewayToolError.executionFailed("Expired selection did not reach its barrier")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      let tools = try await BlockingOperationExecutor(label: "newer-discovery-selection").perform {
        try providerHost.listIndependentDiscovery()
      }
      #expect(tools.contains { $0.name == "background" })
      let newerExecutions = try providerHost.discoveryExecutions()
      let stale = try #require(gate.selections.first)
      let newerBefore = try #require(gate.selections.last)
      let newerAuthorizationIDs = try fixture.database.configuredPermissionStore()
        .readWithDatabase { _, ledger in
          try #require(ledger.executions[newerBefore.executionID]).authorizationIDs
        }
      let staleProof = try #require(stale.evidence?.proof)
      let staleScratch = fixture.database.permissionExecutionRoot.appendingPathComponent(
        staleProof.id.uuidString)
      try await runtime.permissionRuntime.coordinator.reconcile()
      let cleanupDeadline = ContinuousClock.now + .seconds(10)
      while true {
        let settled = try fixture.database.configuredPermissionStore().readWithDatabase {
          database, _ in
          guard let record = try ExecutionRuntimeRecord.load(stale.executionID, database) else {
            return false
          }
          return record.completed && record.admissionFinished && record.scratchDirectory == nil
            && !record.children.isEmpty
            && record.children.values.allSatisfy { $0.completed && $0.released }
        }
        if settled && !FileManager.default.fileExists(atPath: staleScratch.path) { break }
        guard ContinuousClock.now < cleanupDeadline else {
          throw GatewayToolError.executionFailed("Stale discovery cleanup was not confirmed")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(!FileManager.default.fileExists(atPath: staleScratch.path))
      #expect(gate.selections.count == 2 && gate.replacementCount == 0)
      gate.releaseSelection()
      do {
        _ = try await #require(pending).value
        Issue.record("The retired selection unexpectedly forwarded the old call")
      } catch let error as ProjectPathResolutionError {
        guard case .cannotInspectExistingAncestor = error else { throw error }
      }
      #expect(try latch.effects(home: home).isEmpty)
      #expect(gate.replacementCount == 0)
      #expect(try providerHost.discoveryExecutions() == newerExecutions)
      let earlierSelections = gate.finish()
      #expect(earlierSelections.count == 2)
      let newerSelection = try #require(earlierSelections.last)
      #expect(newerSelection.connectionID == newerBefore.connectionID)
      #expect(newerSelection.executionID == newerBefore.executionID)
      gate.arm(providerHost, expiries: 0)
      let result = try await runtime.callToolAsync(
        name: "mcp.tools.call",
        arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
        context: .init(session: fixture.session))
      let selections = gate.finish()
      #expect(selections.count == 1)
      #expect(earlierSelections.first?.evidence?.after.limitEndReason == .timeLimit)
      #expect(earlierSelections.first?.connectionID != newerSelection.connectionID)
      #expect(selections.first?.connectionID == newerSelection.connectionID)
      #expect(selections.first?.executionID == newerSelection.executionID)
      try fixture.database.configuredPermissionStore().readWithDatabase { _, ledger in
        let execution = try #require(ledger.executions[newerSelection.executionID])
        #expect(execution.isRunning)
        #expect(execution.authorizationIDs == newerAuthorizationIDs)
      }
      #expect(gate.replacementCount == 0)
      #expect(try providerHost.discoveryExecutions() == newerExecutions)
      providerHost.assertProviderPID(
        try #require(
          Self.payload(result).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value))
      #expect(try latch.effects(home: home).count == 1)
      try await Self.waitForResourceCount(1, runtime: runtime)
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "finish"),
        context: .init(session: fixture.session))
      try await Self.waitForResourceCount(0, runtime: runtime)
    } catch {
      gate.releaseSelection()
      if let pending { _ = await pending.result }
      _ = gate.finish()
      await runtime.shutdown()
      try await providerHost.finishAfterRuntimeShutdown()
      #expect(runtime.ownedWork.snapshot.isEmpty)
      throw error
    }
    await runtime.shutdown()
    try await providerHost.finishAfterRuntimeShutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  @Test(.timeLimit(.minutes(2)))
  func callerExpiryAfterDiscoveryFailurePreventsRenewalAndToolDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let latch = MCPInvocationDiscoveryLatch()
    let gate = MCPInvocationDiscoverySelectionGate()
    let source = Self.provider.replacingOccurrences(
      of: "elif method == \"tools/list\":",
      with: "elif method == \"tools/list\":\n" + latch.listCountingPython
    ).replacingOccurrences(
      of: "if params[\"name\"] == \"background\":",
      with: "if params[\"name\"] == \"background\":\n" + latch.backgroundPython)
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "replay"], work: true,
      source: source, backgroundProvider: true, discoveryGate: gate)
    let runtime = fixture.runtime
    let providerHost = try #require(fixture.providerHost)
    let home = URL(
      fileURLWithPath: try fixture.database.prepareProviderContainer(.localServer("provider")).root
        .string
    ).appendingPathComponent("home")
    do {
      let priorDiscoveries = try providerHost.discoveryExecutions()
      let priorLists = try latch.listInputs(home: home)
      #expect(try latch.effects(home: home).isEmpty)
      gate.arm(providerHost, expiries: 1, expireReplacementCaller: true)
      do {
        _ = try await runtime.callToolAsync(
          name: "mcp.tools.call",
          arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
          context: .init(session: fixture.session))
        Issue.record("Expired caller unexpectedly forwarded the tool")
      } catch {
        #expect(error as? PermissionModelError == .invalidAuthorization)
      }
      let selected = gate.finish()
      #expect(selected.count == 1 && gate.replacementCount == 1)
      #expect(selected.first?.evidence?.after.limitEndReason == .timeLimit)
      let caller = try #require(gate.callerExpiry)
      #expect(caller.before.id == caller.after.id)
      #expect(caller.before.startedAt == caller.after.startedAt)
      #expect(caller.before.limits.timeMilliseconds == 600_000)
      #expect(caller.after.limits.timeMilliseconds == caller.before.limits.timeMilliseconds)
      #expect(caller.after.authorizationIDs == caller.before.authorizationIDs)
      #expect(caller.after.owner == caller.before.owner)
      #expect(caller.after.limitEndReason == .timeLimit && !caller.after.isRunning)
      #expect(try providerHost.discoveryExecutions() == priorDiscoveries)
      #expect(try latch.listInputs(home: home) == priorLists)
      #expect(try latch.effects(home: home).isEmpty)
      providerHost.assertProviderPID(Int64(providerHost.process.pid))
    } catch {
      _ = gate.finish()
      await runtime.shutdown()
      try await providerHost.finishAfterRuntimeShutdown()
      #expect(runtime.ownedWork.snapshot.isEmpty)
      throw error
    }
    await runtime.shutdown()
    try await providerHost.finishAfterRuntimeShutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  private static func capacityFailureSnapshot(
    database: GatewayDatabase, runtime: GatewayRuntime, connectionID: String
  ) throws -> String {
    let ownership = runtime.ownedWork.snapshot
    let capturedAt = Date()
    let (original, records) = try database.configuredPermissionStore().readWithDatabase {
      database, ledger in
      (
        ledger,
        Dictionary(
          uniqueKeysWithValues: try ExecutionRuntimeRecord.all(database).map {
            ($0.id, $0)
          })
      )
    }
    var current = original
    _ = current.reconcileExecutionLimits(now: capturedAt)
    let ids = Set(records.keys).union(original.executions.keys)
    let ordered = ids.sorted {
      let left = original.executions[$0]?.startedAt ?? .distantPast
      let right = original.executions[$1]?.startedAt ?? .distantPast
      return left == right ? $0.uuidString < $1.uuidString : left < right
    }
    func tools(_ id: UUID) -> [String] {
      (original.executions[id]?.authorizationIDs ?? []).compactMap {
        original.authorizations[$0]?.invocation.tool
      }.sorted()
    }
    let groups = Dictionary(grouping: ordered) { id in
      let before = original.executions[id]
      let after = current.executions[id]
      return "tools=\(tools(id)) original_running=\(before?.isRunning.description ?? "missing") "
        + "original_revoked=\(before?.revoked.description ?? "missing") "
        + "current_running=\(after?.isRunning.description ?? "missing") "
        + "current_revoked=\(after?.revoked.description ?? "missing") "
        + "current_reason=\(String(describing: after?.limitEndReason)) "
        + "runtime_completed=\(records[id]?.completed.description ?? "missing")"
    }.map { "\($0.key) count=\($0.value.count)" }.sorted()
    // Always retain examples of the fixed provider, discovery, changed authority,
    // and the oldest/newest calls, while keeping the diagnostic bounded.
    let providers = ordered.filter { tools($0).contains("mcp.fixture.provider-host") }
    let discoveries = ordered.filter { tools($0).contains("provider.discovery") }
    let changed = ordered.filter {
      original.executions[$0]?.revoked == true || current.executions[$0]?.revoked == true
        || original.executions[$0]?.limitEndReason != nil
        || current.executions[$0]?.limitEndReason != nil
        || original.executions[$0]?.isRunning != current.executions[$0]?.isRunning
    }
    var selected: [UUID] = []
    for id in Array(providers.prefix(2)) + Array(discoveries.suffix(2))
      + Array(ordered.prefix(2)) + Array(ordered.suffix(3)) + changed
    {
      if !selected.contains(id) && selected.count < 16 { selected.append(id) }
    }
    let details = selected.map { id in
      let record = records[id]
      let before = original.executions[id]
      let after = current.executions[id]
      let proofs = (before?.authorizationIDs ?? []).sorted { $0.uuidString < $1.uuidString }
        .prefix(8).compactMap { proofID -> String? in
          guard let proof = original.authorizations[proofID] else {
            return "id=\(proofID) missing"
          }
          return
            "id=\(proofID) principal=\(proof.invocation.principal) tool=\(proof.invocation.tool) "
            + "project=\(proof.invocation.projectID ?? "none") source=\(proof.sandboxProjectID ?? "none") "
            + "original_finished=\(proof.finished) original_revoked=\(proof.revoked) "
            + "current_revoked=\(current.authorizations[proofID]?.revoked.description ?? "missing") "
            + "execution=\(proof.executionID?.uuidString ?? "none") basis=\(proof.basis.map { String(describing: $0) }.sorted())"
        }
      var validation = current
      let access =
        before.map { execution in
          let authorizations = execution.authorizationIDs.compactMap { original.authorizations[$0] }
          let hasProvider = authorizations.contains {
            if case .plugin = $0.invocation.principal { return true }
            return false
          }
          let connectionConsent = original.environment.connections[connectionID]?.consent
          let usesConnectionConsent = authorizations.contains { proof in
            proof.basis.contains { element in
              guard case .consent(let identity) = element, let consent = connectionConsent,
                case .fullAccess(.connection) = consent.mode
              else { return false }
              return identity == consent.identity
            }
          }
          let authorityConnection =
            hasProvider || execution.delegatedTo != nil
            ? (usesConnectionConsent ? connectionID : nil) : connectionID
          return String(
            describing: validation.executionAccess(
              id, principal: execution.owner, operation: .writeInput,
              connectionID: authorityConnection, authorizingInvocation: nil, now: capturedAt))
        } ?? "not_evaluated"
      let children = (record?.children ?? [:]).sorted { $0.key.uuidString < $1.key.uuidString }
      let childDetails = children.prefix(4).map { child in
        "id=\(child.key) pid=\(child.value.recovery?.root.processID.description ?? "unpublished") "
          + "identity=\(child.value.recovery?.root.identity.description ?? "unpublished") "
          + "completed=\(child.value.completed) released=\(child.value.released)"
      }
      return "id=\(id) admission_finished=\(record?.admissionFinished.description ?? "missing") "
        + "runtime_completed=\(record?.completed.description ?? "missing") "
        + "started_at=\(before?.startedAt.timeIntervalSince1970.description ?? "missing") "
        + "owner=\(String(describing: before?.owner)) delegated_to=\(String(describing: before?.delegatedTo)) "
        + "background=\(before?.limitRequest.background.description ?? "missing") "
        + "requested_ms=\(before?.limitRequest.timeMilliseconds?.description ?? "none") "
        + "original_ms=\(before?.limits.timeMilliseconds?.description ?? "none") "
        + "current_ms=\(after?.limits.timeMilliseconds?.description ?? "none") "
        + "original_running=\(before?.isRunning.description ?? "missing") original_revoked=\(before?.revoked.description ?? "missing") "
        + "original_reason=\(String(describing: before?.limitEndReason)) "
        + "current_running=\(after?.isRunning.description ?? "missing") current_revoked=\(after?.revoked.description ?? "missing") "
        + "current_reason=\(String(describing: after?.limitEndReason)) copied_write_input=\(access) "
        + "proofs_total=\(before?.authorizationIDs.count ?? 0) proofs=\(proofs) "
        + "children_total=\(children.count) children=\(childDetails)"
    }
    let owners = Dictionary(grouping: ownership) { record in
      "kind=\(record.kind.rawValue) connection=\(record.connectionID?.uuidString ?? "none") "
        + "uncertain=\(record.uncertain)"
    }.map { key, records in "\(key) count=\(records.count)" }.sorted()
    let pending = original.pendingExecutionTerminations.map(\.uuidString).sorted()
    return "captured_at=\(capturedAt.timeIntervalSince1970) executions_total=\(ids.count) "
      + "pending_total=\(pending.count) pending_sample=\(Array(pending.prefix(16))) "
      + "groups=\(Array(groups.prefix(32))) groups_total=\(groups.count) "
      + "details=\(details) ownership=\(Array(owners.prefix(16))) ownership_groups_total=\(owners.count)"
  }

  @Test(.timeLimit(.minutes(2)))
  func profileChangesRetireRetainedInvocationWithoutResurrection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "replay"], work: true)
    let runtime = fixture.runtime
    let context = InvocationContext(session: fixture.session)
    do {
      let started = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "background"), context: context)
      let reportedPID = try #require(
        Self.payload(started).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value)
      let processID = try #require(Int32(exactly: reportedPID))
      let provider = try #require(DarwinProcessIdentity.current(pid: processID)?.identity)
      try await Self.waitForResourceCount(1, runtime: runtime)
      let resource = try #require(runtime.ownedWork.snapshot.first { $0.kind == .mcpResource })
      _ = try #require(resource.connectionID)
      #expect(resource.projectID == "fixture" && resource.registrationID == "provider")
      let replay = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      let retainedID = try #require(
        Self.payload(replay).objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
      #expect(
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", id: retainedID
        ).reference.toolName == "background")
      var grant = try #require(fixture.database.profiles().first { $0.id == .localAdmin })
      grant.permissions.removeEntry(for: .project("fixture"))
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(projectID: "fixture", origin: "provider", id: retainedID)
      }
      try await Self.waitForRetiredProvider(
        provider, resource: resource, runtime: runtime, database: fixture.database,
        invocationID: retainedID)
      let retired = try #require(try fixture.database.hostCallRecordStore().record(id: retainedID))
      #expect(retired.lifecycle == .completed)
      #expect(retired.requestLeaseIDs.isEmpty && retired.workLeaseIDs.isEmpty)
      grant = try #require(fixture.database.profiles().first { $0.id == .localAdmin })
      try grant.permissions.set(.granted(.read), for: .project("fixture"))
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(projectID: "fixture", origin: "provider", id: retainedID)
      }
      #expect(fixture.session.snapshot.fullAccessConsent == nil)
      await runtime.shutdown()
      try await Self.waitForRetiredProvider(
        provider, resource: resource, runtime: runtime, database: fixture.database,
        invocationID: retainedID)
      let completed = try #require(
        try fixture.database.hostCallRecordStore().record(id: retainedID))
      #expect(completed.lifecycle == .completed)
      #expect(completed.requestLeaseIDs.isEmpty && completed.workLeaseIDs.isEmpty)
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  private static func waitForRetiredProvider(
    _ provider: DarwinProcessIdentity, resource: GatewayOwnedWork.Record, runtime: GatewayRuntime,
    database: GatewayDatabase, invocationID: UUID
  ) async throws {
    var uncertainResource = resource
    uncertainResource.uncertain = true
    func retired() throws -> Bool {
      let record = try database.hostCallRecordStore().record(id: invocationID)
      let snapshot = runtime.ownedWork.snapshot
      return DarwinProcessIdentity.current(pid: provider.pid, includingZombies: true)?.identity
        != provider
        && record?.lifecycle == .completed
        && record?.requestLeaseIDs.isEmpty == true && record?.workLeaseIDs.isEmpty == true
        && snapshot.count == 2 && snapshot.contains(uncertainResource)
        && snapshot.contains {
          $0.kind == .mcpObservation && $0.uncertain
            && $0.projectID == resource.projectID && $0.registrationID == resource.registrationID
            && $0.connectionID == resource.connectionID
            && $0.resourceID == resource.connectionID?.uuidString
        }
    }
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if try retired() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(
      try retired(),
      "Provider \(provider) was not joined with only its original uncertain resource and observation remaining: \(runtime.ownedWork.snapshot)"
    )
  }

  @Test(.timeLimit(.minutes(2)), arguments: [false, true])
  func nativeDispatchLeaseFailureNeverReachesProvider(failWorkLease: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("dispatched")
    let source = Self.provider.replacingOccurrences(
      of: "elif method == \"tools/call\":",
      with: "elif method == \"tools/call\":\n        open(" + String(reflecting: marker.path)
        + ", \"w\").write(\"dispatched\")")
    let database = try fixturePermissionDatabase(path: root.appendingPathComponent("host.db").path)
    let connection = database.connection
    let fixture = try await Self.makeFixture(
      root: root, names: ["background"], work: true, source: source, database: database)
    let runtime = fixture.runtime
    let context = InvocationContext(session: fixture.session)
    do {
      try await connection.writer.write { database in
        let condition =
          failWorkLease ? "WHEN json_array_length(NEW.payload, '$.workLeaseIDs') > 0" : ""
        try database.execute(
          sql: "CREATE TRIGGER fail_lease BEFORE UPDATE ON hostCallRecords " + condition
            + " BEGIN SELECT RAISE(ABORT, 'fixture'); END")
      }
      await #expect(throws: (any Error).self) {
        try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "background"), context: context)
      }
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      let records = try await connection.writer.read { database in
        try Data.fetchAll(database, sql: "SELECT payload FROM hostCallRecords").map {
          try JSONDecoder().decode(HostCallRecord.self, from: $0)
        }
      }
      let record = try #require(records.first)
      #expect(records.count == 1)
      #expect(record.admission.reference == .init(serverID: "provider", toolName: "background"))
      #expect(record.admission.upstreamName == "mcp.tools.call")
      #expect(record.admission.controlSessionID == fixture.session.id)
      #expect(record.admission.authorizationID != nil)
      if failWorkLease { #expect(record.lifecycle == .completed) }
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", id: record.admission.id)
      }
    } catch {
      await runtime.shutdown()
      throw error
    }
    await runtime.shutdown()
  }

  private static func waitForResourceCount(
    _ count: Int, runtime: GatewayRuntime, timeout: Duration = .seconds(3)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      let snapshot = runtime.ownedWork.snapshot
      if snapshot.filter({ $0.kind == .mcpResource }).count == count,
        !snapshot.contains(where: { $0.kind == .mcpObservation })
      {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Provider work did not settle to \(count) resources.")
  }

  @Test(.timeLimit(.minutes(2)), arguments: [false, true], ["sync", "async", "detached"])
  func nativeProviderReceivesOnlyItsHostBoundInvocation(hostServices: Bool, mode: String)
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await Self.makeFixture(
      root: root, names: ["inspect", "deferred", "release", "replay"], work: false,
      hostServices: hostServices)
    let runtime = fixture.runtime
    let context = InvocationContext(session: fixture.session)
    do {
      let arguments = Self.arguments(tool: mode == "detached" ? "deferred" : "inspect")
      let result: JSONValue
      if mode == "sync" {
        result = try await BlockingOperationExecutor(label: "host-invocation-test").perform {
          try runtime.callTool(name: "mcp.tools.call", arguments: arguments, context: context)
        }
      } else if mode == "async" {
        result = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: arguments, context: context)
      } else {
        var startedArguments = try #require(arguments.objectValue)
        startedArguments["wait_for_result"] = .bool(false)
        startedArguments["request_id"] = .string("detached")
        let started = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(startedArguments), context: context)
        #expect(Self.payload(started).objectValue?["state"] == .string("running"))
        startedArguments["request_id"] = .string("second")
        _ = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(startedArguments), context: context)
        #expect(runtime.ownedWork.snapshot.filter { $0.kind == .mcpRequest }.count == 2)
        _ = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "release"), context: context)
        let first = try await Self.readResult(runtime, id: "detached", context: context)
        let second = try await Self.readResult(runtime, id: "second", context: context)
        if hostServices {
          let firstID = first.objectValue?["structuredContent"]?.objectValue?["result"]?
            .objectValue?["invocation_id"]
          let secondID = second.objectValue?["structuredContent"]?.objectValue?["result"]?
            .objectValue?["invocation_id"]
          #expect(firstID != nil && secondID != nil && firstID != secondID)
        }
        result = .object([
          "structuredContent": .object([
            "result": first
          ])
        ])
      }
      let reportedContext = try #require(
        Self.payload(result).objectValue?["structuredContent"]?.objectValue)
      if hostServices {
        let bound = try #require(reportedContext["result"]?.objectValue)
        #expect(bound["registration_id"] == .string("provider"))
        #expect(bound["project_id"] == .string("fixture"))
        #expect(bound["operation"] == .null)
        #expect(bound["tool"] == .string(mode == "detached" ? "deferred" : "inspect"))
        #expect(bound["capability_id"] == .string("mcp.tools.call"))
        #expect(bound["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
        let replay = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
        #expect(Self.payload(replay).objectValue?["isError"] == .bool(true))
      } else {
        #expect(reportedContext["host_metadata"] == .null)
      }
    } catch {
      await runtime.shutdown()
      throw error
    }
    await runtime.shutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  /// Metadata is observed through the same admitted native connection used by calls.
  private static func makeFixture(
    root: URL, names: [String], work: Bool, hostServices: Bool = true,
    source suppliedSource: String? = nil, database suppliedDatabase: GatewayDatabase? = nil,
    backgroundProvider: Bool = false,
    discoveryGate: MCPInvocationDiscoverySelectionGate? = nil,
    launcher suppliedLauncher: ExecutionLauncher? = nil,
    policyReader: (any ManagedPolicyReading)? = nil, startupTimeoutMs: Int? = nil
  ) async throws -> (
    runtime: GatewayRuntime, session: GatewayControlSession, database: GatewayDatabase,
    providerHost: MCPInvocationBackgroundProvider?
  ) {
    let root = try ProjectPathResolver.canonicalProject(root)
    let source = suppliedSource ?? provider
    let script = root.appendingPathComponent("provider.py")
    try writePythonTestExecutable(source, to: script)
    let arguments = work ? ["work"] : []
    let launcher = suppliedLauncher ?? testExecutionLauncher()
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = policyReader ?? TestManagedPolicyReader()
    let database =
      try suppliedDatabase
      ?? fixturePermissionDatabase(path: root.appendingPathComponent("host.db").path)
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    let profile = ProfileGrant(
      id: .localAdmin,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.read), .mcpServer("provider"): .granted(.read),
      ]), fullAccess: true, allowedCallers: [.localMCP])
    try database.saveProfile(profile)
    let server = MCPServerConfig(
      id: "provider", transport: .stdio, command: script.path,
      args: arguments, allowedTools: names,
      startupTimeoutMs: startupTimeoutMs ?? (backgroundProvider ? 30_000 : 5_000),
      requestTimeoutMs: 5_000,
      toolRisks: Dictionary(uniqueKeysWithValues: names.map { ($0, .readOnly) }),
      hostServices: hostServices)
    let capture =
      backgroundProvider
      ? MCPInvocationScopedClientCapture(
        base: MCPProxyClient(
          launcher: launcher,
          onDiscoverySelection: { serverID, connectionID, executionID in
            try discoveryGate?.didSelect(
              serverID: serverID, connectionID: connectionID, executionID: executionID)
          }), projectID: project.id, discoveryGate: discoveryGate) : nil
    let runtime = try await GatewayRuntime.make(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: profile.id), profiles: [.init(grant: profile)],
        mcp: .init(servers: [server]), projectDirectory: root),
      context: .init(
        caller: .localMCP, profileID: profile.id, projectID: project.id,
        trustedPrincipalID: "host-invocation-client"),
      database: database, registeredProjects: [project], platform: platform, mcpClient: capture,
      bundledPlugins: .init(packages: [], issues: []), requiresControlSession: true)
    var providerHost: MCPInvocationBackgroundProvider?
    do {
      let session = try runtime.makeControlSession()
      try fixtureApproveLocalProvider(
        server, database: database, runtime: runtime.permissionRuntime,
        permissions: fixturePermissions([.project(project.id): .granted(.read)]), fullAccess: true)
      _ = try session.approveFullAccess(expectedRevision: session.revision)
      if let capture {
        #expect(capture.scopes.count == 1)
        let scope = try #require(capture.scopes.first)
        providerHost = try await MCPInvocationBackgroundProvider.start(
          runtime: runtime, database: database, session: session, scope: scope, server: server)
      }
      let catalog = try await runtime.callToolAsync(
        name: "mcp.tools.list",
        arguments: .object(["project_id": .string("fixture"), "server": .string("provider")]),
        context: .init(session: session))
      let tools = try #require(payload(catalog).arrayValue)
      #expect(Set(tools.compactMap { $0.objectValue?["name"]?.stringValue }) == Set(names))
      return (runtime, session, database, providerHost)
    } catch {
      await runtime.shutdown()
      if let providerHost {
        do { try await providerHost.finishAfterRuntimeShutdown() } catch let cleanupError {
          Issue.record("Background provider cleanup failed: \(cleanupError)")
        }
      }
      throw error
    }
  }

  private static func arguments(tool: String, timeoutMilliseconds: Int64? = nil) -> JSONValue {
    var arguments: [String: JSONValue] = [
      "project_id": .string("fixture"), "server": .string("provider"), "tool": .string(tool),
      "arguments": .object(["invocation_id": .string("caller-forged-id")]),
    ]
    if let timeoutMilliseconds { arguments["timeout_ms"] = .integer(timeoutMilliseconds) }
    return .object(arguments)
  }

  private static func readResult(
    _ runtime: GatewayRuntime, id: String, context: InvocationContext
  ) async throws -> JSONValue {
    let deadline = ContinuousClock.now + .seconds(2)
    var receipt: JSONValue = .null
    repeat {
      receipt = try await runtime.callToolAsync(
        name: "mcp.requests.read",
        arguments: .object([
          "project_id": .string("fixture"), "server": .string("provider"),
          "request_id": .string(id),
        ]), context: context)
      if Self.payload(receipt).objectValue?["state"] == .string("succeeded") { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    return try #require(Self.payload(receipt).objectValue?["result"])
  }

  private static func payload(_ value: JSONValue) -> JSONValue {
    value.objectValue?["structuredContent"]?.objectValue?["result"] ?? .null
  }

  private static let provider = #"""
    import json, os, socket, sys, uuid
    channel = None
    sequence = 0
    pending = []
    previous = None
    work_enabled = len(sys.argv) > 1
    resources = []
    revision = 0
    instance = str(uuid.uuid4())
    work_uri = "computer-mcp://runtime/work/v1"
    def send(id, result):
        print(json.dumps({"jsonrpc": "2.0", "id": id, "result": result}), flush=True)
    def host(method, params):
        global sequence
        sequence += 1
        channel.write((json.dumps({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}) + "\n").encode())
        channel.flush()
        while True:
            response = json.loads(channel.readline())
            if response.get("id") == sequence:
                return response
    def describe(invocation):
        global channel
        if invocation is None:
            return {"content": [], "structuredContent": {"host_metadata": None}}
        if channel is None:
            connection = socket.socket(fileno=int(os.environ["COMPUTER_MCP_HOST_FD"]))
            connection.settimeout(5)
            channel = connection.makefile("rwb")
            host("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "generic-fixture", "version": "1"}})
            channel.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            channel.flush()
        return host("tools/call", {"name": "host.invocations.describe", "arguments": {"invocation_id": invocation}})["result"]
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        params = request.get("params", {})
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "generic-fixture", "version": "1"}}
            if work_enabled:
                result["capabilities"]["resources"] = {}
        elif method == "tools/list":
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in ["inspect", "deferred", "release", "replay", "background", "derive", "finish"]]}
            if work_enabled:
                for tool in result["tools"]:
                    tool["_meta"] = {"io.github.computer-mcp/work": {"format_version": 1, "uri": work_uri}}
                    if tool["name"] == "background":
                        tool["_meta"]["io.github.computer-mcp/host-action"] = "diagnostics.snapshot"
        elif method == "resources/read":
            assert work_enabled and params["uri"] == work_uri
            result = {"contents": [{"uri": work_uri, "mimeType": "application/json", "text": json.dumps({"format_version": 1, "instance_id": instance, "revision": revision, "resources": resources})}]}
        elif method == "tools/call":
            invocation = params.get("_meta", {}).get("io.github.computer-mcp/host-invocation")
            if params["name"] == "deferred":
                pending.append((request["id"], invocation))
                continue
            if params["name"] == "background":
                previous = invocation
                resources.append({"kind": "fixture", "id": str(request["id"]), "acquired_by": params["_meta"]["io.github.computer-mcp/work-invocation"], "state": "active"})
                revision += 1
                result = {"content": [], "structuredContent": {"pid": os.getpid()}}
            elif params["name"] == "derive":
                resources = [{**resources[-1], "id": "derived"}]
                revision += 1
                result = {"content": []}
            elif params["name"] == "finish":
                resources.clear()
                revision += 1
                result = {"content": []}
            elif params["name"] == "release":
                for id, binding in pending:
                    send(id, describe(binding))
                    previous = binding
                pending.clear()
                result = {"content": []}
            elif params["name"] == "replay":
                result = describe(previous)
            else:
                result = describe(invocation)
                previous = invocation
        else:
            raise RuntimeError("Unexpected method")
        send(request["id"], result)
    """#
}
