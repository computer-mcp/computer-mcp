import Foundation

package enum WorktreeError: Error, LocalizedError, Equatable {
  case unsafeConfiguration(String)
  case identityChanged(String)
  case busy(String)
  case unsupportedRepository(String)
  case invalidRequest(String)
  case commandFailed(String)
  case recoveryRequired(String)

  package var errorDescription: String? {
    switch self {
    case .unsafeConfiguration(let message), .identityChanged(let message), .busy(let message),
      .unsupportedRepository(let message), .invalidRequest(let message),
      .commandFailed(let message), .recoveryRequired(let message):
      message
    }
  }
}
