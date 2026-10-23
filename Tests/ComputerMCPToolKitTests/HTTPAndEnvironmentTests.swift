import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPToolKit
import Foundation
import Testing

struct HTTPAndEnvironmentTests {
  @Test(arguments: [
    ("", "url must not be empty."),
    ("https://example.com/a b", "url must not contain whitespace."),
    ("https://example.com/\u{1}", "url must not contain control characters."),
    ("file:///tmp/file", "url must be an absolute http or https URL."),
    ("https://user:password@example.com", "url must not contain userinfo credentials."),
  ])
  func httpURLValidationKeepsExactErrors(value: String, message: String) {
    #expect(throws: GatewayToolError.invalidArguments(message)) {
      try validateHTTPCheckURL(value)
    }
  }

  @Test
  func httpURLNormalizationKeepsPathQueryAndFragment() throws {
    #expect(
      try validateHTTPCheckURL("HTTPS://example.com/a?q=1#part").absoluteString
        == "https://example.com/a?q=1#part")
  }

  @Test
  func httpMetadataUsesTheFinalMarkerAndPreservesBodyTruncation() {
    let output = """
      body
      MARK
      body data
      MARK
      http_code=204
      url_effective=https://example.com/
      content_type=
      redirect_url=
      time_total=0.125
      size_download=64
      """
    let parsed = parseHTTPCheckOutput(
      output, marker: "MARK", includeBody: true, maxBodyBytes: 4, stdoutTruncated: false)
    #expect(parsed.metaFound && parsed.httpCode == 204)
    #expect(parsed.urlEffective == "https://example.com/")
    #expect(parsed.contentType == nil && parsed.redirectURL == nil)
    #expect(parsed.timeTotal == 0.125 && parsed.sizeDownload == 64)
    #expect(parsed.body == "body" && parsed.bodyTruncated)
    let hidden = parseHTTPCheckOutput(
      output, marker: "MARK", includeBody: false, maxBodyBytes: 4, stdoutTruncated: true)
    #expect(hidden.body == nil && !hidden.bodyTruncated)
  }

  @Test
  func httpFallbackRetainsCharacterPrefixAndByteTruncationRules() {
    let parsed = parseHTTPCheckOutput(
      "空格x", marker: "missing", includeBody: true, maxBodyBytes: 2, stdoutTruncated: false)
    #expect(!parsed.metaFound && parsed.httpCode == nil)
    #expect(parsed.body == "空格" && parsed.bodyTruncated)
    let empty = parseHTTPCheckOutput(
      "", marker: "missing", includeBody: true, maxBodyBytes: 2, stdoutTruncated: true)
    #expect(empty.body == nil && empty.bodyTruncated)
    let summary = networkCommandSummary(
      .init(
        executable: "curl", arguments: [], exitCode: nil, timedOut: true, stdout: "body",
        stderr: "timeout", stdoutTruncated: true, stderrTruncated: false))
    #expect(
      summary
        == .object([
          "exit_code": .null, "timed_out": .bool(true), "stderr": .string("timeout"),
          "stdout_truncated": .bool(true), "stderr_truncated": .bool(false),
        ]))
  }

  @Test
  func environmentDescriptionsTrackPresenceAndRedactValues() {
    var keys: Set<String> = ["EXISTING"]
    let entry = environmentEntry(
      key: "TOKEN", owner: "provider", purpose: "authentication", valueOrigin: "manifest",
      processEnvironment: ["TOKEN": "synthetic-value"], declaredKeys: &keys)
    #expect(keys == ["EXISTING", "TOKEN"])
    #expect(
      entry
        == .object([
          "key": .string("TOKEN"), "owner": .string("provider"),
          "purpose": .string("authentication"), "value_origin": .string("manifest"),
          "process_environment_present": .bool(true), "value_redacted": .bool(true),
        ]))
    #expect(httpAuthMode(configuration: .init()) == "none")
    #expect(
      httpAuthMode(configuration: .init(server: .init(http: .init(accessTokenEnv: "TOKEN"))))
        == "bearer")
  }

  @Test
  func pathSearchDropsEmptyEntriesAndRetainsDeclaredOrder() throws {
    #expect(
      pathSearchDirectories(environment: ["PATH": ":/first::/second:/first:"])
        == ["/first", "/second", "/first"])
    #expect(pathSearchDirectories(environment: ["PATH": ""]).isEmpty)
    #expect(
      pathSearchDirectories(environment: [:])
        == ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    try validateExecutableLookupName("tool-name_1.0+@")
    #expect(throws: GatewayToolError.invalidArguments("name must not start with an option marker."))
    {
      try validateExecutableLookupName("--tool")
    }
    #expect(throws: GatewayToolError.invalidArguments("name must be an executable basename.")) {
      try validateExecutableLookupName("..")
    }
    #expect(
      throws: GatewayToolError.invalidArguments(
        "name must be an executable basename without slashes or whitespace.")
    ) {
      try validateExecutableLookupName("path/tool")
    }
  }

  @Test
  func gitPathsPreserveLiteralPathspecsAndRejectTraversal() throws {
    #expect(try optionalGitPaths(in: [:]).isEmpty)
    #expect(
      try optionalGitPaths(in: ["paths": .array([.string("a/./b"), .string("space name")])])
        == ["a/./b", "space name"])
    for (path, message) in [
      ("", "paths must not contain empty strings."),
      ("/root/file", "paths must be project-relative: /root/file"),
      (":(glob)*", "git pathspec magic is not supported: :(glob)*"),
      (":/query", "git pathspec magic is not supported: :/query"),
      ("a/../b", "paths must not escape project: a/../b"),
    ] {
      #expect(throws: GatewayToolError.invalidArguments(message)) {
        try optionalGitPaths(in: ["paths": .array([.string(path)])])
      }
    }
  }
}
