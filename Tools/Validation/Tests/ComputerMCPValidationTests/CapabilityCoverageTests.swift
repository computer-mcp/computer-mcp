import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite("Production Readiness Report")
struct CapabilityCoverageTests {
  @Test("Canonical catalog contains all maintained Test Cases")
  func catalog() throws {
    let catalog = try ValidationTestCaseCatalog.bundled()

    #expect(catalog.testCases.count == 22)
    #expect(catalog.validate().isEmpty)
    #expect(catalog.testCases.contains { $0.id == "connector.openai.round_trip" })
    #expect(catalog.testCases.contains { $0.id == "transport.cloudflare.quick_tunnel_isolated" })
    #expect(!catalog.testCases.contains { $0.id == "transport.cloudflare.named_tunnel" })
  }

  @Test("Missing Test Case evidence fails closed")
  func missingEvidence() {
    let report = ProductionReadinessReportBuilder().build(inventory: emptyInventory())

    #expect(!report.isReady)
    #expect(report.summary.testCaseCount == 22)
    #expect(report.summary.testCasePassedCount == 0)
    #expect(report.summary.testCasePendingCount == 22)
    #expect(
      report.issues.filter { $0.code == "test_case.correlation_incomplete" }.count == 22
    )
  }

  @Test("Verified bundle projects Test Case and capability coverage")
  func verifiedBundleProjection() throws {
    let bundle = try makeBundle()
    let report = ProductionReadinessReportBuilder().build(
      inventory: inventory(),
      fixtureReport: fixture(),
      evidenceBundles: [bundle]
    )
    let testCase = try #require(
      report.testCases.first { $0.id == "profile.observe_write_policy_denied" }
    )
    let capability = try #require(report.capabilityCoverage.first)

    #expect(testCase.status == .passed)
    #expect(testCase.observedTransports == [.openAISecureMCPTunnel])
    #expect(testCase.observedProfiles == [GatewayProfileID.chatGPTObserve.rawValue])
    #expect(capability.externalConsumer.status == .passed)
    #expect(capability.externalConsumer.testCaseID == testCase.id)
    #expect(capability.runtime.status == .pending)
    #expect(!report.isReady)
  }

  @Test("A Test Case label cannot replace its required assertions")
  func missingAssertionsFailClosed() throws {
    let bundle = try makeBundle(assertionIDs: ["step.1"])
    let report = ProductionReadinessReportBuilder().build(
      inventory: inventory(),
      fixtureReport: fixture(),
      evidenceBundles: [bundle]
    )
    let testCase = try #require(
      report.testCases.first { $0.id == "profile.observe_write_policy_denied" }
    )

    #expect(testCase.status == .pending)
    #expect(testCase.detail?.contains("expected_result.1") == true)
    #expect(
      report.issues.contains {
        $0.code == "test_case.correlation_incomplete"
          && $0.message.contains("expected_result.1")
      }
    )
  }

  @Test("Control Socket Test Cases do not masquerade as Gateway capabilities")
  func controlSocketTestCaseProjection() throws {
    let report = ProductionReadinessReportBuilder().build(
      inventory: inventory(),
      fixtureReport: fixture(),
      evidenceBundles: [try makeControlBundle()]
    )
    let testCase = try #require(
      report.testCases.first { $0.id == "installation.app_and_embedded_cli" }
    )

    #expect(testCase.status == .passed)
    #expect(!report.issues.contains { $0.code == "evidence.unknown_capability" })
    #expect(report.capabilityCoverage.count == 1)
  }

  @Test("Report emits snake-case JSON and Markdown")
  func artifacts() throws {
    let report = ProductionReadinessReportBuilder().build(inventory: emptyInventory())
    let data = try report.encodedJSON()
    let json = String(decoding: data, as: UTF8.self)
    let markdown = report.markdown()

    #expect(json.contains("\"schema_version\" : 1"))
    #expect(json.contains("\"capability_coverage\""))
    #expect(json.contains("\"test_cases\""))
    #expect(markdown.hasPrefix("# Computer MCP Production Readiness Report"))
    #expect(markdown.contains("## Capability Coverage"))
    #expect(try ProductionReadinessReport.decodeJSON(data) == report)
  }

  @Test("Duplicate inventory targets fail closed")
  func duplicateInventoryTargets() {
    let source = inventory()
    let duplicated = CapabilityInventoryReport(
      schemaVersion: source.schemaVersion,
      generatedAt: source.generatedAt,
      summary: source.summary,
      profiles: source.profiles + source.profiles,
      issues: source.issues
    )

    let report = ProductionReadinessReportBuilder().build(inventory: duplicated)

    #expect(!report.isReady)
    #expect(report.issues.contains { $0.code == "inventory.duplicate_capability" })
  }

  private func emptyInventory() -> CapabilityInventoryReport {
    CapabilityInventoryReport(
      schemaVersion: 1,
      generatedAt: timestamp,
      summary: CapabilityInventorySummary(
        profileCount: 0,
        profileToolCount: 0,
        uniqueToolCount: 0,
        issueCount: 0
      ),
      profiles: [],
      issues: []
    )
  }

  private func inventory() -> CapabilityInventoryReport {
    let tool = CapabilityInventoryTool(
      name: "policy.probe",
      domain: "policy",
      hasInputSchema: true,
      hasOutputSchema: true,
      hasAnnotations: true,
      risk: "read_only",
      workspaceRequirement: "none",
      localOnly: false,
      usesNetwork: false,
      schemaDigest: digest
    )
    let profile = CapabilityInventoryProfile(
      configuration: "runtime.toml",
      serverName: "computer-mcp",
      caller: GatewayCallerKind.secureTunnel.rawValue,
      profile: GatewayProfileID.chatGPTObserve.rawValue,
      toolCount: 1,
      toolNames: [tool.name],
      domains: [CapabilityInventoryDomain(name: "system", toolCount: 1, toolNames: [tool.name])],
      tools: [tool],
      duplicateToolNames: [],
      requiresRuntimeEvidence: true,
      acceptanceDigest: digest
    )
    return CapabilityInventoryReport(
      schemaVersion: 1,
      generatedAt: timestamp,
      summary: CapabilityInventorySummary(
        profileCount: 1,
        profileToolCount: 1,
        uniqueToolCount: 1,
        issueCount: 0
      ),
      profiles: [profile],
      issues: []
    )
  }

  private func fixture() -> CapabilityFixtureReport {
    CapabilityFixtureReport(
      generatedAt: timestamp,
      rootPath: "/tmp/computer-mcp-validation",
      entries: [],
      contentDigest: digest
    )
  }

  private func makeBundle(
    assertionIDs: [String] = ["step.1", "expected_result.1"]
  ) throws -> ValidationEvidenceBundle {
    let outputDigest = String(repeating: "b", count: 64)
    let environment = ValidationEnvironment(
      appBundleIdentifier: "com.example.computer-mcp",
      appVersion: "1.0.0",
      appBuild: "1",
      appDigest: digest,
      buildDigest: digest,
      configuration: "runtime.toml",
      configurationDigest: digest,
      catalogDigest: digest,
      profileID: .chatGPTObserve,
      profileDigest: digest,
      fixtureDigest: digest
    )
    let audit = AuditEvent(
      id: "audit-observe-denial",
      requestID: "gateway-observe-denial",
      mcpRequestID: "consumer-observe-denial",
      caller: .secureTunnel,
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: "tunnel-1",
      tunnelProfileID: "openai-observe",
      profileID: .chatGPTObserve,
      capabilityID: "policy.probe",
      decision: .allowed,
      inputDigest: digest,
      outputDigest: outputDigest,
      outputByteCount: 64,
      outputTruncated: false
    )
    let attempt = ValidationAttempt(
      id: "attempt-observe-denial",
      testCaseID: "profile.observe_write_policy_denied",
      generatedAt: timestamp,
      toolName: "policy.probe",
      capabilityID: "policy.probe",
      profileID: .chatGPTObserve,
      inputDigest: digest,
      consumerResultID: "chatgpt-result-observe-denial",
      gatewayRequestID: audit.requestID,
      auditEvent: audit,
      result: ValidationResultDigest(digest: outputDigest, byteCount: 64),
      outcome: .passed,
      assertions: assertionIDs.map {
        ValidationAssertion(id: $0, passed: true, observationDigest: digest)
      },
      independentPostconditions: [
        ValidationPostcondition(
          id: "cleanup.1",
          passed: true,
          observer: "browser_result",
          observationDigest: digest
        )
      ]
    )
    let run = ValidationRun(
      id: "run-observe-denial",
      generatedAt: timestamp,
      layer: .externalConsumer,
      consumer: ValidationConsumer(kind: "chatgpt"),
      environment: environment,
      transport: ValidationTransportProvenance(
        transport: .openAISecureMCPTunnel,
        tunnelInstanceID: "tunnel-1",
        tunnelProfileID: "openai-observe",
        socketConnectionID: "socket-1"
      ),
      attempts: [attempt]
    )
    return try ValidationEvidenceBundle.sealed(
      id: "evidence-observe-denial",
      generatedAt: timestamp,
      environment: environment,
      runs: [run]
    )
  }

  private func makeControlBundle() throws -> ValidationEvidenceBundle {
    let outputDigest = String(repeating: "c", count: 64)
    let environment = ValidationEnvironment(
      appBundleIdentifier: "com.example.computer-mcp",
      appVersion: "1.0.0",
      appBuild: "1",
      appDigest: digest,
      buildDigest: digest,
      configuration: "runtime.toml",
      configurationDigest: digest,
      catalogDigest: digest,
      profileID: .localAdmin,
      profileDigest: digest,
      fixtureDigest: digest
    )
    let audit = AuditEvent(
      id: "audit-installation",
      requestID: "gateway-installation",
      mcpRequestID: "client-installation",
      caller: .localCLI,
      transport: ValidationTransport.controlSocket.rawValue,
      socketConnectionID: "control-socket-1",
      profileID: .localAdmin,
      capabilityID: "app.status",
      decision: .allowed,
      inputDigest: digest,
      outputDigest: outputDigest,
      outputByteCount: 64,
      outputTruncated: false
    )
    let attempt = ValidationAttempt(
      id: "attempt-installation",
      testCaseID: "installation.app_and_embedded_cli",
      generatedAt: timestamp,
      toolName: "app.status",
      capabilityID: "app.status",
      profileID: .localAdmin,
      inputDigest: digest,
      transportRequestID: "client-installation",
      gatewayRequestID: audit.requestID,
      auditEvent: audit,
      result: ValidationResultDigest(digest: outputDigest, byteCount: 64),
      outcome: .passed,
      assertions: [
        ValidationAssertion(id: "step.1", passed: true, observationDigest: digest),
        ValidationAssertion(id: "expected_result.1", passed: true, observationDigest: digest),
      ],
      independentPostconditions: [
        ValidationPostcondition(
          id: "cleanup.1",
          passed: true,
          observer: "distribution_verifier",
          observationDigest: digest
        )
      ]
    )
    return try ValidationEvidenceBundle.sealed(
      id: "evidence-installation",
      generatedAt: timestamp,
      environment: environment,
      runs: [
        ValidationRun(
          id: "run-installation",
          generatedAt: timestamp,
          layer: .runtime,
          environment: environment,
          transport: ValidationTransportProvenance(
            transport: .controlSocket,
            socketConnectionID: "control-socket-1"
          ),
          attempts: [attempt]
        )
      ]
    )
  }

  private var timestamp: String { "2026-08-02T00:00:00.000Z" }
  private var digest: String { String(repeating: "a", count: 64) }
}
