import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPlugins

struct PluginContributionRequirementTests {
  @Test func declaredPrivacyAndFolderCategoriesAreConjunctive() throws {
    let requirements = PluginToolRequirements(
      project: .write,
      permissions: [.screen, .desktopControl, .localNetwork, .machine, .unifiedLogs, .skills],
      filesAndFolders: [
        .desktop, .documents, .downloads, .iCloudDrive, .networkVolumes, .removableVolumes,
      ])
    #expect(requirements.access == .projectWrite)
    let privacy: [Permission] = [
      .screen, .desktopControl, .localNetwork, .machineInformation, .unifiedLogs, .skills,
    ]
    let expected =
      try privacy.map { try PermissionRequirement($0, .access) }
      + FolderCategory.allCases.map { try PermissionRequirement(.filesAndFolders($0), .read) }
    #expect(Set(requirements.callerPermissions) == Set(expected))
  }

  @Test func reviewProjectionCannotChangeWithoutChangingItsBinding() throws {
    let manifest = try PluginManifest.parse(
      PluginManifestFixture.header + """

        [[mcp]]
        id = 'remote'
        transport = 'http'
        url = 'https://example.test/mcp'
        requirements = { project = 'write', permissions = ['screen'] }
        """)
    let projection = try PluginContributionRequirements(
      sourceDigest: PluginStore.manifestDigest(manifest),
      declarations: .init(manifest), componentID: "remote")
    let origin = PluginContributionOrigin(
      pluginID: manifest.id, componentID: "remote",
      version: manifest.version,
      source: .init(kind: .development, root: URL(fileURLWithPath: "/fixture")),
      reviewedRequirements: projection)
    let catalog = try origin.applyingRequirements(
      to: CapabilityDescriptor(
        id: "exposed", risk: .readOnly, requirement: .none,
        mcpReference: .init(serverID: "registered", toolName: "inspect")))
    #expect(catalog.projectRequirement == .required && catalog.requirement.access == .projectWrite)
    #expect(catalog.requirement.permissions == [try .init(.screen, .access)])
    let data = try JSONEncoder().encode(projection)
    let restored = try JSONDecoder().decode(PluginContributionRequirements.self, from: data)
    #expect(restored.approvalDigest == projection.approvalDigest)
    let changed = String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "write", with: "read")
    let tampered = try JSONDecoder().decode(
      PluginContributionRequirements.self, from: Data(changed.utf8))
    #expect(tampered.sourceDigest == projection.sourceDigest)
    #expect(tampered.approvalDigest != projection.approvalDigest)
    let minimum = ToolRequirement(
      access: .sourceProjectWrite, namedProjectAccess: .write,
      requiresFullAccess: true, paths: [.init("path", .write)], execution: .start,
      target: .mcp(server: .registered(id: "server"), access: .all), networkURL: "url",
      contribution: .mcp(server: .registered(id: "server")))
    let result = projection.applying(to: minimum, tool: "anything")
    #expect(result.access == .sourceProjectWrite && result.requiresFullAccess)
    #expect(result.namedProjectAccess == .write && result.paths == minimum.paths)
    #expect(result.target == minimum.target && result.execution == .start)
    #expect(result.networkURL == "url" && result.contribution == minimum.contribution)
    #expect(result.permissions == [try .init(.screen, .access)])
  }
}
