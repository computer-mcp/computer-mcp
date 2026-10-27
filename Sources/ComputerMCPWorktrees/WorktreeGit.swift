import Foundation

/// The composition adapter must execute the pinned trusted Git binary, enforce both
/// bounds, replace its environment and return raw bytes. No shell or caller program runs.
package protocol WorktreeGitExecuting: Sendable {
  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult
  /// Send the supplied start/update/prepare input, require both acknowledgements,
  /// then run the body while Git owns its locks. Commit only on success; otherwise
  /// abort and reap. The adapter enforces command bounds throughout the session.
  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws
}

package struct WorktreeGitCommand: Sendable {
  package var arguments: [String]
  package var directory: URL
  package var environment: [String: String]
  package var input: Data
  package var timeoutMilliseconds: Int
  package var maxOutputBytes: Int

  package init(
    arguments: [String], directory: URL, environment: [String: String], input: Data = Data(),
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) {
    self.arguments = arguments
    self.directory = directory
    self.environment = environment
    self.input = input
    self.timeoutMilliseconds = timeoutMilliseconds
    self.maxOutputBytes = maxOutputBytes
  }
}

package struct WorktreeGitResult: Sendable {
  package let output: Data
  package let error: Data
  package let exitCode: Int32

  package init(output: Data, error: Data, exitCode: Int32) {
    self.output = output
    self.error = error
    self.exitCode = exitCode
  }
}

extension WorktreeGitExecuting {
  package func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void)
    throws
  {
    throw WorktreeError.unsupportedRepository("Prepared reference transactions are unavailable.")
  }
}
