import AppKit
import ComputerMCPPlatform
import Foundation

/// Observes registered Apple application bundles without launching them.
package struct ApplicationBundleLookup: ApplicationBundleLocating {
  package init() {}

  package func locate(bundleIdentifier: String) -> ApplicationBundleLocation {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
      return .found(url)
    }
    return .notFound
  }
}
