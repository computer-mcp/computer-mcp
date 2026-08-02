import Foundation

public struct ValidationObservation: Codable, Equatable, Sendable {
  public let id: String
  public let testCaseID: String
  public let generatedAt: String
  public let toolName: String
  public let transportRequestID: String?
  public let consumerResultID: String?
  public let gatewayRequestID: String
  public let passed: Bool
  public let observationDigest: String
  public let assertionIDs: [String]
  public let expectedOutcome: ValidationAttemptOutcome?
  public let independentPostconditions: [ValidationPostcondition]

  public init(
    id: String,
    testCaseID: String,
    generatedAt: String,
    toolName: String,
    transportRequestID: String? = nil,
    consumerResultID: String? = nil,
    gatewayRequestID: String,
    passed: Bool,
    observationDigest: String,
    assertionIDs: [String],
    expectedOutcome: ValidationAttemptOutcome? = nil,
    independentPostconditions: [ValidationPostcondition]
  ) {
    self.id = id
    self.testCaseID = testCaseID
    self.generatedAt = generatedAt
    self.toolName = toolName
    self.transportRequestID = transportRequestID
    self.consumerResultID = consumerResultID
    self.gatewayRequestID = gatewayRequestID
    self.passed = passed
    self.observationDigest = observationDigest
    self.assertionIDs = assertionIDs
    self.expectedOutcome = expectedOutcome
    self.independentPostconditions = independentPostconditions
  }
}

public struct ValidationObservationBundle: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let generatedAt: String
  public let layer: ValidationEvidenceLayer
  public let consumer: ValidationConsumer?
  public let transport: ValidationTransportProvenance
  public let observations: [ValidationObservation]

  public init(
    schemaVersion: Int = ValidationObservationBundle.currentSchemaVersion,
    generatedAt: String,
    layer: ValidationEvidenceLayer,
    consumer: ValidationConsumer? = nil,
    transport: ValidationTransportProvenance,
    observations: [ValidationObservation]
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.layer = layer
    self.consumer = consumer
    self.transport = transport
    self.observations = observations
  }

  public func encodedJSON() throws -> Data {
    try ValidationJSONCoding.encode(self)
  }

  public static func decodeJSON(_ data: Data) throws -> ValidationObservationBundle {
    let bundle = try ValidationJSONCoding.decode(Self.self, from: data)
    guard bundle.schemaVersion == currentSchemaVersion else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Validation Observation Bundle",
        expected: currentSchemaVersion,
        actual: bundle.schemaVersion
      )
    }
    try ValidationJSONCoding.requireExactShape(
      bundle,
      input: data,
      artifact: "Validation Observation Bundle"
    )
    return bundle
  }
}

public enum ValidationObservationCollectorError: Error, LocalizedError, Equatable {
  case invalidObservation(String)
  case auditCardinality(requestID: String, count: Int)
  case auditMismatch(requestID: String, detail: String)
  case verificationRejected([ValidationEvidenceIssue])

  public var errorDescription: String? {
    switch self {
    case .invalidObservation(let detail):
      return "Invalid Validation observation: \(detail)"
    case .auditCardinality(let requestID, let count):
      return "Expected exactly one audit row for Gateway request '\(requestID)'; found \(count)."
    case .auditMismatch(let requestID, let detail):
      return "Audit row for Gateway request '\(requestID)' is not admissible: \(detail)"
    case .verificationRejected(let issues):
      return
        "Collected Validation Evidence Bundle failed verification: "
        + issues.map { "\($0.code) at \($0.path)" }.joined(separator: ", ")
    }
  }
}

public struct ValidationObservationCollector: Sendable {
  private let database: GatewayDatabase

  public init(database: GatewayDatabase) {
    self.database = database
  }

