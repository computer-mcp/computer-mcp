import ComputerMCPCore
import ComputerMCPWorktrees
import Foundation
import Testing

@testable import ComputerMCPGateway

struct GatewayRecoveryOwnerAuthorityAcceptanceTests {
  @Test func onlyTrustedLocalAppAdminCanEnterOwnerOperations() throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let handle = try JSONDecoder().decode(
      RecoveryOperationHandle.self,
      from: JSONSerialization.data(withJSONObject: [
        "storeKey": String(repeating: "a", count: 64),
        "generation": UUID().uuidString,
        "action": "release",
        "id": UUID().uuidString,
        "requestDigest": String(repeating: "b", count: 64),
      ]))
    let app = try GatewayRecoveryOwnerService(
      database: f.database, platform: f.platform,
      owner: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "app"))
    #expect(try app.list().isEmpty)
    #expect(throws: WorktreeRecoveryOwnerError.unavailable) {
      try app.operation(handle: handle)
    }
    let denied: [ExecutionContext] = [
      .init(caller: .localCLI, profileID: .localAdmin, trustedPrincipalID: "cli"),
      .init(caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "mcp"),
      .init(caller: .secureTunnel, profileID: .localAdmin, trustedPrincipalID: "remote"),
      .init(caller: .localApp, profileID: .chatGPTOperate, trustedPrincipalID: "app"),
      .init(caller: .localApp, profileID: .localAdmin),
    ]
    let storage = try #require(f.database.worktreeStorage)
    #expect(!FileManager.default.fileExists(atPath: storage.recovery.path))
    for context in denied {
      let service = try GatewayRecoveryOwnerService(
        database: f.database, platform: f.platform, owner: context)
      #expect(throws: WorktreeRecoveryOwnerError.unauthorized) { try service.list() }
      #expect(throws: WorktreeRecoveryOwnerError.unauthorized) {
        try service.reviewRelease(
          storeKey: handle.storeKey, generation: handle.generation, selections: [])
      }
      #expect(throws: WorktreeRecoveryOwnerError.unauthorized) {
        try service.prepareMaintenance(storeKey: handle.storeKey, generation: handle.generation)
      }
      #expect(throws: WorktreeRecoveryOwnerError.unauthorized) {
        try service.operation(handle: handle)
      }
      #expect(throws: WorktreeRecoveryOwnerError.unauthorized) {
        try service.resume(handle: handle)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: storage.recovery.path))
  }
}
