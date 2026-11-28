import Foundation
import GRDB

/// A shared profile's owner ceiling document, committed with its permission ledger.
/// Parsing belongs to Configuration; persistence retains the exact bounded source.
package struct PermissionOwnerPolicyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
  package static let databaseTableName = "permissionOwnerPolicies"
  package let profileID: String
  package let payload: Data?
  package let authorityEpoch: String

  package init(profileID: String, payload: Data?, authorityEpoch: UUID) {
    self.profileID = profileID
    self.payload = payload
    self.authorityEpoch = authorityEpoch.uuidString
  }
}