  public func collect(
    observations bundle: ValidationObservationBundle,
    runID: String,
    environment: ValidationEnvironment
  ) throws -> ValidationEvidenceBundle {
    try validate(bundle, runID: runID)

    var attempts: [ValidationAttempt] = []
    var auditEventIDs = Set<String>()
    var gatewayRequestIDs = Set<String>()
    for observation in bundle.observations {
      try validate(observation)
      guard gatewayRequestIDs.insert(observation.gatewayRequestID).inserted else {
        throw ValidationObservationCollectorError.invalidObservation(
          "Gateway request '\(observation.gatewayRequestID)' is duplicated"
        )
      }
      let rows = try database.auditEvents(requestID: observation.gatewayRequestID)
      guard rows.count == 1, let audit = rows.first else {
        throw ValidationObservationCollectorError.auditCardinality(
          requestID: observation.gatewayRequestID,
          count: rows.count
        )
      }
      guard auditEventIDs.insert(audit.id).inserted else {
        throw ValidationObservationCollectorError.invalidObservation(
          "audit event '\(audit.id)' is duplicated"
        )
      }
      try validate(audit, observation: observation, bundle: bundle, environment: environment)
      let expectedOutcome = observation.expectedOutcome ?? .passed
      attempts.append(
        ValidationAttempt(
          id: observation.id,
          testCaseID: observation.testCaseID,
          generatedAt: observation.generatedAt,
          toolName: observation.toolName,
          capabilityID: audit.capabilityID,
          profileID: audit.profileID,
          workspaceID: audit.workspaceID,
          inputDigest: audit.inputDigest ?? "",
          transportRequestID: observation.transportRequestID,
          consumerResultID: observation.consumerResultID,
          gatewayRequestID: audit.requestID,
          auditEvent: audit,
          result: ValidationResultDigest(
            digest: audit.outputDigest ?? "",
            byteCount: audit.outputByteCount ?? -1,
            truncated: audit.outputTruncated ?? false
          ),
          outcome: expectedOutcome,
          assertions: observation.assertionIDs.map {
            ValidationAssertion(
              id: $0,
              passed: observation.passed,
              observationDigest: observation.observationDigest
            )
          },
          independentPostconditions: observation.independentPostconditions
        )
      )
    }

    let run = ValidationRun(
      id: runID,
      generatedAt: bundle.generatedAt,
      layer: bundle.layer,
      consumer: bundle.consumer,
      environment: environment,
      transport: bundle.transport,
      attempts: attempts.sorted { $0.id < $1.id }
    )
    let evidenceBundle = try ValidationEvidenceBundle.sealed(
      id: "evidence-\(runID)",
      generatedAt: bundle.generatedAt,
      environment: environment,
      runs: [run]
    )
    let verification = ValidationEvidenceBundleVerifier().verify(
      evidenceBundle,
      database: database
    )
    guard verification.isVerified else {
      throw ValidationObservationCollectorError.verificationRejected(verification.issues)
    }
    return evidenceBundle
  }

  private func validate(_ bundle: ValidationObservationBundle, runID: String) throws {
    guard bundle.schemaVersion == ValidationObservationBundle.currentSchemaVersion else {
      throw ValidationObservationCollectorError.invalidObservation(
        "unsupported schema version \(bundle.schemaVersion)"
      )
    }
    guard !runID.isEmpty, !bundle.generatedAt.isEmpty, !bundle.observations.isEmpty else {
      throw ValidationObservationCollectorError.invalidObservation(
        "run identifier, timestamp, and observations are required"
      )
    }

    switch bundle.layer {
    case .contract:
      throw ValidationObservationCollectorError.invalidObservation(
        "contract evidence is derived from the canonical capability inventory"
      )
    case .runtime:
      guard bundle.consumer == nil else {
        throw ValidationObservationCollectorError.invalidObservation(
          "runtime observations cannot identify an external consumer"
        )
      }
      guard
        bundle.transport.transport != .openAISecureMCPTunnel,
        bundle.transport.transport != .cloudflareTunnel
      else {
        throw ValidationObservationCollectorError.invalidObservation(
          "runtime observations require a local transport without Tunnel provenance"
        )
      }
      if bundle.transport.transport == .cloudflareQuickTunnel {
        guard bundle.transport.tunnelInstanceID?.isEmpty == false,
          bundle.transport.tunnelProfileID == nil
        else {
          throw ValidationObservationCollectorError.invalidObservation(
            "Quick Tunnel observations require one ephemeral instance and no release profile"
          )
        }
      } else if bundle.transport.tunnelInstanceID != nil
        || bundle.transport.tunnelProfileID != nil
      {
        throw ValidationObservationCollectorError.invalidObservation(
          "local runtime observations cannot claim Tunnel provenance"
        )
      }
      guard
        bundle.observations.allSatisfy({
          $0.transportRequestID?.isEmpty == false && $0.consumerResultID == nil
        })
      else {
        throw ValidationObservationCollectorError.invalidObservation(
          "runtime observations require transport_request_id and cannot claim consumer_result_id"
        )
      }
    case .externalConsumer:
      guard bundle.consumer?.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      else {
        throw ValidationObservationCollectorError.invalidObservation(
          "external_consumer observations require consumer.kind"
        )
      }
      guard bundle.observations.allSatisfy({ $0.consumerResultID?.isEmpty == false }) else {
        throw ValidationObservationCollectorError.invalidObservation(
          "external_consumer observations require consumer_result_id"
        )
      }
      guard
        bundle.transport.transport == .openAISecureMCPTunnel
          || bundle.transport.transport == .cloudflareTunnel,
        bundle.transport.tunnelInstanceID?.isEmpty == false,
        bundle.transport.tunnelProfileID?.isEmpty == false
      else {
        throw ValidationObservationCollectorError.invalidObservation(
          "external_consumer observations require an authenticated Tunnel transport"
        )
      }
    }

    switch bundle.transport.transport {
    case .gatewaySocket, .controlSocket, .openAISecureMCPTunnel:
      guard bundle.transport.socketConnectionID?.isEmpty == false else {
        throw ValidationObservationCollectorError.invalidObservation(
          "the selected transport requires socket_connection_id"
        )
      }
    case .cloudflareTunnel, .cloudflareQuickTunnel:
      break
    }
  }

