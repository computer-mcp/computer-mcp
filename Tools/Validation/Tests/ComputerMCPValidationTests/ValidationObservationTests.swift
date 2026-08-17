import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite("Validation observation correlation")
struct ValidationObservationTests {
  @Test("Reviewed expected failures stay scoped to explicit fail-closed capabilities")
  func reviewedExpectedFailurePolicy() {
    #expect(
      ValidationReviewedOutcomePolicy.permitsExpectedFailure(
        testCaseID: "catalog.dynamic_full_coverage",
        toolName: "codex.app.apps.list"
      )
    )
    #expect(
      ValidationReviewedOutcomePolicy.permitsExpectedFailure(
        testCaseID: "catalog.dynamic_full_coverage",
        toolName: "codex.app.requests.respond"
      )
    )
    #expect(
      ValidationReviewedOutcomePolicy.permitsExpectedFailure(
        testCaseID: "catalog.dynamic_full_coverage",
        toolName: "codex.mcp.approval.respond"
      )
    )
    #expect(
      !ValidationReviewedOutcomePolicy.permitsExpectedFailure(
        testCaseID: "catalog.dynamic_full_coverage",
        toolName: "system.time"
      )
    )
    #expect(
      !ValidationReviewedOutcomePolicy.permitsExpectedFailure(
        testCaseID: "transport.cloudflare.quick_tunnel_isolated",
        toolName: "codex.app.requests.respond"
      )
    )
  }

  @Test("Only the audited Codex App directory 403 is a reviewed upstream challenge")
  func reviewedUpstreamDirectoryChallenge() {
    let providerResult =
      "codex.app.request_failed: failed to list apps: Request failed with status 403 Forbidden"
    #expect(
      ValidationReviewedOutcomePolicy.permitsUpstreamDirectoryChallenge(
        testCaseID: "catalog.dynamic_full_coverage",
        toolName: "codex.app.apps.list",
        providerResult: providerResult,
        auditDecision: "failed",
        auditErrorCode: "gateway.execution_failed"
      )
    )
    #expect(
      !ValidationReviewedOutcomePolicy.permitsUpstreamDirectoryChallenge(
        testCaseID: "catalog.dynamic_full_coverage",
        toolName: "codex.app.apps.list",
        providerResult: providerResult.replacingOccurrences(of: "403", with: "500"),
        auditDecision: "failed",
        auditErrorCode: "gateway.execution_failed"
      )
    )
    #expect(
      !ValidationReviewedOutcomePolicy.permitsUpstreamDirectoryChallenge(
        testCaseID: "catalog.dynamic_full_coverage",
        toolName: "codex.app.apps.list",
        providerResult: providerResult,
        auditDecision: "failed",
        auditErrorCode: nil
      )
    )
    #expect(
      !ValidationReviewedOutcomePolicy.permitsUpstreamDirectoryChallenge(
        testCaseID: "catalog.dynamic_full_coverage",
        toolName: "system.time",
        providerResult: providerResult,
        auditDecision: "failed",
        auditErrorCode: "gateway.execution_failed"
      )
    )
  }

  @Test("Observation collector rejects an unreviewed expected failure")
  func unreviewedExpectedFailureObservation() throws {
    let observations = ValidationObservationBundle(
      generatedAt: timestamp,
      layer: .runtime,
      transport: ValidationTransportProvenance(
        transport: .gatewaySocket,
        socketConnectionID: "socket-unreviewed-failure-1"
      ),
      observations: [
        ValidationObservation(
          id: "unreviewed-failure-observation-1",
          testCaseID: "catalog.dynamic_full_coverage",
          generatedAt: timestamp,
          toolName: "system.time",
          transportRequestID: "client-unreviewed-failure-1",
          gatewayRequestID: "gateway-unreviewed-failure-1",
          passed: true,
          observationDigest: digest,
          assertionIDs: ["step.1", "expected_result.1"],
          expectedOutcome: .expectedFailure,
          independentPostconditions: [
            ValidationPostcondition(
              id: "cleanup.1",
              passed: true,
              observer: "fixture_semantic_validator",
              observationDigest: digest
            )
          ]
        )
      ]
    )

    expectThrows(
      try ValidationObservationCollector(database: GatewayDatabase(inMemory: ())).collect(
        observations: observations,
        runID: "run-unreviewed-failure-001",
        environment: makeEnvironment(profileID: .chatGPTOperate)
      )
    ) { error in
      guard case ValidationObservationCollectorError.invalidObservation(let detail) = error else {
        Issue.record("Expected invalidObservation; received \(error)")
        return
      }
      #expect(detail.contains("expected_failure"))
    }
  }

  @Test("OpenAI consumer result correlates to one audit row")
  func openAICorrelation() throws {
    let database = try GatewayDatabase(inMemory: ())
    try database.recordAudit(makeAudit())

    let bundle = try ValidationObservationCollector(database: database).collect(
      observations: makeObservations(),
      runID: "run-openai-001",
      environment: makeEnvironment()
    )
    let verification = ValidationEvidenceBundleVerifier().verify(bundle, database: database)

    #expect(verification.isVerified, Comment(rawValue: String(describing: verification.issues)))
    #expect(bundle.runs[0].consumer?.kind == "chatgpt")
    #expect(bundle.runs[0].transport.transport == .openAISecureMCPTunnel)
    #expect(bundle.runs[0].attempts[0].consumerResultID == "consumer-result-1")
    #expect(bundle.runs[0].attempts[0].testCaseID == "profile.observe_write_policy_denied")
  }

  @Test("Observed transport request mismatch is rejected")
  func transportRequestMismatch() throws {
    let database = try GatewayDatabase(inMemory: ())
    try database.recordAudit(makeAudit())
    let observations = ValidationObservationBundle(
      generatedAt: timestamp,
      layer: .externalConsumer,
      consumer: ValidationConsumer(kind: "chatgpt"),
      transport: transport,
      observations: [makeObservation(transportRequestID: "wrong-request")]
    )

    expectThrows(
      try ValidationObservationCollector(database: database).collect(
        observations: observations,
        runID: "run-openai-002",
        environment: makeEnvironment()
      )
    ) { error in
      guard case ValidationObservationCollectorError.auditMismatch = error else {
        Issue.record("Expected auditMismatch; received \(error)")
        return
      }
    }
  }

  @Test("Observation document encodes consumer and transport generically")
  func observationSchema() throws {
    let observations = makeObservations()
    let data = try observations.encodedJSON()
    let encoded = String(decoding: data, as: UTF8.self)

    #expect(encoded.contains("\"kind\" : \"chatgpt\""))
    #expect(encoded.contains("\"transport\" : \"openai_secure_mcp_tunnel\""))
    #expect(encoded.contains("\"consumer_result_id\""))
    #expect(encoded.contains("\"layer\" : \"external_consumer\""))
    #expect(!encoded.contains(["back", "end"].joined()))
    #expect(try ValidationObservationBundle.decodeJSON(data) == observations)
  }

  @Test("Observation decoder rejects a noncurrent schema")
  func observationSchemaVersion() throws {
    let current = try JSONDecoder().decode(
      JSONValue.self,
      from: makeObservations().encodedJSON()
    )
    var object = try #require(current.objectValue)
    object["schema_version"] = .number(3)

    expectThrows(
      try ValidationObservationBundle.decodeJSON(
        JSONEncoder().encode(JSONValue.object(object))
      )
    ) { error in
      #expect(
        error as? ValidationArtifactError
          == ValidationArtifactError.unsupportedSchema(
            artifact: "Validation Observation Bundle",
            expected: 2,
            actual: 3
          )
      )
    }
  }

  @Test("Observation decoder rejects fields outside the current schema")
  func observationUnknownField() throws {
    let current = try JSONDecoder().decode(
      JSONValue.self,
      from: makeObservations().encodedJSON()
    )
    var object = try #require(current.objectValue)
    object["deprecated_field"] = .bool(true)

    expectThrows(
      try ValidationObservationBundle.decodeJSON(
        JSONEncoder().encode(JSONValue.object(object))
      )
    ) { error in
      #expect(
        error as? ValidationArtifactError
          == ValidationArtifactError.noncanonicalShape(
            artifact: "Validation Observation Bundle"
          )
      )
    }
  }

  @Test("Runtime result correlates without an external consumer")
  func runtimeCorrelation() throws {
    let database = try GatewayDatabase(inMemory: ())
    let runtimeAudit = AuditEvent(
      id: "audit-runtime-1",
      requestID: "gateway-runtime-1",
      mcpRequestID: "client-runtime-1",
      caller: .localMCP,
      transport: "gateway_socket",
      socketConnectionID: "socket-runtime-1",
      profileID: .chatGPTOperate,
      capabilityID: "system.time",
      decision: .allowed,
      inputDigest: digest,
      outputDigest: outputDigest,
      outputByteCount: 64,
      outputTruncated: false
    )
    try database.recordAudit(runtimeAudit)
    let observations = ValidationObservationBundle(
      generatedAt: timestamp,
      layer: .runtime,
      transport: ValidationTransportProvenance(
        transport: .gatewaySocket,
        socketConnectionID: "socket-runtime-1"
      ),
      observations: [
        ValidationObservation(
          id: "runtime-observation-1",
          testCaseID: "catalog.dynamic_full_coverage",
          generatedAt: timestamp,
          toolName: "system.time",
          transportRequestID: "client-runtime-1",
          gatewayRequestID: "gateway-runtime-1",
          passed: true,
          observationDigest: digest,
          assertionIDs: ["step.1", "expected_result.1"],
          independentPostconditions: [
            ValidationPostcondition(
              id: "cleanup.1",
              passed: true,
              observer: "fixture_inspector",
              observationDigest: digest
            )
          ]
        )
      ]
    )

    let bundle = try ValidationObservationCollector(database: database).collect(
      observations: observations,
      runID: "run-runtime-001",
      environment: makeEnvironment(profileID: .chatGPTOperate)
    )

    #expect(bundle.runs[0].layer == .runtime)
    #expect(bundle.runs[0].consumer == nil)
    #expect(bundle.runs[0].attempts[0].consumerResultID == nil)
    #expect(ValidationEvidenceBundleVerifier().verify(bundle, database: database).isVerified)
  }

  @Test("Authenticated OpenAI runtime result preserves Tunnel provenance")
  func authenticatedOpenAIRuntimeCorrelation() throws {
    let database = try GatewayDatabase(inMemory: ())
    let runtimeAudit = AuditEvent(
      id: "audit-openai-runtime-1",
      requestID: "gateway-openai-runtime-1",
      mcpRequestID: "client-openai-runtime-1",
      caller: .secureTunnel,
      transport: "gateway_socket",
      socketConnectionID: "socket-openai-runtime-1",
      tunnelInstanceID: "tunnel-openai-runtime-1",
      tunnelProfileID: "computer-mcp",
      profileID: .chatGPTOperate,
      capabilityID: "system.time",
      decision: .allowed,
      inputDigest: digest,
      outputDigest: outputDigest,
      outputByteCount: 64,
      outputTruncated: false
    )
    try database.recordAudit(runtimeAudit)
    let observations = ValidationObservationBundle(
      generatedAt: timestamp,
      layer: .runtime,
      transport: ValidationTransportProvenance(
        transport: .openAISecureMCPTunnel,
        tunnelInstanceID: "tunnel-openai-runtime-1",
        tunnelProfileID: "computer-mcp",
        socketConnectionID: "socket-openai-runtime-1"
      ),
      observations: [
        ValidationObservation(
          id: "openai-runtime-observation-1",
          testCaseID: "catalog.dynamic_full_coverage",
          generatedAt: timestamp,
          toolName: "system.time",
          transportRequestID: "client-openai-runtime-1",
          gatewayRequestID: "gateway-openai-runtime-1",
          passed: true,
          observationDigest: digest,
          assertionIDs: ["step.1", "expected_result.1"],
          independentPostconditions: [
            ValidationPostcondition(
              id: "cleanup.1",
              passed: true,
              observer: "fixture_inspector",
              observationDigest: digest
            )
          ]
        )
      ]
    )

    let bundle = try ValidationObservationCollector(database: database).collect(
      observations: observations,
      runID: "run-openai-runtime-001",
      environment: makeEnvironment(profileID: .chatGPTOperate)
    )

    #expect(bundle.runs[0].layer == .runtime)
    #expect(bundle.runs[0].consumer == nil)
    #expect(bundle.runs[0].transport.transport == .openAISecureMCPTunnel)
    #expect(bundle.runs[0].transport.tunnelInstanceID == "tunnel-openai-runtime-1")
    #expect(bundle.runs[0].transport.tunnelProfileID == "computer-mcp")
    #expect(ValidationEvidenceBundleVerifier().verify(bundle, database: database).isVerified)
  }

  @Test("Authenticated runtime can prove a reviewed expected execution failure")
  func authenticatedRuntimeExpectedFailureCorrelation() throws {
    let database = try GatewayDatabase(inMemory: ())
    let runtimeAudit = AuditEvent(
      id: "audit-openai-expected-failure-1",
      requestID: "gateway-openai-expected-failure-1",
      mcpRequestID: "client-openai-expected-failure-1",
      caller: .secureTunnel,
      transport: "gateway_socket",
      socketConnectionID: "socket-openai-expected-failure-1",
      tunnelInstanceID: "tunnel-openai-expected-failure-1",
      tunnelProfileID: "computer-mcp",
      profileID: .chatGPTOperate,
      capabilityID: "codex.app.requests.respond",
      decision: .failed,
      errorCode: "gateway.invalid_arguments",
      inputDigest: digest,
      outputDigest: outputDigest,
      outputByteCount: 64,
      outputTruncated: false
    )
    try database.recordAudit(runtimeAudit)
    let observations = ValidationObservationBundle(
      generatedAt: timestamp,
      layer: .runtime,
      transport: ValidationTransportProvenance(
        transport: .openAISecureMCPTunnel,
        tunnelInstanceID: "tunnel-openai-expected-failure-1",
        tunnelProfileID: "computer-mcp",
        socketConnectionID: "socket-openai-expected-failure-1"
      ),
      observations: [
        ValidationObservation(
          id: "openai-expected-failure-observation-1",
          testCaseID: "catalog.dynamic_full_coverage",
          generatedAt: timestamp,
          toolName: "codex.app.requests.respond",
          transportRequestID: "client-openai-expected-failure-1",
          gatewayRequestID: "gateway-openai-expected-failure-1",
          passed: true,
          observationDigest: digest,
          assertionIDs: ["step.1", "expected_result.1"],
          expectedOutcome: .expectedFailure,
          independentPostconditions: [
            ValidationPostcondition(
              id: "cleanup.1",
              passed: true,
              observer: "fixture_semantic_validator",
              observationDigest: digest
            )
          ]
        )
      ]
    )

    let bundle = try ValidationObservationCollector(database: database).collect(
      observations: observations,
      runID: "run-openai-expected-failure-001",
      environment: makeEnvironment(profileID: .chatGPTOperate)
    )
    let verification = ValidationEvidenceBundleVerifier().verify(bundle, database: database)
    let coverage = try ValidationEvidenceBundleVerifier().verifiedCoverageEvidence(from: bundle)

    #expect(verification.isVerified, Comment(rawValue: String(describing: verification.issues)))
    #expect(bundle.schemaVersion == 2)
    #expect(bundle.runs[0].attempts[0].outcome == .expectedFailure)
    #expect(coverage.rows.count == 1)
    #expect(coverage.rows[0].status == .passed)
  }

  @Test("Authenticated OpenAI runtime rejects incomplete Tunnel provenance")
  func authenticatedOpenAIRuntimeRequiresCompleteProvenance() throws {
    let database = try GatewayDatabase(inMemory: ())
    let observations = ValidationObservationBundle(
      generatedAt: timestamp,
      layer: .runtime,
      transport: ValidationTransportProvenance(
        transport: .openAISecureMCPTunnel,
        tunnelInstanceID: "tunnel-openai-runtime-1",
        socketConnectionID: "socket-openai-runtime-1"
      ),
      observations: [
        ValidationObservation(
          id: "openai-runtime-observation-1",
          testCaseID: "catalog.dynamic_full_coverage",
          generatedAt: timestamp,
          toolName: "system.time",
          transportRequestID: "client-openai-runtime-1",
          gatewayRequestID: "gateway-openai-runtime-1",
          passed: true,
          observationDigest: digest,
          assertionIDs: ["step.1", "expected_result.1"],
          independentPostconditions: [
            ValidationPostcondition(
              id: "cleanup.1",
              passed: true,
              observer: "fixture_inspector",
              observationDigest: digest
            )
          ]
        )
      ]
    )

    expectThrows(
      try ValidationObservationCollector(database: database).collect(
        observations: observations,
        runID: "run-openai-runtime-incomplete-001",
        environment: makeEnvironment(profileID: .chatGPTOperate)
      )
    ) { error in
      guard case ValidationObservationCollectorError.invalidObservation(let detail) = error else {
        Issue.record("Expected invalidObservation; received \(error)")
        return
      }
      #expect(detail.contains("authenticated Tunnel provenance"))
    }
  }

  @Test("A development Quick Tunnel keeps outer provenance separate from the HTTP audit")
  func quickTunnelCorrelation() throws {
    let database = try GatewayDatabase(inMemory: ())
    let audit = AuditEvent(
      id: "audit-quick-1",
      requestID: "gateway-quick-1",
      mcpRequestID: "client-quick-1",
      caller: .localApp,
      transport: "streamable_http",
      profileID: .localAdmin,
      capabilityID: "system.time",
      decision: .allowed,
      inputDigest: digest,
      outputDigest: outputDigest,
      outputByteCount: 64,
      outputTruncated: false
    )
    try database.recordAudit(audit)
    let observations = ValidationObservationBundle(
      generatedAt: timestamp,
      layer: .runtime,
      transport: ValidationTransportProvenance(
        transport: .cloudflareQuickTunnel,
        tunnelInstanceID: "quick-tunnel-1"
      ),
      observations: [
        ValidationObservation(
          id: "quick-observation-1",
          testCaseID: "transport.cloudflare.quick_tunnel_isolated",
          generatedAt: timestamp,
          toolName: "system.time",
          transportRequestID: "client-quick-1",
          gatewayRequestID: "gateway-quick-1",
          passed: true,
          observationDigest: digest,
          assertionIDs: ["step.1", "expected_result.1"],
          independentPostconditions: [
            ValidationPostcondition(
              id: "cleanup.1",
              passed: true,
              observer: "runtime_state_inspector",
              observationDigest: digest
            )
          ]
        )
      ]
    )

    let bundle = try ValidationObservationCollector(database: database).collect(
      observations: observations,
      runID: "run-quick-001",
      environment: makeEnvironment(profileID: .localAdmin)
    )

    #expect(bundle.runs[0].transport.tunnelInstanceID == "quick-tunnel-1")
    #expect(bundle.runs[0].transport.tunnelProfileID == nil)
    #expect(ValidationEvidenceBundleVerifier().verify(bundle, database: database).isVerified)
  }

  private var timestamp: String { "2026-08-02T00:00:00.000Z" }
  private var digest: String { String(repeating: "a", count: 64) }
  private var outputDigest: String { String(repeating: "b", count: 64) }

  private var transport: ValidationTransportProvenance {
    ValidationTransportProvenance(
      transport: .openAISecureMCPTunnel,
      tunnelInstanceID: "tunnel-instance-1",
      tunnelProfileID: "openai-observe",
      socketConnectionID: "socket-1"
    )
  }

  private func makeObservations() -> ValidationObservationBundle {
    ValidationObservationBundle(
      generatedAt: timestamp,
      layer: .externalConsumer,
      consumer: ValidationConsumer(kind: "chatgpt"),
      transport: transport,
      observations: [makeObservation()]
    )
  }

  private func makeObservation(
    transportRequestID: String? = nil
  ) -> ValidationObservation {
    ValidationObservation(
      id: "observation-1",
      testCaseID: "profile.observe_write_policy_denied",
      generatedAt: timestamp,
      toolName: "policy.probe",
      transportRequestID: transportRequestID,
      consumerResultID: "consumer-result-1",
      gatewayRequestID: "gateway-request-1",
      passed: true,
      observationDigest: digest,
      assertionIDs: ["step.1", "expected_result.1"],
      expectedOutcome: .passed,
      independentPostconditions: [
        ValidationPostcondition(
          id: "cleanup.1",
          passed: true,
          observer: "browser_result",
          observationDigest: digest
        )
      ]
    )
  }

  private func makeAudit() -> AuditEvent {
    AuditEvent(
      id: "audit-1",
      requestID: "gateway-request-1",
      mcpRequestID: "consumer-request-1",
      caller: .secureTunnel,
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: "tunnel-instance-1",
      tunnelProfileID: "openai-observe",
      profileID: .chatGPTObserve,
      capabilityID: "policy.probe",
      decision: .allowed,
      inputDigest: digest,
      outputDigest: outputDigest,
      outputByteCount: 64,
      outputTruncated: false
    )
  }

  private func makeEnvironment(profileID: GatewayProfileID = .chatGPTObserve)
    -> ValidationEnvironment
  {
    ValidationEnvironment(
      appBundleIdentifier: "com.example.computer-mcp",
      appVersion: "1.0.0",
      appBuild: "1",
      appDigest: digest,
      buildDigest: digest,
      configuration: "runtime.toml",
      configurationDigest: digest,
      catalogDigest: digest,
      profileID: profileID,
      profileDigest: digest,
      fixtureDigest: digest
    )
  }
}
