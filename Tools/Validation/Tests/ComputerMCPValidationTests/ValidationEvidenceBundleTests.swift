import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite("Validation Evidence Bundle")
struct ValidationEvidenceBundleTests {
  @Test("OpenAI external consumer evidence verifies and projects")
  func openAIExternalConsumer() throws {
    let bundle = try makeBundle(
      transport: .openAISecureMCPTunnel,
      profileID: .chatGPTObserve,
      caller: .secureTunnel,
      auditTransport: "gateway_socket",
      testCaseID: "profile.observe_write_policy_denied",
      socketConnectionID: "socket-openai"
    )

    let report = ValidationEvidenceBundleVerifier().verify(bundle)
    let projection = try ValidationEvidenceBundleVerifier().verifiedCoverageEvidence(from: bundle)

    #expect(report.isVerified, Comment(rawValue: String(describing: report.issues)))
    #expect(projection.rows.count == 1)
    #expect(projection.rows[0].layer == .externalConsumer)
    #expect(projection.rows[0].transport == "openai_secure_mcp_tunnel")
    #expect(projection.rows[0].testCaseID == "profile.observe_write_policy_denied")
    #expect(projection.provenance[0].transport == .openAISecureMCPTunnel)
  }

  @Test("Cloudflare uses the same external consumer evidence layer")
  func cloudflareExternalConsumer() throws {
    let bundle = try makeBundle(
      transport: .cloudflareTunnel,
      profileID: .cloudflareOperate,
      caller: .cloudflareTunnel,
      auditTransport: "cloudflare_tunnel",
      testCaseID: "transport.cloudflare.named_tunnel",
      socketConnectionID: nil
    )

    let report = ValidationEvidenceBundleVerifier().verify(bundle)
    let projection = try ValidationEvidenceBundleVerifier().verifiedCoverageEvidence(from: bundle)

    #expect(report.isVerified, Comment(rawValue: String(describing: report.issues)))
    #expect(projection.rows[0].layer == .externalConsumer)
    #expect(projection.rows[0].transport == "cloudflare_tunnel")
    #expect(projection.provenance[0].transport == .cloudflareTunnel)
  }

  @Test("Unknown Test Case fails closed")
  func unknownTestCase() throws {
    let bundle = try makeBundle(
      transport: .openAISecureMCPTunnel,
      profileID: .chatGPTObserve,
      caller: .secureTunnel,
      auditTransport: "gateway_socket",
      testCaseID: "unknown.test_case",
      socketConnectionID: "socket-openai"
    )

    let report = ValidationEvidenceBundleVerifier().verify(bundle)

    #expect(!report.isVerified)
    #expect(report.issues.contains { $0.code == "attempt.test_case_unknown" })
  }

  @Test("Digest tampering is rejected")
  func digestTampering() throws {
    let valid = try makeBundle(
      transport: .openAISecureMCPTunnel,
      profileID: .chatGPTObserve,
      caller: .secureTunnel,
      auditTransport: "gateway_socket",
      testCaseID: "profile.observe_write_policy_denied",
      socketConnectionID: "socket-openai"
    )
    let tampered = ValidationEvidenceBundle(
      id: valid.id,
      generatedAt: valid.generatedAt,
      environment: valid.environment,
      runs: valid.runs,
      contentDigest: String(repeating: "0", count: 64)
    )

    let report = ValidationEvidenceBundleVerifier().verify(tampered)

    #expect(report.issues.contains { $0.code == "evidence_bundle.digest_mismatch" })
    expectThrows(try ValidationEvidenceBundleVerifier().verifiedCoverageEvidence(from: tampered))
  }

  @Test("Canonical evidence JSON is snake case and consumer neutral")
  func canonicalJSON() throws {
    let bundle = try makeBundle(
      transport: .cloudflareTunnel,
      profileID: .cloudflareOperate,
      caller: .cloudflareTunnel,
      auditTransport: "cloudflare_tunnel",
      testCaseID: "transport.cloudflare.named_tunnel",
      socketConnectionID: nil
    )

    let encoded = String(decoding: try bundle.canonicalJSON(), as: UTF8.self)

    #expect(encoded.contains("\"schema_version\":1"))
    #expect(encoded.contains("\"external_consumer\""))
    #expect(encoded.contains("\"test_case_id\""))
    #expect(!encoded.contains(["back", "end"].joined()))
    #expect(!encoded.contains(["chat", "GPT"].joined()))
    #expect(try ValidationEvidenceBundle.decodeCanonicalJSON(Data(encoded.utf8)) == bundle)
  }

