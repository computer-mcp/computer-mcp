import ComputerMCPCore

/// Parsed lifecycle inputs; only the host composition supplies the implementation.
package enum GitWorktreeOperation: Sendable {
  case add(name: String, branch: String?, base: String?)
  case list
  case remove(force: Bool)
  case merge(branch: String)
  case deleteBranch(name: String, force: Bool, dryRun: Bool, confirm: Bool)
}

package protocol GitWorktreeServing: Sendable {
  func call(_ operation: GitWorktreeOperation) throws -> JSONValue
}
