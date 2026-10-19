package enum ComputerUsePermissionStatus: String, Codable, Sendable {
  case granted
  case notGranted = "not-granted"
}

package struct ComputerUsePermissionSnapshot: Codable, Equatable, Sendable {
  package var accessibility: ComputerUsePermissionStatus
  package var screenRecording: ComputerUsePermissionStatus

  package init(
    accessibility: ComputerUsePermissionStatus,
    screenRecording: ComputerUsePermissionStatus
  ) {
    self.accessibility = accessibility
    self.screenRecording = screenRecording
  }
}
