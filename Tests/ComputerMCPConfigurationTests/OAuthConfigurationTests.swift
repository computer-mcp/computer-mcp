import ComputerMCPConfiguration
import Foundation
import Testing

struct OAuthConfigurationTests {
  @Test func oauthDefaultsOffAndRoundTripsSnakeCaseSettings() throws {
    let text = """
      schema_version = 1
      [[transports.cloudflare]]
      id = "fixture"
      tunnel_name = "named"
      public_hostname = "gateway.example"
      """
    let base = URL(fileURLWithPath: "/tmp/oauth-configuration")
    var configuration = try GatewayConfiguration.load(text: text, baseURL: base)
    #expect(configuration.transports.cloudflare[0].oauthEnabled == false)
    #expect(
      configuration.transports.cloudflare[0].oauthClientAllowlist == ["claude.ai", "claude.com"])
    configuration.transports.cloudflare[0].oauthEnabled = true
    configuration.transports.cloudflare[0].oauthClientAllowlist = ["client.example"]
    let exported = try configuration.exportedTOML()
    let restored = try GatewayConfiguration.load(text: exported, baseURL: base)
    #expect(restored.transports.cloudflare == configuration.transports.cloudflare)
    #expect(exported.contains("oauth_enabled = true"))
    #expect(exported.contains("oauth_client_allowlist"))
  }

  @Test(arguments: [
    "*.example", "https://client.example", "client.example/path", "user@client.example",
    "client.example:443", "client.example?query", "client.example#fragment", "",
  ])
  func allowlistUsesExactHosts(host: String) {
    #expect(throws: (any Error).self) {
      try CloudflareTunnelTransportConfig.validateOAuthClientAllowlist([host])
    }
  }
}
