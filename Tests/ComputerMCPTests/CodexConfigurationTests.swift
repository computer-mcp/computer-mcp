import Foundation
import Testing

@testable import ComputerMCP

@Suite
final class CodexConfigurationTests {
  @Test
  func testCodexDefaultsAreDisabledAndFailClosed() throws {
    let configuration = GatewayConfiguration()

    #expect(!(configuration.codex.enabled))
    #expect(configuration.codex.appServerEnabled)
    #expect(configuration.codex.execEnabled)
    #expect(configuration.codex.mcpEnabled)
    #expect(configuration.codex.experimentalAPI)
    #expect((configuration.codex.sandbox) == (.workspaceWrite))
    #expect((configuration.codex.approvalPolicy) == (.never))
    #expect((configuration.codex.maxSessions) == (8))
    #expect((configuration.codex.maxEventsPerSession) == (1_024))
    expectNoThrow(try configuration.validate())
  }

  @Test
  func testCodexTOMLLoadsAllRuntimeSettings() throws {
    let directory = try ScopedTemporaryDirectory()
    let path = directory.url.appendingPathComponent("computer-mcp.toml")
    try """
    schema_version = 1

    [codex]
    enabled = true
    executable = "/opt/local/bin/codex"
    app_server_enabled = true
    exec_enabled = false
    mcp_enabled = true
    experimental_api = true
    app_server_request_timeout_seconds = 45
    sandbox = "read-only"
    approval_policy = "on-request"
    max_sessions = 4
    max_events_per_session = 512
    """
    .write(to: path, atomically: true, encoding: .utf8)

    let configuration = try GatewayConfiguration.load(path: path.path)

    #expect(configuration.codex.enabled)
    #expect((configuration.codex.executable) == ("/opt/local/bin/codex"))
    #expect(configuration.codex.appServerEnabled)
    #expect(!(configuration.codex.execEnabled))
    #expect(configuration.codex.mcpEnabled)
    #expect(configuration.codex.experimentalAPI)
    #expect((configuration.codex.appServerRequestTimeoutSeconds) == (45))
    #expect((configuration.codex.sandbox) == (.readOnly))
    #expect((configuration.codex.approvalPolicy) == (.onRequest))
    #expect((configuration.codex.maxSessions) == (4))
    #expect((configuration.codex.maxEventsPerSession) == (512))
  }

  @Test
  func testCodexRejectsUnboundedAppServerRequestDeadline() {
    let configuration = GatewayConfiguration(
      codex: CodexConfig(enabled: true, appServerRequestTimeoutSeconds: 0)
    )

    expectThrows(try configuration.validate()) { error in
      #expect(error.localizedDescription.contains("app_server_request_timeout_seconds"))
    }
  }

  @Test
  func testCodexRejectsDangerFullAccess() {
    let configuration = GatewayConfiguration(
      codex: CodexConfig(enabled: true, sandbox: .dangerFullAccess)
    )

    expectThrows(try configuration.validate()) { error in
      #expect(
        (error as? ConfigurationError) == (.invalid("codex.sandbox cannot be danger-full-access.")))
    }
  }

  @Test
  func testCodexRequiresAtLeastOneEnabledPath() {
    let configuration = GatewayConfiguration(
      codex: CodexConfig(
        enabled: true,
        appServerEnabled: false,
        execEnabled: false,
        mcpEnabled: false
      )
    )

    expectThrows(try configuration.validate()) { error in
      #expect(
        (error as? ConfigurationError)
          == (.invalid("At least one Codex path must be enabled when [codex].enabled is true.")))
    }
  }

  @Test
  func testCodexBoundsSessionAndEventLimits() {
    expectThrows(
      try GatewayConfiguration(
        codex: CodexConfig(enabled: true, maxSessions: 0)
      ).validate()
    )
    expectThrows(
      try GatewayConfiguration(
        codex: CodexConfig(enabled: true, maxEventsPerSession: 63)
      ).validate()
    )
  }
}
