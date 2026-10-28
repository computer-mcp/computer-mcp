import Foundation

package enum ExecutionLaunchMethod: String, CaseIterable, Sendable {
  case posixSpawn
  case subprocess
  case foundation
}

package enum ExecutionMode: Sendable {
  case sandbox(SandboxConfiguration)
  case fullAccess
}

package struct ExecutionCommand: Sendable {
  package let executable: SandboxPath
  package let arguments: [String]
  package let directory: SandboxPath
  /// Borrowed until start returns; used before any stdio descriptor remapping.
  package let directoryDescriptor: Int32?
  /// Destination-to-source mappings, borrowed until start returns.
  package let inheritedDescriptors: [Int32: Int32]
  package let environment: [String: String]

  package init(
    executable: SandboxPath, arguments: [String], directory: SandboxPath,
    environment: [String: String], directoryDescriptor: Int32? = nil,
    inheritedDescriptors: [Int32: Int32] = [:]
  ) {
    self.executable = executable
    self.arguments = arguments
    self.directory = directory
    self.directoryDescriptor = directoryDescriptor
    self.inheritedDescriptors = inheritedDescriptors
    self.environment = environment
  }
}

package struct ExecutionExit: Sendable, Equatable {
  package let status: Int32
  package let signal: Int32?

  package init(status: Int32, signal: Int32? = nil) {
    self.status = status
    self.signal = signal
  }
}

package struct ExecutionMember: Codable, Hashable, Sendable {
  package let processID: Int32
  /// Stable across exec; distinct for each use of a PID.
  package let identity: UInt64

  package init(processID: Int32, identity: UInt64) {
    self.processID = processID
    self.identity = identity
  }
}

/// A best-effort OS report attributed to this execution; permission policy decides whether a
/// request is useful. It cannot change the execution's existing sandbox or replay its operation.
package struct ExecutionSandboxViolation: Sendable, Equatable {
  package let operation: String
  package let path: String

  package init(operation: String, path: String) {
    self.operation = operation
    self.path = path
  }
}

/// Persisted before the bootstrap releases its target. Backend data is ownership
/// evidence, never permission to launch or to expose an execution's results.
package struct ExecutionRecoveryState: Codable, Sendable {
  package let root: ExecutionMember
  package let sandboxed: Bool
  package let backend: String
  package let payload: Data?

  package init(root: ExecutionMember, sandboxed: Bool, backend: String, payload: Data? = nil) {
    self.root = root
    self.sandboxed = sandboxed
    self.backend = backend
    self.payload = payload
  }
}

/// Only the caller's wait ended; ownership and cleanup remain live.
package struct ExecutionWaitExpired: Error, Sendable, CustomStringConvertible {
  package let ownership: any ExecutionOwnership

  package init(ownership: any ExecutionOwnership) { self.ownership = ownership }

  package var description: String { "Execution wait deadline expired" }
}

/// Ownership or termination could not be confirmed; execution resources remain retained.
package struct ExecutionCompletionFailure: Error, Sendable, CustomStringConvertible {
  package struct Member: Sendable {
    package let process: ExecutionMember
    package let reason: String

    package init(process: ExecutionMember, reason: String) {
      self.process = process
      self.reason = reason
    }
  }

  /// The same handle is available even when a convenience run or cancelled start fails.
  package let ownership: any ExecutionOwnership
  package let members: [Member]
  package let reasons: [String]
  package let bestEffort: Bool

  package init(
    ownership: any ExecutionOwnership, members: [Member], reasons: [String], bestEffort: Bool
  ) {
    self.ownership = ownership
    self.members = members
    self.reasons = reasons
    self.bestEffort = bestEffort
  }

  package var description: String {
    let details = members.map {
      "PID \($0.process.processID) [\($0.process.identity)]: \($0.reason)"
    }
    let scope = bestEffort ? ["Full access membership is best effort"] : []
    return (["Execution completion could not be confirmed"] + scope + reasons + details).joined(
      separator: "; ")
  }
}

