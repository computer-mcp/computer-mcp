import ComputerMCPPlatformDarwin
import ComputerMCPTunnels

extension SystemNetworkProxyResolver: OpenAITunnelHTTPProxyResolving {
  package func systemHTTPProxy() -> String? {
    let settings = SystemNetworkProxySettings.resolved(from: proxySettings())
    return settings.httpsProxy ?? settings.httpProxy
  }
}
