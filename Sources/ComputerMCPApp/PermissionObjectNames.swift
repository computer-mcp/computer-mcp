import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPPermissions

extension ProjectAccess {
  var localizedTitle: String {
    let key =
      switch self {
      case .ask: "Ask"
      case .deny: "Deny"
      case .read: "Read"
      case .write: "Write"
      }
    return AppLocalization.string(key)
  }
}

extension PermissionObjectNames {
  func title(for permission: Permission) -> String {
    switch permission {
    case .project(let id): objectTitle("Project", id: id, names: projects)
    case .plugin(let id): objectTitle("Plugin", id: id, names: plugins)
    case .mcpServer(let id): objectTitle("MCP server", id: id, names: mcpServers)
    default: AppLocalization.string(permission.permissionTitle)
    }
  }

  func project(_ id: String) -> String { Self.identity(id, name: projects[id]) }
  func plugin(_ id: String) -> String { Self.identity(id, name: plugins[id]) }
  func server(_ id: String) -> String { Self.identity(id, name: mcpServers[id]) }

  static func profile(_ id: GatewayProfileID) -> String {
    identity(id.rawValue, name: AppLocalization.string(id.displayName))
  }

  private func objectTitle(_ kind: String, id: String, names: [String: String]) -> String {
    AppLocalization.string(kind) + " · " + Self.identity(id, name: names[id])
  }

  private static func identity(_ id: String, name: String?) -> String {
    guard let name, name != id else { return id }
    return name + " · " + id
  }
}
