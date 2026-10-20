import ComputerMCPCore
import ComputerMCPPlatform
import Foundation

package func validateHTTPCheckURL(_ value: String) throws -> URL {
  try validateUTF8ByteLimit(value, name: "url", maxBytes: 4_096)
  guard !value.isEmpty else {
    throw GatewayToolError.invalidArguments("url must not be empty.")
  }
  guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
    throw GatewayToolError.invalidArguments("url must not contain whitespace.")
  }
  guard
    value.unicodeScalars.allSatisfy({ scalar in
      !((scalar.value <= 0x1F) || (scalar.value >= 0x7F && scalar.value <= 0x9F))
    })
  else {
    throw GatewayToolError.invalidArguments("url must not contain control characters.")
  }
  guard var components = URLComponents(string: value),
    let scheme = components.scheme?.lowercased(),
    scheme == "http" || scheme == "https",
    let host = components.host,
    !host.isEmpty
  else {
    throw GatewayToolError.invalidArguments("url must be an absolute http or https URL.")
  }
  guard components.user == nil, components.password == nil else {
    throw GatewayToolError.invalidArguments("url must not contain userinfo credentials.")
  }
  components.scheme = scheme
  guard let url = components.url else {
    throw GatewayToolError.invalidArguments("url must be a valid absolute URL.")
  }
  return url
}

package func networkCommandSummary(_ result: CommandResult) -> JSONValue {
  .object([
    "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
    "timed_out": .bool(result.timedOut),
    "stderr": .string(result.stderr),
    "stdout_truncated": .bool(result.stdoutTruncated),
    "stderr_truncated": .bool(result.stderrTruncated),
  ])
}

package func parseHTTPCheckOutput(
  _ stdout: String,
  marker: String,
  includeBody: Bool,
  maxBodyBytes: Int,
  stdoutTruncated: Bool
) -> HTTPCheckOutput {
  guard let markerRange = stdout.range(of: "\n\(marker)\n", options: .backwards) else {
    let body = includeBody && !stdout.isEmpty ? String(stdout.prefix(maxBodyBytes)) : nil
    return HTTPCheckOutput(
      metaFound: false,
      httpCode: nil,
      urlEffective: nil,
      contentType: nil,
      redirectURL: nil,
      timeTotal: nil,
      sizeDownload: nil,
      body: body,
      bodyTruncated: includeBody && (stdoutTruncated || stdout.utf8.count > maxBodyBytes)
    )
  }

  let bodyText = String(stdout[..<markerRange.lowerBound])
  let metaText = String(stdout[markerRange.upperBound...])
  let meta = Dictionary(
    uniqueKeysWithValues: metaText.split(separator: "\n").compactMap {
      line -> (String, String)? in
      guard let separator = line.firstIndex(of: "=") else {
        return nil
      }
      let key = String(line[..<separator])
      let value = String(line[line.index(after: separator)...])
      return (key, value)
    })

  let body: String?
  let bodyTruncated: Bool
  if includeBody {
    let limitedBody =
      bodyText.utf8.count > maxBodyBytes ? String(bodyText.prefix(maxBodyBytes)) : bodyText
    body = limitedBody
    bodyTruncated =
      stdoutTruncated || bodyText.utf8.count > maxBodyBytes
      || (Double(meta["size_download"] ?? "") ?? 0) > Double(maxBodyBytes)
  } else {
    body = nil
    bodyTruncated = false
  }

  return HTTPCheckOutput(
    metaFound: true,
    httpCode: Int(meta["http_code"] ?? ""),
    urlEffective: emptyStringAsNil(meta["url_effective"]),
    contentType: emptyStringAsNil(meta["content_type"]),
    redirectURL: emptyStringAsNil(meta["redirect_url"]),
    timeTotal: Double(meta["time_total"] ?? ""),
    sizeDownload: Double(meta["size_download"] ?? ""),
    body: body,
    bodyTruncated: bodyTruncated
  )
}

private func emptyStringAsNil(_ value: String?) -> String? {
  guard let value, !value.isEmpty else {
    return nil
  }
  return value
}

package struct HTTPCheckOutput {
  package var metaFound: Bool
  package var httpCode: Int?
  package var urlEffective: String?
  package var contentType: String?
  package var redirectURL: String?
  package var timeTotal: Double?
  package var sizeDownload: Double?
  package var body: String?
  package var bodyTruncated: Bool
}
