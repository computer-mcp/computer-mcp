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
    Self.state(for: SMAppService.mainApp.status)
  }

  package static func state(for status: SMAppService.Status) -> LaunchAtLoginState {
    switch status {
    case .enabled:
      return .enabled
    case .notRegistered:
      return .disabled
    case .requiresApproval:
      return .requiresApproval
    case .notFound:
      // The main app remains registerable when no background-task record exists.
      // Registration is authoritative for reporting an ineligible app bundle.
      return .disabled
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
