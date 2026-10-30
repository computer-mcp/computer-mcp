import ComputerMCPEgress
import ComputerMCPPermissions
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPSandbox
import Foundation

package enum GatewayExecutionPurpose: Sendable {
  case readOnlyHelper
  case projectProgram
  case pluginProgram
  case remoteService
}

/// Host-created storage and canonical working directory. A worktree binding
/// comes from its repository owner and is checked against the current ledger.
package struct GatewaySandboxContext: Sendable {
  package let directory: SandboxPath
  package let temporaryDirectory: SandboxPath
  package let purpose: GatewayExecutionPurpose
  package let privateWorkingDirectory: Bool
  package let fixedHostOperation: PreparedExecutionContext.FixedHostOperation?
  package let worktree: GatewayWorktreeExecution?
  package let providerContainer: GatewayProviderContainer?
  let providerResources: [VerifiedFileIdentity]

  package init(
    directory: SandboxPath, temporaryDirectory: SandboxPath,
    purpose: GatewayExecutionPurpose = .readOnlyHelper, privateWorkingDirectory: Bool = false,
    fixedHostOperation: PreparedExecutionContext.FixedHostOperation? = nil,
    worktree: GatewayWorktreeExecution? = nil, providerContainer: GatewayProviderContainer? = nil,
    providerResources: [VerifiedFileIdentity] = []
  ) {
    self.directory = directory
    self.temporaryDirectory = temporaryDirectory
    self.purpose = purpose
    self.privateWorkingDirectory = privateWorkingDirectory
    self.fixedHostOperation = fixedHostOperation
    self.worktree = worktree
    self.providerContainer = providerContainer
    self.providerResources = providerResources
  }
}

package struct GatewayExecutionConfiguration: Sendable {
  package let authorization: InvocationAuthorization
  package let sandbox: SandboxConfiguration?
  package let egress: EgressPolicy
  package let limits: EffectiveExecutionLimits
  package let permitsProgramLaunch: Bool
}

