import Foundation

package enum GatewayControlError: Error, LocalizedError, Equatable {
  case fullShellManifestDisabled

  package var errorDescription: String? {
    switch self {
    case .fullShellManifestDisabled:
      "Enable policy.shell_enabled in the active manifest before enabling Full Shell."
    }
  }
}
