/// Gateway-established provenance attached to private host diagnostics.
struct MCPHostServiceOwner: Codable, Equatable, Sendable {
  let workspaceID: String?
  let profileID: String?
  let caller: String?
  let transport: String?
  let socketConnectionID: String?
  let tunnelInstanceID: String?
  let tunnelProfileID: String?
  var principalID: String? = nil

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case profileID = "profile_id"
    case caller
    case transport
    case socketConnectionID = "socket_connection_id"
    case tunnelInstanceID = "tunnel_instance_id"
    case tunnelProfileID = "tunnel_profile_id"
    case principalID = "principal_id"
  }

}