/// Composition only: neither the sandbox nor the proxy reads permission storage.
package enum GatewaySandboxCompiler {
  package static func compile(
    ledger: inout PermissionLedger, authorizationID: UUID, context: GatewaySandboxContext,
    proxy: SandboxProxyPorts? = nil, ownedTemporaryDirectory: SandboxPath? = nil,
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    reservedProjection: ExecutionPermissionProjection? = nil,
    provider: ProviderExecutionBinding? = nil, providerWorkingDirectory: SandboxPath? = nil
  ) throws -> GatewayExecutionConfiguration {
    guard let authorization = ledger.authorizations[authorizationID] else {
      throw PermissionModelError.unknownAuthorization
    }
    if context.purpose == .pluginProgram || !context.providerResources.isEmpty {
      guard let provider, provider.providerAuthorization.id == authorizationID,
        provider.identity == context.providerContainer?.identity
      else { throw PermissionModelError.invalidAuthorization }
      for id in provider.authorizationIDs { _ = try ledger.invocationAccess(id) }
    }
    for resource in context.providerResources {
      try resource.verify(URL(fileURLWithPath: resource.path))
    }
    let settings = ledger.sandboxSettings.settings(
      for: authorization.invocation.principal, sourceProjectID: authorization.sandboxProjectID)
    try GatewayProviderReadExceptions.verify(settings.readExceptions, userHome: userHome)
    if context.providerContainer != nil, authorization.invocation.projectID == nil,
      context.purpose == .readOnlyHelper, authorization.mode != .sandbox
    {
      throw ExecutionEnvironmentError.unavailable("Provider discovery requires sandbox admission")
    }
    if let container = context.providerContainer {
      guard authorization.invocation.principal == .plugin(container.identity),
        ledger.environment.paths?.hostDataLocations.contains(where: {
          $0.contains(container.storageRoot)
        }) == true
      else { throw PermissionModelError.invalidAuthorization }
      try container.verify()
    }
    if let worktree = context.worktree {
      guard worktree.binding.projectID == authorization.invocation.projectID,
        context.directory == worktree.directory,
        ledger.environment.paths?.registeredProjects.contains(where: {
          $0.id == worktree.binding.projectID
            && $0.hostContentIdentity == worktree.binding.generation
            && $0.root.string == worktree.directory.value
        }) == true
      else { throw PermissionModelError.invalidAuthorization }
      try worktree.binding.verify()
    }
    if let fixed = context.fixedHostOperation {
      guard fixed.directory == context.directory, context.purpose == .readOnlyHelper,
        authorization.mode != .sandbox || !fixed.allowsWrites || context.worktree != nil
      else {
        throw ExecutionEnvironmentError.unavailable(
          "Writable host operations require their verified execution context")
      }
    }
    let providerWrites =
      context.purpose == .pluginProgram
      && authorization.actions.contains {
        $0.requirement.permission == authorization.sandboxProjectID.map(Permission.project)
          && $0.requirement.value == .write
      }
    if authorization.mode == .sandbox,
      (context.purpose == .projectProgram || providerWrites) && context.worktree == nil
    {
      throw ExecutionEnvironmentError.unavailable(
        "Execution requires a verified worktree and private Git context")
    }
    let sandboxed =
      authorization.mode == .sandbox || context.purpose == .readOnlyHelper
      || context.purpose == .remoteService
    let writableWorktree =
      context.worktree != nil
      && (context.purpose == .projectProgram || providerWrites
        || context.fixedHostOperation?.allowsWrites == true)
    if sandboxed && writableWorktree && reservedProjection == nil {
      _ = try ledger.prepareWorktreePermissions(authorizationID)
    }
    let projection: ExecutionPermissionProjection
    if let reservedProjection {
      guard reservedProjection.authorization.id == authorizationID,
        authorization.executionID != nil,
        reservedProjection.authorization.basis.isSubset(of: authorization.basis),
        try ledger.invocationAccess(authorizationID).id == authorizationID
      else { throw PermissionModelError.invalidAuthorization }
      projection = reservedProjection
    } else {
      projection = try ledger.prepareExecutionPermissions(authorizationID, sandboxed: sandboxed)
    }
    try projection.limits.requireEnforceable(by: .init())
    let network: EgressAccess
    switch projection.network {
    case .none: network = .none
    case .full: network = .full
    case .trusted:
      // The ledger's trusted list, including its identities, owns this snapshot.
      network = .custom(
        hosts: ledger.environment.trustedHosts.map(\.host).sorted(), includeTrusted: false)
    case .custom(let hosts, let trusted):
      network = .custom(
        hosts: hosts.union(trusted ? Set(ledger.environment.trustedHosts.map(\.host)) : [])
          .sorted(),
        includeTrusted: false)
    }
    let egress = try EgressPolicy(
      access: context.fixedHostOperation == nil ? network : .none,
      localNetwork: context.fixedHostOperation == nil && projection.localNetwork,
      localNetworkHosts: context.fixedHostOperation == nil ? projection.localNetworkHosts : [])
    let sandbox: SandboxConfiguration?
    if sandboxed {
      var reads = Set(projection.readablePaths.map(\.path))
      let scratch = try ownedTemporaryDirectory.map { try CanonicalPath($0.value) }
      guard ownedTemporaryDirectory == nil || ownedTemporaryDirectory == context.temporaryDirectory
      else {
        throw PermissionModelError.invalidAuthorization
      }
      let paths = ledger.environment.paths
      var nonHostDenials = paths?.deniedLocations ?? []
      nonHostDenials.formUnion(settings.deniedReadLocations)
      for source in ledger.environment.limits[authorization.invocation.principal]?.sources.values
        ?? [PolicySource: PolicyAvailability]().values
      {
        if case .available(let policy) = source {
          nonHostDenials.formUnion(policy.deniedReadLocations)
        }
      }
      for element in authorization.basis {
        if case .connection(let id, _) = element {
          nonHostDenials.formUnion(
            ledger.environment.connections[id]?.attenuation.deniedReadLocations ?? [])
        }
      }
      let content = paths?.registeredProjects.first {
        $0.id == authorization.invocation.projectID && $0.hostContentIdentity != nil
      }?.root
      let privateRepository = try context.worktree.map {
        try CanonicalPath($0.git.repository.value)
      }
      let containerRoot = context.providerContainer?.root
      let resources = try Set(context.providerResources.map { try CanonicalPath($0.path) })
      guard
        !resources.contains(where: { resource in
          nonHostDenials.contains { $0.contains(resource) || resource.contains($0) }
        })
      else { throw PermissionModelError.invalidAuthorization }
      reads.formUnion(resources)
      if let directory = providerWorkingDirectory, directory != context.directory {
        let path = try CanonicalPath(directory.value)
        guard
          resources.contains(where: { $0.contains(path) })
            || projection.readablePaths.contains(where: {
              $0.path.contains(path)
                && !($0.excludedSubtrees ?? []).contains(where: { $0.contains(path) })
            })
        else { throw PermissionModelError.invalidAuthorization }
      }
      if let containerRoot {
        guard
          !nonHostDenials.contains(where: {
            $0.contains(containerRoot) || containerRoot.contains($0)
          })
        else {
          throw PermissionModelError.invalidAuthorization
        }
        reads.insert(containerRoot)
      }
      let ownedOpenings = Set(
        [scratch, content, privateRepository, containerRoot].compactMap { $0 }
          + Array(resources)
      ).filter {
        candidate in
        !nonHostDenials.contains(where: { $0.contains(candidate) })
      }
      let hostExceptions = (paths?.hostDataLocations ?? []).filter { root in
        ownedOpenings.contains { root.contains($0) && ($0 == scratch || root != $0) }
      }
      let scratchAllowed =
        scratch.map { candidate in
          !nonHostDenials.contains(where: { $0.contains(candidate) })
        } ?? false
      let forbidden = projection.forbiddenPaths.subtracting(hostExceptions)
      let denied = projection.boundaries.subtracting(reads).subtracting(projection.forbiddenPaths)
      var regions = try denied.sorted(by: { $0.string < $1.string }).map { path in
        try SandboxReadRegion(
          path: SandboxPath(path.string),
          exceptions: reads.union(scratchAllowed ? Set(scratch.map { [$0] } ?? []) : [])
            .filter { path != $0 && path.contains($0) }
            .sorted(by: { $0.string < $1.string }).map { try SandboxPath($0.string) })
      }
      for root in hostExceptions {
        let exceptions = ownedOpenings.filter { root.contains($0) }
        regions.append(
          try SandboxReadRegion(
            path: SandboxPath(root.string),
            exceptions: exceptions.sorted { $0.string < $1.string }.map {
              try SandboxPath($0.string)
            }))
      }
      // The working directory itself must be readable; traversable ancestors do
      // not confer a recursive read opening.
      let workingPath = try CanonicalPath(context.directory.value)
      let privateDirectory =
        context.privateWorkingDirectory
        && (context.purpose == .readOnlyHelper || context.purpose == .remoteService
          || context.purpose == .pluginProgram && provider != nil)
        && context.directory == context.temporaryDirectory
      guard
        privateDirectory
          || projection.readablePaths.contains(where: {
            $0.path.contains(workingPath)
              && !($0.excludedSubtrees ?? []).contains(where: { $0.contains(workingPath) })
          })
      else { throw PermissionModelError.invalidAuthorization }
      var deniedWrites: [CanonicalPath] = []
      var allowedWrites: [CanonicalPath] = []
      if writableWorktree
        || (context.fixedHostOperation?.operation == .git
          && context.fixedHostOperation?.allowsWrites == true)
      {
        for boundary in projection.boundaries.union([workingPath])
          .filter({ workingPath.contains($0) }).sorted(by: { $0.string < $1.string })
        {
          do {
            try ledger.authorizePathUse(authorizationID, path: boundary, operation: .write)
            allowedWrites.append(boundary)
          } catch {
            deniedWrites.append(boundary)
          }
        }
      }
      let writeRegions = try deniedWrites.map { denied in
        try SandboxReadRegion(
          path: SandboxPath(denied.string),
          exceptions: allowedWrites.filter { denied != $0 && denied.contains($0) }
            .map { try SandboxPath($0.string) })
      }
      if let worktree = context.worktree {
        regions.append(try .init(path: .init(worktree.git.sharedDirectory.value + "/computer-mcp")))
        try ledger.authorizePathUse(
          authorizationID, path: workingPath, operation: writableWorktree ? .write : .read)
      }
      let container = try context.providerContainer?.sandbox
      sandbox = try SandboxConfiguration(
        readOnly: !writableWorktree, worktree: context.directory,
        temporaryDirectory: context.temporaryDirectory,
        homeDirectory: container?.home ?? context.temporaryDirectory,
        cacheDirectory: container?.cache ?? context.temporaryDirectory,
        readableRoots: reads.sorted(by: { $0.string < $1.string }).map {
          try SandboxPath($0.string)
        },
        providerContainer: container,
        deniedReadRegions: regions,
        deniedWriteRegions: writeRegions,
        forbiddenReads: forbidden.sorted(by: { $0.string < $1.string })
          .map { try SandboxPath($0.string) },
        listableAncestors: projection.directoryPaths.map { try SandboxPath($0.path.string) },
        git: context.worktree?.git,
        proxy: proxy,
        services: .init(
          screenCapture: projection.screenCapture, accessibility: projection.accessibility))
    } else {
      sandbox = nil
    }
    return GatewayExecutionConfiguration(
      authorization: ledger.authorizations[authorizationID]!, sandbox: sandbox, egress: egress,
      limits: projection.limits,
      permitsProgramLaunch: context.purpose != .remoteService && context.fixedHostOperation == nil)
  }
}
