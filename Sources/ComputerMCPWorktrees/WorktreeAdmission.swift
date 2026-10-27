import ComputerMCPPlatformPOSIX
import Foundation

/// A durable writer reservation survives its host's OS locks. An unknown or
/// unacknowledged reservation prevents destruction, including after host death.
package struct WorktreeWriterUse: Codable, Equatable, Sendable {
  package let admission: WorktreeAdmission
  package let ownerID: UUID
  package let executionID: UUID
}

/// Minted from verified topology. The short gate lock is never held while
/// waiting for execution, Git, a repository lock, or a database transaction.
package struct WorktreeAdmission: Codable, Equatable, Sendable {
  package let projectID: String
  package let generation: UUID
  private let directory: WorktreeDirectoryIdentity

  private struct State: Codable, Equatable {
    let projectID: String
    let generation: UUID
    var closedBy: UUID?
    var writers: [UUID: UUID] = [:]
  }

  init(topology: VerifiedWorktreeTopology) throws {
    try topology.verifyDirectories()
    projectID = topology.projectID
    generation = topology.generation
    let parent = try topology.common.child("computer-mcp", create: true)
      .child("admission", create: true)
    let name = generation.uuidString.lowercased()
    let created: Bool
    do {
      directory = try parent.child(name, create: true, exclusive: true).identity
      created = true
    } catch let error as POSIXError where error.code == .EEXIST {
      directory = try parent.child(name).identity
      created = false
    }
    try transaction(create: created) { _ in }
  }

  private func transaction<T>(create: Bool = false, _ body: (inout State) throws -> T) throws -> T {
    let opened = try WorktreeDirectory(URL(fileURLWithPath: directory.path))
    guard opened.identity == directory else {
      throw WorktreeError.identityChanged("Worktree admission directory changed.")
    }
    let gate: FileLock
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while true {
      try Task.checkCancellation()
      do {
        gate = try FileLock(
          path: opened.url.appendingPathComponent("gate.lock").path, mode: .exclusive)
        break
      } catch FileLockError.held {
        guard ContinuousClock.now < deadline else {
          throw WorktreeError.busy("Worktree admission is changing; retry the operation.")
        }
        Thread.sleep(forTimeInterval: 0.002)
      }
    }
    defer { gate.release() }
    let io = WorktreeJournalIO()
    let previous = try io.read("state.json", in: opened, limit: 4_194_304)
    guard previous != nil || create else {
      throw WorktreeError.recoveryRequired("Worktree admission state is missing.")
    }
    var state =
      try previous.map { try JSONDecoder().decode(State.self, from: $0) }
      ?? State(projectID: projectID, generation: generation)
    guard state.projectID == projectID, state.generation == generation else {
      throw WorktreeError.identityChanged("Worktree admission identity changed.")
    }
    let original = state
    let result = try body(&state)
    try gate.verifyIdentity()
    guard previous == nil || state != original else { return result }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(state)
    guard bytes.count <= 4_194_304 else {
      throw WorktreeError.busy("Worktree writer ledger exceeded its bound.")
    }
    try io.write(bytes, name: "state.json", in: opened, replacing: previous)
    return result
  }

  /// Called before a prepared context can execute any mutation or launch.
  package func reserve(ownerID: UUID, executionID: UUID) throws -> WorktreeWriterUse {
    try transaction { state in
      guard state.closedBy == nil else {
        throw WorktreeError.busy("Worktree admission is closed for removal or recovery.")
      }
      guard state.writers[executionID] == nil else {
        throw WorktreeError.recoveryRequired("Writer reservation already exists.")
      }
      state.writers[executionID] = ownerID
    }
    return .init(admission: self, ownerID: ownerID, executionID: executionID)
  }

  package func requireOpen(_ use: WorktreeWriterUse) throws {
    try transaction { state in
      guard use.admission == self, state.closedBy == nil,
        state.writers[use.executionID] == use.ownerID
      else { throw WorktreeError.busy("Worktree writer admission is closed.") }
    }
  }

  /// Only confirmed execution completion may acknowledge its reservation. A
  /// failed acknowledgement retains the reservation for the same owner's recovery.
  package func acknowledge(_ use: WorktreeWriterUse) throws {
    try transaction { state in
      guard use.admission == self else {
        throw WorktreeError.identityChanged("Writer belongs to another worktree.")
      }
      if let owner = state.writers[use.executionID] {
        guard owner == use.ownerID else {
          throw WorktreeError.identityChanged("Writer ownership changed.")
        }
        state.writers[use.executionID] = nil
      }
    }
  }

  /// The caller holds the repository lock through destruction. Repeating the
  /// same operation recovers its closed gate; another operation cannot take it.
  package func close(operationID: UUID) throws -> [WorktreeWriterUse] {
    try transaction { state in
      guard state.closedBy == nil || state.closedBy == operationID else {
        throw WorktreeError.recoveryRequired("Another operation owns the closed admission gate.")
      }
      state.closedBy = operationID
      return state.writers.map {
        .init(admission: self, ownerID: $0.value, executionID: $0.key)
      }
    }
  }

  package func requireDrained(operationID: UUID) throws {
    try transaction { state in
      guard state.closedBy == operationID, state.writers.isEmpty else {
        throw WorktreeError.busy("Worktree writers have not all confirmed termination.")
      }
    }
  }

  /// A failed dirty check can retain the worktree after termination. Reopening
  /// requires the same operation and complete writer acknowledgement.
  package func reopen(operationID: UUID) throws {
    try transaction { state in
      guard state.closedBy != nil else { return }
      guard state.closedBy == operationID, state.writers.isEmpty else {
        throw WorktreeError.recoveryRequired("Cannot reopen an unresolved worktree admission.")
      }
      state.closedBy = nil
    }
  }
}

extension WorktreeRepository {
  package func admission(projectID: String) throws -> WorktreeAdmission {
    try WorktreeAdmission(topology: topology(projectID: projectID))
  }
}
