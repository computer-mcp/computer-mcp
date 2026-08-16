import CryptoKit
import Foundation

public struct ValidationEnvironment: Codable, Equatable, Sendable {
  public let appBundleIdentifier: String
  public let appVersion: String
  public let appBuild: String
  public let appDigest: String
  public let buildDigest: String
  public let configuration: String
  public let configurationDigest: String
  public let catalogDigest: String
  public let profileID: GatewayProfileID
  public let profileDigest: String
  public let fixtureDigest: String

  public init(
    appBundleIdentifier: String,
    appVersion: String,
    appBuild: String,
    appDigest: String,
    buildDigest: String,
    configuration: String,
    configurationDigest: String,
    catalogDigest: String,
    profileID: GatewayProfileID,
    profileDigest: String,
    fixtureDigest: String
  ) {
    self.appBundleIdentifier = appBundleIdentifier
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.appDigest = appDigest
    self.buildDigest = buildDigest
    self.configuration = configuration
    self.configurationDigest = configurationDigest
    self.catalogDigest = catalogDigest
    self.profileID = profileID
    self.profileDigest = profileDigest
    self.fixtureDigest = fixtureDigest
  }
}

public struct ValidationTransportProvenance: Codable, Equatable, Sendable {
  public let transport: ValidationTransport
  public let tunnelInstanceID: String?
  public let tunnelProfileID: String?
  public let socketConnectionID: String?

  public init(
    transport: ValidationTransport,
    tunnelInstanceID: String? = nil,
    tunnelProfileID: String? = nil,
    socketConnectionID: String? = nil
  ) {
    self.transport = transport
    self.tunnelInstanceID = tunnelInstanceID
    self.tunnelProfileID = tunnelProfileID
    self.socketConnectionID = socketConnectionID
  }
}

public enum ValidationTransportProvenanceError: Error, LocalizedError, Equatable, Sendable {
  case missingAuditEvents
  case inconsistentSocketConnection
  case mixedCallerKinds
  case unsupportedGatewaySocketCaller(GatewayCallerKind)
  case incompleteSecureTunnelIdentity

  public var errorDescription: String? {
    switch self {
    case .missingAuditEvents:
      "Gateway Socket provenance requires at least one audit event."
    case .inconsistentSocketConnection:
      "Gateway Socket provenance requires one nonempty socket connection identifier."
    case .mixedCallerKinds:
      "Gateway Socket provenance cannot combine multiple caller identities."
    case .unsupportedGatewaySocketCaller(let caller):
      "Gateway Socket provenance does not support caller '\(caller.rawValue)'."
    case .incompleteSecureTunnelIdentity:
      "Secure Tunnel provenance requires one nonempty Tunnel instance and profile identifier."
    }
  }
}

