import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPSandbox
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Shared by every profile and connection using the same durable host database.
package final class GatewayPermissionRuntime: @unchecked Sendable {
  package let store: SQLitePermissionStore
  package let service: GatewayPermissionService
  package let coordinator: ExecutionRevocationCoordinator
  private let directory: URL
  private let gitExecutable: String

  package init(database: GatewayDatabase, platform: PlatformServices) throws {
    store = try database.configuredPermissionStore()
    directory = database.permissionExecutionRoot
    gitExecutable = platform.gitExecutable
    let notifications = GatewayExecutionNotifications()
    let service = GatewayPermissionService(
      store: store, policyReader: platform.permissionPolicyReader,
      onAuthorityChange: { notifications.notify() },
      projectBookmarks: platform.projectGrants,
      projectNesting: { projects in
        try GatewayTrackedProjectNesting.inspect(
          projects, runner: ProcessCommandRunner(launcher: platform.launcher))
      })
    self.service = service
    let coordinator = try ExecutionRevocationCoordinator(
      store: store, launcher: platform.launcher, directory: directory,
      proxyFactory: platform.executionProxy,
      refreshPolicy: { _ = try service.reconcilePolicy(notify: false) })
    self.coordinator = coordinator
    notifications.attach(coordinator)
    database.setPermissionAuthorityChangeHandler { coordinator.notify() }
    Task { try? await coordinator.recover() }
  }

  package func ready() async throws { try await coordinator.recover() }

  package func prepare(
    authorization: InvocationAuthorization, descriptor: CapabilityDescriptor,
    directory workingDirectory: URL?, connectionID: String?, remoteService: Bool = false,
    hostManagement: Bool = false,
    auditContext: ExecutionContext? = nil
  ) async throws -> any InvocationExecutionAuthority {
    try await ready()
    switch descriptor.requirement.execution {
    case .read, .input, .cancel, .list:
      return try coordinator.continuation(
        authorizationID: authorization.id, connectionID: connectionID)
    default: break
    }
    if hostManagement {
      return GatewayManagementInvocation(
        authorization: authorization,
        pathAccess: GatewayPathAccess(store: store, authorizationID: authorization.id))
    }
    if [
      "project.list", "project.describe", "project.request", "policy.probe", "runtime.owners.list",
      "runtime.owners.call", "mcp.servers.list", "mcp.servers.status", "mcp.events.read",
    ].contains(descriptor.id) {
      return GatewayInvocationPathScope(
        pathAccess: GatewayPathAccess(store: store, authorizationID: authorization.id))
    }
    if ["network.ping", "network.tcp_check", "network.http_check"].contains(descriptor.id) {
      throw ExecutionEnvironmentError.unavailable(
        "This diagnostic requires a prepared fixed-service network execution context")
    }
    let requirement = descriptor.requirement
    let writes =
      requirement.access == .projectWrite || requirement.access == .sourceProjectWrite
      || requirement.paths.contains { $0.operation == .write }
    let fixed: PreparedExecutionContext.FixedHostOperation?
    if let operation = descriptor.hostOperation {
      guard !remoteService, descriptor.mcpReference == nil,
        requirement.execution == .none, requirement.access != .sourceProjectWrite,
        let workingDirectory
      else {
        throw ExecutionEnvironmentError.unavailable(
          "The host operation requires its lifecycle service and fixed Git executable")
      }
      if writes,
        try await store.read().environment.paths?.registeredProjects.contains(where: {
          $0.id == authorization.invocation.projectID && $0.hostContentIdentity != nil
        }) == true
      {
        throw ExecutionEnvironmentError.unavailable(
          "Writable worktree tools require a bound worktree admission lease")
      }
      fixed = try .init(
        operation: operation, gitExecutable: SandboxPath(gitExecutable),
        directory: SandboxPath(ProjectPathResolver.canonicalProject(workingDirectory).path),
        allowsWrites: writes)
    } else {
      fixed = nil
    }
    let purpose: GatewayExecutionPurpose
    if fixed != nil {
      purpose = .readOnlyHelper
    } else if remoteService {
      purpose = .remoteService
    } else if descriptor.mcpReference != nil || descriptor.id.hasPrefix("mcp.") {
      purpose = .pluginProgram
    } else if writes || requirement.requiresFullAccess || requirement.execution == .start {
      purpose = .projectProgram
    } else {
      purpose = .readOnlyHelper
    }
    let temporary = directory.appendingPathComponent(authorization.id.uuidString, isDirectory: true)
    guard temporary.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
      throw ExecutionEnvironmentError.unavailable(
        "A private execution directory could not be exclusively created")
    }
    do {
      return try await coordinator.prepare(
        authorizationID: authorization.id,
        context: GatewaySandboxContext(
          directory: SandboxPath(
            try ProjectPathResolver.canonicalProject(
              remoteService ? temporary : (workingDirectory ?? temporary)
            ).path),
          temporaryDirectory: SandboxPath(try ProjectPathResolver.canonicalProject(temporary).path),
          purpose: purpose, privateWorkingDirectory: remoteService || workingDirectory == nil,
          fixedHostOperation: fixed),
        fullAccessEnvironment: ProcessInfo.processInfo.environment, connectionID: connectionID,
        auditContext: auditContext)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

extension GatewayDatabase {
  package func permissionRuntime(platform: PlatformServices) throws -> GatewayPermissionRuntime {
    try permissionRuntimeLock.withLock {
      if let existing = permissionRuntimeCache { return existing }
      let runtime = try GatewayPermissionRuntime(database: self, platform: platform)
      permissionRuntimeCache = runtime
      return runtime
    }
  }
}

private struct GatewayInvocationPathScope: InvocationExecutionAuthority {
  let pathAccess: (any HostPathAccessChecking)?
}

/// The synchronous API joins the same asynchronous admission and dispatch path.
private final class GatewaySynchronousResult<Value: Sendable>: @unchecked Sendable {
  let signal = DispatchSemaphore(value: 0)
  var result: Result<Value, any Error>?
}

enum GatewaySynchronousOperation {
  static func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) throws
    -> Value
  {
    let box = GatewaySynchronousResult<Value>()
    Task.detached {
      do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
      box.signal.signal()
    }
    box.signal.wait()
    return try box.result!.get()
  }
}

private final class GatewayExecutionNotifications: @unchecked Sendable {
  private let lock = NSLock()
  private weak var coordinator: ExecutionRevocationCoordinator?
  func attach(_ coordinator: ExecutionRevocationCoordinator) {
    lock.withLock { self.coordinator = coordinator }
  }
  func notify() { lock.withLock { coordinator }?.notify() }
}
