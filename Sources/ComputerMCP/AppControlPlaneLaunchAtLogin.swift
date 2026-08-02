import Foundation
import ServiceManagement

package enum LaunchAtLoginState: String, Codable, Equatable, Sendable {
  case disabled
  case enabled
  case requiresApproval = "requires-approval"
  case unavailable
}

package protocol LaunchAtLoginControlling: Sendable {
  func state() -> LaunchAtLoginState
  func setEnabled(_ enabled: Bool) throws
}

package struct SMAppServiceLaunchAtLoginController: LaunchAtLoginControlling {
  package init() {}

  package func state() -> LaunchAtLoginState {
    switch SMAppService.mainApp.status {
    case .enabled:
      return .enabled
    case .notRegistered:
      return .disabled
    case .requiresApproval:
      return .requiresApproval
    case .notFound:
      return .unavailable
    @unknown default:
      return .unavailable
    }
  }

  package func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