extension ValidationTransportProvenance {
  public static func authenticatedGatewaySocket(
    auditEvents: [AuditEvent]
  ) throws -> ValidationTransportProvenance {
    guard !auditEvents.isEmpty else {
      throw ValidationTransportProvenanceError.missingAuditEvents
    }
    let socketConnectionIDs = auditEvents.compactMap { nonempty($0.socketConnectionID) }
    guard socketConnectionIDs.count == auditEvents.count,
      Set(socketConnectionIDs).count == 1,
      let socketConnectionID = socketConnectionIDs.first
    else {
      throw ValidationTransportProvenanceError.inconsistentSocketConnection
    }
    let callers = Set(auditEvents.map(\.caller))
    guard callers.count == 1, let caller = callers.first else {
      throw ValidationTransportProvenanceError.mixedCallerKinds
    }

    switch caller {
    case .localMCP:
      return ValidationTransportProvenance(
        transport: .gatewaySocket,
        socketConnectionID: socketConnectionID
      )
    case .secureTunnel:
      let tunnelInstanceIDs = auditEvents.compactMap { nonempty($0.tunnelInstanceID) }
      let tunnelProfileIDs = auditEvents.compactMap { nonempty($0.tunnelProfileID) }
      guard tunnelInstanceIDs.count == auditEvents.count,
        tunnelProfileIDs.count == auditEvents.count,
        Set(tunnelInstanceIDs).count == 1,
        Set(tunnelProfileIDs).count == 1,
        let tunnelInstanceID = tunnelInstanceIDs.first,
        let tunnelProfileID = tunnelProfileIDs.first
      else {
        throw ValidationTransportProvenanceError.incompleteSecureTunnelIdentity
      }
      return ValidationTransportProvenance(
        transport: .openAISecureMCPTunnel,
        tunnelInstanceID: tunnelInstanceID,
        tunnelProfileID: tunnelProfileID,
        socketConnectionID: socketConnectionID
      )
    case .cloudflareTunnel, .localApp, .localCLI:
      throw ValidationTransportProvenanceError.unsupportedGatewaySocketCaller(caller)
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}

public struct ValidationConsumer: Codable, Equatable, Sendable {
  public let kind: String

  public init(kind: String) {
    self.kind = kind
  }
}

public enum ValidationAttemptOutcome: String, Codable, Sendable {
  case passed
  case expectedDenial = "expected_denial"
  case failed
}

public struct ValidationResultDigest: Codable, Equatable, Sendable {
  public let digest: String
  public let byteCount: Int
  public let truncated: Bool

  public init(digest: String, byteCount: Int, truncated: Bool = false) {
    self.digest = digest
    self.byteCount = byteCount
    self.truncated = truncated
  }
}

public struct ValidationAssertion: Codable, Equatable, Sendable {
  public let id: String
  public let passed: Bool
  public let observationDigest: String

  public init(id: String, passed: Bool, observationDigest: String) {
    self.id = id
    self.passed = passed
    self.observationDigest = observationDigest
  }
}

public struct ValidationPostcondition: Codable, Equatable, Sendable {
  public let id: String
  public let passed: Bool
  public let observer: String
  public let observationDigest: String

  public init(
    id: String,
    passed: Bool,
    observer: String,
    observationDigest: String
  ) {
    self.id = id
    self.passed = passed
    self.observer = observer
    self.observationDigest = observationDigest
  }
}

public struct ValidationAttempt: Codable, Equatable, Sendable {
  public let id: String
  public let testCaseID: String
  public let generatedAt: String
  public let toolName: String
  public let capabilityID: String
  public let profileID: GatewayProfileID
  public let workspaceID: String?
  public let inputDigest: String
  public let transportRequestID: String?
  public let consumerResultID: String?
  public let gatewayRequestID: String
  public let auditEvent: AuditEvent
  public let result: ValidationResultDigest
  public let outcome: ValidationAttemptOutcome
  public let assertions: [ValidationAssertion]
  public let independentPostconditions: [ValidationPostcondition]

  public init(
    id: String,
    testCaseID: String = "",
    generatedAt: String,
    toolName: String,
    capabilityID: String,
    profileID: GatewayProfileID,
    workspaceID: String? = nil,
    inputDigest: String,
    transportRequestID: String? = nil,
    consumerResultID: String? = nil,
    gatewayRequestID: String,
    auditEvent: AuditEvent,
    result: ValidationResultDigest,
    outcome: ValidationAttemptOutcome,
    assertions: [ValidationAssertion],
    independentPostconditions: [ValidationPostcondition]
  ) {
    self.id = id
    self.testCaseID = testCaseID
    self.generatedAt = generatedAt
    self.toolName = toolName
    self.capabilityID = capabilityID
    self.profileID = profileID
    self.workspaceID = workspaceID
    self.inputDigest = inputDigest
    self.transportRequestID = transportRequestID
    self.consumerResultID = consumerResultID
    self.gatewayRequestID = gatewayRequestID
    self.auditEvent = auditEvent
    self.result = result
    self.outcome = outcome
    self.assertions = assertions
    self.independentPostconditions = independentPostconditions
  }
}

public struct ValidationRun: Codable, Equatable, Sendable {
  public let id: String
  public let generatedAt: String
  public let layer: ValidationEvidenceLayer
  public let consumer: ValidationConsumer?
  public let environment: ValidationEnvironment
  public let transport: ValidationTransportProvenance
  public let attempts: [ValidationAttempt]

  public init(
    id: String,
    generatedAt: String,
    layer: ValidationEvidenceLayer,
    consumer: ValidationConsumer? = nil,
    environment: ValidationEnvironment,
    transport: ValidationTransportProvenance,
    attempts: [ValidationAttempt]
  ) {
    self.id = id
    self.generatedAt = generatedAt
    self.layer = layer
    self.consumer = consumer
    self.environment = environment
    self.transport = transport
    self.attempts = attempts
  }
}

public struct ValidationEvidenceBundle: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let id: String
  public let generatedAt: String
  public let environment: ValidationEnvironment
  public let runs: [ValidationRun]
  public let contentDigest: String

  public init(
    schemaVersion: Int = ValidationEvidenceBundle.currentSchemaVersion,
    id: String,
    generatedAt: String,
    environment: ValidationEnvironment,
    runs: [ValidationRun],
    contentDigest: String
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.generatedAt = generatedAt
    self.environment = environment
    self.runs = runs
    self.contentDigest = contentDigest
  }

  public static func sealed(
    id: String,
    generatedAt: String,
    environment: ValidationEnvironment,
    runs: [ValidationRun]
  ) throws -> ValidationEvidenceBundle {
    let unsealed = ValidationEvidenceBundle(
      id: id,
      generatedAt: generatedAt,
      environment: environment,
      runs: runs,
      contentDigest: ""
    )
    return ValidationEvidenceBundle(
      id: id,
      generatedAt: generatedAt,
      environment: environment,
      runs: runs,
      contentDigest: try unsealed.calculatedContentDigest()
    )
  }

  public func canonicalJSON() throws -> Data {
    try ValidationEvidenceCanonicalJSON.encode(self)
  }

  public static func decodeCanonicalJSON(_ data: Data) throws -> ValidationEvidenceBundle {
    let bundle = try ValidationEvidenceCanonicalJSON.decode(Self.self, from: data)
    guard bundle.schemaVersion == currentSchemaVersion else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Validation Evidence Bundle",
        expected: currentSchemaVersion,
        actual: bundle.schemaVersion
      )
    }
    try ValidationEvidenceCanonicalJSON.requireExactShape(bundle, input: data)
    return bundle
  }

  public func canonicalContentJSON() throws -> Data {
    try ValidationEvidenceCanonicalJSON.encode(
      DigestPayload(
        schemaVersion: schemaVersion,
        id: id,
        generatedAt: generatedAt,
        environment: environment,
        runs: runs
      )
    )
  }

  public func calculatedContentDigest() throws -> String {
    ValidationEvidenceCanonicalJSON.sha256(try canonicalContentJSON())
  }

  private struct DigestPayload: Codable {
    let schemaVersion: Int
    let id: String
    let generatedAt: String
    let environment: ValidationEnvironment
    let runs: [ValidationRun]
  }
}

