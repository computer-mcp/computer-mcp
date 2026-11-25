import Foundation

package struct WorktreeStorage: Sendable {
  package let content: URL
  package let repositories: URL
  package let runtime: URL
  package let journals: URL
  package let recovery: URL
  let base: URL

  /// Only file-backed hosts have lifecycle storage. Composition supplies the App's
  /// actual distribution root; standalone hosts derive their root from the database.
  package init?(databaseURL: URL?, applicationSupportRoot: URL? = nil) {
    guard let databaseURL else { return nil }
    base = (applicationSupportRoot ?? databaseURL.deletingLastPathComponent())
      .standardizedFileURL.resolvingSymlinksInPath()
    let app = applicationSupportRoot != nil
    content = base.appendingPathComponent(app ? "Worktrees" : "worktrees")
    repositories = base.appendingPathComponent(
      app ? "WorktreeRepositories" : "worktree-repositories")
    runtime = base.appendingPathComponent(app ? "WorktreeRuntime" : "worktree-runtime")
    journals = base.appendingPathComponent(app ? "WorktreeJournals" : "worktree-journals")
    recovery = base.appendingPathComponent(app ? "WorktreeRecovery" : "worktree-recovery")
  }

  func prepare() throws {
    let parent = try WorktreeDirectory(base)
    for url in [content, repositories, runtime, journals] {
      _ = try parent.child(url.lastPathComponent, create: true)
    }
  }

  func validate(projectRoots: [URL], ownedRoots: Set<String>) throws {
    for project in projectRoots.map({ $0.standardizedFileURL.resolvingSymlinksInPath().path }) {
      guard !Self.contains(project, recovery.path), !Self.contains(recovery.path, project) else {
        throw WorktreeError.unsafeConfiguration("Recovery storage overlaps a registered project.")
      }
      if ownedRoots.contains(project) { continue }
      for storage in [content, repositories, runtime, journals] {
        let path = storage.path
        guard !Self.contains(project, path), !Self.contains(path, project) else {
          throw WorktreeError.unsafeConfiguration("Worktree storage overlaps a registered project.")
        }
      }
    }
  }

  static func contains(_ parent: String, _ path: String) -> Bool {
    parent == "/" || path == parent || path.hasPrefix(parent + "/")
  }
}
