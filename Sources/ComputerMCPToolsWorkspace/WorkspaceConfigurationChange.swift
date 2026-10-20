import ComputerMCPCore
import Foundation

package enum WorkspaceHostChange: Sendable {
  case register(URL, displayName: String?)
  case repair(id: String, root: URL, displayName: String?)
  case remove(String)
  case deduplicate(expectedPlanDigest: String, allowMetadataConflicts: Bool)
}

package enum WorkspaceChangeResult: Equatable, Sendable {
  case registered(RegisteredWorkspace, created: Bool)
  case repaired(RegisteredWorkspace)
  case removed
  case deduplicated(WorkspaceDeduplicationResult)
}

package enum WorkspaceConfigurationMutation: Sendable {
  case register(RegisteredWorkspace)
  case repair(RegisteredWorkspace, root: WorkspaceRootIdentity)
  case remove(String)
  case deduplicate(expectedPlanDigest: String, allowMetadataConflicts: Bool)
}

package enum WorkspaceRepairError: Error, LocalizedError, Equatable {
  case rootAlreadyRegistered(workspaceID: String)

  package var errorDescription: String? {
    switch self {
    case .rootAlreadyRegistered(let id):
      "This folder is already registered as workspace '\(id)'. Select another folder or use that workspace."
    }
  }
}

/// Candidate inputs are derived by the canonical SQL mutation in a rolled-back savepoint.
/// Its timestamp and receipt identity remain stable when the same mutation commits.
package struct PreparedWorkspaceChange<State: Sendable>: Sendable {
  package let mutation: WorkspaceConfigurationMutation
  package let expected: State
  package let proposed: State
  package let resolvedProfiles: [ProfileGrant]
  package let result: WorkspaceChangeResult
  package let timestamp: Date
  package let receiptID: String

  package init(
    mutation: WorkspaceConfigurationMutation, expected: State, proposed: State,
    resolvedProfiles: [ProfileGrant], result: WorkspaceChangeResult, timestamp: Date,
    receiptID: String
  ) {
    self.mutation = mutation
    self.expected = expected
    self.proposed = proposed
    self.resolvedProfiles = resolvedProfiles
    self.result = result
    self.timestamp = timestamp
    self.receiptID = receiptID
  }
}