public struct ValidationEvidenceIssue: Codable, Equatable, Sendable {
  public let code: String
  public let path: String
  public let message: String

  public init(code: String, path: String, message: String) {
    self.code = code
    self.path = path
    self.message = message
  }
}

public struct ValidationEvidenceVerificationReport: Codable, Equatable, Sendable {
  public let evidenceBundleID: String
  public let evidenceBundleDigest: String
  public let runCount: Int
  public let attemptCount: Int
  public let issues: [ValidationEvidenceIssue]

  public init(
    evidenceBundleID: String,
    evidenceBundleDigest: String,
    runCount: Int,
    attemptCount: Int,
    issues: [ValidationEvidenceIssue]
  ) {
    self.evidenceBundleID = evidenceBundleID
    self.evidenceBundleDigest = evidenceBundleDigest
    self.runCount = runCount
    self.attemptCount = attemptCount
    self.issues = issues
  }

  public var isVerified: Bool {
    issues.isEmpty
  }
}

public struct CapabilityCoverageProvenance: Codable, Equatable, Sendable {
  public let evidenceID: String
  public let evidenceBundleID: String
  public let evidenceBundleDigest: String
  public let runID: String
  public let attemptID: String
  public let transport: ValidationTransport
  public let tunnelInstanceID: String?
  public let tunnelProfileID: String?
  public let socketConnectionID: String
  public let transportRequestID: String?
  public let consumerResultID: String?
  public let gatewayRequestID: String
  public let auditEventID: String

  public init(
    evidenceID: String,
    evidenceBundleID: String,
    evidenceBundleDigest: String,
    runID: String,
    attemptID: String,
    transport: ValidationTransport,
    tunnelInstanceID: String?,
    tunnelProfileID: String?,
    socketConnectionID: String,
    transportRequestID: String?,
    consumerResultID: String?,
    gatewayRequestID: String,
    auditEventID: String
  ) {
    self.evidenceID = evidenceID
    self.evidenceBundleID = evidenceBundleID
    self.evidenceBundleDigest = evidenceBundleDigest
    self.runID = runID
    self.attemptID = attemptID
    self.transport = transport
    self.tunnelInstanceID = tunnelInstanceID
    self.tunnelProfileID = tunnelProfileID
    self.socketConnectionID = socketConnectionID
    self.transportRequestID = transportRequestID
    self.consumerResultID = consumerResultID
    self.gatewayRequestID = gatewayRequestID
    self.auditEventID = auditEventID
  }
}

public struct VerifiedCapabilityCoverageEvidence: Codable, Equatable, Sendable {
  public let verification: ValidationEvidenceVerificationReport
  public let rows: [CapabilityCoverageEvidence]
  public let provenance: [CapabilityCoverageProvenance]

  public init(
    verification: ValidationEvidenceVerificationReport,
    rows: [CapabilityCoverageEvidence],
    provenance: [CapabilityCoverageProvenance]
  ) {
    self.verification = verification
    self.rows = rows
    self.provenance = provenance
  }
}

public enum ValidationEvidenceBundleVerificationError: Error, Equatable, LocalizedError {
  case rejected([ValidationEvidenceIssue])

  public var errorDescription: String? {
    switch self {
    case .rejected(let issues):
      return
        "Validation Evidence Bundle was rejected: "
        + issues.map { "\($0.code) at \($0.path)" }.joined(separator: ", ")
    }
  }
}

public struct ValidationEvidenceBundleVerifier: Sendable {
  public static let maximumResultByteCount = 1_048_576

  public init() {}

