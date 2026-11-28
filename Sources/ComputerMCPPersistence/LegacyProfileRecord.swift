import ComputerMCPCore
import Foundation
import GRDB

/// The pre-permission profile table is read only by profile migration.
package struct LegacyProfileRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "profiles"

  package var id: String
  package var capabilityIDsJSON: String
  package var mcpServerIDsJSON: String
  package var projectIDsJSON: String
  package var allowedCallersJSON: String
  package var fullShellEnabled: Bool
  package var mode: String?
  package var confirmationPolicy: String?
  package var authorizationRevision: Int64
  package var updatedAt: Date

  package init(_ value: LegacyProfileGrant, updatedAt: Date) throws {
    self.id = value.id.rawValue
    self.capabilityIDsJSON = try Self.encode(value.capabilityIDs)
    self.mcpServerIDsJSON = try Self.encode(value.mcpServerIDs)
    self.projectIDsJSON = try Self.encode(value.projectIDs)
    self.allowedCallersJSON = try Self.encode(Set(value.allowedCallers.map(\.rawValue)))
    self.fullShellEnabled = value.fullShellEnabled
    self.mode = value.mode.rawValue
    self.confirmationPolicy = value.confirmationPolicy.rawValue
    self.authorizationRevision = value.authorizationRevision
    self.updatedAt = updatedAt
  }

  package func value() throws -> LegacyProfileGrant {
    guard let profileID = GatewayProfileID(rawValue: id) else {
      throw GatewayDatabaseError.invalidStoredValue("Unknown profile id '\(id)'.")
    }
    let callerValues: Set<String> = try Self.decode(allowedCallersJSON)
    let callers = try Set(
      callerValues.map { value in
        guard let caller = GatewayCallerKind(rawValue: value) else {
          throw GatewayDatabaseError.invalidStoredValue("Unknown caller '\(value)'.")
        }
        return caller
      })
    return LegacyProfileGrant(
      id: profileID,
      capabilityIDs: try Self.decode(capabilityIDsJSON),
      projectIDs: try Self.decode(projectIDsJSON),
      allowedCallers: callers,
      fullShellEnabled: fullShellEnabled,
      mcpServerIDs: try Self.decode(mcpServerIDsJSON),
      mode: try mode.map {
        guard let value = LegacyPermissionMode(rawValue: $0) else {
          throw GatewayDatabaseError.invalidStoredValue("Invalid profile permission mode.")
        }
        return value
      } ?? .legacy(profileID: profileID, fullShellEnabled: fullShellEnabled),
      confirmationPolicy: try confirmationPolicy.map {
        guard let value = LegacyConfirmationPolicy(rawValue: $0) else {
          throw GatewayDatabaseError.invalidStoredValue("Invalid profile confirmation policy.")
        }
        return value
      } ?? .riskBased,
      authorizationRevision: authorizationRevision
    )
  }

  private static func encode(_ value: Set<String>) throws -> String {
    let data = try JSONEncoder().encode(value.sorted())
    guard let result = String(data: data, encoding: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Could not encode profile string set.")
    }
    return result
  }

  private static func decode(_ value: String) throws -> Set<String> {
    guard let data = value.data(using: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Profile string set is not UTF-8.")
    }
    return Set(try JSONDecoder().decode([String].self, from: data))
  }
}
