import Foundation

package enum MCPHostServiceError: Error, LocalizedError {
  case denied(String)
  package var errorDescription: String? {
    switch self {
    case .denied(let detail): "host.service_denied: " + detail
    }
  }
}