  public func verify(
    _ evidenceBundle: ValidationEvidenceBundle
  ) -> ValidationEvidenceVerificationReport {
    var issues: [ValidationEvidenceIssue] = []
    func issue(_ code: String, _ path: String, _ message: String) {
      issues.append(
        ValidationEvidenceIssue(code: code, path: path, message: message)
      )
    }

    if evidenceBundle.schemaVersion != ValidationEvidenceBundle.currentSchemaVersion {
      issue("evidence_bundle.schema_unsupported", "$.schema_version", "Unsupported schema version.")
    }
    validateIdentifier(evidenceBundle.id, path: "$.id", issue: issue)
    validateTimestamp(evidenceBundle.generatedAt, path: "$.generatedAt", issue: issue)
    validateEnvironment(evidenceBundle.environment, path: "$.environment", issue: issue)
    if evidenceBundle.runs.isEmpty {
      issue(
        "evidence_bundle.runs_empty", "$.runs", "An Evidence Bundle must contain at least one run.")
    }
    do {
      let calculated = try evidenceBundle.calculatedContentDigest()
      if evidenceBundle.contentDigest != calculated {
        issue(
          "evidence_bundle.digest_mismatch",
          "$.content_digest",
          "The claimed Evidence Bundle digest does not match its canonical content."
        )
      }
    } catch {
      issue(
        "evidence_bundle.encoding_failed",
        "$",
        "The Evidence Bundle could not be canonically encoded."
      )
    }

    var runIDs = Set<String>()
    var attemptIDs = Set<String>()
    var gatewayRequestIDs = Set<String>()
    var auditEventIDs = Set<String>()

    for (runIndex, run) in evidenceBundle.runs.enumerated() {
      let runPath = "$.runs[\(runIndex)]"
      validateIdentifier(run.id, path: "\(runPath).id", issue: issue)
      if !runIDs.insert(run.id).inserted {
        issue("run.id_duplicate", "\(runPath).id", "Run IDs must be unique.")
      }
      validateTimestamp(run.generatedAt, path: "\(runPath).generatedAt", issue: issue)
      validateEnvironment(run.environment, path: "\(runPath).environment", issue: issue)
      if run.environment != evidenceBundle.environment {
        issue(
          "run.environment_drift",
          "\(runPath).environment",
          "Every run must use the Evidence Bundle's exact immutable environment."
        )
      }
      validateTransport(run, path: runPath, issue: issue)
      if run.attempts.isEmpty {
        issue("run.attempts_empty", "\(runPath).attempts", "A run must contain attempts.")
      }

      for (attemptIndex, attempt) in run.attempts.enumerated() {
        let attemptPath = "\(runPath).attempts[\(attemptIndex)]"
        validateIdentifier(attempt.id, path: "\(attemptPath).id", issue: issue)
        if !attemptIDs.insert(attempt.id).inserted {
          issue(
            "attempt.id_duplicate",
            "\(attemptPath).id",
            "Attempt IDs must be unique across the Evidence Bundle."
          )
        }
        if !gatewayRequestIDs.insert(attempt.gatewayRequestID).inserted {
          issue(
            "attempt.gateway_request_duplicate",
            "\(attemptPath).gatewayRequestID",
            "A gateway request cannot prove more than one attempt."
          )
        }
        if !auditEventIDs.insert(attempt.auditEvent.id).inserted {
          issue(
            "attempt.audit_event_duplicate",
            "\(attemptPath).auditEvent.id",
            "An audit event cannot prove more than one attempt."
          )
        }
        validateAttempt(
          attempt,
          run: run,
          path: attemptPath,
          issue: issue
        )
      }
    }

    issues.sort {
      ($0.path, $0.code, $0.message) < ($1.path, $1.code, $1.message)
    }
    return ValidationEvidenceVerificationReport(
      evidenceBundleID: evidenceBundle.id,
      evidenceBundleDigest: evidenceBundle.contentDigest,
      runCount: evidenceBundle.runs.count,
      attemptCount: evidenceBundle.runs.reduce(0) { $0 + $1.attempts.count },
      issues: issues
    )
  }

  public func verify(
    _ evidenceBundle: ValidationEvidenceBundle,
    database: GatewayDatabase
  ) -> ValidationEvidenceVerificationReport {
    let structural = verify(evidenceBundle)
    var issues = structural.issues
    for (runIndex, run) in evidenceBundle.runs.enumerated() {
      for (attemptIndex, attempt) in run.attempts.enumerated() {
        let path = "$.runs[\(runIndex)].attempts[\(attemptIndex)].auditEvent"
        do {
          let rows = try database.auditEvents(requestID: attempt.gatewayRequestID)
          if rows.count != 1 {
            issues.append(
              ValidationEvidenceIssue(
                code: "audit.grdb_cardinality_mismatch",
                path: path,
                message:
                  "Expected exactly one GRDB audit row for gateway request "
                  + "'\(attempt.gatewayRequestID)'; found \(rows.count)."
              )
            )
          } else if !auditEventsMatch(rows[0], attempt.auditEvent) {
            issues.append(
              ValidationEvidenceIssue(
                code: "audit.grdb_snapshot_mismatch",
                path: path,
                message: "The evidenceBundle audit snapshot does not match the exact GRDB row."
              )
            )
          }
        } catch {
          issues.append(
            ValidationEvidenceIssue(
              code: "audit.grdb_query_failed",
              path: path,
              message: "The exact GRDB audit query failed: \(error.localizedDescription)"
            )
          )
        }
      }
    }
    issues.sort {
      ($0.path, $0.code, $0.message) < ($1.path, $1.code, $1.message)
    }
    return ValidationEvidenceVerificationReport(
      evidenceBundleID: structural.evidenceBundleID,
      evidenceBundleDigest: structural.evidenceBundleDigest,
      runCount: structural.runCount,
      attemptCount: structural.attemptCount,
      issues: issues
    )
  }

