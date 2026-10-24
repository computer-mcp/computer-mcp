import ComputerMCPSandbox
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

// Blocking kernel fixtures share the dispatch thread pool; deadline assertions need each
// scenario to run without competing blocked fixtures consuming its scheduling budget.
@Suite(.nativeIntegration, .serialized) struct ExecutionCompletionTests {
  @Test func missingKernelSentinelCannotConfirmAnEmptyExecution() async throws {
    let fixture = try SimulatedExecution(configure: { $0.omitKernel = true })
    fixture.rootExited()
    fixture.processes.mutate { $0.entries = [:] }
    let failure = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(failure.reasons.contains { $0.contains("kernproc") })
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.omitKernel = false }
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test(arguments: [UInt64(100), UInt64(101)])
  func processMustBeBelowSnapshotWatermark(uniqueID: UInt64) async throws {
    let fixture = try SimulatedExecution(configure: {
      $0.watermark = 100
      $0.entries[1_000_099] = .init(
        identity: .init(pid: 1_000_099, uniqueID: uniqueID), parentUniqueID: 999,
        group: 0, session: 0, state: .running)
    })
    fixture.rootExited()
    fixture.processes.mutate { $0.entries[SimulatedExecution.leaf.pid] = nil }
    let failure = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(failure.reasons.contains { $0.contains("snapshot watermark") })
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.watermark = uniqueID + 1 }
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test func failedProbeCannotConfirmAnEmptyExecution() async throws {
    let fixture = try SimulatedExecution(configure: { $0.probeFails = true })
    fixture.rootExited()
    fixture.processes.mutate { $0.entries = [:] }
    let failure = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(failure.reasons.contains { $0.contains("Identity probe failed") })
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.probeFails = false }
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test func identityChangeAcrossMembershipQueryInvalidatesRound() async throws {
    let fixture = try SimulatedExecution(configure: {
      $0.changeIdentityDuringContains = true
      $0.entries[1_000_099] = .init(
        identity: .init(pid: 1_000_099, uniqueID: 99), parentUniqueID: 999,
        group: 0, session: 0, state: .running)
    })
    fixture.rootExited()
    fixture.processes.mutate { $0.entries[SimulatedExecution.leaf.pid] = nil }
    let failure = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(failure.reasons.contains { $0.contains("changed during membership inspection") })
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.changeIdentityDuringContains = false }
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test func unreadableMemberRetainsOwnershipUntilIdentityCanBeSignalled() async throws {
    let fixture = try SimulatedExecution(configure: { $0.readFails = true })
    fixture.rootExited()
    _ = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(750)))
    }
    #expect(fixture.processes.state.signals.isEmpty)
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.readFails = false }
    #expect(try await fixture.owner.wait().status == 23)
    #expect(fixture.processes.state.signals.contains { $0.1 == SIGKILL })
    #expect(!fixture.markerExists)
  }

  @Test func reusedMemberPIDRejectsTokenWithoutSignallingReplacement() async throws {
    let fixture = try SimulatedExecution(configure: { $0.replaceOnSignal = true })
    fixture.rootExited()
    #expect(try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3))).status == 23)
    let state = fixture.processes.state
    #expect(state.rejectedSignals > 0)
    #expect(!state.signals.contains { $0.1 == SIGKILL })
    #expect(state.entries[SimulatedExecution.leaf.pid]?.parentUniqueID == 999)
  }

  @Test func missingExecutionSentinelInvalidatesSnapshot() async throws {
    let fixture = try SimulatedExecution(configure: { $0.omitSentinel = true })
    fixture.rootExited()
    fixture.processes.mutate { $0.entries = [:] }
    let failure = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(failure.reasons.contains { $0.contains("did not reach execution sentinel") })
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.omitSentinel = false }
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test func lostSentinelFailsClosedAndKeepsKillingMembers() async throws {
    let fixture = try SimulatedExecution()
    fixture.rootExited()
    fixture.processes.mutate { $0.sentinelMissing = true }
    let failure = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .seconds(3)))
    }
    #expect(failure.reasons.contains { $0.contains("Cannot confirm execution sentinel") })
    try await eventually { fixture.processes.state.signals.contains { $0.1 == SIGKILL } }
    #expect(fixture.markerExists)
    _ = try await fixture.failure {
      try await failure.ownership.wait(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(fixture.markerExists)
    // Restore the injected boundary solely to drain the fixture's retained monitor.
    fixture.clear()
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test func lateSentinelFailureRevokesAndKillsWithoutPublishingCompletion() async throws {
    let gate = InspectionGate()
    let revoked = InspectionGate()
    defer { gate.release() }
    let fixture = try SimulatedExecution(configure: {
      $0.sentinelMissing = true
      $0.beforeSentinelRead = { gate.block() }
    })
    fixture.owner.onCancellation { revoked.release() }
    fixture.rootExited()
    try await eventually { gate.entered }
    _ = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(80)))
    }
    gate.release()
    try await eventually { fixture.processes.state.signals.contains { $0.1 == SIGKILL } }
    #expect(revoked.isReleased)
    #expect(fixture.markerExists)
    fixture.clear()
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test func exitingRecordBeforeSZOMBIsNotClassifiedAsNonmember() async throws {
    let fixture = try SimulatedExecution(configure: { $0.exitingBeforeSZOMB = true })
    fixture.rootExited()
    fixture.processes.mutate { $0.entries = [:] }
    let failure = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(failure.reasons.contains { $0.contains("zombie membership cannot be classified") })
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.exitingBeforeSZOMB = false }
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test(arguments: [
    "nonmember", "launchd", "host", "member", "missing", "unreadable", "zombie", "reused",
    "changed", "exited", "traced", "bsd-unreadable",
  ])
  func zombieNonmembershipRequiresUntracedStateAndVerifiedParent(condition: String) async throws {
    let parentPID: pid_t = condition == "launchd" ? 1 : condition == "host" ? getpid() : 1_000_097
    let zombiePID: pid_t = 1_000_099
    let fixture = try SimulatedExecution(configure: {
      $0.entries = [
        zombiePID: .init(
          identity: .init(pid: zombiePID, uniqueID: 99), parentUniqueID: 999,
          group: 0, session: 0, state: .zombie, parentID: parentPID,
          isTraced: condition == "bsd-unreadable" ? nil : condition == "traced"),
        parentPID: .init(
          identity: .init(pid: parentPID, uniqueID: condition == "reused" ? 1000 : 999),
          parentUniqueID: condition == "member" ? 1 : 999, group: 0, session: 0,
          state: condition == "zombie" ? .zombie : .running),
      ]
      if condition == "missing" { $0.entries[parentPID] = nil }
      if condition == "unreadable" { $0.unreadablePIDs.insert(parentPID) }
    })
    defer { fixture.clear() }
    if condition == "changed" || condition == "exited" {
      let processes = fixture.processes
      processes.mutate {
        $0.beforeContains = {
          processes.mutate { state in
            guard state.reads[zombiePID] == 1, let current = state.entries[parentPID] else {
              return
            }
            state.entries[parentPID] = .init(
              identity: .init(
                pid: parentPID,
                uniqueID: condition == "changed" ? current.identity.uniqueID + 1 : 999),
              parentUniqueID: 999, group: 0, session: 0,
              state: condition == "exited" ? .zombie : .running)
          }
        }
      }
    }
    fixture.rootExited()
    if condition == "nonmember" {
      #expect(try await fixture.owner.wait().status == 23)
      #expect(fixture.processes.state.entries[zombiePID]?.state == .zombie)
      #expect(fixture.processes.state.signals.isEmpty)
    } else {
      let failure = try await fixture.failure {
        try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(150)))
      }
      if condition == "traced" || condition == "bsd-unreadable" {
        #expect(failure.reasons.contains { $0.contains("zombie membership cannot be classified") })
        #expect(fixture.processes.state.entries[zombiePID]?.state == .zombie)
        #expect(fixture.processes.state.signals.isEmpty)
      }
      #expect(fixture.markerExists)
      fixture.clear()
      #expect(try await fixture.owner.wait().status == 23)
    }
  }

  @Test func knownMemberIsKilledBeforeSecondIdentityRead() async throws {
    let fixture = try SimulatedExecution()
    fixture.rootExited()
    _ = try await fixture.owner.members()
    fixture.processes.mutate { $0.failSecondRead = true }
    #expect(try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3))).status == 23)
    #expect(
      fixture.processes.state.signals.contains {
        $0.0 == SimulatedExecution.leaf && $0.1 == SIGKILL
      })
  }

  @Test func forkAndExitAfterPIDEnumerationCannotLookEmpty() async throws {
    let fixture = try SimulatedExecution()
    fixture.processes.mutate { $0.churn = 8 }
    fixture.rootExited()
    let result = try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3)))
    #expect(result.status == 23)
    let state = fixture.processes.state
    #expect(state.churn == 0)
    #expect(state.emptyScansAfterKill >= 1)
    #expect(!fixture.markerExists)
  }

  @Test(arguments: [
    "enumeration", "read", "kill-signal", "kill-pending",
    "omitted",
  ])
  func cancellationDeadlineReportsFailureAndRetainsMarker(problem: String) async throws {
    let fixture = try SimulatedExecution()
    fixture.processes.mutate {
      switch problem {
      case "enumeration": $0.enumerationFails = true
      case "read": $0.readFails = true
      case "kill-signal": $0.failedSignal = SIGKILL
      case "kill-pending": $0.ignoreKill = true
      default:
        $0.omitMembers = true
        $0.ignoreKill = true
      }
    }
    let started = ContinuousClock.now
    let failure = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3)))
    }
    #expect(started.duration(to: .now) < .seconds(6))
    #expect(!failure.bestEffort)
    #expect(!failure.members.isEmpty)
    #expect(fixture.markerExists)
    if problem == "enumeration" {
      #expect(failure.reasons.contains { $0.contains("enumeration failed") })
    }
    if problem == "read" { #expect(failure.members.contains { $0.reason.contains("unreadable") }) }
    if problem.hasSuffix("signal") {
      #expect(
        failure.members.contains { $0.reason.contains("errno 1") }
          || failure.reasons.contains { $0.contains("errno 1") })
    }
    fixture.clear()
    #expect(try await fixture.owner.wait(until: .now.advanced(by: .seconds(2))).status == 23)
    #expect(!fixture.markerExists)
  }

  @Test(arguments: [true, false])
  func waitDeadlineAndFullAccessCancellationAreBounded(sandboxed: Bool) async throws {
    let fixture = try SimulatedExecution(sandboxed: sandboxed)
    fixture.processes.mutate { $0.failedSignal = SIGKILL }
    let waited = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(80)))
    }
    #expect(waited.bestEffort == !sandboxed)
    #expect(!waited.members.isEmpty)
    #expect(fixture.processes.state.signals.isEmpty)
    let cancelled = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3)))
    }
    #expect(cancelled.bestEffort == !sandboxed)
    #expect(
      cancelled.members.contains { $0.reason.contains("errno 1") }
        || cancelled.reasons.contains { $0.contains("errno 1") })
    fixture.clear()
    #expect(try await fixture.owner.wait(until: .now.advanced(by: .seconds(2))).status == 23)
  }

  @Test func earliestConcurrentDeadlineLeavesSharedCleanupRunning() async throws {
    let fixture = try SimulatedExecution()
    async let first = fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(100)))
    }
    async let second = fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .seconds(2)))
    }
    let failures = try await (first, second)
    #expect(!failures.0.members.isEmpty && !failures.1.members.isEmpty)
    fixture.clear()
    try await eventually { !fixture.markerExists }
    _ = try await fixture.owner.wait(until: .now.advanced(by: .seconds(2)))
    #expect(!fixture.markerExists)
  }

  @Test func identityReuseIsExitOfOriginalMemberWithoutSignallingReplacement() async throws {
    let fixture = try SimulatedExecution(sandboxed: false)
    _ = try await fixture.owner.members()
    fixture.processes.mutate { state in
      state.entries[SimulatedExecution.leaf.pid] = .init(
        identity: .init(pid: SimulatedExecution.leaf.pid, uniqueID: 900), parentUniqueID: 0,
        group: 0, session: 0, state: .running)
    }
    fixture.rootExited()
    _ = try await fixture.owner.cancel(until: .now.advanced(by: .seconds(2)))
    #expect(!fixture.processes.state.signals.contains { $0.0.uniqueID == 900 })
    #expect(fixture.processes.state.entries[SimulatedExecution.leaf.pid]?.identity.uniqueID == 900)
  }

  @Test func knownBootstrapRemainsOwnedBeforeSandboxInstallation() async throws {
    let fixture = try SimulatedExecution(configure: {
      $0.entries = [
        SimulatedExecution.root.pid: .init(
          identity: SimulatedExecution.root, parentUniqueID: 999,
          group: 0, session: 0, state: .running)
      ]
    })
    let cancellation = Task {
      try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3)))
    }
    try await eventually { fixture.processes.state.entries.isEmpty }
    #expect(
      fixture.processes.state.signals.contains {
        $0.0 == SimulatedExecution.root && $0.1 == SIGKILL
      })
    fixture.rootExited()
    #expect(try await cancellation.value.status == 23)
    #expect(!fixture.markerExists)
  }

  @Test func cancellationBeforeLaunchIdentityReturnsRecoverableFailure() async throws {
    let marker = try ExecutionSandboxMarker()
    let owner = DarwinExecutionOwnership(
      marker: marker, sentinel: SimulatedProcessTable.sentinel(),
      table: SimulatedProcessTable().table)
    let result: ExecutionCompletionFailure
    do {
      let _: any ExecutionOwnership = try await withCheckedThrowingContinuation { continuation in
        owner.starting(continuation)
        owner.requestCancellation(until: .now.advanced(by: .milliseconds(80)))
      }
      Issue.record("Expected startup cancellation failure")
      return
    } catch let failure as ExecutionCompletionFailure { result = failure }
    #expect(result.reasons.contains("Root exit has not been collected"))
    owner.exited(.success(.init(status: 23)))
    #expect(try await result.ownership.wait(until: .now.advanced(by: .seconds(2))).status == 23)
  }

  @Test func pidReuseBeforeFirstReadCannotMakeAnIncompleteScanEmpty() async throws {
    let fixture = try SimulatedExecution()
    fixture.rootExited()
    fixture.processes.mutate { $0.reuseOnList = 8 }
    _ = try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3)))
    #expect(fixture.processes.state.reuseOnList == 0)
    #expect(fixture.processes.state.emptyScansAfterKill >= 1)
  }

  @Test(arguments: [
    "fork-exit", "fork-zombie", "pid-reuse", "identity", "system-exit",
  ])
  func incompleteKillRoundRetainsOwnershipUntilFreshClassification(race: String) async throws {
    let first = InspectionGate()
    let next = InspectionGate()
    defer {
      first.release()
      next.release()
    }
    let fixture = try SimulatedExecution(configure: {
      if race == "fork-zombie" { $0.entries[SimulatedExecution.leaf.pid] = nil }
      $0.onList = { count in
        if count == 1 { first.block() }
        if count == 3 { next.block() }
      }
    })
    fixture.rootExited()
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    fixture.owner.requestCancellation(until: deadline)
    let cancellation = Task { try await fixture.owner.cancel(until: deadline) }
    try await eventually { first.entered }
    // Keep the first enumeration pending until the grace interval has elapsed.
    try await Task.sleep(for: .milliseconds(550))
    fixture.processes.mutate {
      $0.raceAfterList = 2
      switch race {
      case "fork-exit": $0.churn = 1
      case "fork-zombie": $0.forkToZombie = true
      case "pid-reuse": $0.reuseOnList = 1
      case "system-exit": $0.systemExitOnList = 1
      default: $0.replaceDuringContains = true
      }
    }
    first.release()
    try await eventually { next.entered }
    #expect(fixture.markerExists)
    #expect(fixture.processes.state.listCount == 3)
    if race == "fork-zombie" {
      fixture.processes.mutate { state in
        state.entries = state.entries.filter { $0.value.state != .zombie }
      }
    }
    next.release()
    #expect(try await cancellation.value.status == 23)
    #expect(!fixture.markerExists)
    #expect(fixture.processes.state.signals.contains { $0.1 == SIGKILL })
  }

  @Test func nonmemberExitChurnHasDeadlineAndDoesNotPreventMemberKills() async throws {
    let fixture = try SimulatedExecution(configure: { $0.systemExitOnList = Int.max })
    fixture.rootExited()
    let start = ContinuousClock.now
    let failure = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(750)))
    }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(failure.reasons.contains { $0.contains("disappeared during classification") })
    #expect(fixture.processes.state.signals.contains { $0.1 == SIGKILL })
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.systemExitOnList = 0 }
    #expect(try await failure.ownership.wait(until: .now.advanced(by: .seconds(2))).status == 23)
    #expect(!fixture.markerExists)
  }

  @Test func olderZombiesAfterSentinelDoNotPreventCompletion() async throws {
    let fixture = try SimulatedExecution()
    fixture.rootExited()
    fixture.processes.mutate {
      $0.olderZombie = true
    }
    #expect(try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3))).status == 23)
    #expect(fixture.processes.state.olderZombie)
    #expect(!fixture.markerExists)
  }

  @Test func interleavedContinueAndSelfStopCannotPreventKillingMembers() async throws {
    let fixture = try SimulatedExecution()
    fixture.processes.mutate { $0.continuePeerOnRead = true }
    let cancellation = Task {
      try await fixture.owner.cancel(until: .now.advanced(by: .seconds(3)))
    }
    try await eventually { fixture.processes.state.signals.filter { $0.1 == SIGKILL }.count == 2 }
    fixture.rootExited()
    #expect(try await cancellation.value.status == 23)
    let state = fixture.processes.state
    #expect(state.continuedPeer)
    #expect(state.emptyScansAfterKill >= 1)
  }

  @Test func continuousForkAndExitFailsDeadlineThenBackgroundCleanupFinishes() async throws {
    let fixture = try SimulatedExecution()
    fixture.rootExited()
    fixture.processes.mutate { $0.continuousChurn = true }
    let failure = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(750)))
    }
    #expect(!failure.reasons.isEmpty)
    #expect(fixture.markerExists)
    let scans = fixture.processes.state.listCount
    try await eventually { fixture.processes.state.listCount >= scans + 3 }
    #expect(!fixture.processes.state.signals.contains { $0.1 == SIGKILL })
    // A round that includes the replacement can kill it despite earlier incomplete rounds.
    fixture.processes.mutate { $0.enumerateReplacement = true }
    try await eventually { !fixture.markerExists }
    #expect(fixture.processes.state.entries.isEmpty)
    #expect(fixture.processes.state.continuousChurn)
    #expect(try await failure.ownership.members().isEmpty)
    #expect(try await failure.ownership.wait().status == 23)
  }

  @Test(arguments: ["enumeration", "read", "membership", "signal"])
  func blockedKernelOperationDoesNotBlockCancellationDeadline(operation: String) async throws {
    let gate = InspectionGate()
    defer { gate.release() }
    let fixture = try SimulatedExecution(configure: {
      switch operation {
      case "enumeration": $0.beforeList = { gate.block() }
      case "read": $0.beforeRead = { gate.block() }
      case "membership": $0.beforeContains = { gate.block() }
      default: $0.beforeSignal = { gate.block() }
      }
    })
    fixture.owner.requestCancellation()
    try await eventually { gate.entered }
    let started = ContinuousClock.now
    let failure = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(120)))
    }
    let elapsed = started.duration(to: .now)
    #expect(elapsed < .milliseconds(500))
    #expect(!failure.members.isEmpty)
    #expect(failure.reasons.contains("Process inspection is pending"))
    #expect(fixture.markerExists)
    fixture.clear()
    gate.release()
    try await eventually { !fixture.markerExists }
    #expect(try await failure.ownership.wait().status == 23)
  }

  @Test func inspectionTimeoutRequiresFreshCompleteSnapshot() async throws {
    let expired = InspectionGate()
    let following = InspectionGate()
    defer {
      expired.release()
      following.release()
    }
    let fixture = try SimulatedExecution()
    _ = try await fixture.owner.members()
    fixture.rootExited()
    fixture.processes.mutate {
      $0.entries = [:]
      $0.listCount = 0
      $0.onList = { count in
        if count == 1 { expired.block() }
        if count >= 2 { following.block() }
      }
    }
    try await eventually { expired.entered }
    // The caller's deadline stays open while the worker's one-second inspection budget expires.
    try await Task.sleep(for: .milliseconds(1100))
    expired.release()
    try await eventually { following.entered }
    #expect(fixture.markerExists)
    following.release()
    #expect(try await fixture.owner.wait(until: .now.advanced(by: .seconds(3))).status == 23)
  }

  @Test func lateEmptyScanCannotRetireMarkerOrPublishCompletion() async throws {
    let late = InspectionGate()
    let fresh = InspectionGate()
    defer {
      late.release()
      fresh.release()
    }
    let fixture = try SimulatedExecution()
    _ = try await fixture.owner.members()
    fixture.rootExited()
    fixture.processes.mutate {
      $0.entries = [:]
      $0.listCount = 0
      $0.onList = { count in
        if count == 1 { late.block() }
        if count >= 2 { fresh.block() }
      }
    }
    try await eventually { late.entered }
    _ = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(80)))
    }
    late.release()
    try await eventually { fresh.entered }
    #expect(fixture.markerExists)
    _ = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(80)))
    }
    #expect(fixture.markerExists)
    fresh.release()
    try await eventually { !fixture.markerExists }
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test(arguments: [false, true])
  func memberOrUnclassifiedZombiePreventsCompletion(unreadable: Bool) async throws {
    let fixture = try SimulatedExecution(configure: {
      $0.entries[SimulatedExecution.leaf.pid] = .init(
        identity: SimulatedExecution.leaf, parentUniqueID: unreadable ? 999 : 1,
        group: 0, session: 0, state: .zombie)
      $0.zombieUnreadable = unreadable
      $0.zombieOnKill = true
    })
    fixture.rootExited()
    _ = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(750)))
    }
    #expect(fixture.processes.state.entries[SimulatedExecution.leaf.pid]?.state == .zombie)
    #expect(fixture.markerExists)
    fixture.processes.mutate { $0.entries[SimulatedExecution.leaf.pid] = nil }
    #expect(try await fixture.owner.wait().status == 23)
    #expect(!fixture.markerExists)
  }

  @Test(arguments: [false, true])
  func sandboxClassifiesOnlyAfterRootExitOrCancellation(cancel: Bool) async throws {
    let gate = InspectionGate()
    defer { gate.release() }
    let fixture = try SimulatedExecution(configure: { $0.beforeList = { gate.block() } })
    #expect(
      try await fixture.owner.members() == [
        .init(processID: SimulatedExecution.root.pid, identity: SimulatedExecution.root.uniqueID)
      ])
    // Let the observation timer run; it must not classify a running sandbox.
    try await Task.sleep(for: .milliseconds(75))
    #expect(fixture.processes.state.listCount == 0)
    if cancel { fixture.owner.requestCancellation() } else { fixture.rootExited() }
    try await eventually { gate.entered }
    fixture.clear()
    gate.release()
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test(arguments: [false, true])
  func fullAccessExitDuringInspectionDoesNotWaitForTimer(cancel: Bool) async throws {
    let gate = InspectionGate()
    let fixture = try SimulatedExecution(
      sandboxed: false, observationInterval: .seconds(60),
      configure: {
        $0.entries[SimulatedExecution.leaf.pid] = nil
        $0.beforeGroup = { gate.block() }
      })
    let observation = Task { try await fixture.owner.members() }
    let completed = InspectionGate()
    let waiter = Task {
      let result = try await fixture.owner.wait()
      completed.release()
      return result
    }
    defer {
      gate.release()
      fixture.clear()
      observation.cancel()
      waiter.cancel()
    }
    try await eventually { gate.entered }
    if cancel { fixture.owner.requestCancellation() }
    fixture.rootExited()
    gate.release()
    try await eventually { completed.isReleased }
    #expect(try await waiter.value.status == 23)
    #expect(try await observation.value.isEmpty)
    #expect(fixture.processes.state.listCount == 0)
  }

  @Test func fullAccessCancellationCompletesDuringGraceOnceMembersExit() async throws {
    let fixture = try SimulatedExecution(sandboxed: false, configure: { $0.exitOnTerm = true })
    _ = try await fixture.owner.members()
    fixture.rootExited()
    #expect(
      try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(350))).status == 23)
    #expect(!fixture.processes.state.signals.isEmpty)
    #expect(fixture.processes.state.signals.allSatisfy { $0.1 == SIGTERM })
    #expect(fixture.processes.state.listCount == 0)
  }

  @Test func fullAccessNonemptyUnanchoredGroupCannotConfirmCompletion() async throws {
    let fixture = try SimulatedExecution(
      sandboxed: false,
      configure: { state in
        state.entries[SimulatedExecution.leaf.pid] = .init(
          identity: SimulatedExecution.leaf, parentUniqueID: 999,
          group: SimulatedExecution.root.pid, session: SimulatedExecution.root.pid, state: .running)
      })
    fixture.rootExited()
    let failure = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(failure.bestEffort)
    #expect(failure.reasons.contains { $0.contains("ownership anchor") })
    #expect(fixture.processes.state.signals.isEmpty)
    fixture.clear()
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test func fullAccessDepartedAnchorDoesNotAcquireReusedGroup() async throws {
    let replacement = DarwinProcessIdentity(pid: 1_000_004, uniqueID: 4)
    let fixture = try SimulatedExecution(
      sandboxed: false,
      configure: { state in
        state.departGroupOnConfirmation = true
        state.entries[replacement.pid] = .init(
          identity: replacement, parentUniqueID: 999,
          group: SimulatedExecution.root.pid, session: SimulatedExecution.root.pid, state: .running)
      })
    fixture.rootExited()
    let failure = try await fixture.failure {
      try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(150)))
    }
    #expect(failure.bestEffort)
    #expect(fixture.processes.state.entries[SimulatedExecution.leaf.pid]?.group == 0)
    #expect(!fixture.processes.state.signals.contains { $0.0 == replacement })
    fixture.clear()
    #expect(try await fixture.owner.wait().status == 23)
  }

  @Test(arguments: [false, true])
  func completionWaitsForRevocationDispatch(sandboxed: Bool) async throws {
    let gate = InspectionGate()
    defer { gate.release() }
    let fixture = try SimulatedExecution(sandboxed: sandboxed)
    fixture.owner.onCancellation { gate.block() }
    DispatchQueue(label: "test.execution-revocation").async {
      fixture.owner.requestCancellation()
    }
    try await eventually { gate.entered }
    fixture.clear()
    _ = try await fixture.failure {
      try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(650)))
    }
    #expect(fixture.markerExists == sandboxed)
    gate.release()
    #expect(try await fixture.owner.wait().status == 23)
    #expect(!fixture.markerExists)
  }

}

