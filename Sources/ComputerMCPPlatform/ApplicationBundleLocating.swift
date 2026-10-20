import Foundation

package enum ApplicationBundleLocation: Equatable, Sendable {
  case found(URL)
  case notFound
}

/// Observes registered applications without launching them.
package protocol ApplicationBundleLocating: Sendable {
  func locate(bundleIdentifier: String) -> ApplicationBundleLocation
}
