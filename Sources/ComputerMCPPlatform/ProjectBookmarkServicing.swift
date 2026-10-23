import ComputerMCPCore
import Foundation

package protocol ProjectBookmarkServicing: Sendable {
  func registerFolder(
    at url: URL,
    displayName: String?
  ) throws -> RegisteredProject

  func resolve(
    _ project: RegisteredProject
  ) throws -> ResolvedProjectAccess
}

/// A point-in-time access check, independent of whether a folder is registered or granted.
package struct ProjectAccessReport: Sendable {
  package let project: RegisteredProject
  package let error: ProjectBookmarkError?

  package init(project: RegisteredProject, error: ProjectBookmarkError?) {
    self.project = project
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

extension ProjectBookmarkServicing {
  package func inspect(_ project: RegisteredProject) throws -> ProjectAccessReport {
    do {
      let access = try resolve(project)
      defer { access.close() }
      return ProjectAccessReport(project: access.project, error: nil)
    } catch let error as ProjectBookmarkError {
      return ProjectAccessReport(project: project, error: error)
    }
  }
}

package final class ResolvedProjectAccess: @unchecked Sendable {
  package let project: RegisteredProject
  package let rootURL: URL
  package let bookmarkWasRefreshed: Bool
  package let rootIdentity: ProjectRootIdentity

  private let lock = NSLock()
  private var active = true
  private var stopAccessing: (@Sendable () -> Void)?

  /// Created by a project bookmark service after it starts access to `rootURL`;
  /// `stopAccessing` ends that access and runs at most once.
  package init(
    project: RegisteredProject,
    rootURL: URL,
    bookmarkWasRefreshed: Bool,
    stopAccessing: (@Sendable () -> Void)?
  ) throws {
    self.rootIdentity = try ProjectRootIdentity(rootURL)
    self.project = project
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