final class SimulatedExecution: Sendable {
  static let root = DarwinProcessIdentity(pid: 1_000_001, uniqueID: 1)
  static let leaf = DarwinProcessIdentity(pid: 1_000_002, uniqueID: 2)
  let processes = SimulatedProcessTable()
  let owner: DarwinExecutionOwnership
  private let markerPath: String?

  init(
    sandboxed: Bool = true, observationInterval: DispatchTimeInterval = .milliseconds(25),
    configure: (inout SimulatedProcessTable.State) -> Void = { _ in }
  )
    throws
  {
    processes.mutate(configure)
    let marker = try sandboxed ? ExecutionSandboxMarker() : nil
    markerPath = marker?.own.value
    owner = DarwinExecutionOwnership(
      marker: marker, sentinel: sandboxed ? SimulatedProcessTable.sentinel() : nil,
      table: processes.table, observationInterval: observationInterval)
    try owner.launched(Self.root)
  }

  var markerExists: Bool { markerPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

  func rootExited() {
    processes.mutate { $0.entries[Self.root.pid] = nil }
    owner.exited(.success(.init(status: 23)))
  }

  func clear() {
    processes.mutate { $0 = .init(entries: [:]) }
    owner.exited(.success(.init(status: 23)))
  }

  func failure(_ operation: () async throws -> ExecutionExit) async throws
    -> ExecutionCompletionFailure
  {
    do {
      _ = try await operation()
      Issue.record("Expected completion failure")
      throw CancellationError()
    } catch let failure as ExecutionCompletionFailure { return failure }
  }
}

final class SimulatedProcessTable: @unchecked Sendable {
  static let boundary = DarwinProcessSnapshot(
    identity: .init(pid: 1_000_000, uniqueID: 0), parentUniqueID: 999,
    group: 0, session: 0, state: .zombie)
  static func sentinel() -> DarwinExecutionSentinel {
    .init(identity: boundary.identity, reap: {})
  }
  struct State {
    var entries: [pid_t: DarwinProcessSnapshot] = [
      SimulatedExecution.root.pid: .init(
        identity: SimulatedExecution.root, parentUniqueID: 0,
        group: SimulatedExecution.root.pid, session: SimulatedExecution.root.pid, state: .running),
      SimulatedExecution.leaf.pid: .init(
        identity: SimulatedExecution.leaf, parentUniqueID: 1,
        group: SimulatedExecution.root.pid, session: SimulatedExecution.root.pid, state: .running),
    ]
    var beforeList: (@Sendable () -> Void)?
    var beforeRead: (@Sendable () -> Void)?
    var beforeGroup: (@Sendable () -> Void)?
    var beforeSentinelRead: (@Sendable () -> Void)?
    var beforeContains: (@Sendable () -> Void)?
    var beforeSignal: (@Sendable () -> Void)?
    var onList: (@Sendable (Int) -> Void)?
    var listCount = 0
    var continuousChurn = false
    var enumerateReplacement = false
    var continuePeerOnRead = false
    var continuedPeer = false
    var raceAfterList = 0
    var forkToZombie = false
    var churn = 0
    var reuseOnList = 0
    var systemExitOnList = 0
    var changeIdentityDuringContains = false
    var replaceDuringContains = false
    var enumerationFails = false
    var readFails = false
    var unreadablePIDs: Set<pid_t> = []
    var failedSignal: Int32?
    var ignoreKill = false
    var exitOnTerm = false
    var departGroupOnConfirmation = false
    var zombieOnKill = false
    var omitMembers = false
    var omitKernel = false
    var olderZombie = false
    var exitingBeforeSZOMB = false
    var failSecondRead = false
    var reads: [pid_t: Int] = [:]
    var omitSentinel = false
    var sentinelMissing = false
    var zombieUnreadable = false
    var replaceOnSignal = false
    var rejectedSignals = 0
    var watermark: UInt64?
    var probeFails = false
    var signals: [(DarwinProcessIdentity, Int32)] = []
    var emptyScansAfterKill = 0
  }
  private let lock = NSLock()
  private var storage = State()
  var state: State { lock.withLock { storage } }
  func mutate(_ body: (inout State) -> Void) { lock.withLock { body(&storage) } }