/// Retains execution resources through confirmed completion. Full access membership is a
/// best-effort observation of the execution's process group and known descendant identities.
/// Each caller's deadline ends only its own wait. Ownership failures reach all pending waiters;
/// resources remain retained while background cleanup and observation continue.
package protocol ExecutionOwnership: Sendable {
  func recoveryState() throws -> ExecutionRecoveryState
  /// Installed during bindOwnership; invoked before the target can execute.
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void)

  /// Installed before launch. Missing, untrusted or unattributable reports produce no callback.
  func onSandboxViolation(_ handler: @escaping @Sendable (ExecutionSandboxViolation) -> Void)

  /// Return identities whose exit is unconfirmed, including after a deadline. Running sandboxes
  /// return known identities; classification begins after root exit or cancellation.
  func members() async throws -> [ExecutionMember]
  /// Register a nonblocking revocation callback before handing the execution to its caller.
  /// Invoked outside the owner lock at cancellation entry, or when bound to a cancelled execution
  /// whose completion is still unconfirmed.
  /// The owner retains the callback and its resources through confirmed completion.
  func onCancellation(_ handler: @escaping @Sendable () -> Void)
  /// TERM, a 500 ms grace interval, then identity-checked KILL rounds. Full access can complete
  /// during grace once its known PIDs have exited and the group is empty. Sandbox completion
  /// requires a fully classified snapshot.
  /// The deadline bounds this caller's wait, independently of the backend's termination budget.
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit
  /// A confirmed failed launch returns its collected exit here; the start operation
  /// reports the launch error separately. Only unconfirmed completion may throw.
  /// Cancelling a waiter requests bounded cancellation. A timeout throws
  /// ExecutionWaitExpired; callers must retain execution resources and may retry.
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit
  /// Waits without a caller deadline. Ownership failures still propagate.
  func wait() async throws -> ExecutionExit
}

extension ExecutionOwnership {
  package func onSandboxViolation(
    _ handler: @escaping @Sendable (ExecutionSandboxViolation) -> Void
  ) {}

  package func recoveryState() throws -> ExecutionRecoveryState {
    throw ExecutionEnvironmentError.unavailable("Durable execution ownership is unavailable")
  }
  package func cancel() async throws -> ExecutionExit {
    try await cancel(until: .now.advanced(by: .seconds(5)))
  }

  package func wait() async throws -> ExecutionExit {
    while true {
      do {
        return try await wait(until: .now.advanced(by: .seconds(120)))
      } catch is ExecutionWaitExpired { continue }
    }
  }
}

/// Streams are caller-owned descriptors, duplicated before start returns.
/// bindOwnership installs nonblocking lifecycle callbacks before spawning any process.
package protocol ExecutionPlatform: Sendable {
  var supportsRecovery: Bool { get }
  /// Unconfined process groups, stable identity checks and restart interruption.
  /// This does not promise ownership of descendants that escape observation.
  var supportsBestEffortOwnership: Bool { get }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool
  var bootSessionID: String? { get }
  var hostSystemReadPaths: [SandboxPath] { get }
  func interrupt(_ members: [ExecutionMember]) async throws
  func releaseRecovery(_ state: ExecutionRecoveryState) throws
  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership
  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership
}

extension ExecutionPlatform {
  package func releaseRecovery(_ state: ExecutionRecoveryState) throws {}
  package func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    throw ExecutionEnvironmentError.unavailable("Durable execution recovery is unavailable")
  }
  package func supportsDurableOwnership(sandboxed: Bool) -> Bool { false }
  package var supportsRecovery: Bool { false }
  package var supportsBestEffortOwnership: Bool { false }
  package var bootSessionID: String? { nil }
  package var hostSystemReadPaths: [SandboxPath] { [] }
  package func interrupt(_ members: [ExecutionMember]) async throws {
    guard members.isEmpty else {
      throw ExecutionEnvironmentError.unavailable("Execution recovery is unavailable")
    }
  }
}

package struct UnsupportedExecutionPlatform: ExecutionPlatform {
  package init() {}

  package func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?,
    method: ExecutionLaunchMethod, input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    if sandbox != nil {
      throw ExecutionEnvironmentError.unavailable(
        "Sandbox execution is unavailable: the Linux bubblewrap backend has not been implemented")
    }
    throw ExecutionEnvironmentError.unavailable(
      "Full access execution requires a platform launcher with privacy responsibility separation")
  }
}
