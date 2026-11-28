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

  struct RecoveryHold: Codable, Equatable, Sendable {
    let operationID: UUID
    let requestDigest: String
  }

  private struct State: Codable, Equatable {
    let projectID: String
    let generation: UUID
    var closedBy: UUID?
    var recoveryHold: RecoveryHold?
    var writers: [UUID: UUID] = [:]
    var unconfinedWriters: Set<UUID>?
    // A completed Full access program may have left an unobserved descendant.
    var hadUnconfinedWriters: Bool?
    var unconfirmedTerminations: [UUID: String]?
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

  static func existing(for topology: VerifiedWorktreeTopology) throws -> Self? {
    try topology.verifyDirectories()
    guard let host = try topology.common.childIfPresent("computer-mcp"),
      let parent = try host.childIfPresent("admission"),
      let gate = try parent.childIfPresent(topology.generation.uuidString.lowercased())
    else { return nil }
    return Self(
      projectID: topology.projectID, generation: topology.generation, directory: gate.identity)
  }

  /// Publish a complete gate for a generation that never used execution.
  /// Legacy gates keep their existing identity and fail closed on missing state.
  static func prepareRecoveryGate(
    for topology: VerifiedWorktreeTopology, reviewed: Self?, operationID: UUID,
    io: WorktreeJournalIO
  ) throws -> Self {
    try topology.verifyDirectories()
    let parent = try topology.common.child("computer-mcp", create: true)
      .child("admission", create: true)
    let name = topology.generation.uuidString.lowercased()
    func admission(in directory: WorktreeDirectory) -> Self {
      Self(
        projectID: topology.projectID, generation: topology.generation,
        directory: directory.identity)
    }
    if let current = try parent.childIfPresent(name) {
      let existing = admission(in: current)
      guard reviewed.map({ $0 == existing }) ?? true else {
        throw WorktreeError.identityChanged("Reviewed gate was substituted.")
      }
      try parent.synchronize()
      return existing
    }
    guard reviewed == nil else { throw WorktreeError.identityChanged("Reviewed gate is missing.") }
    let stagingName = ".owner-" + operationID.uuidString.lowercased() + "-" + name
    let stage =
      try parent.childIfPresent(stagingName)
      ?? parent.child(stagingName, create: true, exclusive: true)
    try admission(in: stage).transaction(create: true, synchronizeUnchanged: true, io: io) {
      state in
      guard state == State(projectID: topology.projectID, generation: topology.generation)
      else { throw invalidRecoveryMetadata() }
    }
    do {
      try io.beforePublication()
      try stage.verify()
      try topology.verifyDirectories()
      try parent.renameExclusive(stagingName, to: name)
    } catch let error as POSIXError where error.code == .EEXIST {
      // Ordinary execution may finish initializing its gate after its
      // repository topology check. Its installed gate remains authoritative.
      try parent.removeOwnedTree(stage.identity, io: io)
    }
    try io.beforeDirectorySync()
    try parent.synchronize()
    return try admission(in: parent.child(name))
  }

  private init(projectID: String, generation: UUID, directory: WorktreeDirectoryIdentity) {
    self.projectID = projectID
    self.generation = generation
    self.directory = directory
  }

  private func transaction<T>(
    create: Bool = false, existingOnly: Bool = false, synchronizeUnchanged: Bool = false,
    io: WorktreeJournalIO = .init(), _ body: (inout State) throws -> T
  ) throws -> T {
    let opened = try WorktreeDirectory(URL(fileURLWithPath: directory.path))
    guard opened.identity == directory else {
      throw WorktreeError.identityChanged("Worktree admission directory changed.")
    }
    let gate: FileLock
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while true {
      try Task.checkCancellation()
      do {
        let path = opened.url.appendingPathComponent("gate.lock").path
        gate =
          try existingOnly
          ? FileLock(lockingExisting: path)
          : FileLock(path: path, mode: .exclusive)
        break
      } catch FileLockError.held {
        guard ContinuousClock.now < deadline else {
          throw WorktreeError.busy("Worktree admission is changing; retry the operation.")
        }
        Thread.sleep(forTimeInterval: 0.002)
      }
    }
    defer { gate.release() }
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
    guard state.closedBy == nil || state.recoveryHold == nil else {
      throw invalidRecoveryMetadata()
    }
    let original = state
    let result = try body(&state)
    try gate.verifyIdentity()
    guard previous == nil || state != original else {
      if synchronizeUnchanged, let previous {
        try io.synchronize("state.json", in: opened, expecting: previous)
      }
      return result
    }
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
  package func reserve(
    ownerID: UUID, executionID: UUID, unconfined: Bool = false
  ) throws -> WorktreeWriterUse {
    try transaction { state in
      guard state.closedBy == nil, state.recoveryHold == nil else {
        throw WorktreeError.busy("Worktree admission is closed for removal or recovery.")
      }
      guard state.writers[executionID] == nil else {
        throw WorktreeError.recoveryRequired("Writer reservation already exists.")
      }
      state.writers[executionID] = ownerID
      if unconfined {
        state.unconfinedWriters = (state.unconfinedWriters ?? []).union([executionID])
        state.hadUnconfinedWriters = true
      }
    }
    return .init(admission: self, ownerID: ownerID, executionID: executionID)
  }

  package func requireOpen(_ use: WorktreeWriterUse) throws {
    try transaction { state in
      guard use.admission == self, state.closedBy == nil, state.recoveryHold == nil,
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
        state.unconfinedWriters?.remove(use.executionID)
      }
    }
  }

  /// A destructive operation may release an unconfined writer after its in-process
  /// invocation drains. The execution owner retains physical cleanup and reports uncertainty.
  package func acknowledgeUnconfined(
    _ use: WorktreeWriterUse, operationID: UUID, unconfirmedTermination: String?
  ) throws {
    try transaction { state in
      guard use.admission == self, state.closedBy == operationID else {
        throw WorktreeError.identityChanged("Unconfined writer does not belong to this operation.")
      }
      guard let owner = state.writers[use.executionID] else { return }
      guard owner == use.ownerID, state.unconfinedWriters?.contains(use.executionID) == true else {
        throw WorktreeError.identityChanged("Writer does not have best-effort ownership.")
      }
      if let unconfirmedTermination {
        var outcomes = state.unconfirmedTerminations ?? [:]
        outcomes[use.executionID] = unconfirmedTermination
        state.unconfirmedTerminations = outcomes
      }
      state.writers[use.executionID] = nil
      state.unconfinedWriters?.remove(use.executionID)
    }
  }

  package func terminationWarnings(operationID: UUID) throws -> [String] {
    try transaction { state in
      guard state.closedBy == operationID else {
        throw WorktreeError.identityChanged("Termination report belongs to another operation.")
      }
      guard state.hadUnconfinedWriters == true else { return [] }
      return [
        "Full access execution was admitted for this worktree. Descendants outside process-group observation may survive termination and still change its files."
      ]
        + (state.unconfirmedTerminations ?? [:]).sorted { $0.key.uuidString < $1.key.uuidString }
        .map {
          "Full access termination was not confirmed for execution \($0.key): \($0.value)"
        }
    }
  }

  /// The caller holds the repository lock through destruction. Repeating the
  /// same operation recovers its closed gate; another operation cannot take it.
  package func close(operationID: UUID) throws -> [WorktreeWriterUse] {
    try transaction { state in
      guard state.recoveryHold == nil, state.closedBy == nil || state.closedBy == operationID else {
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
        throw WorktreeError.busy("Worktree writers have not completed their termination barriers.")
      }
    }
  }

  func holdRecovery(_ hold: RecoveryHold, io: WorktreeJournalIO) throws {
    try transaction(existingOnly: true, synchronizeUnchanged: true, io: io) { state in
      guard state.closedBy == nil, state.writers.isEmpty,
        state.recoveryHold == nil || state.recoveryHold == hold
      else {
        throw WorktreeError.busy("Worktree admission belongs to an active writer or operation.")
      }
      state.recoveryHold = hold
    }
  }

  func clearRecovery(_ hold: RecoveryHold, io: WorktreeJournalIO) throws {
    try transaction(existingOnly: true, synchronizeUnchanged: true, io: io) { state in
      if state.recoveryHold == hold { state.recoveryHold = nil }
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
