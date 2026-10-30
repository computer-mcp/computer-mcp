import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPWorktrees
import Foundation

/// Refusals with a dedicated code in the project host-service contract.
enum MCPHostOperationError: Error, LocalizedError {
  case conflict(String)
  case notFound

  var code: String {
    switch self {
    case .conflict: "host.operation_conflict"
    case .notFound: "host.operation_not_found"
    }
  }

  var errorDescription: String? {
    switch self {
    case .conflict(let detail): detail
    case .notFound: "No operation is visible under the current authorized scope."
    }
  }
}

/// Wire shapes and lifecycle semantics of `projects-v1` operations.
enum MCPHostOperations {
  /// Lifecycle fields with host defaults resolved once; only these select effects.
  static func normalizedArguments(
    _ action: MCPHostServiceAction, _ arguments: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    func optionalString(_ key: String) throws -> JSONValue {
      guard let value = arguments[key], value != .null else { return .null }
      guard let text = value.stringValue, !text.isEmpty, text.utf8.count <= 1024 else {
        throw WorktreeError.invalidRequest("The lifecycle argument \(key) must be a string.")
      }
      return .string(text)
    }
    switch action {
    case .projectProvision:
      guard let name = arguments["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 1024
      else { throw WorktreeError.invalidRequest("A worktree name is required.") }
      let branch = try optionalString("branch")
      return [
        "name": .string(name),
        "branch": branch == .null ? .string("worktree/" + name) : branch,
        "base": try optionalString("base"),
      ]
    case .projectRemoval:
      guard let value = (arguments["force"] ?? .bool(false)).boolValue else {
        throw WorktreeError.invalidRequest("force must be a Boolean.")
      }
      return ["force": .bool(value)]
    case .projectList, .diagnosticsSnapshot: return [:]
    }
  }

  static func envelope(_ operation: HostOperationRecord) -> JSONValue {
    let admission = operation.binding.admission
    return .object([
      "operation_id": .string(operation.id.uuidString.lowercased()),
      "invocation_id": .string(admission.id.uuidString),
      "action": .string(operation.binding.action.rawValue),
      "source_project_id": .string(admission.sourceProjectID),
      "project_id": .string(admission.projectID),
      "state": .string(operation.state.rawValue),
      "result": operation.result ?? .null,
      "error": operation.error.map {
        .object(["code": .string($0.code), "message": .string($0.message)])
      } ?? .null,
    ])
  }

  static func created(_ result: CreatedWorktree, worktreeID: UUID) -> JSONValue {
    .object([
      "worktree_id": .string(worktreeID.uuidString.lowercased()),
      "project_id": .string(result.projectID), "path": .string(result.path.path),
      "branch": .string(result.branch), "base": .string(result.base),
      "warnings": .array(result.warnings.map(JSONValue.string)),
    ])
  }

  static func removed(_ result: WorktreeRemovalResult, worktreeID: UUID) -> JSONValue {
    .object([
      "worktree_id": .string(worktreeID.uuidString.lowercased()),
      "project_id": .string(result.projectID),
      "branch": .string(
        result.branch.hasPrefix("refs/heads/")
          ? String(result.branch.dropFirst("refs/heads/".count)) : result.branch),
      "oid": .string(result.oid),
      "termination_warnings": .array(result.terminationWarnings.map(JSONValue.string)),
    ])
  }

  static func inventory(_ items: [WorktreeInventoryItem]) -> JSONValue {
    .object([
      "worktrees": .array(
        items.map { item in
          .object([
            "path": item.path.map(JSONValue.string) ?? .null,
            "project_id": item.projectID.map(JSONValue.string) ?? .null,
            "branch": item.branch.map(JSONValue.string) ?? .null,
            "base": item.base.map(JSONValue.string) ?? .null,
            "ahead": item.ahead.map { .integer(Int64($0)) } ?? .null,
            "behind": item.behind.map { .integer(Int64($0)) } ?? .null,
            "dirty": item.dirty.map(JSONValue.bool) ?? .null,
            "unavailable": item.unavailable.map(JSONValue.string) ?? .null,
            "worktree_id": item.worktreeID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "owner": .string(item.owner.rawValue),
          ])
        })
    ])
  }

  static func code(for error: any Error) -> String {
    switch error {
    case let error as MCPHostOperationError: return error.code
    case is MCPHostServiceContractError: return MCPHostServiceContractError.code
    case let error as GatewayPermissionCallError: return error.code
    case let error as WorktreeError:
      switch error {
      case .unsafeConfiguration: return "worktree.unsafe_configuration"
      case .identityChanged: return "worktree.identity_changed"
      case .busy: return "worktree.busy"
      case .unsupportedRepository: return "worktree.unsupported_repository"
      case .invalidRequest: return "worktree.invalid_request"
      case .commandFailed: return "worktree.command_failed"
      case .recoveryRequired: return "worktree.recovery_required"
      }
    case DerivedProjectStoreError.revisionConflict: return "worktree.busy"
    case is DerivedProjectStoreError: return "worktree.identity_changed"
    default: return "host.service_denied"
    }
  }

  static func failure(_ error: any Error) -> HostOperationRecord.Failure {
    let message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    return .init(
      code: code(for: error),
      message: SensitiveValueRedactor.redactString(message, maximumCharacters: 1024))
  }

  /// What the lifecycle journals establish about an operation; nil when unreadable.
  static func journalOutcome(_ operation: HostOperationRecord, storage: WorktreeStorage?)
    -> WorktreeOperationOutcome?
  {
    guard let storage else { return nil }
    switch operation.binding.action {
    case .projectProvision: return try? storage.creationOutcome(operationID: operation.id)
    case .projectRemoval:
      return try? storage.removalOutcome(
        projectID: operation.binding.admission.projectID, operationID: operation.id)
    case .projectList, .diagnosticsSnapshot: return nil
    }
  }

  /// Completed journals establish success; an absent journal proves no effect began.
  static func settle(
    _ operation: HostOperationRecord, outcome: WorktreeOperationOutcome?,
    cause: HostOperationRecord.Failure, store: HostOperationStore
  ) throws -> HostOperationRecord {
    let current: Set<HostOperationRecord.State> = [operation.state]
    switch outcome {
    case .created(let result):
      return try store.finish(
        operation.id, from: current, to: .completed,
        result: created(result, worktreeID: operation.id))
    case .removed(let result):
      return try store.finish(
        operation.id, from: current, to: .completed,
        result: removed(result, worktreeID: operation.binding.worktreeID ?? operation.id))
    case .notStarted:
      return try store.finish(operation.id, from: current, to: .failed, error: cause)
    case .refused:
      // The lifecycle reopened admission after refusing uncommitted content.
      return try store.finish(
        operation.id, from: current, to: .failed,
        error: .init(code: "gateway.execution_failed", message: cause.message))
    case .uncertain, nil:
      guard operation.state != .recoveryRequired else { return operation }
      return try store.finish(operation.id, from: current, to: .recoveryRequired, error: cause)
    }
  }
}

extension GatewayDatabase {
  /// Restart reconciliation by a new execution owner, before it admits lifecycle
  /// callbacks. A reserved operation began no effects; running ones are judged by
  /// their journals.
  func reconcileHostOperations(owner: UUID) throws {
    let store = HostOperationStore(connection: connection)
    for operation in try store.unfinished() where operation.binding.owner != owner {
      switch operation.state {
      case .reserved:
        try store.finish(
          operation.id, from: [.reserved], to: .failed,
          error: .init(
            code: "host.service_denied",
            message: "The originating invocation ended before lifecycle effects began."))
      case .running, .recoveryRequired:
        let outcome = MCPHostOperations.journalOutcome(operation, storage: worktreeStorage)
        if operation.state == .recoveryRequired, outcome == .notStarted { continue }
        let cause: HostOperationRecord.Failure =
          outcome == .notStarted
          ? .init(
            code: "host.service_denied",
            message: "The host stopped before lifecycle effects began.")
          : operation.error
            ?? .init(
              code: "worktree.recovery_required",
              message:
                "The host stopped during this operation; journal recovery must establish its outcome."
            )
        _ = try MCPHostOperations.settle(operation, outcome: outcome, cause: cause, store: store)
      case .completed, .failed: continue
      }
    }
  }
}
