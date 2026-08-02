@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionOnboardingError: LocalizedError {
  case unknownPermission(String)

  var errorDescription: String? {
    switch self {
    case .unknownPermission(let id):
      "Unknown macOS permission: \(id)"
    }
  }
}

@MainActor
protocol SystemPermissionRequesting: Sendable {
  func requestPermission(id: String) throws -> PermissionRequestOutcome
}

struct MacOSSystemPermissionRequester: SystemPermissionRequesting {
  func requestPermission(id: String) throws -> PermissionRequestOutcome {
    switch id {
    case "accessibility":
      let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      let isGranted = AXIsProcessTrustedWithOptions(
        [promptKey: true] as CFDictionary
      )
      return PermissionRequestOutcome(
        permissionID: id,
        state: isGranted ? .granted : .notGranted,
        systemPromptRequested: !isGranted
      )

    case "screen-recording":
      let isGranted =
        CGPreflightScreenCaptureAccess()
        || CGRequestScreenCaptureAccess()
      return PermissionRequestOutcome(
        permissionID: id,
        state: isGranted ? .granted : .notGranted,
        systemPromptRequested: !isGranted
      )

    default:
      throw PermissionOnboardingError.unknownPermission(id)
    }
  }
}
