import ComputerMCPCore
import ComputerMCPPermissions
import Foundation
import TOML

/// One source's ceilings. Resolve its object fallbacks before combining sources.
package struct ManagedPolicyDocument: Decodable, Sendable {
  package let permissions: Permissions
  package let allowsFullAccess: Bool
  package let allowsRemoteFullAccess: Bool
  package let network: NetworkAccess
  package let deniedReadLocations: Set<CanonicalPath>
  package let executionLimits: ExecutionLimitCeilings

  package static func decode(_ data: Data) throws -> Self {
    guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
      throw ConfigurationError.invalid("Policy must be UTF-8 TOML within the size limit.")
    }
    return try TOMLDecoder().decode(Self.self, from: text)
  }

  package func resolved(for caller: GatewayCallerKind) -> ManagedPolicy {
    ManagedPolicy(
      permissionCeilings: permissions,
      allowsFullAccess: allowsFullAccess && (!caller.isRemote || allowsRemoteFullAccess),
      network: network, deniedReadLocations: deniedReadLocations, executionLimits: executionLimits)
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: PolicyKey.self)
    let known: Set<String> = [
      "full_access", "remote_full_access", "network", "denied_read_locations", "execution",
      "permissions", "projects", "files_and_folders", "plugins", "mcp_servers",
    ]
    guard c.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
      throw ConfigurationError.invalid("Unknown managed policy field.")
    }
    allowsFullAccess = try c.decodeIfPresent(Bool.self, forKey: .init("full_access")) ?? true
    allowsRemoteFullAccess =
      try c.decodeIfPresent(Bool.self, forKey: .init("remote_full_access")) ?? true
    network = try c.decodeIfPresent(NetworkDocument.self, forKey: .init("network"))?.value ?? .full
    deniedReadLocations = try Set(
      c.decodeIfPresent([String].self, forKey: .init("denied_read_locations"))?.map(
        CanonicalPath.init) ?? [])
    executionLimits =
      try c.decodeIfPresent(PolicyExecutionDocument.self, forKey: .init("execution"))?.limits
      ?? .none
    var permissions = Permissions()
    for table in ["permissions", "projects", "files_and_folders", "plugins", "mcp_servers"] {
      for (id, text) in try c.decodeIfPresent([String: String].self, forKey: .init(table)) ?? [:] {
        let permission: Permission
        switch table {
        case "permissions":
          guard let value = PermissionManifestVocabulary.privacy[id] else {
            throw ConfigurationError.invalid("Unknown managed permission.")
          }
          permission = value
        case "files_and_folders":
          guard let value = PermissionManifestVocabulary.folders[id] else {
            throw ConfigurationError.invalid("Unknown managed folder category.")
          }
          permission = .filesAndFolders(value)
        default:
          try PermissionManifestVocabulary.validateObject(id)
          permission =
            table == "projects" ? .project(id) : table == "plugins" ? .plugin(id) : .mcpServer(id)
        }
        let state: PermissionState
        if text == "deny" {
          state = .denied
        } else {
          guard text != "access",
            let value = text == "allow" ? PermissionValue.access : PermissionValue(rawValue: text)
          else {
            throw ConfigurationError.invalid("Invalid managed permission value.")
          }
          state = .granted(value)
        }
        try permissions.set(state, for: permission)
      }
    }
    self.permissions = permissions
  }
}

private struct PolicyKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ string: String) { stringValue = string }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { return nil }
}

private struct PolicyExecutionDocument: Decodable {
  let limits: ExecutionLimitCeilings
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: PolicyKey.self)
    let known: Set<String> = [
      "time_ms", "output_bytes", "memory_bytes", "retention_seconds", "retained_output_bytes",
    ]
    guard c.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
      throw ConfigurationError.invalid("Unknown execution limit.")
    }
    limits = try ExecutionLimitCeilings(
      timeMilliseconds: c.decodeIfPresent(Int64.self, forKey: .init("time_ms")),
      outputBytes: c.decodeIfPresent(Int64.self, forKey: .init("output_bytes")),
      memoryBytes: c.decodeIfPresent(Int64.self, forKey: .init("memory_bytes")),
      retentionSeconds: c.decodeIfPresent(Int64.self, forKey: .init("retention_seconds")),
      retainedOutputBytes: c.decodeIfPresent(Int64.self, forKey: .init("retained_output_bytes")))
  }
}
