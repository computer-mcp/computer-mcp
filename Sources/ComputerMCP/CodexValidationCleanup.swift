import Foundation

enum CodexValidationPhase: String, Codable, CaseIterable, Sendable {
  case primaryAcceptance = "primary_acceptance"
  case threadFinish = "thread_finish"
  case unsubscribeRelease = "unsubscribe_release"
  case runtimeStop = "runtime_stop"
  case processReap = "process_reap"
  case worktreeCleanup = "worktree_cleanup"
  case finalDiagnostics = "final_diagnostics"
}

struct CodexValidationDeadlines: Equatable, Sendable {
  let primaryAcceptanceMilliseconds: Int
  let threadFinishMilliseconds: Int
  let unsubscribeReleaseMilliseconds: Int
  let runtimeStopMilliseconds: Int
  let processReapMilliseconds: Int
  let worktreeCleanupMilliseconds: Int
  let finalDiagnosticsMilliseconds: Int

  init(
    primaryAcceptanceMilliseconds: Int = 300_000,
    threadFinishMilliseconds: Int = 30_000,
    unsubscribeReleaseMilliseconds: Int = 15_000,
    runtimeStopMilliseconds: Int = 10_000,
    processReapMilliseconds: Int = 5_000,
    worktreeCleanupMilliseconds: Int = 15_000,
    finalDiagnosticsMilliseconds: Int = 10_000
  ) {
    self.primaryAcceptanceMilliseconds = Self.bounded(primaryAcceptanceMilliseconds)
    self.threadFinishMilliseconds = Self.bounded(threadFinishMilliseconds)
    self.unsubscribeReleaseMilliseconds = Self.bounded(unsubscribeReleaseMilliseconds)
    self.runtimeStopMilliseconds = Self.bounded(runtimeStopMilliseconds)
    self.processReapMilliseconds = Self.bounded(processReapMilliseconds)
    self.worktreeCleanupMilliseconds = Self.bounded(worktreeCleanupMilliseconds)
    self.finalDiagnosticsMilliseconds = Self.bounded(finalDiagnosticsMilliseconds)
  }

  func milliseconds(for phase: CodexValidationPhase) -> Int {
    switch phase {
    case .primaryAcceptance: primaryAcceptanceMilliseconds
    case .threadFinish: threadFinishMilliseconds
    case .unsubscribeRelease: unsubscribeReleaseMilliseconds
    case .runtimeStop: runtimeStopMilliseconds
    case .processReap: processReapMilliseconds
    case .worktreeCleanup: worktreeCleanupMilliseconds
    case .finalDiagnostics: finalDiagnosticsMilliseconds
    }
  }

  private static func bounded(_ value: Int) -> Int {
    max(1, min(value, 3_600_000))
  }
}

struct CodexValidationCleanupTarget: Codable, Equatable, Sendable {
  let owner: CodexRuntimeOwner?
  let workspacePath: String
  let threadID: String?
  let runtimeID: String?
  let processID: Int32?
  let managedWorktreeID: String?

  private enum CodingKeys: String, CodingKey {
    case owner
    case workspacePath = "workspace_path"
    case threadID = "thread_id"
    case runtimeID = "runtime_id"
    case processID = "process_id"
    case managedWorktreeID = "managed_worktree_id"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

struct CodexValidationPhaseOperation: Sendable {
  let phase: CodexValidationPhase
  let run: @Sendable () async throws -> JSONValue

  init(
    phase: CodexValidationPhase,
    run: @escaping @Sendable () async throws -> JSONValue
  ) {
    self.phase = phase
    self.run = run
  }
}

enum CodexValidationPhaseStatus: String, Codable, Sendable {
  case completed
  case warning
  case skipped
}

struct CodexValidationPhaseResult: Codable, Equatable, Sendable {
  let phase: CodexValidationPhase
  let status: CodexValidationPhaseStatus
  let deadlineMilliseconds: Int
  let elapsedMilliseconds: Double
  let evidence: JSONValue?
  let warning: String?
  let safeManualAction: String?

  private enum CodingKeys: String, CodingKey {
    case phase
    case status
    case deadlineMilliseconds = "deadline_milliseconds"
    case elapsedMilliseconds = "elapsed_milliseconds"
    case evidence
    case warning
    case safeManualAction = "safe_manual_action"
  }
}

struct CodexValidationCleanupReport: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let target: CodexValidationCleanupTarget
  let phases: [CodexValidationPhaseResult]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case target
    case phases
  }

