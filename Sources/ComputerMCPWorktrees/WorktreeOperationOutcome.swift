import Foundation

/// What the durable lifecycle journals establish about one host operation. Reading
/// runs no Git and never repairs, adopts or cleans anything.
package enum WorktreeOperationOutcome: Equatable, Sendable {
  /// No journal records this operation, so it caused no lifecycle effect.
  case notStarted
  case created(CreatedWorktree)
  case removed(WorktreeRemovalResult)
  /// Removal refused uncommitted content before capture and reopened admission.
  case refused
  /// Effects began; only host journal recovery can establish the result.
  case uncertain
}

extension WorktreeStorage {
  package func creationOutcome(operationID: UUID) throws -> WorktreeOperationOutcome {
    guard
      let data = try journal(
        "worktree-" + operationID.uuidString.lowercased() + ".json", in: journals)
    else { return .notStarted }
    let journal = try JSONDecoder().decode(WorktreeCreationJournal.self, from: data)
    guard journal.operationID == operationID else { return .uncertain }
    switch journal.phase {
    case .active, .removing, .removed: return .created(journal.result)
    case .reserved, .directories, .checkout, .branch: return .uncertain
    }
  }

  package func removalOutcome(projectID: String, operationID: UUID) throws
    -> WorktreeOperationOutcome
  {
    guard
      let data = try journal(
        projectID + ".json", in: journals.appendingPathComponent("removals"))
    else { return .notStarted }
    let journal = try JSONDecoder().decode(WorktreeRemovalJournal.self, from: data)
    // A later removal journal replaces only a terminal earlier one.
    guard journal.operationID == operationID else { return .notStarted }
    switch journal.phase {
    case .finished:
      guard let oid = journal.oid, let branch = journal.record.worktree?.branch else {
        return .uncertain
      }
      return .removed(
        .init(
          projectID: journal.record.projectID, branch: branch, oid: oid,
          terminationWarnings: journal.terminationWarnings ?? []))
    case .abandoned: return .refused
    case .closing, .preserved, .content, .repository, .runtime, .unregistering: return .uncertain
    }
  }

  private func journal(_ name: String, in directory: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
    return try WorktreeJournalIO().read(name, in: WorktreeDirectory(directory), limit: 131_072)
  }
}

extension WorktreeRepository {
  /// The main checkout's current branch, captured as a lifecycle reservation's default
  /// base; nil when HEAD is detached.
  package func mainBranch() throws -> String? {
    let result = try command(["symbolic-ref", "--quiet", "HEAD"], accepting: [0, 1])
    guard result.exitCode == 0 else { return nil }
    let ref = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    guard ref.hasPrefix("refs/heads/") else {
      throw WorktreeError.invalidRequest("Invalid main branch.")
    }
    return String(ref.dropFirst("refs/heads/".count))
  }
}
