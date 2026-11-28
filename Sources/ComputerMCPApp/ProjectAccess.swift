import ComputerMCPControlPlane

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
