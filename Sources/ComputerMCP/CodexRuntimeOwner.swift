/// Gateway-established provenance used by scoped grants and execution receipts.
struct CodexRuntimeOwner: Codable, Equatable, Sendable {
  let workspaceID: String?
  let profileID: String?
  let caller: String?
  let transport: String?
  let socketConnectionID: String?
  let tunnelInstanceID: String?
  let tunnelProfileID: String?

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case profileID = "profile_id"
    case caller
    case transport
    case socketConnectionID = "socket_connection_id"
    case tunnelInstanceID = "tunnel_instance_id"
    case tunnelProfileID = "tunnel_profile_id"
  }

  var elevationConnectionID: String? {
    if let socketConnectionID, !socketConnectionID.isEmpty {
      return socketConnectionID
    }
    if let tunnelInstanceID, !tunnelInstanceID.isEmpty {
      return "tunnel:\(tunnelInstanceID)"
    }
    return nil
  }
}
