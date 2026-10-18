import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class HTTPBearerAuthenticatorTests {
  @Test
  func testNoAuthModeAllowsRequestsWhenBearerIsNotConfigured() {
    let authenticator = HTTPBearerAuthenticator(configuration: HTTPServerConfig())

    #expect(
      (authenticator.authorizationError(for: HTTPRequest(method: "POST", path: "/mcp"))) == nil)
    #expect(
      authenticator.authenticatedPrincipalID(
        for: HTTPRequest(
          method: "POST", headers: [HTTPHeaderName.authorization: "Bearer self-claimed"],
          path: "/mcp"))
        == nil)
  }

  @Test
  func testPrincipalBelongsToVerifiedCredentialNotSessionOrClaimedIdentity() throws {
    let authenticator = HTTPBearerAuthenticator(
      configuration: HTTPServerConfig(), accessToken: "shared-fixture-token")
    let first = HTTPRequest(
      method: "POST",
      headers: [
        HTTPHeaderName.authorization: "Bearer shared-fixture-token",
        HTTPHeaderName.sessionID: "first-session",
        "X-Principal-ID": "forged-owner",
      ], path: "/mcp")
    let reconnected = HTTPRequest(
      method: "POST",
      headers: [
        HTTPHeaderName.authorization: "Bearer shared-fixture-token",
        HTTPHeaderName.sessionID: "new-session",
      ], path: "/mcp")
    let principal = try #require(authenticator.authenticatedPrincipalID(for: first))
    #expect(principal == authenticator.authenticatedPrincipalID(for: reconnected))
    #expect(principal.hasPrefix("credential:sha256:"))
    #expect(!principal.contains("shared-fixture-token"))
    #expect(!principal.contains("forged-owner"))

    let other = HTTPBearerAuthenticator(
      configuration: HTTPServerConfig(), accessToken: "other-fixture-token")
    #expect(other.authenticatedPrincipalID(for: first) == nil)
    let otherRequest = HTTPRequest(
      method: "POST", headers: [HTTPHeaderName.authorization: "Bearer other-fixture-token"],
      path: "/mcp")
    #expect(try #require(other.authenticatedPrincipalID(for: otherRequest)) != principal)
  }

  @Test
  func testMissingBearerEnvironmentDeniesRequest() {
    let authenticator = HTTPBearerAuthenticator(
      configuration: HTTPServerConfig(
        accessTokenEnv: "COMPUTER_MCP_TEST_MISSING_BEARER"
      ),
      environment: [:]
    )

    let response = authenticator.authorizationError(
      for: HTTPRequest(method: "POST", path: "/mcp")
    )

    #expect((response?.headers["X-Computer-MCP-Status"]) == ("401"))
    #expect((response?.headers[HTTPHeaderName.wwwAuthenticate]) == ("Bearer"))
  }

  @Test
  func testMatchingBearerAllowsRequestAndMismatchIsDenied() {
    let authenticator = HTTPBearerAuthenticator(
      configuration: HTTPServerConfig(
        accessTokenEnv: "COMPUTER_MCP_TEST_BEARER"
      ),
      environment: ["COMPUTER_MCP_TEST_BEARER": "expected-token"]
    )

    #expect(
      (authenticator.authorizationError(
        for: HTTPRequest(
          method: "POST",
          headers: [HTTPHeaderName.authorization: "Bearer expected-token"],
          path: "/mcp"
        )
      )) == nil)
    #expect(
      (authenticator.authorizationError(
        for: HTTPRequest(
          method: "POST",
          headers: [HTTPHeaderName.authorization: "Bearer wrong-token"],
          path: "/mcp"
        )
      )?.headers["X-Computer-MCP-Status"]) == ("401"))
  }

  @Test
  func testConstantTimeDigestHelperChecksEveryFixedDigestPosition() {
    let expected = Array(repeating: UInt8(0x5A), count: 32)
    var firstMismatch = expected
    firstMismatch[0] ^= 0xFF
    var lastMismatch = expected
    lastMismatch[31] ^= 0xFF

    #expect(HTTPBearerAuthenticator.constantTimeEqual(expected, expected))
    #expect(!HTTPBearerAuthenticator.constantTimeEqual(firstMismatch, expected))
    #expect(!HTTPBearerAuthenticator.constantTimeEqual(lastMismatch, expected))
    #expect(!HTTPBearerAuthenticator.constantTimeEqual(Array(expected.dropLast()), expected))
  }
}
