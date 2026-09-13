import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct MCPDerivedWorkspaceRegistrationTests {
  @Test
  func registrationAndGrantAreAtomicDurableAndIdempotent() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    try fixture.database.registerDerivedWorkspace(fixture.registration)
    let storedWorkspace = try #require(try fixture.database.workspace(id: "child"))
    try fixture.database.registerDerivedWorkspace(fixture.registration)
    let reopened = try GatewayDatabase(path: fixture.databasePath.path)
    #expect(try reopened.workspace(id: "child") == storedWorkspace)
    #expect(storedWorkspace.rootPath == fixture.registration.workspace.rootPath)
    #expect(try reopened.profiles().first?.workspaceIDs == ["source", "child"])
    #expect(try reopened.derivedWorkspaceRegistration(id: "child") == fixture.registration)
    try reopened.unregisterDerivedWorkspace(fixture.registration)
    try reopened.unregisterDerivedWorkspace(fixture.registration)
    #expect(try fixture.database.workspace(id: "child") == nil)
    #expect(try fixture.database.profiles().first?.workspaceIDs == ["source"])
    #expect(FileManager.default.fileExists(atPath: fixture.registration.workspace.rootPath))
  }

  @Test(arguments: ["source-grant", "existing-path", "preexisting-grant", "changed-source"])
  func failedRegistrationLeavesNoPartialRowsOrGrant(change: String) throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    if change == "source-grant" || change == "preexisting-grant" {
      var grant = try #require(try fixture.database.profiles().first)
      if change == "source-grant" {
        grant.workspaceIDs.remove("source")
      } else {
        grant.workspaceIDs.insert("child")
      }
      try fixture.database.saveProfile(grant)
    } else if change == "existing-path" {
      try fixture.database.saveWorkspace(
        .init(
          id: "independent", displayName: "Independent",
          rootPath: fixture.registration.workspace.rootPath))
    } else {
      var source = try #require(try fixture.database.workspace(id: "source"))
      source.rootPath = fixture.root.path
      try fixture.database.saveWorkspace(source)
    }
    let grants = try fixture.database.profiles()
    #expect(throws: (any Error).self) {
      try fixture.database.registerDerivedWorkspace(fixture.registration)
    }
    #expect(try fixture.database.workspace(id: "child") == nil)
    #expect(try fixture.database.derivedWorkspaceRegistration(id: "child") == nil)
    #expect(try fixture.database.profiles() == grants)
  }

  @Test(arguments: ["new-profile", "workspace-edit", "alias-identity"])
  func unregisterNeverDeletesIndependentChanges(change: String) throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    try fixture.database.registerDerivedWorkspace(fixture.registration)
    if change == "new-profile" {
      try fixture.database.saveProfile(
        .init(
          id: .chatGPTObserve, capabilityIDs: [], workspaceIDs: ["child"],
          allowedCallers: [.secureTunnel]))
    } else {
      var child = fixture.registration.workspace
      child.displayName = "Independently renamed"
      if change == "alias-identity" { child.rootPath = fixture.root.path }
      try fixture.database.saveWorkspace(child)
    }
    let grants = try fixture.database.profiles()
    let child = try fixture.database.workspace(id: "child")
    #expect(throws: (any Error).self) {
      try fixture.database.unregisterDerivedWorkspace(fixture.registration)
    }
    #expect(try fixture.database.workspace(id: "child") == child)
    #expect(try fixture.database.profiles() == grants)
    #expect(try fixture.database.derivedWorkspaceRegistration(id: "child") == fixture.registration)
  }

  @Test
  func sourceRevocationDoesNotPreventRemovalOfAnUnchangedOwnedRegistration() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    try fixture.database.registerDerivedWorkspace(fixture.registration)
    var grant = try #require(try fixture.database.profiles().first)
    grant.workspaceIDs.remove("source")
    try fixture.database.saveProfile(grant)
    try fixture.database.unregisterDerivedWorkspace(fixture.registration)
    #expect(try fixture.database.workspace(id: "child") == nil)
    #expect(try fixture.database.profiles().first?.workspaceIDs.isEmpty == true)
  }
}

private final class DerivedFixture {
  let root: URL
  let databasePath: URL
  let database: GatewayDatabase
  let registration: MCPDerivedWorkspaceRegistration
  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    root = directory.resolvingSymlinksInPath()
    let source = root.appendingPathComponent("source")
    let child = root.appendingPathComponent("derived")
    for path in [source, child] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    }
    databasePath = root.appendingPathComponent("host.sqlite")
    database = try GatewayDatabase(path: databasePath.path)
    try database.saveWorkspace(.init(id: "source", displayName: "Source", rootPath: source.path))
    try database.saveProfile(
      .init(
        id: .chatGPTOperate, capabilityIDs: [], workspaceIDs: ["source"],
        allowedCallers: [.secureTunnel]))
    registration = .init(
      origin: "fixture", receiptID: UUID().uuidString, sourceWorkspaceID: "source",
      sourceRoot: source.path,
      receiptDigest: "fixture-digest", profileID: .chatGPTOperate, caller: .secureTunnel,
      workspace: .init(id: "child", displayName: "Derived", rootPath: child.path))
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
