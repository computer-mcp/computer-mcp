import Foundation
import GRDB

/// Schema names and live authorization state change together in the migrator's transaction.
enum ProjectSchemaMigration {
  static func migrate(_ database: Database) throws {
    for (old, new) in [
      ("workspaces", "projects"), ("pluginDerivedWorkspaces", "pluginDerivedProjects"),
      ("workspaceAliases", "projectAliases"),
      ("workspaceCanonicalRoots", "projectCanonicalRoots"),
      ("workspaceDeduplicationReceipts", "projectDeduplicationReceipts"),
    ] {
      try database.execute(sql: "ALTER TABLE \(old) RENAME TO \(new)")
    }
    for (table, old, new) in [
      ("projectAliases", "aliasWorkspaceID", "aliasProjectID"),
      ("projectAliases", "canonicalWorkspaceID", "canonicalProjectID"),
      ("projectCanonicalRoots", "workspaceID", "projectID"),
      ("profiles", "workspaceIDsJSON", "projectIDsJSON"),
      ("auditEvents", "workspaceID", "projectID"),
      ("operationTickets", "workspaceID", "projectID"),
      ("pluginDerivedProjects", "workspaceID", "projectID"),
      ("pluginDerivedProjects", "sourceWorkspaceID", "sourceProjectID"),
    ] {
      try database.execute(sql: "ALTER TABLE \(table) RENAME COLUMN \(old) TO \(new)")
    }
    try database.execute(sql: "DROP INDEX workspaceAliases_on_canonicalWorkspaceID")
    try database.execute(sql: "DROP INDEX workspaceCanonicalRoots_on_workspaceID")
    try database.execute(
      sql: "CREATE INDEX projectAliases_on_canonicalProjectID ON projectAliases(canonicalProjectID)"
    )
    try database.execute(
      sql: "CREATE INDEX projectCanonicalRoots_on_projectID ON projectCanonicalRoots(projectID)")
    for row in try Row.fetchAll(database, sql: "SELECT id, capabilityIDsJSON FROM profiles") {
      let input: String = row["capabilityIDsJSON"]
      let tools = try JSONDecoder().decode([String].self, from: Data(input.utf8))
      let output = tools.map(toolID)
      if output != tools {
        let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        try database.execute(
          sql: "UPDATE profiles SET capabilityIDsJSON = ? WHERE id = ?",
          arguments: [json, row["id"] as String])
      }
    }
    try database.execute(
      sql: "UPDATE profiles SET mode = 'project-operations' WHERE mode = 'workspace-operations'")
    // Trust snapshots are compared with live grants on every connection, including configured grants.
    for row in try Row.fetchAll(database, sql: "SELECT id, profile FROM clientControlTrust") {
      let input: String = row["profile"]
      guard var object = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]
      else {
        throw GatewayDatabaseError.invalidStoredValue("Client trust profile must be a JSON object.")
      }
      for key in ["grant", "configuredGrant"] {
        guard var grant = object[key] as? [String: Any] else { continue }
        if let ids = grant.removeValue(forKey: "workspaceIDs") { grant["projectIDs"] = ids }
        if let tools = grant["capabilityIDs"] as? [String] {
          grant["capabilityIDs"] = tools.map(toolID)
        }
        if grant["mode"] as? String == "workspace-operations" {
          grant["mode"] = "project-operations"
        }
        object[key] = grant
      }
      let output = String(
        decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        as: UTF8.self)
      try database.execute(
        sql: "UPDATE clientControlTrust SET profile = ? WHERE id = ?",
        arguments: [output, row["id"] as String])
    }
    // Host-owned plugin choices are live configuration; package declarations and arguments stay opaque.
    for row in try Row.fetchAll(database, sql: "SELECT id, payloadJSON FROM pluginState") {
      let input: String = row["payloadJSON"]
      guard var state = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]
      else {
        throw GatewayDatabaseError.invalidStoredValue("Plugin state must be a JSON object.")
      }
      var settings = state["settings"] as? [String: [String: Any]] ?? [:]
      var changed = false
      for (pluginID, var choice) in settings {
        guard var components = choice["mcp"] as? [String: [String: Any]] else { continue }
        for (componentID, var component) in components {
          guard var risks = component["toolRisks"] as? [String: Any] else { continue }
          for (tool, risk) in risks where risk as? String == "workspace-write" {
            risks[tool] = "project-write"
            changed = true
          }
          if component["toolRisks"] != nil { component["toolRisks"] = risks }
          components[componentID] = component
        }
        if choice["mcp"] != nil { choice["mcp"] = components }
        settings[pluginID] = choice
      }
      if changed {
        state["settings"] = settings
        let output = String(
          decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
          as: UTF8.self)
        try database.execute(
          sql: "UPDATE pluginState SET payloadJSON = ? WHERE id = ?",
          arguments: [output, row["id"] as Int])
      }
    }
    // Unfinished tickets still name callable tools; completed tickets retain their historical values.
    try database.execute(
      sql: """
        UPDATE operationTickets SET capabilityID = 'project.' || substr(capabilityID, 11)
        WHERE state IN ('prepared', 'pending_approval', 'approved', 'executing') AND capabilityID LIKE 'workspace.%'
        """)
  }

  private static func toolID(_ value: String) -> String {
    value.hasPrefix("workspace.") ? "project." + value.dropFirst(10) : value
  }
}
