import Foundation

enum WorkspaceHostChange: Sendable {
  case register(URL, displayName: String?)
  case repair(id: String, root: URL, displayName: String?)
  case remove(String)
  case deduplicate(expectedPlanDigest: String, allowMetadataConflicts: Bool)
}

enum WorkspaceChangeResult: Equatable, Sendable {
  case registered(RegisteredWorkspace, created: Bool)
  case repaired(RegisteredWorkspace)
  case removed
  case deduplicated(WorkspaceDeduplicationResult)
}

enum WorkspaceConfigurationMutation: Sendable {
  case register(RegisteredWorkspace)
  case repair(RegisteredWorkspace, root: WorkspaceRootIdentity)
  case remove(String)
  case deduplicate(expectedPlanDigest: String, allowMetadataConflicts: Bool)
}

enum WorkspaceRepairError: Error, LocalizedError, Equatable {
  case rootAlreadyRegistered(workspaceID: String)

  var errorDescription: String? {
    switch self {
    case .rootAlreadyRegistered(let id):
      "This folder is already registered as workspace '\(id)'. Select another folder or use that workspace."
    }
  }
}

/// Candidate inputs are derived by the canonical SQL mutation in a rolled-back savepoint.
/// Its timestamp and receipt identity remain stable when the same mutation commits.
struct PreparedWorkspaceChange: Sendable {
  let mutation: WorkspaceConfigurationMutation
  let expected: GatewayDatabase.ConfigurationState
  let proposed: GatewayDatabase.ConfigurationState
  let resolvedProfiles: [ProfileGrant]
  let result: WorkspaceChangeResult
  let timestamp: Date
  let receiptID: String
}
