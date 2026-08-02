import Foundation

package struct RegisteredWorkspace: Codable, Equatable, Sendable, Identifiable {
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

package struct AuditEvent: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var occurredAt: Date
  package var requestID: String
  package var mcpRequestID: String?
  package var invocationID: String?
  package var parentRequestID: String?
  package var ticketID: String?
  package var caller: GatewayCallerKind
  package var transport: String?
  package var socketConnectionID: String?
  package var tunnelInstanceID: String?
  package var tunnelProfileID: String?
  package var profileID: GatewayProfileID
  package var workspaceID: String?
  package var capabilityID: String
  package var decision: AuditDecision
  package var errorCode: String?
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
    transport: String? = nil,
    socketConnectionID: String? = nil,
    tunnelInstanceID: String? = nil,
    tunnelProfileID: String? = nil,
    profileID: GatewayProfileID,
    workspaceID: String? = nil,
    capabilityID: String,
    decision: AuditDecision,
    errorCode: String? = nil,
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
    self.transport = transport
    self.socketConnectionID = socketConnectionID
    self.tunnelInstanceID = tunnelInstanceID
    self.tunnelProfileID = tunnelProfileID
    self.profileID = profileID
    self.workspaceID = workspaceID
    self.capabilityID = capabilityID
    self.decision = decision
    self.errorCode = errorCode
    self.durationMilliseconds = durationMilliseconds
    self.inputDigest = inputDigest
    self.outputDigest = outputDigest
    self.outputByteCount = outputByteCount
    self.outputTruncated = outputTruncated
  }
}

package enum OperationTicketState: String, Codable, Sendable {
  case prepared
  case executing
  case succeeded
  case failed
}

package struct OperationTicket: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var capabilityID: String
  package var caller: GatewayCallerKind
  package var profileID: GatewayProfileID
  package var principalID: String
  package var workspaceID: String?
  package var inputDigest: String
  package var stateDigest: String?
  package var state: OperationTicketState
  package var prepareRequestID: String
  package var invocationID: String?
  package var parentRequestID: String?
  package var createdAt: Date
  package var expiresAt: Date
  package var executingAt: Date?
  package var completedAt: Date?
  package var failureCode: String?

  package init(
    id: String = UUID().uuidString,
    capabilityID: String,
    caller: GatewayCallerKind,
    profileID: GatewayProfileID,
    principalID: String? = nil,
    workspaceID: String? = nil,
    inputDigest: String,
    stateDigest: String? = nil,
    state: OperationTicketState = .prepared,
    prepareRequestID: String = UUID().uuidString,
    invocationID: String? = nil,
    parentRequestID: String? = nil,
    createdAt: Date = Date(),
    expiresAt: Date,
    executingAt: Date? = nil,
    completedAt: Date? = nil,
    failureCode: String? = nil
  ) {
    self.id = id
    self.capabilityID = capabilityID
    self.caller = caller
    self.profileID = profileID
    self.principalID =
      principalID
      ?? "\(caller.rawValue):\(profileID.rawValue)"
    self.workspaceID = workspaceID
    self.inputDigest = inputDigest
    self.stateDigest = stateDigest
    self.state = state
    self.prepareRequestID = prepareRequestID
    self.invocationID = invocationID
    self.parentRequestID = parentRequestID
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.executingAt = executingAt
    self.completedAt = completedAt
    self.failureCode = failureCode
  }
}
