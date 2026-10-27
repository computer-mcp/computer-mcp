import ComputerMCPEgress
import ComputerMCPPermissions
import ComputerMCPSandbox
import Foundation

package enum GatewayExecutionPurpose: Sendable {
  case readOnlyHelper
  case projectProgram
  case pluginProgram
  case remoteService
}

/// Host-created storage and canonical working directory. Writable project and
/// plugin contexts require their owners' verified worktree/private Git context.
package struct GatewaySandboxContext: Sendable {
  package let directory: SandboxPath
  package let temporaryDirectory: SandboxPath
  package let purpose: GatewayExecutionPurpose
  package let privateWorkingDirectory: Bool

  package init(
    directory: SandboxPath, temporaryDirectory: SandboxPath,
    purpose: GatewayExecutionPurpose = .readOnlyHelper, privateWorkingDirectory: Bool = false
  ) {
    self.directory = directory
    self.temporaryDirectory = temporaryDirectory
    self.purpose = purpose
    self.privateWorkingDirectory = privateWorkingDirectory
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
    if authorization.mode == .sandbox,
      context.purpose == .projectProgram || context.purpose == .pluginProgram
    {
      throw ExecutionEnvironmentError.unavailable(
        "Execution requires a verified worktree and private Git context")
    }
    let projection = try ledger.prepareExecutionPermissions(authorizationID)
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
      access: network, localNetwork: projection.localNetwork,
      localNetworkHosts: projection.localNetworkHosts)
    let sandbox: SandboxConfiguration?
    if authorization.mode == .sandbox || context.purpose == .readOnlyHelper
      || context.purpose == .remoteService
    {
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
      let hostExceptions: Set<CanonicalPath> =
        scratch.map { scratch in
          guard !nonHostDenials.contains(where: { $0.contains(scratch) }) else { return [] }
          return (paths?.hostDataLocations ?? []).filter { $0.contains(scratch) }
        } ?? []
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
      if let scratch {
        for root in hostExceptions where root != scratch {
          regions.append(
            try SandboxReadRegion(
              path: SandboxPath(root.string),
              exceptions: [SandboxPath(scratch.string)]))
        }
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
      sandbox = try SandboxConfiguration(
        readOnly: true, worktree: context.directory,
        temporaryDirectory: context.temporaryDirectory,
        homeDirectory: context.temporaryDirectory, cacheDirectory: context.temporaryDirectory,
        readableRoots: reads.sorted(by: { $0.string < $1.string }).map {
          try SandboxPath($0.string)
        },
        deniedReadRegions: regions,
        forbiddenReads: forbidden.sorted(by: { $0.string < $1.string })
          .map { try SandboxPath($0.string) },
        listableAncestors: projection.directoryPaths.map { try SandboxPath($0.path.string) },
        proxy: proxy,
        services: .init(
          screenCapture: projection.screenCapture, accessibility: projection.accessibility))
    } else {
      sandbox = nil
    }
    return GatewayExecutionConfiguration(
      authorization: projection.authorization, sandbox: sandbox, egress: egress,
      limits: projection.limits, permitsProgramLaunch: context.purpose != .remoteService)
  }
}
