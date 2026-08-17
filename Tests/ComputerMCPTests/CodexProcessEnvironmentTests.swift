import Foundation
import Testing

@testable import ComputerMCP

@Suite
final class CodexProcessEnvironmentTests {
  @Test
  func testFixedMacOSProxiesAreMappedToConventionalCodexEnvironment() {
    let environment = CodexProcessEnvironment.resolved(
      base: ["PATH": "/usr/bin"],
      systemProxy: SystemNetworkProxySettings(
        httpProxy: "http://127.0.0.1:6152",
        httpsProxy: "http://127.0.0.1:6152",
        socksProxy: "socks5://127.0.0.1:6153",
        bypassHosts: ["*.local", "localhost", "invalid,entry"]
      )
    )

    #expect(environment["PATH"] == "/usr/bin")
    #expect(environment["HTTP_PROXY"] == "http://127.0.0.1:6152")
    #expect(environment["http_proxy"] == "http://127.0.0.1:6152")
    #expect(environment["HTTPS_PROXY"] == "http://127.0.0.1:6152")
    #expect(environment["https_proxy"] == "http://127.0.0.1:6152")
    #expect(environment["ALL_PROXY"] == "socks5://127.0.0.1:6153")
    #expect(environment["all_proxy"] == "socks5://127.0.0.1:6153")
    #expect(environment["NO_PROXY"] == "localhost,127.0.0.1,::1,*.local")
    #expect(environment["no_proxy"] == "localhost,127.0.0.1,::1,*.local")
  }

  @Test
  func testInheritedProxyEnvironmentWinsAndIsMirroredWithoutSystemOverride() {
    let environment = CodexProcessEnvironment.resolved(
      base: [
        "PATH": "/usr/bin",
        "https_proxy": "http://inherited.example:8080",
        "NO_PROXY": "internal.example",
      ],
      systemProxy: SystemNetworkProxySettings(
        httpProxy: "http://system.example:9000",
        httpsProxy: "http://system.example:9001",
        socksProxy: "socks5://system.example:9002"
      )
    )

    #expect(environment["HTTP_PROXY"] == nil)
    #expect(environment["http_proxy"] == nil)
    #expect(environment["HTTPS_PROXY"] == "http://inherited.example:8080")
    #expect(environment["https_proxy"] == "http://inherited.example:8080")
    #expect(environment["ALL_PROXY"] == nil)
    #expect(environment["all_proxy"] == nil)
    #expect(environment["NO_PROXY"] == "internal.example")
    #expect(environment["no_proxy"] == "internal.example")
  }

  @Test
  func testNoProxyConfigurationLeavesTheBaseEnvironmentUnchanged() {
    let base = ["PATH": "/usr/bin", "LANG": "en_US.UTF-8"]
    let environment = CodexProcessEnvironment.resolved(
      base: base,
      systemProxy: SystemNetworkProxySettings()
    )

    #expect(environment == base)
  }

  @Test
  func testConflictingInheritedVariableCasesRemainUntouched() {
    let environment = CodexProcessEnvironment.resolved(
      base: [
        "HTTPS_PROXY": "http://uppercase.example:8080",
        "https_proxy": "http://lowercase.example:8081",
      ],
      systemProxy: SystemNetworkProxySettings(httpsProxy: "http://system.example:9001")
    )

    #expect(environment["HTTPS_PROXY"] == "http://uppercase.example:8080")
    #expect(environment["https_proxy"] == "http://lowercase.example:8081")
  }

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
