import Crypto
import Foundation

package struct RegisteredProject: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var displayName: String
  package var rootPath: String
  package var bookmarkData: Data?
  package var bookmarkIsStale: Bool
  package var createdAt: Date
  package var updatedAt: Date

  package init(
    id: String = UUID().uuidString,
    displayName: String,
    rootPath: String,
    bookmarkData: Data? = nil,
    bookmarkIsStale: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.displayName = displayName
    self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    self.bookmarkData = bookmarkData
    self.bookmarkIsStale = bookmarkIsStale
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

package struct ProviderState: Codable, Equatable, Sendable {
  package var id: String
  package var kind: String
  package var executablePath: String?
  package var observedVersion: String?
  package var health: String
  package var detail: String?
  package var checkedAt: Date

  package init(
    id: String,
    kind: String,
    executablePath: String? = nil,
    observedVersion: String? = nil,
    health: String,
    detail: String? = nil,
    checkedAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.executablePath = executablePath
    self.observedVersion = observedVersion
    self.health = health
    self.detail = detail
    self.checkedAt = checkedAt
  }
}

package struct ConfigurationRevision: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var digest: String
  package var manifest: String
  package var createdAt: Date
  package var activatedAt: Date?
  package var activationError: String?

  package init(
    id: String = UUID().uuidString,
    digest: String,
    manifest: String,
    createdAt: Date = Date(),
    activatedAt: Date? = nil,
    activationError: String? = nil
  ) {
    self.id = id
    self.digest = digest
    self.manifest = manifest
    self.createdAt = createdAt
    self.activatedAt = activatedAt
    self.activationError = activationError
  }
}

package enum AuditDecision: String, Codable, Sendable {
  case allowed
  case denied
  case failed
}

package protocol AuditErrorClassifying: Error {
  /// Nil leaves classification to the caller's existing audit rules.
  var auditClassification: (decision: AuditDecision, code: String)? { get }
}

package struct AuditEvent: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var occurredAt: Date
  package var requestID: String
  package var mcpRequestID: String?
  package var invocationID: String?
  package var parentRequestID: String?
  package var ticketID: String?
  package var caller: GatewayCallerKind
  /// Stable verified subject binding. Nil identifies historical or unverified provenance.
  package var principalDigest: String?
  package var transport: String?
  package var socketConnectionID: String?
  package var tunnelInstanceID: String?
  package var tunnelProfileID: String?
  package var profileID: GatewayProfileID
  package var projectID: String?
  package var capabilityID: String
  package var decision: AuditDecision
  package var errorCode: String?
  /// Structured authority or refusal evidence; contains no invocation arguments or credentials.
  package var errorDetails: JSONValue?
  package var durationMilliseconds: Int?
  package var inputDigest: String?
  package var outputDigest: String?
  package var outputByteCount: Int?
  package var outputTruncated: Bool?

  package init(
    id: String = UUID().uuidString,
    occurredAt: Date = Date(),
    requestID: String,
    mcpRequestID: String? = nil,
    invocationID: String? = nil,
    parentRequestID: String? = nil,
    ticketID: String? = nil,
    caller: GatewayCallerKind,
    principalDigest: String? = nil,
    transport: String? = nil,
    socketConnectionID: String? = nil,
    tunnelInstanceID: String? = nil,
    tunnelProfileID: String? = nil,
    profileID: GatewayProfileID,
    projectID: String? = nil,
    capabilityID: String,
    decision: AuditDecision,
    errorCode: String? = nil,
    errorDetails: JSONValue? = nil,
    durationMilliseconds: Int? = nil,
    inputDigest: String? = nil,
    outputDigest: String? = nil,
    outputByteCount: Int? = nil,
    outputTruncated: Bool? = nil
  ) {
    self.id = id
    self.occurredAt = occurredAt
    self.requestID = requestID
    self.mcpRequestID = mcpRequestID
    self.invocationID = invocationID
    self.parentRequestID = parentRequestID
    self.ticketID = ticketID
    self.caller = caller
    self.principalDigest = principalDigest
    self.transport = transport
    self.socketConnectionID = socketConnectionID
    self.tunnelInstanceID = tunnelInstanceID
    self.tunnelProfileID = tunnelProfileID
    self.profileID = profileID
    self.projectID = projectID
    self.capabilityID = capabilityID
    self.decision = decision
    self.errorCode = errorCode
    self.errorDetails = errorDetails
    self.durationMilliseconds = durationMilliseconds
    self.inputDigest = inputDigest
    self.outputDigest = outputDigest
    self.outputByteCount = outputByteCount
    self.outputTruncated = outputTruncated
  }

  package static func verifiedPrincipalDigest(_ principalID: String?) -> String? {
    guard let principalID, !principalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return SHA256.hash(data: Data(principalID.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