  private func auditEventsMatch(_ persisted: AuditEvent, _ snapshot: AuditEvent) -> Bool {
    guard
      persisted.occurredAt.timeIntervalSince1970.milliseconds
        == snapshot.occurredAt.timeIntervalSince1970.milliseconds
    else { return false }

    var persisted = persisted
    var snapshot = snapshot
    persisted.occurredAt = .distantPast
    snapshot.occurredAt = .distantPast
    return persisted == snapshot
  }

  public func verifiedCoverageEvidence(
    from evidenceBundle: ValidationEvidenceBundle
  ) throws -> VerifiedCapabilityCoverageEvidence {
    let verification = verify(evidenceBundle)
    guard verification.isVerified else {
      throw ValidationEvidenceBundleVerificationError.rejected(verification.issues)
    }

    var rows: [CapabilityCoverageEvidence] = []
    var provenance: [CapabilityCoverageProvenance] = []
    for run in evidenceBundle.runs {
      let socketConnectionID = run.transport.socketConnectionID ?? ""
      for attempt in run.attempts
      where attempt.outcome == .passed || attempt.outcome == .expectedDenial {
        let evidenceID = "\(evidenceBundle.id)/\(run.id)/\(attempt.id)"
        let transport = run.transport.transport.rawValue
        let detail =
          "verified_evidence_bundle=\(evidenceBundle.contentDigest); run=\(run.id); "
          + "attempt=\(attempt.id); outcome=\(attempt.outcome.rawValue); "
          + "transport=\(run.transport.transport.rawValue)"
        rows.append(
          CapabilityCoverageEvidence(
            id: evidenceID,
            configuration: evidenceBundle.environment.configuration,
            toolName: attempt.toolName,
            layer: run.layer,
            status: .passed,
            transport: transport,
            profileDigest: evidenceBundle.environment.profileDigest,
            fixtureDigest: evidenceBundle.environment.fixtureDigest,
            testCaseID: attempt.testCaseID,
            runID: run.id,
            requestIDs: [attempt.gatewayRequestID],
            auditEventIDs: [attempt.auditEvent.id],
            detail: detail,
            recordedAt: attempt.generatedAt
          )
        )
        provenance.append(
          CapabilityCoverageProvenance(
            evidenceID: evidenceID,
            evidenceBundleID: evidenceBundle.id,
            evidenceBundleDigest: evidenceBundle.contentDigest,
            runID: run.id,
            attemptID: attempt.id,
            transport: run.transport.transport,
            tunnelInstanceID: run.transport.tunnelInstanceID,
            tunnelProfileID: run.transport.tunnelProfileID,
            socketConnectionID: socketConnectionID,
            transportRequestID: attempt.transportRequestID,
            consumerResultID: attempt.consumerResultID,
            gatewayRequestID: attempt.gatewayRequestID,
            auditEventID: attempt.auditEvent.id
          )
        )
      }
    }
    return VerifiedCapabilityCoverageEvidence(
      verification: verification,
      rows: rows,
      provenance: provenance
    )
  }

  private func validateEnvironment(
    _ environment: ValidationEnvironment,
    path: String,
    issue: (String, String, String) -> Void
  ) {
    let identifiers = [
      ("app_bundle_identifier", environment.appBundleIdentifier),
      ("app_version", environment.appVersion),
      ("app_build", environment.appBuild),
      ("configuration", environment.configuration),
    ]
    for (name, value) in identifiers {
      validateIdentifier(value, path: "\(path).\(name)", issue: issue)
    }
    let digests = [
      ("app_digest", environment.appDigest),
      ("build_digest", environment.buildDigest),
      ("configuration_digest", environment.configurationDigest),
      ("catalog_digest", environment.catalogDigest),
      ("profile_digest", environment.profileDigest),
    ]
    for (name, digest) in digests {
      validateDigest(digest, path: "\(path).\(name)", issue: issue)
    }
    validateDigest(
      environment.fixtureDigest,
      path: "\(path).fixtureDigest",
      issue: issue
    )
  }

