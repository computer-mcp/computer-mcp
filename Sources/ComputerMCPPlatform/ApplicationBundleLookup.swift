import Foundation

#if os(macOS)
  import AppKit
#endif

/// Observes registered Apple application bundles without launching them.
package enum ApplicationBundleLookup {
  package enum Result: Equatable, Sendable {
    case found(URL)
    case notFound
    case unsupported
  }

  package static func locate(bundleIdentifier: String) -> Result {
    #if os(macOS)
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        return .found(url)
      }
      return .notFound
    #else
      return .unsupported
    #endif
  }
}
