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
  package let environment: [String: String]

  package init(
    executable: SandboxPath, arguments: [String], directory: SandboxPath,
    environment: [String: String]
  ) {
    self.executable = executable
    self.arguments = arguments
    self.directory = directory
    self.environment = environment
  }
}

package struct ExecutionExit: Sendable, Equatable {
  package let status: Int32

  package init(status: Int32) { self.status = status }
}

package struct ExecutionMember: Hashable, Sendable {
  package let processID: Int32
  /// Stable across exec; distinct for each use of a PID.
  package let identity: UInt64

  package init(processID: Int32, identity: UInt64) {
    self.processID = processID
    self.identity = identity
  }
}

/// Failed confirmation retains execution resources, whether caused by a deadline or lost ownership evidence.
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
/// Concurrent callers share confirmation: the earliest deadline fails all current waiters and
/// retains resources while the ownership handle continues background cleanup and observation.
package protocol ExecutionOwnership: Sendable {
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
  /// The independent deadline covers the attempt. Failure retains resources for background cleanup.
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit
  /// Cancelling a waiter requests bounded cancellation. A timeout throws
  /// ExecutionCompletionFailure; callers must retain execution resources and may retry.
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit
}

extension ExecutionOwnership {
  package func cancel() async throws -> ExecutionExit {
    try await cancel(until: .now.advanced(by: .seconds(5)))
  }

  package func wait() async throws -> ExecutionExit {
    try await wait(until: .now.advanced(by: .seconds(120)))
  }
}

/// Streams are caller-owned descriptors, duplicated before start returns.
/// bindOwnership installs nonblocking lifecycle callbacks before spawning any process.
package protocol ExecutionPlatform: Sendable {
  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership
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
