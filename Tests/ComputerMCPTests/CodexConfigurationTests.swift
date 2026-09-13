import Foundation
import Testing

@testable import ComputerMCP

@Suite
final class CodexConfigurationTests {
  @Test
  func testEmbeddedCodexImportDefaultsAreDisabledAndFailClosed() throws {
    let configuration = GatewayConfiguration(codex: .init())

    let imported = try #require(configuration.codex)
    #expect(!(imported.enabled))
    #expect(imported.appServerEnabled)
    #expect(imported.execEnabled)
    #expect(imported.mcpEnabled)
    #expect(imported.experimentalAPI)
    #expect((imported.sandbox) == (.workspaceWrite))
    #expect((imported.approvalPolicy) == (.never))
    #expect((imported.maxSessions) == (8))
    #expect((imported.maxEventsPerSession) == (1_024))
    #expect(imported.appServerTerminationGraceMilliseconds == 1_000)
    #expect(imported.appServerKillGraceMilliseconds == 2_000)
    #expect(imported.appServerAppListTimeoutSeconds == 120)
    #expect(imported.appServerApprovalTimeoutSeconds == 300)
    #expect(!imported.appServerAutoApproveWorkspaceWrites)
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
    app_server_app_list_timeout_seconds = 150
    app_server_termination_grace_milliseconds = 1500
    app_server_kill_grace_milliseconds = 2500
    app_server_approval_timeout_seconds = 90
    app_server_auto_approve_workspace_writes = true
    sandbox = "read-only"
    approval_policy = "on-request"
    max_sessions = 4
    max_events_per_session = 512
    """
    .write(to: path, atomically: true, encoding: .utf8)

    let configuration = try GatewayConfiguration.load(path: path.path)

    let imported = try #require(configuration.codex)
    #expect(imported.enabled)
    #expect((imported.executable) == ("/opt/local/bin/codex"))
    #expect(imported.appServerEnabled)
    #expect(!(imported.execEnabled))
    #expect(imported.mcpEnabled)
    #expect(imported.experimentalAPI)
    #expect((imported.appServerRequestTimeoutSeconds) == (45))
    #expect(imported.appServerAppListTimeoutSeconds == 150)
    #expect(imported.appServerTerminationGraceMilliseconds == 1_500)
    #expect(imported.appServerKillGraceMilliseconds == 2_500)
    #expect(imported.appServerApprovalTimeoutSeconds == 90)
    #expect(imported.appServerAutoApproveWorkspaceWrites)
    #expect((imported.sandbox) == (.readOnly))
    #expect((imported.approvalPolicy) == (.onRequest))
    #expect((imported.maxSessions) == (4))
    #expect((imported.maxEventsPerSession) == (512))
  }

  @Test
  func testCodexRejectsUnboundedAppServerRequestDeadline() {
    let configuration = GatewayConfiguration(
      codex: CodexConfigurationImport(enabled: true, appServerRequestTimeoutSeconds: 0)
    )

    expectThrows(try configuration.validate()) { error in
      #expect(error.localizedDescription.contains("app_server_request_timeout_seconds"))
    }
  }

  @Test
  func testCodexRejectsUnboundedAppListDeadline() {
    let configuration = GatewayConfiguration(
      codex: CodexConfigurationImport(enabled: true, appServerAppListTimeoutSeconds: 301)
    )

    expectThrows(try configuration.validate()) { error in
      #expect(error.localizedDescription.contains("app_server_app_list_timeout_seconds"))
    }
  }

  @Test
  func testCodexRejectsDangerFullAccess() {
    let configuration = GatewayConfiguration(
      codex: CodexConfigurationImport(enabled: true, sandbox: .dangerFullAccess)
    )

    expectThrows(try configuration.validate()) { error in
      #expect(
        (error as? ConfigurationError) == (.invalid("codex.sandbox cannot be danger-full-access.")))
    }
  }

  @Test
  func testCodexRequiresAtLeastOneEnabledPath() {
    let configuration = GatewayConfiguration(
      codex: CodexConfigurationImport(
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
        codex: CodexConfigurationImport(enabled: true, maxSessions: 0)
      ).validate()
    )
    expectThrows(
      try GatewayConfiguration(
        codex: CodexConfigurationImport(enabled: true, maxEventsPerSession: 63)
      ).validate()
    )
  }

  @Test
  func testCodexBoundsProcessAndApprovalDeadlines() {
    expectThrows(
      try GatewayConfiguration(
        codex: CodexConfigurationImport(
          enabled: true, appServerTerminationGraceMilliseconds: 30_001)
      ).validate()
    )
    expectThrows(
      try GatewayConfiguration(
        codex: CodexConfigurationImport(enabled: true, appServerKillGraceMilliseconds: 99)
      ).validate()
    )
    expectThrows(
      try GatewayConfiguration(
        codex: CodexConfigurationImport(enabled: true, appServerApprovalTimeoutSeconds: 3_601)
      ).validate()
    )
  }
}
