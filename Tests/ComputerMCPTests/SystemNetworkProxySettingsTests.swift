import Foundation
import Testing

@testable import ComputerMCP

struct SystemNetworkProxySettingsTests {
  @Test
  func testSystemSettingsParserRejectsDisabledAndMalformedFixedProxies() {
    let settings = SystemNetworkProxySettings.resolved(from: [
      "HTTPEnable": 1,
      "HTTPProxy": "127.0.0.1",
      "HTTPPort": 6152,
      "HTTPSEnable": 0,
      "HTTPSProxy": "127.0.0.2",
      "HTTPSPort": 6153,
      "SOCKSEnable": 1,
      "SOCKSProxy": "",
      "SOCKSPort": 6154,
      "ExceptionsList": ["localhost", "*.example.test"],
    ])

    #expect(settings.httpProxy == "http://127.0.0.1:6152")
    #expect(settings.httpsProxy == nil)
    #expect(settings.socksProxy == nil)
    #expect(settings.bypassHosts == ["localhost", "*.example.test"])
  }
}
