import ComputerMCPPlatform

package struct FixedComputerUsePermissionReader: ComputerUsePermissionReading {
  package var snapshot: ComputerUsePermissionSnapshot

  package init(
    snapshot: ComputerUsePermissionSnapshot = .init(
      accessibility: .notGranted, screenRecording: .notGranted)
  ) {
    self.snapshot = snapshot
  }

  package func permissionSnapshot() -> ComputerUsePermissionSnapshot {
    snapshot
  }
}
