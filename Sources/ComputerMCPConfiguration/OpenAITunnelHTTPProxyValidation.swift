import Foundation

/// Returns why `value` is not an acceptable `http_proxy` URL, or `nil` when it is.
package func openAITunnelHTTPProxyValidationFailure(_ value: String) -> String? {
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
