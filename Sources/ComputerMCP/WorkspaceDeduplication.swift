import Foundation

package struct WorkspaceDeduplicationMember: Codable, Equatable, Sendable {
  package var workspaceID: String
  package var displayName: String
  package var rootPath: String
  package var createdAt: Date
  package var referencedProfileIDs: [String]

  package init(
    workspaceID: String,
    displayName: String,
    rootPath: String,
    createdAt: Date,
    referencedProfileIDs: [String]
  ) {
    self.workspaceID = workspaceID
    self.displayName = displayName
    self.rootPath = rootPath
    self.createdAt = createdAt
    self.referencedProfileIDs = referencedProfileIDs
  }
}

package struct WorkspaceDeduplicationGroup: Codable, Equatable, Sendable {
  package var canonicalRootPath: String
  package var canonicalWorkspaceID: String
  package var duplicateWorkspaceIDs: [String]
  package var members: [WorkspaceDeduplicationMember]
  package var hasMetadataConflict: Bool

  package init(
    canonicalRootPath: String,
    canonicalWorkspaceID: String,
    duplicateWorkspaceIDs: [String],
    members: [WorkspaceDeduplicationMember],
    hasMetadataConflict: Bool
  ) {
    self.canonicalRootPath = canonicalRootPath
    self.canonicalWorkspaceID = canonicalWorkspaceID
    self.duplicateWorkspaceIDs = duplicateWorkspaceIDs
    self.members = members
    self.hasMetadataConflict = hasMetadataConflict
  }
}

package struct WorkspaceDeduplicationPlan: Codable, Equatable, Sendable {
  package var schemaVersion: Int
  package var planDigest: String
  package var groups: [WorkspaceDeduplicationGroup]
  package var duplicateCount: Int
  package var affectedProfileIDs: [String]

  package init(
    schemaVersion: Int = 1,
    planDigest: String,
    groups: [WorkspaceDeduplicationGroup],
    duplicateCount: Int,
    affectedProfileIDs: [String]
  ) {
    self.schemaVersion = schemaVersion
    self.planDigest = planDigest
    self.groups = groups
    self.duplicateCount = duplicateCount
    self.affectedProfileIDs = affectedProfileIDs
  }
}

package struct WorkspaceDeduplicationResult: Codable, Equatable, Sendable {
  package var schemaVersion: Int
  package var receiptID: String
  package var planDigest: String
  package var canonicalWorkspaceIDs: [String]
  package var aliasedWorkspaceIDs: [String]
  package var updatedProfileIDs: [String]
  package var appliedAt: Date

  package init(
    schemaVersion: Int = 1,
    receiptID: String,
    planDigest: String,
    canonicalWorkspaceIDs: [String],
    aliasedWorkspaceIDs: [String],
    updatedProfileIDs: [String],
    appliedAt: Date
  ) {
    self.schemaVersion = schemaVersion
    self.receiptID = receiptID
    self.planDigest = planDigest
    self.canonicalWorkspaceIDs = canonicalWorkspaceIDs
    self.aliasedWorkspaceIDs = aliasedWorkspaceIDs
    self.updatedProfileIDs = updatedProfileIDs
    self.appliedAt = appliedAt
  }
}

package enum WorkspaceDeduplicationError: Error, LocalizedError, Equatable {
  case planChanged(expected: String, actual: String)
  case metadataConflict(workspaceIDs: [String])

  package var errorDescription: String? {
    switch self {
    case .planChanged(let expected, let actual):
      return
        "Workspace deduplication state changed; expected plan digest \(expected), actual \(actual). Run preview again."
    case .metadataConflict(let workspaceIDs):
      return
        "Workspace metadata conflicts require explicit review before apply: \(workspaceIDs.joined(separator: ", "))."
    }
  }
}
