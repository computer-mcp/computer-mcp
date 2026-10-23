import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsModelTests {
  @Test func stablePrincipalIdentitiesAndDefaults() {
    #expect(Principal.client("same") != .plugin(.package("same")))
    #expect(Principal.plugin(.package("same")) != .plugin(.localServer("same")))
    #expect(Principal.plugin(.localServer("same")) == .plugin(.localServer("same")))
    #expect(Permissions.newPrincipal.state(for: .machineInformation) == .granted(.access))
    #expect(Permissions.newPrincipal.state(for: .skills) == .granted(.access))
    #expect(Permissions.newPrincipal.state(for: .unifiedLogs) == .notGranted)
    #expect(Permissions.newPrincipal.state(for: .screen) == .notGranted)
  }

  @Test(
    arguments: [
      (.project("p"), PermissionValue.read), (.project("p"), .write),
      (.filesAndFolders(.desktop), .read), (.filesAndFolders(.documents), .read),
      (.filesAndFolders(.downloads), .read), (.filesAndFolders(.iCloudDrive), .read),
      (.filesAndFolders(.networkVolumes), .read), (.filesAndFolders(.removableVolumes), .read),
      (.plugin("p"), .use), (.mcpServer("s"), .read), (.mcpServer("s"), .all),
      (.screen, .access), (.desktopControl, .access), (.localNetwork, .access),
      (.machineInformation, .access), (.unifiedLogs, .access), (.skills, .access),
    ] as [(Permission, PermissionValue)])
  func permissionStates(permission: Permission, value: PermissionValue) throws {
    let requirement = try PermissionRequirement(permission, value)
    let action = PermissionAction(
      requirement: requirement, scope: .project("p"), pluginPurpose: "Build the selected project")
    var rules = Permissions()
    let missing = PermissionEvaluation.evaluate(
      principal: client, action: action, permissions: rules)
    #expect(
      missing
        == .request(
          PermissionRequestContent(
            principal: client, requirement: requirement, scope: .project("p"),
            pluginPurpose: "Build the selected project")))
    try rules.set(.granted(value), for: permission)
    #expect(
      PermissionEvaluation.evaluate(principal: client, action: action, permissions: rules)
        == .allowed)
    try rules.set(.denied, for: permission)
    #expect(
      PermissionEvaluation.evaluate(principal: client, action: action, permissions: rules)
        == .denied(.permissionDenied(permission)))
  }

  @Test(
    arguments: [
      (.project("p"), Permission.project("*"), PermissionValue.write),
      (.plugin("p"), .plugin("*"), .use), (.mcpServer("s"), .mcpServer("*"), .all),
    ] as [(Permission, Permission, PermissionValue)])
  func explicitRulesOverrideFallback(
    permission: Permission, fallback: Permission, value: PermissionValue
  ) throws {
    var rules = try granted([(fallback, value)])
    #expect(rules.state(for: permission) == .granted(value))
    try rules.set(.denied, for: permission)
    #expect(rules.state(for: permission) == .denied)
    try rules.set(.notGranted, for: permission)
    #expect(rules.state(for: permission) == .notGranted)
    try rules.set(.denied, for: fallback)
    try rules.set(.granted(value), for: permission)
    #expect(rules.state(for: permission) == .granted(value))
  }

  @Test func valuesAreDomainCheckedAndReadCanBeUpgraded() throws {
    #expect(throws: PermissionModelError.invalidPermissionValue) {
      try PermissionRequirement(.screen, .write)
    }
    #expect(throws: PermissionModelError.invalidObject) {
      try PermissionRequirement(.project("*"), .read)
    }
    var rules = Permissions()
    #expect(throws: PermissionModelError.invalidPermissionValue) {
      try rules.set(.granted(.write), for: .skills)
    }
    try rules.set(.granted(.read), for: .project("p"))
    if case .request = PermissionEvaluation.evaluate(
      principal: client, action: action(.project("p"), .write), permissions: rules)
    {
    } else {
      Issue.record("Read does not authorize writing, but permits requesting write")
    }
    try rules.set(.granted(.write), for: .project("p"))
    #expect(
      PermissionEvaluation.evaluate(
        principal: client, action: action(.project("p"), .read), permissions: rules) == .allowed)
  }

  @Test func fullAccessStillChecksPermissionsAndConsent() throws {
    let rules = try granted([(.screen, .access)])
    #expect(
      PermissionEvaluation.evaluate(
        principal: client, action: action(), permissions: rules,
        mode: .fullAccess(.notGranted)) == .denied(.fullAccessRequiresConsent))
    #expect(
      PermissionEvaluation.evaluate(
        principal: client, action: action(), permissions: rules,
        mode: .fullAccess(.standing)) == .allowed)
    if case .request = PermissionEvaluation.evaluate(
      principal: client, action: action(.unifiedLogs),
      permissions: rules, mode: .fullAccess(.connection("connection")))
    {
    } else {
      Issue.record("Full access must still request logs")
    }
    let control = PermissionAction(
      requirement: requirement(.plugin("p"), .use), requiresFullAccess: true)
    #expect(
      PermissionEvaluation.evaluate(principal: client, action: control, permissions: rules)
        == .denied(.fullAccessRequired))
  }

  @Test func managedLimitsIntersectWithProvenance() throws {
    let owner = ManagedPolicy(
      permissionCeilings: try granted([(.project("*"), .write)]), network: .trusted)
    let machine = ManagedPolicy(
      permissionCeilings: try granted([(.project("*"), .read)]), allowsFullAccess: false,
      network: .custom(hosts: ["packages.example", "other.example"], includesTrusted: false))
    let limits = ManagedLimits(owner: .available(owner), machine: .available(machine))
    #expect(limits.restrictingSources(for: requirement(.project("p"), .write)) == [.machine])
    #expect(limits.restrictingSources(for: requirement(.project("p"), .read)).isEmpty)
    #expect(
      limits.network(applying: .full, trustedHosts: ["packages.example", "tools.example"])
        == .custom(hosts: ["packages.example"], includesTrusted: false))
    #expect(
      PermissionEvaluation.evaluate(
        principal: client, action: action(.project("p"), .write),
        permissions: try granted([(.project("p"), .write)]), limits: limits)
        == .denied(.managedLimit([.machine])))
    #expect(
      PermissionEvaluation.evaluate(
        principal: client, action: action(.skills), permissions: .newPrincipal,
        mode: .fullAccess(.standing), limits: limits) == .denied(.managedLimit([.machine])))
  }

  @Test(arguments: PolicySource.allCases)
  func unreadableSourceFailsClosed(source: PolicySource) throws {
    let limits = ManagedLimits(
      owner: source == .owner ? .unreadable : .absent,
      machine: source == .machine ? .unreadable : .absent)
    #expect(limits.restrictingSources(for: requirement(.skills, .access)) == [source])
    #expect(limits.denying(path("/anywhere")) == [source])
    #expect(limits.restrictingNetwork(host: "host", trustedHosts: ["host"]) == [source])
    #expect(limits.network(applying: .full, trustedHosts: []) == .none)
    #expect(
      PermissionEvaluation.evaluate(
        principal: client, action: action(.skills), permissions: .newPrincipal,
        mode: .fullAccess(.standing), limits: limits) == .denied(.managedLimit([source])))
  }

  @Test func policyStoreRefreshesAndReadErrorsFailClosed() async throws {
    let store = InMemoryManagedPolicyStore()
    let initial = await ManagedLimits.read(for: client, from: store)
    #expect(initial.restrictingSources(for: requirement(.skills, .access)).isEmpty)
    await store.write(.unreadable, source: .machine, principal: client)
    let tightened = await ManagedLimits.read(for: client, from: store)
    #expect(tightened.restrictingSources(for: requirement(.skills, .access)) == [.machine])
    let failed = await ManagedLimits.read(for: client, from: FailingPolicyStore())
    #expect(failed.restrictingSources(for: requirement(.skills, .access)) == [.owner, .machine])
  }
}

private struct FailingPolicyStore: ManagedPolicyStore {
  func read(source: PolicySource, principal: Principal) async throws -> PolicyAvailability {
    throw PermissionModelError.invalidAuthorization
  }
  func write(_ policy: PolicyAvailability, source: PolicySource, principal: Principal) async throws
  {}
}