  var warnings: [CodexValidationPhaseResult] {
    phases.filter { $0.status == .warning }
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

struct CodexValidationOutcome<Value: Sendable>: Sendable {
  let value: Value
  let cleanup: CodexValidationCleanupReport
}

struct CodexValidationRunError: Error, LocalizedError, Sendable {
  let primaryFailure: String
  let cleanup: CodexValidationCleanupReport

  var errorDescription: String? {
    let suffix =
      cleanup.warnings.isEmpty
      ? "Cleanup completed without warnings."
      : "Cleanup produced \(cleanup.warnings.count) bounded warning(s)."
    return "Primary acceptance failed: \(primaryFailure) \(suffix)"
  }
}

enum CodexValidationCleanupError: Error, LocalizedError, Equatable, Sendable {
  case duplicatePhase(CodexValidationPhase)
  case invalidPrimaryOperation
  case deadlineExceeded(CodexValidationPhase, Int)
  case runtimeOwnershipMismatch(String)
  case processOwnershipMismatch(expected: Int32, actual: Int32?)

  var errorDescription: String? {
    switch self {
    case .duplicatePhase(let phase):
      return "Validation cleanup phase '\(phase.rawValue)' was configured more than once."
    case .invalidPrimaryOperation:
      return "Primary acceptance must be supplied through the primary operation."
    case .deadlineExceeded(let phase, let milliseconds):
      return
        "Validation phase '\(phase.rawValue)' exceeded its \(milliseconds)-millisecond deadline."
    case .runtimeOwnershipMismatch(let runtimeID):
      return
        "Runtime '\(runtimeID)' is not the exact Computer MCP runtime named by the cleanup target."
    case .processOwnershipMismatch(let expected, let actual):
      return
        "Runtime process ownership changed: expected \(expected), observed \(actual.map(String.init) ?? "none")."
    }
  }
}

enum CodexValidationCleanupCoordinator {
  static func run<Value: Sendable>(
    target: CodexValidationCleanupTarget,
    deadlines: CodexValidationDeadlines = CodexValidationDeadlines(),
    cleanupOperations: [CodexValidationPhaseOperation],
    primary: @escaping @Sendable () async throws -> Value
  ) async throws -> CodexValidationOutcome<Value> {
    let operationsByPhase = try indexed(cleanupOperations)
    let primaryResult: Result<Value, Error>
    do {
      primaryResult = .success(
        try await withDeadline(
          phase: .primaryAcceptance,
          milliseconds: deadlines.milliseconds(for: .primaryAcceptance),
          operation: primary
        )
      )
    } catch {
      primaryResult = .failure(error)
    }

    var phaseResults: [CodexValidationPhaseResult] = []
    for phase in CodexValidationPhase.allCases where phase != .primaryAcceptance {
      guard let operation = operationsByPhase[phase] else {
        phaseResults.append(
          CodexValidationPhaseResult(
            phase: phase,
            status: .skipped,
            deadlineMilliseconds: deadlines.milliseconds(for: phase),
            elapsedMilliseconds: 0,
            evidence: nil,
            warning: nil,
            safeManualAction: nil
          )
        )
        continue
      }
      phaseResults.append(
        await runCleanupPhase(
          operation,
          target: target,
          milliseconds: deadlines.milliseconds(for: phase)
        )
      )
    }
    let cleanup = CodexValidationCleanupReport(
      schemaVersion: 1,
      target: target,
      phases: phaseResults
    )
    switch primaryResult {
    case .success(let value):
      return CodexValidationOutcome(value: value, cleanup: cleanup)
    case .failure(let error):
      throw CodexValidationRunError(
        primaryFailure: boundedRedactedError(error),
        cleanup: cleanup
      )
    }
  }

  static func ownedRuntimeStopOperation(
    runtime: LiveCodexAppServerRuntime,
    target: CodexValidationCleanupTarget
  ) -> CodexValidationPhaseOperation {
    CodexValidationPhaseOperation(phase: .runtimeStop) {
      guard target.runtimeID == runtime.runtimeID else {
        throw CodexValidationCleanupError.runtimeOwnershipMismatch(runtime.runtimeID)
      }
      guard target.owner == runtime.owner else {
        throw CodexValidationCleanupError.runtimeOwnershipMismatch(runtime.runtimeID)
      }
      let status = await runtime.status()
      let actualProcessID = status.objectValue?["process"]?.objectValue?["process_id"]?.intValue
        .flatMap(Int32.init)
      if let expectedProcessID = target.processID, actualProcessID != expectedProcessID {
        throw CodexValidationCleanupError.processOwnershipMismatch(
          expected: expectedProcessID,
          actual: actualProcessID
        )
      }
      await runtime.shutdown()
      return .object([
        "runtime_id": .string(runtime.runtimeID),
        "process_id": actualProcessID.map { .number(Double($0)) } ?? .null,
        "action": .string("stopped_exact_computer_mcp_runtime"),
      ])
    }
  }

  private static func indexed(
    _ operations: [CodexValidationPhaseOperation]
  ) throws -> [CodexValidationPhase: CodexValidationPhaseOperation] {
    var indexed: [CodexValidationPhase: CodexValidationPhaseOperation] = [:]
    for operation in operations {
      guard operation.phase != .primaryAcceptance else {
        throw CodexValidationCleanupError.invalidPrimaryOperation
      }
      guard indexed.updateValue(operation, forKey: operation.phase) == nil else {
        throw CodexValidationCleanupError.duplicatePhase(operation.phase)
      }
    }
    return indexed
  }

  private static func runCleanupPhase(
    _ operation: CodexValidationPhaseOperation,
    target: CodexValidationCleanupTarget,
    milliseconds: Int
  ) async -> CodexValidationPhaseResult {
    let clock = ContinuousClock()
    let started = clock.now
    do {
      let evidence = try await withDeadline(
        phase: operation.phase,
        milliseconds: milliseconds,
        operation: operation.run
      )
      return CodexValidationPhaseResult(
        phase: operation.phase,
        status: .completed,
        deadlineMilliseconds: milliseconds,
        elapsedMilliseconds: elapsedMilliseconds(started.duration(to: clock.now)),
        evidence: evidence,
        warning: nil,
        safeManualAction: nil
      )
    } catch {
      return CodexValidationPhaseResult(
        phase: operation.phase,
        status: .warning,
        deadlineMilliseconds: milliseconds,
        elapsedMilliseconds: elapsedMilliseconds(started.duration(to: clock.now)),
        evidence: nil,
        warning: boundedRedactedError(error),
        safeManualAction: safeManualAction(for: operation.phase, target: target)
      )
    }
  }

  private static func withDeadline<Value: Sendable>(
    phase: CodexValidationPhase,
    milliseconds: Int,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let completion = CodexValidationDeadlineCompletion<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard completion.install(continuation) else { return }
        let operationTask = Task {
          do {
            completion.resolve(.success(try await operation()))
          } catch {
            completion.resolve(.failure(error))
          }
        }
        let timeoutTask = Task {
          do {
            try await Task.sleep(for: .milliseconds(milliseconds))
          } catch {
            return
          }
          completion.resolve(
            .failure(CodexValidationCleanupError.deadlineExceeded(phase, milliseconds))
          )
        }
        completion.installTasks(operation: operationTask, timeout: timeoutTask)
      }
    } onCancel: {
      completion.cancel()
    }
  }

