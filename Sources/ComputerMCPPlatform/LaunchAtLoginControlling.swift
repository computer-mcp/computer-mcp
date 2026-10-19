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
