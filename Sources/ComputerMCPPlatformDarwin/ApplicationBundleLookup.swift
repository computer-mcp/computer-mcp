import AppKit
import Foundation

/// Observes registered Apple application bundles without launching them.
package enum ApplicationBundleLookup {
  package enum Result: Equatable, Sendable {
    case found(URL)
    case notFound
  }

  package static func locate(bundleIdentifier: String) -> Result {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
      return .found(url)
    }
    return .notFound
  }
}