  private func validate(_ observation: ValidationObservation) throws {
    guard !observation.id.isEmpty, !observation.testCaseID.isEmpty,
      !observation.generatedAt.isEmpty, !observation.toolName.isEmpty,
      !observation.gatewayRequestID.isEmpty,
      observation.passed, isDigest(observation.observationDigest),
      !observation.assertionIDs.isEmpty,
      Set(observation.assertionIDs).count == observation.assertionIDs.count,
      observation.assertionIDs.allSatisfy({ !$0.isEmpty }),
      observation.expectedOutcome != .failed,
      !observation.independentPostconditions.isEmpty
    else {
      throw ValidationObservationCollectorError.invalidObservation(
        "each observation requires Test Case and request identifiers, a passed result digest, and independent postconditions"
      )
    }
    guard
      observation.independentPostconditions.allSatisfy({
        $0.passed && !$0.id.isEmpty && !$0.observer.isEmpty
          && $0.observer != "gateway_result" && isDigest($0.observationDigest)
      })
    else {
      throw ValidationObservationCollectorError.invalidObservation(
        "independent postconditions must pass and contain non-Gateway SHA-256 digests"
      )
    }
  }

  private func validate(
    _ audit: AuditEvent,
    observation: ValidationObservation,
    bundle: ValidationObservationBundle,
    environment: ValidationEnvironment
  ) throws {
    let expectedOutcome = observation.expectedOutcome ?? .passed
    let decisionMatches =
      switch expectedOutcome {
      case .passed:
        audit.decision == .allowed && audit.errorCode == nil
      case .expectedDenial:
        audit.decision == .denied
          && audit.errorCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      case .failed:
        false
      }
    let expectedCaller: GatewayCallerKind =
      switch bundle.transport.transport {
      case .openAISecureMCPTunnel: .secureTunnel
      case .cloudflareTunnel: .cloudflareTunnel
      case .controlSocket: .localCLI
      case .gatewaySocket: .localMCP
      case .cloudflareQuickTunnel: .localApp
      }
    let expectedAuditTransport: String =
      switch bundle.transport.transport {
      case .openAISecureMCPTunnel: ValidationTransport.gatewaySocket.rawValue
      case .cloudflareQuickTunnel: "streamable_http"
      default: bundle.transport.transport.rawValue
      }
    let tunnelProvenanceMatches =
      bundle.transport.transport == .cloudflareQuickTunnel
      ? audit.tunnelInstanceID == nil && audit.tunnelProfileID == nil
      : audit.tunnelInstanceID == bundle.transport.tunnelInstanceID
        && audit.tunnelProfileID == bundle.transport.tunnelProfileID
    let transportRequestMatches: Bool = {
      guard let transportRequestID = observation.transportRequestID else {
        return bundle.layer == .externalConsumer
          && (bundle.transport.transport == .cloudflareTunnel
            || audit.mcpRequestID?.isEmpty == false)
      }
      guard let auditedRequestID = audit.mcpRequestID else {
        return bundle.transport.transport == .cloudflareTunnel
          || bundle.transport.transport == .cloudflareQuickTunnel
      }
      return auditedRequestID == transportRequestID
    }()
    let valid =
      audit.capabilityID == observation.toolName
      && audit.caller == expectedCaller
      && audit.profileID == environment.profileID
      && audit.transport == expectedAuditTransport
      && audit.socketConnectionID == bundle.transport.socketConnectionID
      && tunnelProvenanceMatches
      && transportRequestMatches
      && audit.inputDigest.map(isDigest) == true
      && audit.outputDigest.map(isDigest) == true
      && audit.outputByteCount.map { $0 >= 0 } == true
      && decisionMatches
    guard valid else {
      throw ValidationObservationCollectorError.auditMismatch(
        requestID: observation.gatewayRequestID,
        detail:
          "consumer, caller, profile, tool, transport, request/result digests, or decision does not match"
      )
    }
  }

  private func isDigest(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }
}
