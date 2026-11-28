import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlugins
import Foundation
import Testing

@testable import ComputerMCPGateway

struct GatewayContributionRequirementTests {
  @Test(arguments: ["generated_inspect", "reexported"])
  func reviewedCatalogAndDispatchKeepRequirementsAcrossRefresh(route: String) async throws {
    let reviewed = try projection("requirements = { project = 'write', permissions = ['screen'] }")
    let origin = PluginContributionOrigin(
      pluginID: "auditor", componentID: "remote", version: try PluginVersion("1.0.0"),
      source: .init(kind: .development, root: URL(fileURLWithPath: "/fixture")),
      reviewedRequirements: reviewed)
    let published = descriptor(route, tool: "inspect", minimum: .privacy(.unifiedLogs))
    let provider = RequirementCatalogProvider(capability: published)
    let router = try GatewayProviderRouter(
      source: { [provider] }, origins: [.init(kind: .mcp, id: "registered"): origin])
    var expected = published
    expected.requirement = .init(
      access: .projectWrite,
      permissions: [try .init(.unifiedLogs, .access), try .init(.screen, .access)])
    expected.projectRequirement = .required
    do {
      for refresh in [false, true] {
        if refresh { try await router.refreshTools(context: .empty) }
        #expect(try router.capability(named: route, context: .empty) == expected)
        #expect(
          try await router.callToolAsync(
            name: route, arguments: nil, expectedCapability: expected, context: .empty)
            == .string("dispatched"))
        await #expect(throws: GatewayProviderRouterError.self) {
          try await router.callToolAsync(
            name: route, arguments: nil, expectedCapability: published, context: .empty)
        }
      }
    } catch {
      await router.shutdown()
      throw error
    }
    await router.shutdown()
  }

  private func projection(_ fields: String) throws -> PluginContributionRequirements {
    let manifest = try PluginManifest.parse(
      """
      id = 'auditor'
      name = 'Auditor'
      version = '1.0.0'
      plugin_api = 1
      [[mcp]]
      id = 'remote'
      transport = 'http'
      url = 'https://example.test/mcp'
      \(fields)
      """)
    return try .init(
      sourceDigest: PluginStore.manifestDigest(manifest),
      declarations: PluginPermissionDeclarations(manifest), componentID: "remote")
  }

  private func resolver(_ projection: PluginContributionRequirements?) throws
    -> GatewayToolRequirementResolver
  {
    let origin = PluginContributionOrigin(
      pluginID: "auditor", componentID: "remote", version: try PluginVersion("1.0.0"),
      source: .init(kind: .development, root: URL(fileURLWithPath: "/fixture")),
      reviewedRequirements: projection)
    return try GatewayToolRequirementResolver(
      configuration: .init(), origins: [.init(kind: .mcp, id: "registered"): origin],
      paths: .init(
        projects: [
          .init(id: "source", root: .init("/fixture/source")),
          .init(id: "derived", root: .init("/fixture/derived"), sourceID: "source"),
        ], rules: []))
  }

  private func descriptor(_ name: String, tool: String, minimum: ToolRequirement = .none)
    -> CapabilityDescriptor
  {
    var value = CapabilityDescriptor(id: name, risk: .readOnly, requirement: minimum)
    value.mcpReference = .init(serverID: "registered", toolName: tool)
    return value
  }

  @Test(arguments: ["mcp.tools.call", "generated_inspect", "reexported", "forwarded"])
  func exactDownstreamNamesResolveRequirementsOnEveryRoute(route: String) throws {
    let reviewed = try projection(
      """
      requirements = { project = 'write', permissions = ['screen'], files_and_folders = ['downloads'] }
      tool_requirements = { status = { project = 'read' }, empty = { project = 'none' } }
      """)
    let resolver = try resolver(reviewed)
    let host = ToolRequirement.downstream(
      serverID: "registered", readOnly: true, remoteExecution: false, hostAction: nil)
    let (read, plugins, _) = try resolver.resolve(
      descriptor: descriptor(route, tool: "status", minimum: host), arguments: [:],
      projectID: "derived", mode: .sandbox)
    #expect(plugins == [.package("auditor")])
    #expect(
      Set(read.actions.map(\.requirement)) == [
        try .init(.project("source"), .read), try .init(.plugin("auditor"), .use),
      ])
    #expect(
      read.providers == [
        .init(provider: .package("auditor"), digest: reviewed.approvalDigest, conservative: false)
      ])
    let (other, _, _) = try resolver.resolve(
      descriptor: descriptor(route, tool: "Status", minimum: host), arguments: [:],
      projectID: "derived", mode: .sandbox)
    #expect(
      Set(other.actions.map(\.requirement)).isSuperset(of: [
        try .init(.project("source"), .write), try .init(.screen, .access),
        try .init(.filesAndFolders(.downloads), .read),
      ]))
    #expect(throws: GatewayToolError.self) {
      try resolver.resolve(
        descriptor: descriptor(route, tool: "status", minimum: host),
        arguments: [:], projectID: nil, mode: .sandbox)
    }
    let (empty, _, _) = try resolver.resolve(
      descriptor: descriptor(route, tool: "empty", minimum: host), arguments: [:],
      projectID: nil, mode: .sandbox)
    #expect(empty.actions.map(\.requirement) == [try .init(.plugin("auditor"), .use)])
  }

  @Test func runtimeMinimumCannotEraseReviewAndStaleProjectionCannotBorrowApproval() throws {
    let reviewed = try projection("requirements = { project = 'write', permissions = ['screen'] }")
    let (requirements, plugins, _) = try resolver(reviewed).resolve(
      descriptor: descriptor("untrusted-read-only", tool: "inspect"), arguments: [:],
      projectID: "derived", mode: .sandbox)
    #expect(plugins == [.package("auditor")])
    #expect(
      Set(requirements.actions.map(\.requirement)) == [
        try .init(.project("source"), .write), try .init(.screen, .access),
        try .init(.plugin("auditor"), .use),
      ])
    let caller = Principal.client("caller")
    var ledger = PermissionLedger()
    var permissions = Permissions.newPrincipal
    for action in requirements.actions {
      try permissions.set(.granted(action.requirement.value), for: action.requirement.permission)
    }
    _ = try ledger.setPermissions(permissions, for: caller, expectedRevision: ledger.revision)
    var environment = ledger.environment
    environment.providerRequirements = [.package("auditor"): .init(digest: reviewed.approvalDigest)]
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    let invocation = InvocationIdentity(
      principal: caller, tool: "inspect", projectID: "derived", argumentsDigest: "input")
    guard
      case .allowed(let proof) = try ledger.authorize(
        invocation: invocation, requirements: requirements, now: .now)
    else {
      Issue.record("The reviewed caller requirements should be satisfied")
      return
    }
    let changed = try projection("requirements = { project = 'read' }")
    let (stale, _, _) = try resolver(changed).resolve(
      descriptor: descriptor("untrusted-read-only", tool: "inspect"), arguments: [:],
      projectID: "derived", mode: .sandbox)
    #expect(
      try ledger.authorize(invocation: invocation, requirements: stale, now: .now)
        == .denied(.authorizationRevoked))
    environment = ledger.environment
    environment.providerRequirements?[.package("auditor")] = .init(digest: changed.approvalDigest)
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    #expect(throws: PermissionModelError.self) { _ = try ledger.invocationAccess(proof.id) }
  }

  @Test func namedProjectAndRemoteAndLifecycleFloorsRemainAdditive() throws {
    let resolver = try resolver(projection("requirements = { project = 'read' }"))
    for lifecycle in [false, true] {
      let host = ToolRequirement.downstream(
        serverID: "registered", readOnly: false,
        remoteExecution: true, hostAction: lifecycle ? .projectRemoval : nil)
      let (requirements, _, _) = try resolver.resolve(
        descriptor: descriptor("route", tool: "status", minimum: host), arguments: [:],
        projectID: "derived", mode: .sandbox)
      #expect(
        requirements.actions.contains { $0.requirement == (try? .init(.project("source"), .write)) }
      )
      #expect(requirements.mode == .fullAccess(.notGranted))
    }
  }

  @Test func undeclaredIsNotAnEmptyDeclarationAndSkillSelectionPreservesItsDependency() throws {
    let reviewed = try projection("tool_requirements = { empty = { project = 'none' } }")
    let resolver = try resolver(reviewed)
    let host = ToolRequirement.downstream(
      serverID: "registered", readOnly: true,
      remoteExecution: false, hostAction: nil)
    let (requirements, _, libraries) = try resolver.resolve(
      descriptor: descriptor("route", tool: "new", minimum: host), arguments: [:],
      projectID: nil, mode: .sandbox)
    #expect(requirements.providers.first?.conservative == true)
    let selected = GatewaySkillLibraryRequirement.selecting(
      libraries, requirements: requirements,
      ledger: .init(), principal: .client("caller"), connectionID: nil)
    #expect(selected == requirements)
    let (legacy, _, _) = try self.resolver(nil).resolve(
      descriptor: descriptor("route", tool: "new", minimum: host), arguments: [:],
      projectID: nil, mode: .sandbox)
    #expect(legacy.providers.isEmpty)
    let direct = try GatewayToolRequirementResolver(
      configuration: .init(), origins: [:],
      paths: .init(projects: [], rules: []))
    let (registered, plugins, _) = try direct.resolve(
      descriptor: descriptor("route", tool: "new", minimum: host), arguments: [:],
      projectID: nil, mode: .sandbox)
    #expect(plugins.isEmpty && registered.providers.isEmpty)
    #expect(registered.actions.map(\.requirement) == [try .init(.mcpServer("registered"), .read)])
  }
}

private struct RequirementCatalogProvider: GatewayToolProvider {
  let id = "requirement-fixture"
  let capability: CapabilityDescriptor
  func definitions() throws -> [ToolDefinition] {
    [
      .init(
        tool: .init(name: capability.id, description: "Fixture", inputSchema: .object([:])),
        capability: capability)
    ]
  }
  func callTool(_ invocation: ToolInvocation) throws -> JSONValue { .string("dispatched") }
}
