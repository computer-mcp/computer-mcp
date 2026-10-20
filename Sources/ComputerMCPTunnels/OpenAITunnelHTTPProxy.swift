import Foundation

package protocol OpenAITunnelHTTPProxyResolving: Sendable {
  func systemHTTPProxy() -> String?
}

package struct SystemNetworkProxySettings: Equatable, Sendable {
  package var httpProxy: String?
  package var httpsProxy: String?
  package var socksProxy: String?
  package var bypassHosts: [String]

  internal init(
    httpProxy: String? = nil,
    httpsProxy: String? = nil,
    socksProxy: String? = nil,
    bypassHosts: [String] = []
  ) {
    self.httpProxy = httpProxy
    self.httpsProxy = httpsProxy
    self.socksProxy = socksProxy
    self.bypassHosts = bypassHosts
  }

  package static func resolved(from settings: [String: Any]) -> Self {
    Self(
      httpProxy: proxyURL(
        settings: settings,
        enabledKey: "HTTPEnable",
        hostKey: "HTTPProxy",
        portKey: "HTTPPort",
        scheme: "http"
      ),
      httpsProxy: proxyURL(
        settings: settings,
        enabledKey: "HTTPSEnable",
        hostKey: "HTTPSProxy",
        portKey: "HTTPSPort",
        scheme: "http"
      ),
      socksProxy: proxyURL(
        settings: settings,
        enabledKey: "SOCKSEnable",
        hostKey: "SOCKSProxy",
        portKey: "SOCKSPort",
        scheme: "socks5"
      ),
      bypassHosts: (settings["ExceptionsList"] as? [String]) ?? []
    )
  }

  private static func proxyURL(
    settings: [String: Any],
    enabledKey: String,
    hostKey: String,
    portKey: String,
    scheme: String
  ) -> String? {
    guard (settings[enabledKey] as? NSNumber)?.boolValue == true,
      let host = settings[hostKey] as? String,
      !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let port = (settings[portKey] as? NSNumber)?.intValue,
      (1...65_535).contains(port)
    else {
      return nil
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = port
    return components.string
  }
}
