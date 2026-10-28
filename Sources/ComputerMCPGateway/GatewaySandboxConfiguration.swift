import ComputerMCPEgress
import ComputerMCPPermissions
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

  package init(
    directory: SandboxPath, temporaryDirectory: SandboxPath,
    purpose: GatewayExecutionPurpose = .readOnlyHelper, privateWorkingDirectory: Bool = false,
    fixedHostOperation: PreparedExecutionContext.FixedHostOperation? = nil,
    worktree: GatewayWorktreeExecution? = nil
  ) {
    self.directory = directory
    self.temporaryDirectory = temporaryDirectory
    self.purpose = purpose
    self.privateWorkingDirectory = privateWorkingDirectory
    self.fixedHostOperation = fixedHostOperation
    self.worktree = worktree
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
    proxy: SandboxProxyPorts? = nil, ownedTemporaryDirectory: SandboxPath? = nil
  ) throws -> GatewayExecutionConfiguration {
    guard let authorization = ledger.authorizations[authorizationID] else {
      throw PermissionModelError.unknownAuthorization
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
    if authorization.mode == .sandbox,
      (context.purpose == .projectProgram && context.worktree == nil)
        || context.purpose == .pluginProgram
    {
      throw ExecutionEnvironmentError.unavailable(
        "Execution requires a verified worktree and private Git context")
    }
    let sandboxed =
      authorization.mode == .sandbox || context.purpose == .readOnlyHelper
      || context.purpose == .remoteService
    let writableWorktree =
      context.worktree != nil
      && (context.purpose == .projectProgram || context.fixedHostOperation?.allowsWrites == true)
    if sandboxed && writableWorktree {
      _ = try ledger.prepareWorktreePermissions(authorizationID)
    }
    let projection = try ledger.prepareExecutionPermissions(authorizationID, sandboxed: sandboxed)
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
      let reads = Set(projection.readablePaths.map(\.path))
      let scratch = try ownedTemporaryDirectory.map { try CanonicalPath($0.value) }
      guard ownedTemporaryDirectory == nil || ownedTemporaryDirectory == context.temporaryDirectory
      else {
        throw PermissionModelError.invalidAuthorization
      }
      let paths = ledger.environment.paths
      var nonHostDenials = paths?.deniedLocations ?? []
      if let projectID = authorization.sandboxProjectID {
        let settingsKey = SandboxSettingsKey(
          principal: authorization.invocation.principal, projectID: projectID)
        nonHostDenials.formUnion(
          ledger.sandboxSettings.entries[settingsKey]?.deniedReadLocations ?? [])
      }
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
      let ownedOpenings = Set([scratch, content, privateRepository].compactMap { $0 }).filter {
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
        && (context.purpose == .readOnlyHelper || context.purpose == .remoteService)
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
      sandbox = try SandboxConfiguration(
        readOnly: !writableWorktree, worktree: context.directory,
        temporaryDirectory: context.temporaryDirectory,
        homeDirectory: context.temporaryDirectory, cacheDirectory: context.temporaryDirectory,
        readableRoots: reads.sorted(by: { $0.string < $1.string }).map {
          try SandboxPath($0.string)
        },
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
