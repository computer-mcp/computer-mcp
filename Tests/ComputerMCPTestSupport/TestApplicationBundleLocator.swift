import ComputerMCPPlatform
import Foundation

package struct TestApplicationBundleLocator: ApplicationBundleLocating {
  private let lookup: @Sendable (String) -> URL?

  package init(_ lookup: @escaping @Sendable (String) -> URL? = { _ in nil }) {
    self.lookup = lookup
  }

  package func locate(bundleIdentifier: String) -> ApplicationBundleLocation {
    lookup(bundleIdentifier).map(ApplicationBundleLocation.found) ?? .notFound
  }
}
