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