  @Test("Evidence decoder rejects fields outside the digest contract")
  func rejectsUnknownEvidenceField() throws {
    let bundle = try makeBundle(
      transport: .openAISecureMCPTunnel,
      profileID: .chatGPTObserve,
      caller: .secureTunnel,
      auditTransport: "gateway_socket",
      testCaseID: "profile.observe_write_policy_denied",
      socketConnectionID: "socket-openai"
    )
    let encoded = String(decoding: try bundle.canonicalJSON(), as: UTF8.self)
    let withUnknownField = Data((encoded.dropLast() + ",\"unexpected\":true}").utf8)

    expectThrows(try ValidationEvidenceBundle.decodeCanonicalJSON(withUnknownField)) { error in
      #expect(
        error as? ValidationArtifactError
          == .noncanonicalShape(artifact: "Validation Evidence Bundle")
      )
    }
  }

  @Test("GRDB audit verification uses persisted millisecond timestamp precision")
  func persistedAuditTimestampPrecision() throws {
    let database = try GatewayDatabase(inMemory: ())
    let bundle = try makeBundle(
      transport: .openAISecureMCPTunnel,
      profileID: .chatGPTObserve,
      caller: .secureTunnel,
      auditTransport: "gateway_socket",
      testCaseID: "profile.observe_write_policy_denied",
      socketConnectionID: "socket-openai",
      occurredAt: Date(timeIntervalSince1970: 1_785_773_084.150)
    )
    let auditEvent = try #require(bundle.runs.first?.attempts.first?.auditEvent)
    try database.recordAudit(auditEvent)
    let decoded = try ValidationEvidenceBundle.decodeCanonicalJSON(bundle.canonicalJSON())

    let report = ValidationEvidenceBundleVerifier().verify(decoded, database: database)

    #expect(report.isVerified, Comment(rawValue: String(describing: report.issues)))
  }

  private func makeBundle(
    transport: ValidationTransport,
    profileID: GatewayProfileID,
    caller: GatewayCallerKind,
    auditTransport: String,
    testCaseID: String,
    socketConnectionID: String?,
    occurredAt: Date = Date(timeIntervalSince1970: 1_754_092_800)
  ) throws -> ValidationEvidenceBundle {
    let digest = String(repeating: "a", count: 64)
    let outputDigest = String(repeating: "b", count: 64)
    let generatedAt = "2026-08-02T00:00:00.000Z"
    let environment = ValidationEnvironment(
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
    let isPolicyProbe = testCaseID == "profile.observe_write_policy_denied"
    let toolName = isPolicyProbe ? "policy.probe" : "system.time"
    let audit = AuditEvent(
      id: "audit-\(transport.rawValue)",
      occurredAt: occurredAt,
      requestID: "gateway-\(transport.rawValue)",
      mcpRequestID: "transport-\(transport.rawValue)",
      caller: caller,
      transport: auditTransport,
      socketConnectionID: socketConnectionID,
      tunnelInstanceID: "tunnel-instance",
      tunnelProfileID: "tunnel-configuration",
      profileID: profileID,
      capabilityID: toolName,
      decision: .allowed,
      inputDigest: digest,
      outputDigest: outputDigest,
      outputByteCount: 128,
      outputTruncated: false
    )
    let attempt = ValidationAttempt(
      id: "attempt-\(transport.rawValue)",
      testCaseID: testCaseID,
      generatedAt: generatedAt,
      toolName: toolName,
      capabilityID: toolName,
      profileID: profileID,
      inputDigest: digest,
      transportRequestID: "transport-\(transport.rawValue)",
      consumerResultID: "consumer-result-\(transport.rawValue)",
      gatewayRequestID: audit.requestID,
      auditEvent: audit,
      result: ValidationResultDigest(digest: outputDigest, byteCount: 128),
      outcome: .passed,
      assertions: [
        ValidationAssertion(id: "step.1", passed: true, observationDigest: digest),
        ValidationAssertion(id: "expected_result.1", passed: true, observationDigest: digest),
      ],
      independentPostconditions: [
        ValidationPostcondition(
          id: "cleanup.1",
          passed: true,
          observer: "external_consumer",
          observationDigest: digest
        )
      ]
    )
    let run = ValidationRun(
      id: "run-\(transport.rawValue)",
      generatedAt: generatedAt,
      layer: .externalConsumer,
      consumer: ValidationConsumer(kind: transport == .cloudflareTunnel ? "mcp_client" : "chatgpt"),
      environment: environment,
      transport: ValidationTransportProvenance(
        transport: transport,
        tunnelInstanceID: "tunnel-instance",
        tunnelProfileID: "tunnel-configuration",
        socketConnectionID: socketConnectionID
      ),
      attempts: [attempt]
    )
    return try ValidationEvidenceBundle.sealed(
      id: "evidence-\(transport.rawValue)",
      generatedAt: generatedAt,
      environment: environment,
      runs: [run]
    )
  }
}
