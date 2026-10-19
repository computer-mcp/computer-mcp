import ComputerMCPCore
import Foundation

package protocol WorkspaceBookmarkServicing: Sendable {
  func registerFolder(
    at url: URL,
    displayName: String?
  ) throws -> RegisteredWorkspace

  func resolve(
    _ workspace: RegisteredWorkspace
  ) throws -> ResolvedWorkspaceAccess
}

/// A point-in-time access check, independent of whether a folder is registered or granted.
package struct WorkspaceAccessReport: Sendable {
  package let workspace: RegisteredWorkspace
  package let error: WorkspaceBookmarkError?

  package init(workspace: RegisteredWorkspace, error: WorkspaceBookmarkError?) {
    self.workspace = workspace
    self.error = error
  }

  package var json: JSONValue {
    .object([
      "status": .string(error == nil ? "available" : "unavailable"),
      "error": error.map {
        .object([
          "code": .string($0.code),
          "stage": .string("resolve"),
          "message": .string($0.localizedDescription),
        ])
      } ?? .null,
    ])
  }
}

extension WorkspaceBookmarkServicing {
  package func inspect(_ workspace: RegisteredWorkspace) throws -> WorkspaceAccessReport {
    do {
      let access = try resolve(workspace)
      defer { access.close() }
      return WorkspaceAccessReport(workspace: access.workspace, error: nil)
    } catch let error as WorkspaceBookmarkError {
      return WorkspaceAccessReport(workspace: workspace, error: error)
    }
  }
}

package final class ResolvedWorkspaceAccess: @unchecked Sendable {
  package let workspace: RegisteredWorkspace
  package let rootURL: URL
  package let bookmarkWasRefreshed: Bool
  package let rootIdentity: WorkspaceRootIdentity

  private let lock = NSLock()
  private var active = true
  private var stopAccessing: (@Sendable () -> Void)?

  /// Created by a workspace bookmark service after it starts access to `rootURL`;
  /// `stopAccessing` ends that access and runs at most once.
  package init(
    workspace: RegisteredWorkspace,
    rootURL: URL,
    bookmarkWasRefreshed: Bool,
    stopAccessing: (@Sendable () -> Void)?
  ) throws {
    self.rootIdentity = try WorkspaceRootIdentity(rootURL)
    self.workspace = workspace
    self.rootURL = rootURL
    self.bookmarkWasRefreshed = bookmarkWasRefreshed
    self.stopAccessing = stopAccessing
  }

  package var isActive: Bool {
    lock.withLock { active }
  }

  package func close() {
    let stop = lock.withLock { () -> (@Sendable () -> Void)? in
      guard active else {
        return nil
      }
      active = false
      defer { stopAccessing = nil }
      return stopAccessing
    }
    stop?()
  }

  deinit {
    close()
  }
}
