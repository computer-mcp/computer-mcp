import Foundation

#if canImport(SystemConfiguration)
  import SystemConfiguration
#endif

internal protocol OpenAITunnelHTTPProxyResolving: Sendable {
  func systemHTTPProxy() -> String?
}

internal struct SystemOpenAITunnelHTTPProxyResolver: OpenAITunnelHTTPProxyResolving {
  internal func systemHTTPProxy() -> String? {
    let settings = SystemNetworkProxySettings.current()
    return settings.httpsProxy ?? settings.httpProxy
  }
}

internal struct SystemNetworkProxySettings: Equatable, Sendable {
  internal var httpProxy: String?
  internal var httpsProxy: String?
  internal var socksProxy: String?
  internal var bypassHosts: [String]

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

  internal static func current() -> Self {
    #if canImport(SystemConfiguration)
      guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
        return Self()
      }
      return resolved(from: settings)
    #else
      return Self()
    #endif
  }

  internal static func resolved(from settings: [String: Any]) -> Self {
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

func openAITunnelHTTPProxyValidationFailure(_ value: String) -> String? {
  guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
    !value.isEmpty,
    !value.contains("\0"),
    !value.contains("\n"),
    !value.contains("\r"),
    let components = URLComponents(string: value),
    let scheme = components.scheme?.lowercased(),
    scheme == "http" || scheme == "https",
    let host = components.host,
    !host.isEmpty,
    components.user == nil,
    components.password == nil,
    components.query == nil,
    components.fragment == nil,
    components.path.isEmpty || components.path == "/"
  else {
    return
      "http_proxy must be an HTTP or HTTPS proxy URL without credentials, query, fragment, or path."
  }
  if let port = components.port, !(1...65_535).contains(port) {
    return "http_proxy port must be between 1 and 65535."
  }
  return nil
}
