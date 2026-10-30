import ComputerMCPEgress
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation

/// Accepts only host-owned proxy events and platform-attributed kernel reports.
/// Recording a need never changes the launch policy or starts replacement work.
final class ExecutionPermissionDiscovery: @unchecked Sendable {
  static let maximumNeeds = 32
  private let store: SQLitePermissionStore
  private let ownerID: UUID
  private let boot: String?
  private let refreshPolicy: (@Sendable () throws -> Void)?
  private let lock = NSLock()
  private var window = ContinuousClock.now
  private var windowCount = 0
  private var observed: [UUID: (seen: Set<Need>, updated: ContinuousClock.Instant)] = [:]

  private enum Need: Hashable {
    case host(String, local: Bool)
    case path(PathRequirement)
  }

  init(
    store: SQLitePermissionStore, ownerID: UUID, boot: String?,
    refreshPolicy: (@Sendable () throws -> Void)?
  ) {
    self.store = store
    self.ownerID = ownerID
    self.boot = boot
    self.refreshPolicy = refreshPolicy
  }

  func receive(_ denial: EgressDenial, executionID: UUID) {
    guard denial.executionID == executionID.uuidString,
      denial.reason == .hostNotAllowed || denial.reason == .localNetworkRequired,
      let host = try? EgressPolicy.normalizeHost(denial.host),
      EgressPolicy.fixedRejection(host: host) == nil
    else { return }
    record(.host(host, local: denial.reason == .localNetworkRequired), executionID: executionID)
  }

  func receive(_ violation: ExecutionSandboxViolation, executionID: UUID) {
    guard
      ["file-read-data", "file-read-metadata", "file-read-xattr"].contains(violation.operation),
      violation.path.hasPrefix("/"),
      let canonical = try? ProjectPathResolver.resolve(
        violation.path, relativeTo: URL(fileURLWithPath: "/")),
      let path = try? CanonicalPath(canonical.path)
    else { return }
    record(.path(.init(path: path, operation: .read)), executionID: executionID)
  }

  func requests(
    _ executionID: UUID, principal: Principal, connectionID: String?, authorizationID: UUID? = nil,
    additionalAuthorizationIDs: Set<UUID> = []
  ) throws -> [PermissionRequest] {
    try refreshPolicy?()
    let outcome: Result<[PermissionRequest], any Error> = try store.transactionWithDatabase {
      database, ledger in
      for id in additionalAuthorizationIDs {
        do { _ = try ledger.invocationAccess(id) } catch { return .failure(error) }
      }
      let decision = ledger.executionAccess(
        executionID, principal: principal, operation: .readResult, connectionID: connectionID,
        authorizingInvocation: authorizationID, now: Date())
      switch decision {
      case .allowed: break
      case .denied(.resultExpired): return .success([])
      default: return .failure(PermissionModelError.invalidAuthorization)
      }
      let ids = try ExecutionRuntimeRecord.load(executionID, database)?.permissionRequestIDs ?? []
      let now = Date()
      let requests = ids.compactMap { ledger.requests[$0] }.filter {
        guard now < $0.expiresAt else { return false }
        switch $0.status {
        case .pending, .onlyThisTime, .always: return true
        default: return false
        }
      }
      return .success(requests.sorted { $0.id.uuidString < $1.id.uuidString })
    }
    return try outcome.get()
  }

  private func record(_ need: Need, executionID: UUID) {
    guard admit(need, executionID: executionID) else { return }
    do {
      try refreshPolicy?()
      try store.transactionWithDatabase { database, ledger in
        guard var record = try ExecutionRuntimeRecord.load(executionID, database),
          record.ownerID == ownerID, record.boot == boot,
          let execution = ledger.executions[executionID],
          let proof = execution.authorizationIDs.compactMap({ ledger.authorizations[$0] })
            .first(where: { $0.invocation.principal == execution.owner }), proof.mode == .sandbox
        else { return }
        let requirement: DiscoveredRequirement
        switch need {
        case .host(let host, let local):
          guard let project = proof.sandboxProjectID else { return }
          requirement = .network(.init(host: host, projectID: project, isLocalNetwork: local))
        case .path(let path): requirement = .path(path)
        }
        let previous = record.permissionNeeds ?? []
        guard previous.count < Self.maximumNeeds, !previous.contains(requirement) else { return }
        let decision = try ledger.recordDiscoveredNeeds(
          executionID: executionID, principal: execution.owner, needs: [requirement], now: Date())
        record.permissionNeeds = previous + [requirement]
        if case .requests(let requests) = decision {
          // A caller can supply at most 64 retry IDs. Bound carried one-time
          // evidence too, so successive executions cannot grow an unlimited chain.
          guard requests.count + proof.requestIDs.count <= 64 else {
            throw PermissionModelError.invalidAuthorization
          }
          record.permissionRequestIDs = Set(requests.map(\.id))
          if let audit = record.auditIdentity {
            try audit.record(
              "permission_required", executionID: executionID, database: database,
              decision: .denied,
              permissionRequestIDs: Set(requests.map(\.id)),
              requestEvidence: GatewayPermissionAuditEvidence(
                database: database, ledger: ledger, profileID: audit.profileID))
          }
        }
        try record.save(database)
      }
    } catch {
      // Persistence or attribution failure cannot turn an already denied
      // operation into authority. The caller still observes its permission error.
    }
  }

  private func admit(_ need: Need, executionID: UUID) -> Bool {
    lock.withLock {
      let now = ContinuousClock.now
      if now - window >= .seconds(60) {
        window = now
        windowCount = 0
        observed = observed.filter { now - $0.value.updated < .seconds(60) }
      }
      var entry = observed[executionID] ?? (seen: [], updated: now)
      guard !entry.seen.contains(need), entry.seen.count < Self.maximumNeeds,
        windowCount < 64, observed[executionID] != nil || observed.count < 128
      else { return false }
      entry.seen.insert(need)
      entry.updated = now
      observed[executionID] = entry
      windowCount += 1
      return true
    }
  }
}
