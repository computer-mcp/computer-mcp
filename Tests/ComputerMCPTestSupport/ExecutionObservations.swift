import ComputerMCPSandbox
import Foundation

package final class ExecutionObservations: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ExecutionMember] = []
  private var owners: [any ExecutionOwnership] = []
  private let beforeStart: @Sendable (ExecutionCommand) throws -> Void

  package init(beforeStart: @escaping @Sendable (ExecutionCommand) throws -> Void = { _ in }) {
    self.beforeStart = beforeStart
  }

  package var members: [ExecutionMember] { lock.withLock { values } }
  package var ownerships: [any ExecutionOwnership] { lock.withLock { owners } }

  package func bind(_ owner: any ExecutionOwnership) {
    lock.withLock { owners.append(owner) }
  }

  package func record(_ member: ExecutionMember, command: ExecutionCommand) throws {
    try beforeStart(command)
    lock.withLock { values.append(member) }
  }
}

package struct ObservedExecutionPlatform: ExecutionPlatform {
  private let base: any ExecutionPlatform
  private let observations: ExecutionObservations

  package init(base: any ExecutionPlatform, observations: ExecutionObservations) {
    self.base = base
    self.observations = observations
  }

  package var supportsRecovery: Bool { base.supportsRecovery }
  package var bootSessionID: String? { base.bootSessionID }
  package var hostSystemReadPaths: [SandboxPath] { base.hostSystemReadPaths }
  package func interrupt(_ members: [ExecutionMember]) async throws {
    try await base.interrupt(members)
  }

  package func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    try await base.start(
      command, sandbox: sandbox, method: method, input: input, output: output,
      error: error,
      bindOwnership: { owner in
        bindOwnership(owner)
        observations.bind(owner)
        owner.beforeStart { [weak observations] in try observations?.record($0, command: command) }
      })
  }
}
