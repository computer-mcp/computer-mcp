import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPGateway

struct GatewayProjectIdentityPublicationTests {
  @Test(arguments: [false, true])
  func unrelatedPublicationPreservesThePhysicalProjectIdentity(registeredThroughAlias: Bool) throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let projectDirectory = directory.appendingPathComponent("project")
    try FileManager.default.createDirectory(
      at: projectDirectory, withIntermediateDirectories: false)
    let physical = try ProjectPathResolver.canonicalProject(projectDirectory)
    let alias = directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture",
      rootPath: registeredThroughAlias ? alias.path : physical.path)
    let database = try GatewayDatabase(inMemory: ())
    let store = try database.configuredPermissionStore()
    try database.saveProject(project)
    try database.bootstrapPermissionProfiles([.localAdmin])
    let service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    try service.configureEnvironment(
      PathEnvironmentSnapshot(projects: [.init(id: project.id, root: .init(physical.path))]),
      trustedHosts: [], expectedProjects: database.projects(), expectedConfigurationRevision: nil)
    let before = try store.readWithDatabase { _, ledger in
      try #require(ledger.environment.paths?.registeredProjects.first)
    }
    let revision = ConfigurationRevision(
      digest: "unrelated-server-name", manifest: "[server]\nname = 'renamed'\n", activatedAt: Date()
    )
    _ = try database.activateConfigurationRevision(
      revision, expected: database.configurationState(), resolution: .init(), activeTunnelIDs: []
    ) { _ in }
    let after = try store.readWithDatabase { _, ledger in
      try #require(ledger.environment.paths?.registeredProjects.first)
    }
    #expect(after.root.string == physical.path)
    #expect(after.identity == before.identity)
    #expect(after == before)
  }
}
