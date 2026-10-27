import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPGateway

struct StandaloneProjectRegistrationTests {
  @Test
  func startupRegistersOnlyExplicitProjectsAndPreservesSavedAuthorityOnRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let counter = TestAuthorizationEpochCounter()
    _ = database.permissionStore(counter: counter)
    try database.bootstrapPermissionProfiles([.localAdmin])
    try database.registerManifestProjectsForStartup([])
    #expect(try database.projects().isEmpty)
    let project = ComputerMCPCore.RegisteredProject(
      id: "declared", displayName: "Saved folder", rootPath: root.path,
      bookmarkData: Data([1, 2, 3]))
    try database.registerManifestProjectsForStartup([project])
    let saved = try #require(database.projects().first)
    let before = try counter.withExclusiveAccess { try $0.read() }
    var declaration = project
    declaration.displayName = "Manifest name"
    declaration.bookmarkData = nil
    declaration.createdAt = Date()
    try database.registerManifestProjectsForStartup([declaration])
    #expect(try database.projects() == [saved])
    #expect(try counter.withExclusiveAccess { try $0.read() } == before)
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    declaration.rootPath = other.path
    #expect(throws: ConfigurationError.self) {
      try database.registerManifestProjectsForStartup([declaration])
    }
    declaration.id = "new"
    #expect(throws: ConfigurationError.self) {
      try database.registerManifestProjectsForStartup([declaration])
    }
    #expect(try database.projects() == [saved])
    #expect(try counter.withExclusiveAccess { try $0.read() } == before)
  }
}
