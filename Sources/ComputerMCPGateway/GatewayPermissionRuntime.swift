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
  private let database: GatewayDatabase
  private let platform: PlatformServices

  package init(database: GatewayDatabase, platform: PlatformServices) throws {
    self.database = database
    self.platform = platform
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

  package func prepareProvider(
    review: GatewayProviderReview, registrationID: String,
    authorization caller: InvocationAuthorization?, directory workingDirectory: URL?,
    connectionID: String?, retryIDs: Set<UUID> = [], auditContext: ExecutionContext? = nil,
    source: GatewayProviderSource? = nil, platformRules: Set<PathRule>? = nil,
    admittedProvider: ProviderExecutionBinding? = nil, discoveryInScratch: Bool = false
  ) async throws -> PreparedExecutionContext {
    #if os(Linux)
      throw ExecutionEnvironmentError.unavailable("Linux provider activation is unavailable")
    #else
      try await ready()
      if let platformRules {
        try database.permissionTransaction { database in
          try GatewayConfigurationPaths.save(
            platformRules, key: GatewayConfigurationPaths.platformKey, database: database)
        }
      }
      let binding =
        try admittedProvider
        ?? service.authorizeProviderExecution(
          review: review, registrationID: registrationID, caller: caller, retryIDs: retryIDs)
      guard binding.identity == review.identity, binding.registrationID == registrationID,
        binding.sourceDigest == review.sourceDigest,
        binding.delegatingAuthorization?.id == caller?.id
      else { throw PermissionModelError.invalidAuthorization }
      let authorizationID = caller?.id ?? binding.providerAuthorization.id
      let container = try database.prepareProviderContainer(binding.identity)
      let worktree = try database.executionWorktree(
        projectID: binding.providerAuthorization.invocation.projectID,
        directory: workingDirectory, platform: platform)
      let temporary = directory.appendingPathComponent(
        authorizationID.uuidString, isDirectory: true)
      guard temporary.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
        throw ExecutionEnvironmentError.unavailable(
          "A private provider execution directory could not be exclusively created")
      }
      do {
        let root = caller == nil ? temporary : (workingDirectory ?? temporary)
        let launchDirectory = try ProjectPathResolver.canonicalProject(
          (discoveryInScratch && caller == nil ? nil : source?.workingDirectory).map {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0)
          } ?? root)
        let launchIdentity = try VerifiedFileIdentity.capture(launchDirectory)
        let validate: @Sendable () throws -> Void = { [service] in
          try container.verify()
          try source?.validate()
          try launchIdentity.verify(launchDirectory)
          try service.validateProviderExecution(binding)
        }
        return try await coordinator.prepare(
          authorizationID: authorizationID,
          context: GatewaySandboxContext(
            directory: SandboxPath(
              try ProjectPathResolver.canonicalProject(
                root
              ).path),
            temporaryDirectory: SandboxPath(
              try ProjectPathResolver.canonicalProject(temporary).path),
            purpose: caller == nil ? .readOnlyHelper : .pluginProgram,
            privateWorkingDirectory: caller == nil || workingDirectory == nil,
            worktree: worktree, providerContainer: container,
            providerResources: source?.resources ?? []),
          connectionID: connectionID, auditContext: auditContext,
          worktreeAdmission: worktree?.binding.admission, provider: binding,
          providerWorkingDirectory: SandboxPath(launchDirectory.path),
          providerExecutable: try source?.executable.map(SandboxPath.init),
          validateProvider: validate)
      } catch {
        // Once reserved, durable recovery owns the scratch and its pending cleanup.
        let reserved = try? store.readWithDatabase { _, ledger in
          ledger.authorizations[binding.providerAuthorization.id]?.executionID != nil
        }
        if reserved == false { try? FileManager.default.removeItem(at: temporary) }
        throw error
      }
    #endif
  }

  package func prepare(
    authorization: InvocationAuthorization, descriptor: CapabilityDescriptor,
    directory workingDirectory: URL?, connectionID: String?, remoteService: Bool = false,
    hostManagement: Bool = false,
    auditContext: ExecutionContext? = nil, callback: ProviderExecutionBinding? = nil,
    validateCallback: (@Sendable () throws -> Void)? = nil
  ) async throws -> any InvocationExecutionAuthority {
    try await ready()
    try validateCallback?()
    let initiatingAuthorization = authorization
    let authorization = callback?.providerAuthorization ?? authorization
    let callbackIDs = callback?.authorizationIDs ?? []
    switch descriptor.requirement.execution {
    case .read, .input, .cancel, .list:
      return try coordinator.continuation(
        authorizationID: initiatingAuthorization.id, connectionID: connectionID,
        additionalAuthorizationIDs: callbackIDs)
    default: break
    }
    if hostManagement {
      return GatewayManagementInvocation(
        authorization: authorization,
        pathAccess: GatewayPathAccess(
          store: store, authorizationID: authorization.id,
          additionalAuthorizationIDs: callbackIDs, validateInvocation: validateCallback))
    }
    if [
      "project.list", "project.describe", "project.request", "policy.probe", "runtime.owners.list",
      "runtime.owners.call", "mcp.servers.list", "mcp.servers.status", "mcp.events.read",
      "mcp.tools.list",
    ].contains(descriptor.id) {
      return GatewayInvocationPathScope(
        pathAccess: GatewayPathAccess(
          store: store, authorizationID: authorization.id,
          additionalAuthorizationIDs: callbackIDs, validateInvocation: validateCallback))
    }
    if ["network.ping", "network.tcp_check", "network.http_check"].contains(descriptor.id) {
      throw ExecutionEnvironmentError.unavailable(
        "This diagnostic requires a prepared fixed-service network execution context")
    }
    if descriptor.hostOperation == .worktreeLifecycle {
      guard !remoteService, descriptor.mcpReference == nil,
        descriptor.requirement.execution == .none,
        [
          "git.worktree_add", "git.worktree_list", "git.worktree_remove", "git.merge",
          "git.branch_delete",
        ].contains(descriptor.id)
      else { throw PermissionModelError.invalidAuthorization }
      try service.validateAuthorization(authorization.id)
      let prepared: Result<InvocationAuthorization, any Error> = try store.transactionWithDatabase {
        _, ledger in
        Result {
          for id in callbackIDs { _ = try ledger.prepareWorktreePermissions(id) }
          return try ledger.prepareWorktreePermissions(authorization.id)
        }
      }
      return GatewayWorktreeInvocation(
        authorization: try prepared.get(), additionalAuthorizationIDs: callbackIDs)
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
    if purpose == .pluginProgram {
      throw ExecutionEnvironmentError.unavailable(
        "Local plugin programs require the plugin owner's verified execution context")
    }
    let worktree: GatewayWorktreeExecution?
    if !remoteService, let workingDirectory {
      worktree = try database.executionWorktree(
        projectID: authorization.invocation.projectID, directory: workingDirectory,
        platform: platform)
    } else {
      worktree = nil
    }
    let temporary = directory.appendingPathComponent(
      initiatingAuthorization.id.uuidString, isDirectory: true)
    guard temporary.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
      throw ExecutionEnvironmentError.unavailable(
        "A private execution directory could not be exclusively created")
    }
    do {
      return try await coordinator.prepare(
        authorizationID: initiatingAuthorization.id,
        context: GatewaySandboxContext(
          directory: SandboxPath(
            try ProjectPathResolver.canonicalProject(
              remoteService ? temporary : (workingDirectory ?? temporary)
            ).path),
          temporaryDirectory: SandboxPath(try ProjectPathResolver.canonicalProject(temporary).path),
          purpose: purpose, privateWorkingDirectory: remoteService || workingDirectory == nil,
          fixedHostOperation: fixed, worktree: worktree,
          providerContainer: try callback.map { try database.prepareProviderContainer($0.identity) }
        ),
        fullAccessEnvironment: callback == nil ? ProcessInfo.processInfo.environment : [:],
        connectionID: connectionID,
        auditContext: auditContext, worktreeAdmission: worktree?.binding.admission,
        validateProvider: validateCallback, callback: callback)
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
      // A new execution owner reconciles operations other owners left unfinished.
      try reconcileHostOperations(owner: runtime.coordinator.ownerIdentity)
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
