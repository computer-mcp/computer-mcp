/// The result's physical execution boundary, independent of its permission grant.
package struct ExecutionOwnershipReport: Codable, Equatable, Sendable {
  package enum Scope: String, Codable, Sendable {
    case sandbox = "durable_sandbox"
    case processGroup = "process_group_best_effort"
  }
  package let scope: Scope
  package let warning: String?

  package init(scope: Scope) {
    self.scope = scope
    warning =
      scope == .processGroup
      ? "Descendants that escape process-group observation are outside ownership and may survive cancellation or host restart."
      : nil
  }
}