  var table: DarwinExecutionProcessTable {
    .init(
      list: { [self] deadline, _ in
        try DarwinExecutionProcessTable.check(deadline)
        let hooks = lock.withLock {
          storage.listCount += 1
          return (storage.beforeList, storage.onList, storage.listCount)
        }
        hooks.0?()
        hooks.1?(hooks.2)
        return try lock.withLock {
          if storage.probeFails {
            throw ExecutionEnvironmentError.launchFailed("Identity probe failed")
          }
          let watermark =
            storage.watermark ?? ((storage.entries.values.map(\.identity.uniqueID).max() ?? 0) + 1)
          if storage.enumerationFails {
            throw ExecutionEnvironmentError.launchFailed("enumeration failed")
          }
          if storage.forkToZombie, storage.listCount >= storage.raceAfterList {
            storage.entries[SimulatedExecution.leaf.pid] = .init(
              identity: SimulatedExecution.leaf, parentUniqueID: 1, group: 0, session: 0,
              state: .running)
          }
          storage.reads = [:]
          var pids = Array(storage.entries.keys).sorted()
          if storage.systemExitOnList > 0, storage.listCount >= storage.raceAfterList {
            // A nonmember system process was present in the snapshot and exited before read.
            pids.append(1_000_099)
            storage.systemExitOnList -= 1
          }
          if storage.reuseOnList > 0, storage.listCount >= storage.raceAfterList,
            let parent = storage.entries.values.first(where: { $0.parentUniqueID != 999 })
          {
            let child = DarwinProcessIdentity(
              pid: parent.identity.pid + 1, uniqueID: parent.identity.uniqueID + 1)
            storage.entries[parent.identity.pid] = .init(
              identity: .init(pid: parent.identity.pid, uniqueID: parent.identity.uniqueID + 1000),
              parentUniqueID: 999, group: 0, session: 0, state: .running)
            storage.entries[child.pid] = .init(
              identity: child, parentUniqueID: parent.identity.uniqueID, group: 0, session: 0,
              state: .running)
            storage.reuseOnList -= 1
          }
          if storage.churn > 0 || storage.continuousChurn || storage.forkToZombie,
            storage.listCount >= storage.raceAfterList,
            let parent = storage.entries.values.first(where: { $0.state == .running })
          {
            let child = DarwinProcessIdentity(
              pid: parent.identity.pid + 1, uniqueID: parent.identity.uniqueID + 1)
            if storage.forkToZombie {
              storage.forkToZombie = false
              storage.entries[parent.identity.pid] = .init(
                identity: parent.identity, parentUniqueID: parent.parentUniqueID,
                group: 0, session: 0, state: .zombie)
            } else {
              storage.entries[parent.identity.pid] = nil
            }
            storage.entries[child.pid] = .init(
              identity: child, parentUniqueID: parent.identity.uniqueID, group: 0, session: 0,
              state: .running)
            if storage.churn > 0 { storage.churn -= 1 }
            if storage.enumerateReplacement { pids = [child.pid] }
          }
          if !storage.entries.values.contains(where: { $0.parentUniqueID != 999 })
            && storage.signals.contains(where: { $0.1 == SIGKILL })
          {
            storage.emptyScansAfterKill += 1
          }
          return .init(
            pids: (storage.omitMembers ? [] : pids) + (storage.omitKernel ? [] : [0])
              + (storage.exitingBeforeSZOMB ? [1_000_098] : [])
              + (storage.omitSentinel || storage.sentinelMissing
                ? [] : [Self.boundary.identity.pid]) + (storage.olderZombie ? [1_000_099] : []),
            watermark: watermark)
        }
      },
      read: { [self] pid in
        if pid == Self.boundary.identity.pid {
          lock.withLock { storage.beforeSentinelRead }?()
          return lock.withLock { storage.sentinelMissing ? nil : Self.boundary }
        }
        lock.withLock { storage.beforeRead }?()
        return try lock.withLock {
          if pid == 1_000_099, storage.olderZombie {
            throw ExecutionEnvironmentError.launchFailed("Older zombie must not be inspected")
          }
          if pid == 1_000_098, storage.exitingBeforeSZOMB {
            return .init(
              identity: .init(pid: pid, uniqueID: 0), parentUniqueID: 999,
              group: 0, session: 0, state: .running)
          }
          storage.reads[pid, default: 0] += 1
          if storage.departGroupOnConfirmation, storage.reads[pid] == 2,
            pid == SimulatedExecution.leaf.pid, let process = storage.entries[pid]
          {
            storage.entries[pid] = .init(
              identity: process.identity, parentUniqueID: process.parentUniqueID,
              group: 0, session: 0, state: .running)
          }
          if storage.failSecondRead, storage.reads[pid] == 2 {
            throw ExecutionEnvironmentError.launchFailed("Second identity read failed")
          }
          if storage.continuePeerOnRead, let current = storage.entries[pid],
            current.parentUniqueID != 999
          {
            // Whichever peer is observed stops itself after waking the other peer.
            for (otherPID, other) in storage.entries where other.parentUniqueID != 999 {
              storage.entries[otherPID] = .init(
                identity: other.identity, parentUniqueID: other.parentUniqueID,
                group: other.group, session: other.session,
                state: otherPID == pid ? .stopped : .running)
            }
            storage.continuedPeer = true
          }
          if storage.readFails || storage.unreadablePIDs.contains(pid)
            || (storage.zombieUnreadable && storage.entries[pid]?.state == .zombie)
          {
            throw ExecutionEnvironmentError.launchFailed("unreadable process table")
          }
          return storage.entries[pid]
        }
      },
      signal: { [self] target, signal in
        let identity = target.identity
        lock.withLock { storage.beforeSignal }?()
        return lock.withLock {
          if storage.replaceOnSignal, signal == SIGKILL {
            storage.replaceOnSignal = false
            storage.entries[identity.pid] = .init(
              identity: .init(pid: identity.pid, uniqueID: identity.uniqueID + 1000),
              parentUniqueID: 999, group: 0, session: 0, state: .running,
              version: target.version &+ 1)
          }
          guard let process = storage.entries[identity.pid], process.identity == identity,
            process.version == target.version
          else {
            storage.rejectedSignals += 1
            return ESRCH
          }
          storage.signals.append((identity, signal))
          if storage.failedSignal == signal { return EPERM }
          if signal == SIGTERM && storage.exitOnTerm { storage.entries[identity.pid] = nil }
          if signal == SIGKILL {
            if storage.zombieOnKill {
              storage.entries[identity.pid] = .init(
                identity: identity, parentUniqueID: process.parentUniqueID, group: process.group,
                session: process.session, state: .zombie)
            } else if !storage.ignoreKill {
              storage.entries[identity.pid] = nil
            }
          }
          return 0
        }
      },
      contains: { [self] pid, _ in
        lock.withLock { storage.beforeContains }?()
        return lock.withLock {
          if pid == 1_000_098 { return false }
          let belongs = storage.entries[pid]?.parentUniqueID != 999
          if storage.changeIdentityDuringContains, let process = storage.entries[pid] {
            storage.entries[pid] = .init(
              identity: .init(pid: pid, uniqueID: process.identity.uniqueID + 1),
              parentUniqueID: process.parentUniqueID, group: process.group,
              session: process.session,
              state: process.state)
          }
          if storage.replaceDuringContains, storage.listCount >= storage.raceAfterList,
            let process = storage.entries[pid]
          {
            storage.replaceDuringContains = false
            storage.entries[pid] = .init(
              identity: .init(pid: pid, uniqueID: process.identity.uniqueID + 1000),
              parentUniqueID: 999, group: 0, session: 0, state: .running)
            let child = DarwinProcessIdentity(pid: pid + 1, uniqueID: process.identity.uniqueID + 1)
            storage.entries[child.pid] = .init(
              identity: child, parentUniqueID: process.identity.uniqueID,
              group: 0, session: 0, state: .running)
          }
          return belongs
        }
      },
      group: { [self] group in
        lock.withLock { storage.beforeGroup }?()
        return lock.withLock {
          if storage.departGroupOnConfirmation { storage.reads = [:] }
          return storage.entries.values.filter { $0.group == group }.map(\.identity.pid)
        }
      })
  }
}

/// Blocks only the inspection worker, never the async test executor or the simulated table lock.
final class InspectionGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var waiting = false
  private var released = false
  var entered: Bool { lock.withLock { waiting } }
  var isReleased: Bool { lock.withLock { released } }
  func block() {
    let shouldWait = lock.withLock {
      if released { return false }
      waiting = true
      return true
    }
    if shouldWait { semaphore.wait() }
  }
  func release() {
    lock.withLock {
      if !released {
        released = true
        semaphore.signal()
      }
    }
  }
}

func eventually(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !condition() {
    try #require(ContinuousClock.now < deadline, "Expected background state was not reached")
    try await Task.sleep(for: .milliseconds(10))
  }
}
