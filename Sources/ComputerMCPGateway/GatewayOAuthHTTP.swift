import ComputerMCPAuthorization
import ComputerMCPCore
import Foundation
import MCP

package struct GatewayOAuthHTTP: Sendable {
  static let paths: Set<String> = [
    "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-authorization-server", "/oauth/authorize", "/oauth/authorize/status",
    "/oauth/token", "/oauth/revoke",
  ]
  package let server: OAuthAuthorizationServer
  private let currentConfiguration: @Sendable () throws -> OAuthServerConfiguration?

  package init(
    server: OAuthAuthorizationServer,
    currentConfiguration: (@Sendable () throws -> OAuthServerConfiguration?)? = nil
  ) {
    self.server = server
    self.currentConfiguration = currentConfiguration ?? { server.configuration }
  }

  func configuration(for request: HTTPRequest) throws -> OAuthServerConfiguration? {
    guard let configuration = try currentConfiguration(),
      configuration.issuer == server.configuration.issuer,
      request.header("Host")?.lowercased() == configuration.hostname.lowercased()
    else { return nil }
    return configuration
  }

  func handle(_ request: HTTPRequest, address: String) async -> HTTPResponse {
    var rateChecked = false
    do {
      guard let configuration = try configuration(for: request) else {
        return Self.response(["error": "not_found"], status: 404)
      }
      let path = normalizedHTTPPath(request.path ?? "/")
      let method = request.method.uppercased()
      switch (method, path) {
      case ("GET", "/.well-known/oauth-protected-resource/mcp"),
        ("GET", "/.well-known/oauth-protected-resource"):
        rateChecked = true
        try await server.checkRate(address: address)
        return Self.response(configuration.protectedResourceMetadata)
      case ("GET", "/.well-known/oauth-authorization-server"):
        rateChecked = true
        try await server.checkRate(address: address)
        return Self.response(configuration.authorizationServerMetadata)
      case ("GET", "/oauth/authorize"):
        let fields = try Self.query(request)
        rateChecked = true
        let pairing = try await server.authorize(
          fields, address: address, clientAllowlist: configuration.clientAllowlist)
        return .data(
          Data(Self.page(pairing).utf8),
          headers: Self.secureHeaders(contentType: "text/html; charset=utf-8"))
      case ("GET", "/oauth/authorize/status"):
        let fields = try Self.query(request)
        guard let token = fields["request"], token.count == 43 else {
          throw OAuthError.invalidRequest
        }
        rateChecked = true
        switch try await server.status(statusToken: token, address: address) {
        case .pending: return Self.response(["status": "pending"])
        case .redirect(let target):
          return Self.response(["status": "complete", "redirect_uri": target])
        }
      case ("POST", "/oauth/token"), ("POST", "/oauth/revoke"):
        guard request.header("Authorization") == nil,
          request.header("Content-Type")?.lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) == "application/x-www-form-urlencoded",
          let body = request.body, let text = String(data: body, encoding: .utf8)
        else { throw OAuthError.invalidRequest }
        let fields = try Self.form(text)
        rateChecked = true
        if path == "/oauth/token" {
          return Self.response(try await server.token(fields, address: address))
        }
        try await server.revoke(fields, address: address)
        return .data(Data(), headers: Self.secureHeaders(contentType: "application/json"))
      default:
        rateChecked = true
        try await server.checkRate(address: address)
        return Self.response(
          ["error": "invalid_request"], status: 405,
          extraHeaders: [
            "Allow": path == "/oauth/token" || path == "/oauth/revoke" ? "POST" : "GET"
          ])
      }
    } catch let error as OAuthError {
      if !rateChecked {
        do { try await server.checkRate(address: address) } catch let rateError as OAuthError {
          return Self.failure(rateError)
        } catch { return Self.response(["error": "server_error"], status: 503) }
      }
      return Self.failure(error)
    } catch {
      return Self.response(["error": "server_error"], status: 503)
    }
  }

  static func unauthorized(_ configuration: OAuthServerConfiguration?) -> HTTPResponse {
    let challenge =
      configuration.map {
        "Bearer resource_metadata=\"\($0.issuer)/.well-known/oauth-protected-resource/mcp\", scope=\"mcp\""
      } ?? "Bearer"
    return response(
      ["error": "unauthorized"], status: 401, extraHeaders: ["WWW-Authenticate": challenge])
  }

  static func failure(_ error: OAuthError) -> HTTPResponse {
    response(
      ["error": error.rawValue], status: error == .rateLimited ? 429 : 400,
      extraHeaders: error == .rateLimited ? ["Retry-After": "2"] : [:])
  }

  private static func response<T: Encodable>(
    _ value: T, status: Int = 200, extraHeaders: [String: String] = [:]
  ) -> HTTPResponse {
    var headers = secureHeaders(contentType: "application/json")
    headers["X-Computer-MCP-Status"] = String(status)
    headers.merge(extraHeaders) { _, value in value }
    return .data((try? JSONEncoder().encode(value)) ?? Data(), headers: headers)
  }

  private static func secureHeaders(contentType: String) -> [String: String] {
    [
      "Content-Type": contentType, "Cache-Control": "no-store", "Pragma": "no-cache",
      "Content-Security-Policy": "frame-ancestors 'none'", "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
    ]
  }

  private static func query(_ request: HTTPRequest) throws -> [String: String] {
    let components = (request.path ?? "").split(
      separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    return try form(components.count == 2 ? String(components[1]) : "")
  }

  /// Duplicate parameters and malformed encodings have no unambiguous OAuth meaning.
  static func form(_ text: String) throws -> [String: String] {
    guard text.utf8.count <= 16 * 1_024 else { throw OAuthError.invalidRequest }
    var fields: [String: String] = [:]
    for item in text.split(separator: "&", omittingEmptySubsequences: false) {
      let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2,
        let name = String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
        let value = String(pair[1]).replacingOccurrences(of: "+", with: " ")
          .removingPercentEncoding,
        !name.isEmpty, fields[name] == nil
      else { throw OAuthError.invalidRequest }
      fields[name] = value
    }
    return fields
  }

  private static func page(_ pairing: OAuthPairing) -> String {
    let request = pairing.request
    return """
      <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
      <title>Computer MCP client access</title><body>
      <h1>Approve in Computer MCP</h1><p>Client: <strong>\(escape(request.clientHost))</strong></p>
      <p>Redirect host: \(escape(request.redirectHost))</p><p>Pairing code: <strong>\(request.pairingCode)</strong></p>
      <p>Review this request on the Mac running Computer MCP and approve this code with the owner CLI.</p>
      <p id="status">Waiting for local approval. This request expires in ten minutes.</p>
      <script>
      const poll = async () => {
        try {
          const response = await fetch('/oauth/authorize/status?request=\(pairing.statusToken)', {cache:'no-store'});
          const result = await response.json();
          if (result.redirect_uri) { window.location.replace(result.redirect_uri); return; }
          if (!response.ok && response.status !== 429) {
            document.getElementById('status').textContent = 'This request is no longer available.'; return;
          }
        } catch (_) {}
        setTimeout(poll, 2000);
      };
      setTimeout(poll, 2000);
      </script></body></html>
      """
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}
