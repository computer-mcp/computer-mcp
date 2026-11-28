import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence

struct GatewayPermissionCompositionTests {
  @Test(arguments: ["app", "standalone"])
  func refusingAnotherCompositionPreservesThePermissionEpoch(owner: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("authority.sqlite").path
    let first: GatewayPermissionComposition = owner == "app" ? .app : .standalone
    let other: GatewayPermissionComposition = owner == "app" ? .standalone : .app
    let database = try GatewayDatabase(path: path)
    try database.claimPermissionComposition(first)
    let counter = TestAuthorizationEpochCounter()
    let store = database.permissionStore(counter: counter)
    try database.bootstrapPermissionProfiles([.operate])
    let epoch = try #require(store.readWithDatabase { _, ledger in ledger.authorizationEpochID })
    let watermark = try #require(counter.withExclusiveAccess { try $0.read() })

    let reopened = try GatewayDatabase(path: path)
    try expectCompositionRefusal { try reopened.claimPermissionComposition(other) }
    #expect(throws: AuthorizationEpochCounterError.unavailable) {
      _ = try reopened.configuredPermissionStore()
    }
    #expect(try counter.withExclusiveAccess { try $0.read() } == watermark)
    #expect(try store.readWithDatabase { _, ledger in ledger.authorizationEpochID } == epoch)
    #expect(try counter.withExclusiveAccess { try $0.read() } == watermark)
  }

  @Test(arguments: ["app", "standalone"])
  func repeatingTheSameCompositionDoesNotChangeAuthority(owner: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("authority.sqlite").path
    let composition: GatewayPermissionComposition = owner == "app" ? .app : .standalone
    let database = try GatewayDatabase(path: path)
    try database.claimPermissionComposition(composition)
    let counter = TestAuthorizationEpochCounter()
    let store = database.permissionStore(counter: counter)
    try database.bootstrapPermissionProfiles([.operate])
    let epoch = try #require(store.readWithDatabase { _, ledger in ledger.authorizationEpochID })
    let watermark = try #require(counter.withExclusiveAccess { try $0.read() })
    try database.claimPermissionComposition(composition)
    let reopened = try GatewayDatabase(path: path)
    try reopened.claimPermissionComposition(composition)
    #expect(try counter.withExclusiveAccess { try $0.read() } == watermark)
    #expect(try store.readWithDatabase { _, ledger in ledger.authorizationEpochID } == epoch)
    #expect(try counter.withExclusiveAccess { try $0.read() } == watermark)
  }

  @Test
  func appOwnershipSurvivesReopeningACustomDatabasePathBeforeCounterSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("custom-app-state.sqlite").path
    try GatewayDatabase(path: path).claimPermissionComposition(.app)
    let reopened = try GatewayDatabase(path: path)
    #expect(try reopened.configurationRevisions().isEmpty)
    try expectCompositionRefusal { try reopened.claimPermissionComposition(.standalone) }
    try reopened.claimPermissionComposition(.app)
    #expect(throws: AuthorizationEpochCounterError.unavailable) {
      _ = try reopened.configuredPermissionStore()
    }
  }

  @Test(arguments: [false, true])
  func onlyActivatedUnmarkedConfigurationIdentifiesAnAppDatabase(activated: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("unmarked.sqlite").path
    let database = try GatewayDatabase(path: path)
    let time = Date(timeIntervalSince1970: 1_700_000_000)
    try database.saveConfigurationRevision(
      .init(
        id: "reviewed", digest: "fixture-digest", manifest: "schema_version = 1",
        createdAt: time, activatedAt: activated ? time : nil))
    if activated {
      try expectCompositionRefusal { try database.claimPermissionComposition(.standalone) }
      try database.claimPermissionComposition(.app)
    } else {
      try database.claimPermissionComposition(.standalone)
    }
    #expect(throws: AuthorizationEpochCounterError.unavailable) {
      _ = try database.configuredPermissionStore()
    }
    #expect(try database.configurationRevisions().count == 1)
  }

  private func expectCompositionRefusal(_ operation: () throws -> Void) throws {
    do {
      try operation()
      Issue.record("A database composition must have exactly one authority owner.")
    } catch let error as GatewayDatabaseError {
      guard case .invalidStoredValue(let guidance) = error else { throw error }
      #expect(!guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}
