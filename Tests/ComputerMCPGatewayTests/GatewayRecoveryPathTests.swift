import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation
import Testing

@testable import ComputerMCPGateway

@Suite(.nativeIntegration, .serialized)
struct GatewayRecoveryPathTests {
  @Test func standaloneRecoveryRootIsProjectedAsHostData() async throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let recovery = try #require(f.database.worktreeStorage?.recovery)
    let platform = PlatformServices(
      launcher: f.platform.launcher, projectGrants: RecoveryPathProjectGrants(),
      pluginDirectories: f.platform.pluginDirectories, applications: f.platform.applications,
      toolProviders: f.platform.toolProviders, managementToolNames: [],
      executableSearchDirectories: [],
      gitExecutable: f.platform.gitExecutable, fileChanges: f.platform.fileChanges,
      permissionPolicyReader: f.platform.permissionPolicyReader)
    let context = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate, projectID: "source",
      trustedPrincipalID: "recovery-path-test")
    let gateway = try GatewayRuntime(
      configuration: GatewayConfiguration(), context: context,
      database: f.database, registeredProjects: f.database.projects(), platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    do {
      _ = try gateway.makeControlSession()
      let paths = try #require(
        gateway.permissionRuntime.store.readWithDatabase { _, ledger in ledger.environment.paths })
      let root = try CanonicalPath(
        ProjectPathResolver.resolve(recovery.path, relativeTo: URL(fileURLWithPath: "/")).path)
      #expect(paths.hostDataLocations.contains(root))
      let result = try gateway.permissionRuntime.service.admit(
        subject: GatewayPermissionSubject(context: context), tool: "file.read", projectID: "source",
        argumentsDigest: "recovery-storage",
        requirements: .init(
          paths: [.init(path: CanonicalPath(root.string + "/catalog.json"), operation: .read)],
          sandboxProjectID: "source"))
      #expect(result == .denied(.hostData))
      #expect(!FileManager.default.fileExists(atPath: recovery.path))
      await gateway.shutdown()
    } catch {
      await gateway.shutdown()
      throw error
    }
  }
}

private struct RecoveryPathProjectGrants: ProjectBookmarkServicing {
  func registerFolder(at url: URL, displayName: String?) throws -> ComputerMCPCore.RegisteredProject
  {
    throw PermissionModelError.invalidAuthorization
  }

  func resolve(_ project: ComputerMCPCore.RegisteredProject) throws -> ResolvedProjectAccess {
    try .init(
      project: project, rootURL: URL(fileURLWithPath: project.rootPath),
      bookmarkWasRefreshed: false, stopAccessing: nil)
  }
}
