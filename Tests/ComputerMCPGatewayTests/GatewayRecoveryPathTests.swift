import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import Foundation
import Testing

@testable import ComputerMCPGateway

@Suite(.nativeIntegration, .serialized)
struct GatewayRecoveryPathTests {
  @Test func standaloneRecoveryRootIsProjectedAsHostData() async throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let recovery = try #require(f.database.worktreeStorage?.recovery)
    let gateway = try GatewayRuntime(
      configuration: GatewayConfiguration(),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, projectID: "source",
        trustedPrincipalID: "recovery-path-test"),
      database: f.database, registeredProjects: f.database.projects(), platform: f.platform,
      bundledPlugins: .init(packages: [], issues: []))
    do {
      _ = try gateway.makeControlSession()
      let paths = try #require(
        gateway.permissionRuntime.store.readWithDatabase { _, ledger in ledger.environment.paths })
      #expect(
        paths.pathRules.contains(.init(root: try CanonicalPath(recovery.path), kind: .hostData)))
      #expect(!FileManager.default.fileExists(atPath: recovery.path))
      await gateway.shutdown()
    } catch {
      await gateway.shutdown()
      throw error
    }
  }
}
