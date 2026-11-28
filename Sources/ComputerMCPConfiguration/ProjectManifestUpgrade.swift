import ComputerMCPCore
import Foundation
import TOML

/// Translates schema-owned names only. Project IDs, paths, commands and plugin arguments are opaque.
package enum ProjectManifestUpgrade {
  package struct Result: Equatable, Sendable {
    package let manifest: String
    package let removedBuiltinIDs: [String]
    package let renamedBuiltinIDs: [String: String]
  }

  /// Only the historical manifest path translates retired builtin declarations.
  package static func currentBuiltinID(for historicalID: String) -> String? {
    switch historicalID {
    case "git.worktrees": return "git.worktree_list"
    case "delivery.apply", "delivery.scopes.list": return nil
    default: return historicalID
    }
  }

  package static func upgraded(_ text: String) throws -> Result? {
    let original = try TOMLDecoder().decode(JSONValue.self, from: text)
    var result = try transform(original, path: [])
    var removed = Set<String>()
    var renamed: [String: String] = [:]
    if case .object(var root) = result, case .object(var builtin) = root["builtin"],
      case .array(let enabled) = builtin["enabled"]
    {
      builtin["enabled"] = .array(
        enabled.compactMap { value in
          guard case .string(let id) = value else { return value }
          guard let current = currentBuiltinID(for: id) else {
            removed.insert(id)
            return nil
          }
          if id != current { renamed[id] = current }
          return .string(current)
        })
      root["builtin"] = .object(builtin)
      result = .object(root)
    }
    guard result != original else { return nil }
    return Result(
      manifest: String(decoding: try TOMLEncoder().encode(result), as: UTF8.self),
      removedBuiltinIDs: removed.sorted(), renamedBuiltinIDs: renamed)
  }

  package static func validate(_ text: String) throws {
    let original = try TOMLDecoder().decode(JSONValue.self, from: text)
    // Reject retired fields before terminology checks; App migration uses upgraded() instead.
    if case .object(let root) = original, case .array(let profiles) = root["profiles"],
      profiles.contains(where: {
        if case .object(let fields) = $0 { return fields["mode"] != nil }
        return false
      })
    {
      throw ConfigurationError.invalid(ProfileDocument.obsoleteModeMessage)
    }
    if try transform(original, path: []) != original {
      throw ConfigurationError.invalid(
        "Use projects instead of workspaces, project_id instead of workspace_id, "
          + "project.* tool IDs instead of workspace.*. "
          + "cwd uses project; risks use project-write or project-write-capable."
      )
    }
  }

  private static func transform(_ value: JSONValue, path: [String]) throws -> JSONValue {
    switch value {
    case .object(let object):
      if path.isEmpty, object["delivery"] != nil {
        throw ConfigurationError.invalid(GatewayConfiguration.retiredDeliveryMessage)
      }
      var result: [String: JSONValue] = [:]
      for (key, value) in object {
        let renamed: String
        switch (path.joined(separator: "."), key) {
        case ("", "workspaces"), ("profiles", "workspaces"): renamed = "projects"
        case ("runtime", "workspace_id"): renamed = "project_id"
        default: renamed = key
        }
        guard renamed == key || object[renamed] == nil else {
          throw ConfigurationError.invalid(
            "Both \(key) and \(renamed) are present; use \(renamed).")
        }
        result[renamed] = try transform(value, path: path + [renamed])
      }
      return .object(result)
    case .array(let values):
      return .array(try values.map { try transform($0, path: path) })
    case .string(let string):
      let field = path.joined(separator: ".")
      if ["profiles.capabilities", "builtin.enabled", "tools.name"].contains(field),
        string.hasPrefix("workspace.")
      {
        return .string("project." + string.dropFirst(10))
      }
      if field == "profiles.mode", string == "workspace-operations" {
        return .string("project-operations")
      }
      if ["cli.commands.cwd", "mcp.servers.cwd"].contains(field), string == "workspace" {
        return .string("project")
      }
      if ["cli.commands.risk", "tools.risk"].contains(field)
        || path.starts(with: ["mcp", "servers", "tool_risks"])
      {
        if string == "workspace-write" { return .string("project-write") }
        if string == "workspace-write-capable" { return .string("project-write-capable") }
      }
      return value
    default: return value
    }
  }
}
