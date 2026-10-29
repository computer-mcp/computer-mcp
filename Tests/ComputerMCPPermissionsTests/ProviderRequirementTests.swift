import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ProviderRequirementTests {
  private let provider = PluginIdentity.package("auditor")
  private let digest = "reviewed"

  private func requirements(conservative: Bool = true) -> InvocationRequirements {
    InvocationRequirements(
      actions: [action(.plugin("auditor"), .use)],
      providers: [.init(provider: provider, digest: digest, conservative: conservative)])
  }

  private func ledger(
    provider grants: [(Permission, PermissionValue)], caller: [(Permission, PermissionValue)] = []
  ) throws -> PermissionLedger {
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(
      granted(grants), for: .plugin(provider), expectedRevision: ledger.revision)
    _ = try ledger.setPermissions(
      granted(caller + [(.plugin("auditor"), .use)]), for: client, expectedRevision: ledger.revision
    )
    var environment = ledger.environment
    environment.providerRequirements = [provider: .init(digest: digest)]
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    return ledger
  }

  @Test func undeclaredRequiresEveryConcreteTargetAndEffectiveLevel() throws {
    let grants: [(Permission, PermissionValue)] = [
      (.project("alpha"), .write), (.project("beta"), .read), (.plugin("formatter"), .use),
      (.mcpServer("build"), .all), (.filesAndFolders(.downloads), .read), (.screen, .access),
    ]
    var ledger = try ledger(provider: grants)
    var caller = ledger.permissions(for: client)
    try caller.set(.denied, for: .machineInformation)
    try caller.set(.denied, for: .skills)
    _ = try ledger.setPermissions(caller, for: client, expectedRevision: ledger.revision)
    let required = requirements()
    guard
      case .requests(let requests) = try ledger.authorize(
        invocation: invocation(), requirements: required, now: instant)
    else {
      Issue.record("Every sensitive provider grant must require caller permission")
      return
    }
    #expect(Set(requests.compactMap(\.requirement)) == Set(grants.map { requirement($0.0, $0.1) }))
    for request in requests { try ledger.answer(request.id, with: .onlyThisTime, now: instant) }
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: required, retryIDs: Set(requests.map(\.id)),
        now: instant))
    ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
    #expect(throws: Never.self) { _ = try ledger.invocationAccess(proof.id) }
    var changed = ledger.permissions(for: .plugin(provider))
    try changed.set(.granted(.write), for: .project("beta"))
    _ = try ledger.setPermissions(
      changed, for: .plugin(provider), expectedRevision: ledger.revision)
    #expect(throws: PermissionModelError.self) { _ = try ledger.invocationAccess(proof.id) }
  }

  @Test func wildcardRequiresFutureCoverageAndRespectsBothPrincipalsOverrides() throws {
    var ledger = try ledger(
      provider: [(.project("*"), .read)], caller: [(.project("alpha"), .write)])
    #expect(
      try ledger.authorize(invocation: invocation(), requirements: requirements(), now: instant)
        == .denied(.authorizationRevoked))
    _ = try ledger.setPermissions(
      granted([(.project("*"), .read), (.plugin("auditor"), .use)]),
      for: client, expectedRevision: ledger.revision)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: requirements(), now: instant))
    var caller = ledger.permissions(for: client)
    try caller.set(.denied, for: .project("future"))
    _ = try ledger.setPermissions(caller, for: client, expectedRevision: ledger.revision)
    #expect(throws: PermissionModelError.self) { _ = try ledger.invocationAccess(proof.id) }
    #expect(
      try ledger.authorize(invocation: invocation(), requirements: requirements(), now: instant)
        == .denied(.permissionDenied(.project("future"))))
    var grants = ledger.permissions(for: .plugin(provider))
    try grants.set(.denied, for: .project("future"))
    try grants.set(.granted(.write), for: .project("beta"))
    _ = try ledger.setPermissions(grants, for: .plugin(provider), expectedRevision: ledger.revision)
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(), requirements: requirements(), now: instant))
    #expect(pending.requirement == requirement(.project("beta"), .write))
  }

  @Test func managedProviderLevelsAndCallerConnectionCeilingsParticipate() throws {
    var ledger = try ledger(provider: [(.project("*"), .write)], caller: [(.project("*"), .read)])
    var environment = ledger.environment
    environment.limits[.plugin(provider)] = .init(
      owner: .available(
        .init(permissionCeilings: try granted([(.project("*"), .read)]))))
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    _ = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: requirements(), now: instant))
    environment = ledger.environment
    var denied = Permissions()
    try denied.set(.denied, for: .project("future"))
    environment.connections["connection"] = .init(
      principal: client, attenuation: .init(permissionCeilings: denied))
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    #expect(
      try ledger.authorize(
        invocation: invocation(), requirements: requirements(), connectionID: "connection",
        now: instant)
        == .denied(.managedLimit([.connection])))
    environment = ledger.environment
    environment.limits[.plugin(provider)] = .init(owner: .unreadable)
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    #expect(
      try ledger.authorize(invocation: invocation(), requirements: requirements(), now: instant)
        == .denied(.authorizationRevoked))
  }

  @Test(arguments: [false, true])
  func retainedResultsRespectTheNewConnectionsCompleteProviderRequirements(wildcard: Bool) throws {
    let permission = Permission.project(wildcard ? "*" : "beta")
    var ledger = try ledger(provider: [(permission, .read)], caller: [(permission, .read)])
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: requirements(), now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [proof.id])
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .project("beta"))
    var environment = ledger.environment
    environment.connections["restricted"] = .init(
      principal: client,
      attenuation: .init(permissionCeilings: ceilings))
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .readResult,
        now: instant) == .allowed)
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .readResult,
        connectionID: "restricted", now: instant) == .denied(.managedLimit([.connection])))
  }

  @Test func declarationChangeRetirementRegrantAndEpochCannotReviveEvidence() throws {
    var ledger = try ledger(provider: [], caller: [])
    let required = requirements(conservative: false)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: required, now: instant))
    var environment = ledger.environment
    environment.providerRequirements?[provider] = .init(digest: "replacement")
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    #expect(
      try ledger.authorize(invocation: invocation(), requirements: required, now: instant)
        == .denied(.authorizationRevoked))
    environment = ledger.environment
    environment.providerRequirements?[provider] = .init(digest: digest)
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    #expect(throws: PermissionModelError.self) { _ = try ledger.invocationAccess(proof.id) }
    _ = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: required, now: instant))
    ledger.beginAuthorizationEpoch(UUID())
    #expect(ledger.environment.providerRequirements == nil)
  }

  @Test func providerGrantAndCallerWildcardRegrantRetireTheOriginalAuthorization() throws {
    for mutateProvider in [false, true] {
      var ledger = try ledger(provider: [(.plugin("*"), .use)], caller: [(.plugin("*"), .use)])
      let proof = try authorization(
        from: ledger.authorize(
          invocation: invocation(), requirements: requirements(), now: instant))
      let principal: Principal = mutateProvider ? .plugin(provider) : client
      var grants = ledger.permissions(for: principal)
      try grants.set(.notGranted, for: .plugin("*"))
      _ = try ledger.setPermissions(grants, for: principal, expectedRevision: ledger.revision)
      grants = ledger.permissions(for: principal)
      try grants.set(.granted(.use), for: .plugin("*"))
      _ = try ledger.setPermissions(grants, for: principal, expectedRevision: ledger.revision)
      #expect(throws: PermissionModelError.self) { _ = try ledger.invocationAccess(proof.id) }
    }
  }
}
