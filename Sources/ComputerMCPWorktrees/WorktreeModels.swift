import Foundation

package enum WorktreeError: Error, LocalizedError, Equatable {
  case unsafeConfiguration(String)
  case identityChanged(String)
  case busy(String)

  package var errorDescription: String? {
    switch self {
    case .unsafeConfiguration(let message), .identityChanged(let message), .busy(let message):
      message
    }
  }
}
