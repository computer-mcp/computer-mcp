import Foundation

/// Opens or reveals an already-scoped workspace path through the desktop environment.
package protocol WorkspaceOpener: Sendable {
  func open(
    _ url: URL, application: String?, workingDirectory: URL,
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult
  func reveal(
    _ url: URL, workingDirectory: URL, timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult
}
