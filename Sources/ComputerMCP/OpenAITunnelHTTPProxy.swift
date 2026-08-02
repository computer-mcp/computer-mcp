import Foundation

#if canImport(SystemConfiguration)
  import SystemConfiguration
#endif

internal protocol OpenAITunnelHTTPProxyResolving: Sendable {
  func systemHTTPProxy() -> String?
}

internal struct SystemOpenAITunnelHTTPProxyResolver: OpenAITunnelHTTPProxyResolving {
  internal func systemHTTPProxy() -> String? {
    #if canImport(SystemConfiguration)
      guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
        return nil
      }
      return proxyURL(
        settings: settings,
        enabledKey: kSCPropNetProxiesHTTPSEnable as String,
        hostKey: kSCPropNetProxiesHTTPSProxy as String,
        portKey: kSCPropNetProxiesHTTPSPort as String
      )
        ?? proxyURL(
          settings: settings,
          enabledKey: kSCPropNetProxiesHTTPEnable as String,
          hostKey: kSCPropNetProxiesHTTPProxy as String,
          portKey: kSCPropNetProxiesHTTPPort as String
        )
    #else
      return nil
    #endif
  }

  private func proxyURL(
    settings: [String: Any],
    enabledKey: String,
    hostKey: String,
    portKey: String
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
    components.scheme = "http"
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
