import ComputerMCPCore
import Foundation
import TOML

/// Translates schema-owned names only. Project IDs, paths, commands and plugin arguments are opaque.
package enum ProjectManifestUpgrade {
  package static func upgraded(_ text: String) throws -> String? {
    let original = try TOMLDecoder().decode(JSONValue.self, from: text)
    let result = try transform(original, path: [])
    guard result != original else { return nil }
    return String(decoding: try TOMLEncoder().encode(result), as: UTF8.self)
  }

  package static func validate(_ text: String) throws {
    if try upgraded(text) != nil {
      throw ConfigurationError.invalid(
        "Use projects instead of workspaces, project_id instead of workspace_id, "
          + "project.* tool IDs instead of workspace.*, and project-operations instead of workspace-operations. "
          + "Delivery scopes use project; cwd uses project; risks use project-write or project-write-capable."
      )
    }
  }

  private static func transform(_ value: JSONValue, path: [String]) throws -> JSONValue {
    switch value {
    case .object(let object):
      var result: [String: JSONValue] = [:]
      for (key, value) in object {
        let renamed: String
        switch (path.joined(separator: "."), key) {
        case ("", "workspaces"), ("profiles", "workspaces"): renamed = "projects"
        case ("runtime", "workspace_id"): renamed = "project_id"
        case ("delivery.scopes", "workspace"): renamed = "project"
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
