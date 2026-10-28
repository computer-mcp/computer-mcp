import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPSandbox
import Foundation
import NIOConcurrencyHelpers

/// The authority owns durable reservation and completion. Ownership callbacks must
/// only install handlers; the bootstrap invokes persistence before releasing code.
package protocol ExecutionAuthorizing: Sendable {
  var executionID: UUID { get }
  var authorizationIDs: Set<UUID> { get }
  func reserveChild(_ id: UUID) throws
  func bindChild(_ id: UUID, ownership: any ExecutionOwnership)
  func launchFailed(_ id: UUID)
  func finishAdmission() throws
  func retainWork(cancellation: @escaping @Sendable () async -> Void) throws -> ExecutionWorkLease
  func access(_ executionID: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  func permissionRequests(_ executionID: UUID) throws -> [PermissionRequest]
}

extension ExecutionAuthorizing {
  package func permissionRequests(_ executionID: UUID) throws -> [PermissionRequest] { [] }
  package func retainWork(cancellation: @escaping @Sendable () async -> Void) throws
    -> ExecutionWorkLease
  {
    throw ExecutionEnvironmentError.unavailable(
      "This execution authority cannot retain provider work")
  }
}

/// A host-owned logical request remains live until its downstream outcome settles.
/// Dropping the handle does not assert that remote work stopped.
package final class ExecutionWorkLease: Sendable {
  private let completed = NIOLockedValueBox(false)
  private let completion: @Sendable () throws -> Void
  package init(completion: @escaping @Sendable () throws -> Void) { self.completion = completion }
  package func finish() throws {
    try completed.withLockedValue { value in
      guard !value else { return }
      try completion()
      value = true
    }
  }
}

package struct ExecutionPermissionRequestGroup: Sendable {
  package let executionID: UUID
  package let requests: [PermissionRequest]

  package init(executionID: UUID, requests: [PermissionRequest]) {
    self.executionID = executionID
    self.requests = requests
  }
}

package protocol ExecutionAccessChecking: InvocationExecutionAuthority {
  func accessExecution(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  func permissionRequests(_ id: UUID) throws -> [PermissionRequest]
  func currentPermissionRequestGroups() throws -> [ExecutionPermissionRequestGroup]
}

extension ExecutionAccessChecking {
  package func permissionRequests(_ id: UUID) throws -> [PermissionRequest] { [] }
  package func currentPermissionRequestGroups() throws -> [ExecutionPermissionRequestGroup] { [] }
}

package protocol ExecutionRecoveryAuthorizing: Sendable {
  func recoveredExecution(_ id: UUID) throws -> EffectiveExecutionLimits?
  func observeExecutionLimits(
    _ id: UUID, _ observer: @escaping @Sendable (EffectiveExecutionLimits) -> Void) throws
}

/// One logical execution may start several host helpers or background children.
/// Its immutable launch policy takes precedence over provider risk classifications.
package final class PreparedExecutionContext: ExecutionAccessChecking, Sendable {
  package struct FixedHostOperation: Sendable {
    package let operation: HostOperation
    package let gitExecutable: SandboxPath
    package let directory: SandboxPath
    package let allowsWrites: Bool

    package init(
      operation: HostOperation, gitExecutable: SandboxPath, directory: SandboxPath,
      allowsWrites: Bool
    ) {
      self.operation = operation
      self.gitExecutable = gitExecutable
      self.directory = directory
      self.allowsWrites = allowsWrites
    }
  }

  private struct FixedCommand: Sendable {
    let arguments: [String]
    let environment: [String: String]
  }

  package let authority: any ExecutionAuthorizing
  package let mode: ComputerMCPSandbox.ExecutionMode
  package let environment: ExecutionEnvironment
  package let permitsProgramLaunch: Bool
  package let pathAccess: (any HostPathAccessChecking)?
  package let fixedHostOperation: FixedHostOperation?
  private let fixedCommand: FixedCommand?
  package let worktreeGit: SandboxGitConfiguration?
  private let validateWorktree: (@Sendable () throws -> Void)?
  private struct State: Sendable {
    var limits: EffectiveExecutionLimits
    var endReason: ExecutionLimitEndReason?
    var observers: [@Sendable (EffectiveExecutionLimits) -> Void] = []
  }
  private let state: NIOLockedValueBox<State>

  package init(
    authority: any ExecutionAuthorizing, mode: ComputerMCPSandbox.ExecutionMode,
    environment: ExecutionEnvironment,
    limits: EffectiveExecutionLimits, pathAccess: (any HostPathAccessChecking)? = nil,
    permitsProgramLaunch: Bool = true, fixedHostOperation: FixedHostOperation? = nil,
    worktreeGit: SandboxGitConfiguration? = nil,
    validateWorktree: (@Sendable () throws -> Void)? = nil
  ) {
    self.authority = authority
    self.mode = mode
    self.environment = environment
    self.pathAccess = pathAccess
    self.permitsProgramLaunch = permitsProgramLaunch
    self.fixedHostOperation = fixedHostOperation
    self.fixedCommand = nil
    self.worktreeGit = worktreeGit
    self.validateWorktree = validateWorktree
    state = .init(State(limits: limits))
  }

  private init(
    parent: PreparedExecutionContext, sandbox: SandboxConfiguration, command: FixedCommand
  ) {
    authority = parent.authority
    mode = .sandbox(sandbox)
    environment = parent.environment
    pathAccess = parent.pathAccess
    permitsProgramLaunch = true
    fixedHostOperation = parent.fixedHostOperation
    fixedCommand = command
    worktreeGit = parent.worktreeGit
    validateWorktree = parent.validateWorktree
    state = parent.state
  }

  /// A trusted helper binds the complete invocation; provider CLI input cannot enter this scope.
  package func withHostGitCommand<Value>(
    arguments: [String], directory: SandboxPath, environment: [String: String],
    writing commonDirectory: SandboxPath? = nil, _ body: () throws -> Value
  ) throws -> Value {
    guard let fixed = fixedHostOperation, fixed.directory == directory,
      case .sandbox(let initial) = mode, fixedCommand == nil,
      initial.worktree == directory
    else { throw ExecutionEnvironmentError.unavailable("No fixed host Git authority is installed") }
    _ = try authority.access(executionID, operation: .readResult)
    let sandbox: SandboxConfiguration
    try validateWorktree?()
    if let commonDirectory {
      guard worktreeGit == nil else {
        throw ExecutionEnvironmentError.unavailable(
          "Shared Git mutations must run in the source project")
      }
      guard fixed.operation == .git, fixed.allowsWrites else {
        throw ExecutionEnvironmentError.unavailable("This host operation cannot write Git state")
      }
      try pathAccess?.check(URL(fileURLWithPath: directory.value), operation: .write)
      try pathAccess?.check(URL(fileURLWithPath: commonDirectory.value), operation: .write)
      sandbox = try SandboxConfiguration(
        readOnly: false, worktree: initial.worktree,
        temporaryDirectory: initial.temporaryDirectory, homeDirectory: initial.homeDirectory,
        cacheDirectory: initial.cacheDirectory, readableRoots: initial.readableRoots,
        deniedReadRegions: initial.deniedReadRegions,
        deniedWriteRegions: initial.deniedWriteRegions,
        forbiddenReads: initial.forbiddenReads,
        listableAncestors: initial.listableAncestors, hostGitDirectory: commonDirectory)
    } else {
      sandbox = initial
    }
    let scoped = PreparedExecutionContext(
      parent: self, sandbox: sandbox,
      command: FixedCommand(arguments: arguments, environment: environment))
    return try scoped.withValue(body)
  }

  func validateFixedCommand(
    executable: SandboxPath, arguments: [String], directory: SandboxPath,
    directoryDescriptor: Int32?, inheritedDescriptors: [Int32: Int32]
  ) throws {
    try validateWorktree?()
    guard let fixed = fixedHostOperation else { return }
    guard let command = fixedCommand, executable == fixed.gitExecutable,
      arguments == command.arguments, directory == fixed.directory,
      HostCommandEnvironment.current == command.environment,
      directoryDescriptor == nil, inheritedDescriptors.isEmpty
    else {
      throw ExecutionEnvironmentError.unavailable("The command is outside its fixed host operation")
    }
  }

  package var executionID: UUID { authority.executionID }
  package var limits: EffectiveExecutionLimits { state.withLockedValue { $0.limits } }
  package var limitEndReason: ExecutionLimitEndReason? { state.withLockedValue { $0.endReason } }

  package static func current() throws -> PreparedExecutionContext? {
    guard let scope = InvocationExecution.current else { return nil }
    guard let prepared = scope as? PreparedExecutionContext else {
      throw ExecutionEnvironmentError.unavailable(
        "Execution authority has no prepared launch context")
    }
    return prepared
  }

  package func withValue<Value>(_ body: () throws -> Value) rethrows -> Value {
    try InvocationExecution.$current.withValue(self) {
      try HostPathAccess.$current.withValue(pathAccess, operation: body)
    }
  }

  package func withValue<Value: Sendable>(_ body: @Sendable () async throws -> Value) async rethrows
    -> Value
  {
    try await InvocationExecution.$current.withValue(self) {
      try await HostPathAccess.$current.withValue(pathAccess) { try await body() }
    }
  }

  package func accessExecution(_ id: UUID, operation: ExecutionOperation) throws
    -> EffectiveExecutionLimits
  {
    if operation == .writeInput { try validateWorktree?() }
    return try authority.access(id, operation: operation)
  }

  package func finishAdmission() throws { try authority.finishAdmission() }

  package func permissionRequests(_ id: UUID) throws -> [PermissionRequest] {
    try authority.permissionRequests(id)
  }

  package func currentPermissionRequestGroups() throws -> [ExecutionPermissionRequestGroup] {
    let requests = try permissionRequests(executionID)
    return requests.isEmpty ? [] : [.init(executionID: executionID, requests: requests)]
  }

  package func retainWork(cancellation: @escaping @Sendable () async -> Void) throws
    -> ExecutionWorkLease
  {
    try authority.retainWork(cancellation: cancellation)
  }

  package func observeLimits(_ observer: @escaping @Sendable (EffectiveExecutionLimits) -> Void) {
    let limits = state.withLockedValue {
      $0.observers.append(observer)
      return $0.limits
    }
    observer(limits)
  }

  package func applyLimits(
    _ limits: EffectiveExecutionLimits, endReason: ExecutionLimitEndReason? = nil
  ) {
    let delivery = state.withLockedValue {
      $0.endReason = $0.endReason ?? endReason
      let applied = limits.tightening($0.limits)
      guard $0.limits != applied else {
        return (applied, [@Sendable (EffectiveExecutionLimits) -> Void]())
      }
      $0.limits = applied
      return (applied, $0.observers)
    }
    for observer in delivery.1 { observer(delivery.0) }
  }
}
