import ComputerMCPPermissions
import ComputerMCPTestSupport
import Testing

@testable import ComputerMCPPlugins

struct PluginDeclarationUpdateTests {
  private func declarations(
    _ own: String = "", requirement: String = "", override: String = ""
  ) throws -> PluginPermissionDeclarations {
    try .init(
      PluginManifest.parse(
        PluginManifestFixture.header + own + """

          [[mcp]]
          id = 'tools'
          transport = 'http'
          url = 'https://example.test/mcp'
          """ + requirement + override))
  }

  @Test func providerRequestsAndCallerRequirementsHaveOppositeOrdering() throws {
    let read = "\nrequirements = { project = 'read' }"
    let write = "\nrequirements = { project = 'write' }"
    #expect(
      try declarations(requirement: read).update(from: declarations(requirement: write))
        == .widening)
    #expect(
      try declarations(requirement: write).update(from: declarations(requirement: read))
        == .narrowing)
    let permission = "\n[[permissions]]\nid = 'project'\naccess = 'read'\npurpose = 'Read'\n"
    let broader = permission.replacingOccurrences(of: "access = 'read'", with: "access = 'write'")
    #expect(try declarations(broader).update(from: declarations(permission)) == .widening)
    #expect(try declarations(permission).update(from: declarations(broader)) == .narrowing)
    #expect(try declarations().update(from: declarations(permission)) == .narrowing)
    #expect(try declarations(permission).update(from: declarations()) == .widening)
    #expect(
      try declarations(permission, requirement: read).update(
        from: declarations(broader, requirement: write)) == .widening)
  }

  @Test func defaultOverrideAndUndeclaredTransitionsUseResolvedSets() throws {
    let defaultRead = "\nrequirements = { project = 'read' }"
    let screen = "\nrequirements = { project = 'none', permissions = ['screen'] }"
    #expect(try declarations().update(from: declarations(requirement: screen)) == .narrowing)
    #expect(try declarations(requirement: screen).update(from: declarations()) == .widening)
    #expect(
      try declarations(requirement: screen).update(
        from: declarations(), conservativeEquivalent: .init(project: .none, permissions: [.screen]))
        == .narrowing)
    let override = "\ntool_requirements = { status = { project = 'write' } }"
    #expect(
      try declarations(requirement: defaultRead, override: override).update(
        from: declarations(requirement: defaultRead)) == .narrowing)
    #expect(
      try declarations(requirement: defaultRead).update(
        from: declarations(requirement: defaultRead, override: override)) == .widening)
    #expect(try declarations().update(from: declarations(override: override)) == .narrowing)
    #expect(try declarations(override: override).update(from: declarations()) == .widening)
    let privacy = "\nrequirements = { project = 'none', permissions = ['screen', 'skills'] }"
    #expect(
      try declarations(requirement: privacy).update(from: declarations(requirement: screen))
        == .narrowing)
    #expect(
      try declarations(requirement: screen).update(from: declarations(requirement: privacy))
        == .widening)
  }

  @Test func purposeAndSandboxChangesAreClassifiedWithoutGranting() throws {
    let original = "\n[sandbox]\nnetwork = 'trusted'\npurpose = 'Connect'\n"
    let purpose = original.replacingOccurrences(of: "Connect", with: "Use service")
    #expect(try declarations(original).update(from: declarations(original)) == .unchanged)
    #expect(try declarations(purpose).update(from: declarations(original)) == .purposeOnly)
    #expect(
      try declarations(original.replacingOccurrences(of: "'trusted'", with: "'none'")).update(
        from: declarations(original)) == .narrowing)
    #expect(
      try declarations(original.replacingOccurrences(of: "'trusted'", with: "'full'")).update(
        from: declarations(original)) == .widening)
    let full = "\n[sandbox]\nfull_access = true\npurpose = 'Native'\n"
    #expect(try declarations(full).update(from: declarations(original)) == .widening)
    #expect(try declarations(original).update(from: declarations(full)) == .narrowing)
    let read = "\n[sandbox]\nread_exceptions = [{path = '~/.config', purpose = 'Config'}]\n"
    #expect(try declarations(read).update(from: declarations()) == .widening)
    #expect(try declarations().update(from: declarations(read)) == .narrowing)
    #expect(
      try declarations(read.replacingOccurrences(of: "Config", with: "Settings")).update(
        from: declarations(read)) == .purposeOnly)
  }

  @Test func trustedNetworkDependencyCannotBeIntroducedByAnEmptyProjection() throws {
    let trusted = "\n[sandbox]\nnetwork = 'trusted'\npurpose = 'Connect'\n"
    let finite =
      "\n[sandbox]\nnetwork = { level = 'custom', hosts = ['api.example.test'], include_trusted = false }\npurpose = 'Connect'\n"
    let inherited = finite.replacingOccurrences(
      of: "include_trusted = false", with: "include_trusted = true")
    #expect(try declarations(trusted).update(from: declarations()) == .widening)
    #expect(try declarations(trusted).update(from: declarations(finite)) == .widening)
    #expect(try declarations(inherited).update(from: declarations(finite)) == .widening)
    #expect(try declarations(finite).update(from: declarations(inherited)) == .narrowing)
    #expect(try declarations(trusted).update(from: declarations(inherited)) == .narrowing)
    let none = "\n[sandbox]\nnetwork = 'none'\npurpose = 'No network'\n"
    #expect(try declarations(none).update(from: declarations()) == .purposeOnly)
    #expect(try declarations().update(from: declarations(none)) == .purposeOnly)
  }

  @Test func conservativeEqualityNeverDropsConcreteOrWildcardTargets() throws {
    var permissions = Permissions.newPrincipal
    try permissions.set(.granted(.access), for: .screen)
    #expect(
      try PluginToolRequirements.conservativeEquivalent(permissions: permissions, limits: .init())
        == .init(project: .none, permissions: [.screen]))
    try permissions.set(.granted(.read), for: .project("selected"))
    #expect(
      try PluginToolRequirements.conservativeEquivalent(permissions: permissions, limits: .init())
        == nil)
    try permissions.set(.denied, for: .project("selected"))
    try permissions.set(.granted(.write), for: .project("*"))
    #expect(
      try PluginToolRequirements.conservativeEquivalent(permissions: permissions, limits: .init())
        == nil)
  }
  @Test func conservativeEqualityUsesEffectiveCeilingsAndWildcardExceptions() throws {
    var grants = Permissions.newPrincipal
    try grants.set(.granted(.write), for: .project("selected"))
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .project("selected"))
    func equivalent() throws -> PluginToolRequirements? {
      try .conservativeEquivalent(
        permissions: grants, limits: .init(machine: .available(.init(permissionCeilings: ceilings)))
      )
    }
    #expect(try equivalent() == .init(project: .none))
    try ceilings.set(.granted(.read), for: .project("selected"))
    #expect(try equivalent() == nil)
    grants = .newPrincipal
    try grants.set(.granted(.write), for: .project("*"))
    ceilings = .init()
    try ceilings.set(.denied, for: .project("*"))
    #expect(try equivalent() == .init(project: .none))
    try ceilings.set(.granted(.read), for: .project("selected"))
    #expect(try equivalent() == nil)
    try grants.set(.denied, for: .project("selected"))
    #expect(try equivalent() == .init(project: .none))
    #expect(
      try PluginToolRequirements.conservativeEquivalent(
        permissions: .newPrincipal, limits: .init(machine: .unreadable)) == nil)
  }

}