  private static func safeManualAction(
    for phase: CodexValidationPhase,
    target: CodexValidationCleanupTarget
  ) -> String {
    let thread = target.threadID ?? "<none>"
    let runtime = target.runtimeID ?? "<none>"
    let process = target.processID.map(String.init) ?? "<none>"
    switch phase {
    case .threadFinish:
      return "Inspect thread '\(thread)' and interrupt only its active turn through Computer MCP."
    case .unsubscribeRelease:
      return
        "Retry the reviewed release for thread '\(thread)' and verify runtime '\(runtime)' no longer owns it."
    case .runtimeStop:
      return "Inspect runtime '\(runtime)' and stop only that Computer MCP-owned runtime."
    case .processReap:
      return
        "Verify runtime '\(runtime)' still owns process '\(process)' before waiting for or stopping it; do not signal any other process."
    case .worktreeCleanup:
      return
        "Use the managed-worktree removal preview for receipt '\(target.managedWorktreeID ?? "<none>")'; do not remove a path without an exact ownership receipt."
    case .finalDiagnostics:
      return
        "Collect final diagnostics for thread '\(thread)' and runtime '\(runtime)' without changing external process state."
    case .primaryAcceptance:
      return "Review the primary acceptance failure before retrying."
    }
  }

  private static func boundedRedactedError(_ error: Error) -> String {
    String(
      CodexApprovalRedactor.redactString(
        error.localizedDescription,
        maximumCharacters: 4_096
      ).prefix(4_096)
    )
  }

  private static func elapsedMilliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}

private final class CodexValidationDeadlineCompletion<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var operationTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var resolved = false
  private var resolvedResult: Result<Value, Error>?

  func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
    let result = lock.withLock { () -> Result<Value, Error>? in
      guard resolved else {
        self.continuation = continuation
        return nil
      }
      return resolvedResult
    }
    guard let result else { return true }
    continuation.resume(with: result)
    return false
  }

  func installTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
    let shouldCancel = lock.withLock { () -> Bool in
      operationTask = operation
      timeoutTask = timeout
      return resolved
    }
    if shouldCancel {
      operation.cancel()
      timeout.cancel()
    }
  }

  func resolve(_ result: Result<Value, Error>) {
    let claimed = lock.withLock {
      () -> (
        CheckedContinuation<Value, Error>?, Task<Void, Never>?, Task<Void, Never>?
      ) in
      guard !resolved else { return (nil, nil, nil) }
      resolved = true
      resolvedResult = result
      let claimed = (continuation, operationTask, timeoutTask)
      continuation = nil
      operationTask = nil
      timeoutTask = nil
      return claimed
    }
    guard let continuation = claimed.0 else { return }
    claimed.1?.cancel()
    claimed.2?.cancel()
    continuation.resume(with: result)
  }

  func cancel() {
    resolve(.failure(CancellationError()))
  }
}
