import Foundation

package struct ProjectDeduplicationMember: Codable, Equatable, Sendable {
  package var projectID: String
  package var displayName: String
  package var rootPath: String
  package var createdAt: Date
  package var referencedProfileIDs: [String]

  package init(
    projectID: String,
    displayName: String,
    rootPath: String,
    createdAt: Date,
    referencedProfileIDs: [String]
  ) {
    self.projectID = projectID
    self.displayName = displayName
    self.rootPath = rootPath
    self.createdAt = createdAt
    self.referencedProfileIDs = referencedProfileIDs
  }
}

package struct ProjectDeduplicationGroup: Codable, Equatable, Sendable {
  package var canonicalRootPath: String
  package var canonicalProjectID: String
  package var duplicateProjectIDs: [String]
  package var members: [ProjectDeduplicationMember]
  package var hasMetadataConflict: Bool

  package init(
    canonicalRootPath: String,
    canonicalProjectID: String,
    duplicateProjectIDs: [String],
    members: [ProjectDeduplicationMember],
    hasMetadataConflict: Bool
  ) {
    self.canonicalRootPath = canonicalRootPath
    self.canonicalProjectID = canonicalProjectID
    self.duplicateProjectIDs = duplicateProjectIDs
    self.members = members
    self.hasMetadataConflict = hasMetadataConflict
  }
}

package struct ProjectDeduplicationPlan: Codable, Equatable, Sendable {
  package var schemaVersion: Int
  package var planDigest: String
  package var groups: [ProjectDeduplicationGroup]
  package var duplicateCount: Int
  package var affectedProfileIDs: [String]

  package init(
    schemaVersion: Int = 1,
    planDigest: String,
    groups: [ProjectDeduplicationGroup],
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

package struct ProjectDeduplicationResult: Codable, Equatable, Sendable {
  package var schemaVersion: Int
  package var receiptID: String
  package var planDigest: String
  package var canonicalProjectIDs: [String]
  package var aliasedProjectIDs: [String]
  package var updatedProfileIDs: [String]
  package var appliedAt: Date

  package init(
    schemaVersion: Int = 1,
    receiptID: String,
    planDigest: String,
    canonicalProjectIDs: [String],
    aliasedProjectIDs: [String],
    updatedProfileIDs: [String],
    appliedAt: Date
  ) {
    self.schemaVersion = schemaVersion
    self.receiptID = receiptID
    self.planDigest = planDigest
    self.canonicalProjectIDs = canonicalProjectIDs
    self.aliasedProjectIDs = aliasedProjectIDs
    self.updatedProfileIDs = updatedProfileIDs
    self.appliedAt = appliedAt
  }
}

package enum ProjectDeduplicationError: Error, LocalizedError, Equatable {
  case planChanged(expected: String, actual: String)
  case metadataConflict(projectIDs: [String])

  package var errorDescription: String? {
    switch self {
    case .planChanged(let expected, let actual):
      return
        "Project deduplication state changed; expected plan digest \(expected), actual \(actual). Run preview again."
    case .metadataConflict(let projectIDs):
      return
        "Project metadata conflicts require explicit review before apply: \(projectIDs.joined(separator: ", "))."
    }
  }
}

package struct ProjectDeduplicationDigestInput: Codable {
  package var groups: [ProjectDeduplicationGroup]

  package init(groups: [ProjectDeduplicationGroup]) {
    self.groups = groups
  }
}
