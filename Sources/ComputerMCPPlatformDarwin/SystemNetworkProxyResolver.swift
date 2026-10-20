import Foundation
import SystemConfiguration

package struct SystemNetworkProxyResolver: Sendable {
  package init() {}

  package func proxySettings() -> [String: Any] {
    SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
  }
}
