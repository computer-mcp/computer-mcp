import Foundation

package struct WorktreeInventoryItem: Sendable {
  package let path: String?
  package let projectID: String?
  package let branch: String?
  package let base: String?
  package let ahead: Int?
  package let behind: Int?
  package let dirty: Bool?
  package let unavailable: String?
}

struct WorktreeInventoryEntry {
  let path: String
  let head: String?
  let branch: String?
  let detached: Bool
  let bare: Bool
  let prunable: Bool

  static func parse(_ data: Data) throws -> [Self] {
    guard data.isEmpty || data.last == 0,
      let text = String(data: data, encoding: .utf8)
    else {
      throw WorktreeError.commandFailed("Malformed Git worktree inventory.")
    }
    var result: [Self] = []
    var fields: [String: String] = [:]
    for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
      if field.isEmpty {
        guard !fields.isEmpty else { continue }
        guard let rawPath = fields["worktree"], rawPath.hasPrefix("/"),
          case let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path,
          !result.contains(where: { $0.path == path }),
          fields["bare"] != nil
            || (fields["HEAD"] != nil && ((fields["branch"] != nil) != (fields["detached"] != nil)))
        else {
          throw WorktreeError.commandFailed("Invalid Git worktree entry.")
        }
        result.append(
          .init(
            path: path, head: fields["HEAD"], branch: fields["branch"],
            detached: fields["detached"] != nil, bare: fields["bare"] != nil,
            prunable: fields["prunable"] != nil))
        fields = [:]
      } else {
        let pair = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(pair[0])
        guard
          ["worktree", "HEAD", "branch", "detached", "bare", "locked", "prunable"].contains(key),
          fields[key] == nil
        else {
          throw WorktreeError.commandFailed("Unsupported Git worktree inventory field.")
        }
        fields[key] = pair.count == 2 ? String(pair[1]) : ""
      }
    }
    guard fields.isEmpty else {
      throw WorktreeError.commandFailed("Incomplete Git worktree entry.")
    }
    return result
  }
}

extension WorktreeRepository {
  /// The trusted adapter supplies live path visibility. Redacted entries carry no
  /// path, project or branch metadata; foreign checkouts never acquire host authority.
  package func inventory(mayInspect: (URL) throws -> Bool) throws -> [WorktreeInventoryItem] {
    try withLock { _ in
      let entries = try WorktreeInventoryEntry.parse(
        command(["worktree", "list", "--porcelain", "-z"]).output)
      let records = try store.records()
      return try entries.map { entry in
        let root = URL(fileURLWithPath: entry.path)
        guard try mayInspect(root) else {
          return .init(
            path: nil, projectID: nil, branch: nil, base: nil,
            ahead: nil, behind: nil, dirty: nil, unavailable: "Path access denied.")
        }
        let record = records.first {
          $0.root == entry.path && $0.source == source && $0.state == .active
        }
        var projectID: String?
        var branch = entry.branch.map { String($0.dropFirst("refs/heads/".count)) }
        var base: String?
        var ahead: Int?
        var behind: Int?
        var dirty: Bool?
        var unavailable: String?
        do {
          if let record, case .host = record.provenance {
            guard let journal = try readJournal(record.projectID), journal.phase == .active,
              try activeRecord(journal) == record
            else { throw WorktreeError.recoveryRequired("Active journal is unavailable.") }
            let topology = try verifyTopology(journal, repository: identity, source: source)
            projectID = record.projectID
            branch = journal.result.branch
            base = journal.result.base
            dirty = try !status(topology).isEmpty
            guard let baseOID = try revision(journal.base) else {
              throw WorktreeError.recoveryRequired("Recorded base branch is unavailable.")
            }
            let counts = try git.run(
              ["rev-list", "--left-right", "--count", baseOID + "...HEAD"],
              at: root, gitDirectory: topology.gitDirectory.url, objects: topology.objects.url,
              sharedObjects: topology.sharedObjects.url
            ).output
            let parts = String(decoding: counts, as: UTF8.self).split(whereSeparator: {
              $0.isWhitespace
            })
            guard parts.count == 2, let b = Int(parts[0]), let a = Int(parts[1]), a >= 0, b >= 0
            else {
              throw WorktreeError.commandFailed("Invalid ahead/behind counts.")
            }
            ahead = a
            behind = b
          } else {
            guard !entry.bare, !entry.prunable else {
              throw WorktreeError.unsupportedRepository("Checkout is bare or unavailable.")
            }
            let administrative: URL
            if entry.path == identity.main.path {
              administrative = URL(fileURLWithPath: identity.common.path)
            } else {
              administrative = try administrativeDirectory(root: root, repository: identity).url
            }
            if let record, case .plugin = record.provenance { projectID = record.projectID }
            dirty = try !git.run(
              [
                "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all",
                "--ignored=matching",
              ],
              at: root, gitDirectory: administrative
            ).output.isEmpty
            unavailable = "No host-recorded base for this checkout."
          }
        } catch {
          unavailable =
            "Checkout state is unavailable; topology or Git state requires reconciliation."
        }
        return .init(
          path: entry.path, projectID: projectID, branch: branch, base: base,
          ahead: ahead, behind: behind, dirty: dirty, unavailable: unavailable)
      }
    }
  }
}