  private func validateTransport(
    _ run: ValidationRun,
    path: String,
    issue: (String, String, String) -> Void
  ) {
    if [.gatewaySocket, .controlSocket, .openAISecureMCPTunnel].contains(
      run.transport.transport
    ),
      run.transport.socketConnectionID?
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    {
      issue(
        "transport.socket_provenance_missing",
        "\(path).transport.socketConnectionID",
        "Every App runtime run must identify its socket connection."
      )
    }

    switch run.layer {
    case .contract, .runtime:
      if run.consumer != nil {
        issue(
          "consumer.unexpected",
          "\(path).consumer",
          "Contract and runtime evidence cannot claim an external consumer."
        )
      }
      if run.transport.transport == .openAISecureMCPTunnel
        || run.transport.transport == .cloudflareTunnel
      {
        issue(
          "transport.runtime_mismatch",
          "\(path).transport.transport",
          "Contract and runtime evidence cannot claim a remote Tunnel transport."
        )
      }
      if run.transport.transport == .cloudflareQuickTunnel {
        validateOptionalIdentifier(
          run.transport.tunnelInstanceID,
          code: "transport.quick_tunnel_instance_missing",
          path: "\(path).transport.tunnelInstanceID",
          issue: issue
        )
        if run.transport.tunnelProfileID != nil {
          issue(
            "transport.quick_tunnel_profile_claim",
            "\(path).transport.tunnelProfileID",
            "A development Quick Tunnel cannot claim a release Tunnel profile."
          )
        }
      } else if run.transport.tunnelInstanceID != nil || run.transport.tunnelProfileID != nil {
        issue(
          "transport.runtime_tunnel_claim",
          "\(path).transport",
          "Local runtime evidence cannot claim Secure MCP Tunnel provenance."
        )
      }
    case .externalConsumer:
      if run.consumer?.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
        issue(
          "consumer.kind_missing",
          "\(path).consumer.kind",
          "External consumer evidence must identify consumer.kind."
        )
      }
      if run.transport.transport != .openAISecureMCPTunnel
        && run.transport.transport != .cloudflareTunnel
      {
        issue(
          "transport.external_consumer_mismatch",
          "\(path).transport.transport",
          "External consumer evidence must use the OpenAI Secure MCP Tunnel or Cloudflare Tunnel."
        )
      }
      validateOptionalIdentifier(
        run.transport.tunnelInstanceID,
        code: "transport.tunnel_instance_missing",
        path: "\(path).transport.tunnelInstanceID",
        issue: issue
      )
      validateOptionalIdentifier(
        run.transport.tunnelProfileID,
        code: "transport.tunnel_profile_missing",
        path: "\(path).transport.tunnelProfileID",
        issue: issue
      )
    }
  }

  private func validateAttempt(
    _ attempt: ValidationAttempt,
    run: ValidationRun,
    path: String,
    issue: (String, String, String) -> Void
  ) {
    validateIdentifier(attempt.testCaseID, path: "\(path).test_case_id", issue: issue)
    if let catalog = try? ValidationTestCaseCatalog.bundled(),
      let testCase = catalog.testCases.first(where: { $0.id == attempt.testCaseID })
    {
      if !testCase.transports.contains(run.transport.transport) {
        issue(
          "attempt.transport_not_declared",
          "\(path).test_case_id",
          "The Validation Test Case does not declare this transport."
        )
      }
      if !testCase.profiles.isEmpty
        && !testCase.profiles.contains(attempt.profileID.rawValue)
      {
        issue(
          "attempt.profile_not_declared",
          "\(path).profile_id",
          "The Validation Test Case does not declare this profile."
        )
      }
    } else {
      issue(
        "attempt.test_case_unknown",
        "\(path).test_case_id",
        "The attempt must reference a Test Case in the canonical catalog."
      )
    }
    validateTimestamp(attempt.generatedAt, path: "\(path).generatedAt", issue: issue)
    validateIdentifier(attempt.toolName, path: "\(path).toolName", issue: issue)
    validateIdentifier(attempt.capabilityID, path: "\(path).capabilityID", issue: issue)
    if let transportRequestID = attempt.transportRequestID {
      validateIdentifier(
        transportRequestID,
        path: "\(path).transport_request_id",
        issue: issue
      )
    }
    validateIdentifier(
      attempt.gatewayRequestID,
      path: "\(path).gatewayRequestID",
      issue: issue
    )
    validateDigest(attempt.inputDigest, path: "\(path).inputDigest", issue: issue)
    validateDigest(attempt.result.digest, path: "\(path).result.digest", issue: issue)

    if attempt.toolName != attempt.capabilityID {
      issue(
        "attempt.tool_capability_mismatch",
        path,
        "The exposed tool and audited capability must match exactly."
      )
    }
    if attempt.profileID != run.environment.profileID {
      issue(
        "attempt.environment_profile_mismatch",
        "\(path).profileID",
        "The attempt profile differs from the immutable run environment."
      )
    }
    if attempt.result.byteCount < 0
      || attempt.result.byteCount > Self.maximumResultByteCount
    {
      issue(
        "attempt.result_unbounded",
        "\(path).result.byteCount",
        "Result evidence must remain within the bounded digest limit."
      )
    }
    if attempt.outcome == .failed {
      issue(
        "attempt.outcome_failed",
        "\(path).outcome",
        "Failed attempts cannot prove acceptance."
      )
    }

    validateChecks(attempt.assertions, path: "\(path).assertions", issue: issue)
    validatePostconditions(
      attempt.independentPostconditions,
      path: "\(path).independentPostconditions",
      issue: issue
    )

    if run.layer == .externalConsumer {
      validateOptionalIdentifier(
        attempt.consumerResultID,
        code: "attempt.consumer_result_missing",
        path: "\(path).consumer_result_id",
        issue: issue
      )
    } else if attempt.consumerResultID != nil {
      issue(
        "attempt.runtime_consumer_claim",
        "\(path).consumer_result_id",
        "Local runtime attempts cannot claim an external consumer result."
      )
    } else {
      validateOptionalIdentifier(
        attempt.transportRequestID,
        code: "attempt.transport_request_missing",
        path: "\(path).transport_request_id",
        issue: issue
      )
    }

    let audit = attempt.auditEvent
    validateIdentifier(audit.id, path: "\(path).auditEvent.id", issue: issue)
    if audit.requestID != attempt.gatewayRequestID {
      issue(
        "audit.request_mismatch",
        "\(path).auditEvent.requestID",
        "The audit event does not match the exact gateway request."
      )
    }
    if audit.capabilityID != attempt.capabilityID {
      issue(
        "audit.capability_mismatch",
        "\(path).auditEvent.capabilityID",
        "The audit event does not match the attempted capability."
      )
    }
    if audit.profileID != attempt.profileID {
      issue(
        "audit.profile_mismatch",
        "\(path).auditEvent.profileID",
        "The audit event does not match the attempt profile."
      )
    }
    if audit.workspaceID != attempt.workspaceID {
      issue(
        "audit.workspace_mismatch",
        "\(path).auditEvent.workspaceID",
        "The audit event does not match the attempt workspace."
      )
    }
    let expectedAuditTransport: String =
      switch run.transport.transport {
      case .openAISecureMCPTunnel: ValidationTransport.gatewaySocket.rawValue
      case .cloudflareQuickTunnel: "streamable_http"
      default: run.transport.transport.rawValue
      }
    let tunnelProvenanceMatches =
      run.transport.transport == .cloudflareQuickTunnel
      ? audit.tunnelInstanceID == nil && audit.tunnelProfileID == nil
      : audit.tunnelInstanceID == run.transport.tunnelInstanceID
        && audit.tunnelProfileID == run.transport.tunnelProfileID
    if audit.transport != expectedAuditTransport
      || audit.socketConnectionID != run.transport.socketConnectionID
      || !tunnelProvenanceMatches
    {
      issue(
        "audit.transport_provenance_mismatch",
        "\(path).auditEvent",
        "The audit event does not match the run's authenticated transport provenance."
      )
    }
    if audit.inputDigest != attempt.inputDigest {
      issue(
        "audit.input_digest_mismatch",
        "\(path).auditEvent.inputDigest",
        "The audit event does not match the bounded input digest."
      )
    }
    if audit.outputDigest != attempt.result.digest {
      issue(
        "audit.output_digest_mismatch",
        "\(path).auditEvent.outputDigest",
        "The audit event does not match the bounded result digest."
      )
    }
    switch attempt.outcome {
    case .passed:
      if audit.decision != .allowed || audit.errorCode != nil {
        issue(
          "audit.exact_allowed_missing",
          "\(path).auditEvent",
          "A passed attempt requires one exact allowed audit event without an error."
        )
      }
    case .expectedDenial:
      if audit.decision != .denied
        || audit.errorCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
      {
        issue(
          "audit.exact_denial_missing",
          "\(path).auditEvent",
          "An expected-denial attempt requires one exact denied audit event with a stable error code."
        )
      }
    case .failed:
      break
    }
    switch run.layer {
    case .externalConsumer:
      let expectedCaller: GatewayCallerKind =
        run.transport.transport == .cloudflareTunnel ? .cloudflareTunnel : .secureTunnel
      if audit.caller != expectedCaller {
        issue(
          "audit.external_caller_mismatch",
          "\(path).auditEvent.caller",
          "External consumer evidence requires the audited caller for its transport."
        )
      }
      if run.transport.transport == .openAISecureMCPTunnel,
        audit.mcpRequestID?.isEmpty != false
      {
        issue(
          "audit.transport_request_missing",
          "\(path).auditEvent.mcpRequestID",
          "OpenAI Secure MCP Tunnel evidence requires the locally observed MCP request."
        )
      }
      if let transportRequestID = attempt.transportRequestID,
        let auditedRequestID = audit.mcpRequestID,
        auditedRequestID != transportRequestID
      {
        issue(
          "audit.transport_request_mismatch",
          "\(path).auditEvent.mcpRequestID",
          "The local audit and observed transport request do not match."
        )
      }
    case .contract, .runtime:
      if audit.caller.isRemote {
        issue(
          "audit.local_caller_missing",
          "\(path).auditEvent.caller",
          "Contract and runtime evidence cannot reuse remote caller provenance."
        )
      }
      if run.transport.transport != .cloudflareQuickTunnel,
        audit.mcpRequestID != attempt.transportRequestID
      {
        issue(
          "audit.transport_request_mismatch",
          "\(path).auditEvent.mcpRequestID",
          "Runtime evidence must match the exact local MCP JSON-RPC request."
        )
      } else if run.transport.transport == .cloudflareQuickTunnel,
        let auditedRequestID = audit.mcpRequestID,
        auditedRequestID != attempt.transportRequestID
      {
        issue(
          "audit.transport_request_mismatch",
          "\(path).auditEvent.mcpRequestID",
          "When present, the HTTP audit request must match the observed transport request."
        )
      }
    }
  }

  private func validateChecks(
    _ checks: [ValidationAssertion],
    path: String,
    issue: (String, String, String) -> Void
  ) {
    if checks.isEmpty {
      issue("assertions.missing", path, "At least one result assertion is required.")
    }
    var ids = Set<String>()
    for (index, check) in checks.enumerated() {
      let checkPath = "\(path)[\(index)]"
      validateIdentifier(check.id, path: "\(checkPath).id", issue: issue)
      if !ids.insert(check.id).inserted {
        issue("assertion.id_duplicate", "\(checkPath).id", "Assertion IDs must be unique.")
      }
      validateDigest(
        check.observationDigest,
        path: "\(checkPath).observationDigest",
        issue: issue
      )
      if !check.passed {
        issue("assertion.failed", "\(checkPath).passed", "The result assertion failed.")
      }
    }
  }

  private func validatePostconditions(
    _ postconditions: [ValidationPostcondition],
    path: String,
    issue: (String, String, String) -> Void
  ) {
    if postconditions.isEmpty {
      issue(
        "postconditions.missing",
        path,
        "At least one independently observed postcondition is required."
      )
    }
    var ids = Set<String>()
    for (index, postcondition) in postconditions.enumerated() {
      let postconditionPath = "\(path)[\(index)]"
      validateIdentifier(postcondition.id, path: "\(postconditionPath).id", issue: issue)
      validateIdentifier(
        postcondition.observer,
        path: "\(postconditionPath).observer",
        issue: issue
      )
      if postcondition.observer == "gateway_result" {
        issue(
          "postcondition.observer_not_independent",
          "\(postconditionPath).observer",
          "A gateway result cannot independently prove its own postcondition."
        )
      }
      if !ids.insert(postcondition.id).inserted {
        issue(
          "postcondition.id_duplicate",
          "\(postconditionPath).id",
          "Postcondition IDs must be unique."
        )
      }
      validateDigest(
        postcondition.observationDigest,
        path: "\(postconditionPath).observationDigest",
        issue: issue
      )
      if !postcondition.passed {
        issue(
          "postcondition.failed",
          "\(postconditionPath).passed",
          "The independent postcondition failed."
        )
      }
    }
  }

  private func validateIdentifier(
    _ value: String,
    path: String,
    issue: (String, String, String) -> Void
  ) {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.count > 512 {
      issue(
        "value.identifier_invalid",
        path,
        "Identifiers must be nonempty and at most 512 characters."
      )
    }
  }

  private func validateOptionalIdentifier(
    _ value: String?,
    code: String,
    path: String,
    issue: (String, String, String) -> Void
  ) {
    guard let value,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.count <= 512
    else {
      issue(code, path, "Required transport provenance is missing.")
      return
    }
  }

  private func validateDigest(
    _ value: String,
    path: String,
    issue: (String, String, String) -> Void
  ) {
    let valid =
      value.count == 64
      && value.utf8.allSatisfy {
        ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
          || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
      }
    if !valid {
      issue(
        "value.digest_invalid",
        path,
        "Digests must be lowercase hexadecimal SHA-256 values."
      )
    }
  }

  private func validateTimestamp(
    _ value: String,
    path: String,
    issue: (String, String, String) -> Void
  ) {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    if fractional.date(from: value) == nil && basic.date(from: value) == nil {
      issue("value.timestamp_invalid", path, "Timestamps must use ISO 8601.")
    }
  }
}

extension TimeInterval {
  fileprivate var milliseconds: Int64 {
    Int64((self * 1_000).rounded())
  }
}

private enum ValidationEvidenceCanonicalJSON {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    try ValidationJSONCoding.encode(
      value,
      prettyPrinted: false,
      dateEncodingStrategy: .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
      }
    )
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try ValidationJSONCoding.decode(
      type,
      from: data,
      dateDecodingStrategy: .custom { decoder in
        let container = try decoder.singleValueContainer()
        let milliseconds = try container.decode(Double.self)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
      }
    )
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func requireExactShape<T: Encodable>(_ value: T, input: Data) throws {
    try ValidationJSONCoding.requireExactShape(
      value,
      input: input,
      artifact: "Validation Evidence Bundle",
      dateEncodingStrategy: .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
      }
    )
  }

}
