import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPGateway

@Suite struct GatewayToolVisibilityTests {
  @Test func mixedRequirementsObserveTheCurrentPolicyAndProfile() throws {
    let fixture = try VisibilityFixture()
    fixture.reader.set(
      .machineFile,
      .available(Data("full_access = false\n[permissions]\nscreen = 'deny'\n".utf8)))
    #expect(try fixture.visibility() == [true, false, false])
    fixture.reader.set(.machineFile, .absent)
    #expect(try fixture.visibility() == [true, true, true])
    fixture.reader.set(.machineFile, .unreadable("Unavailable fixture policy"))
    #expect(try fixture.visibility() == [false, false, false])
    fixture.reader.set(.machineFile, .absent)

    var profile = try #require(fixture.database.profiles().first)
    profile.allowedCallers = []
    try fixture.database.saveProfile(profile, expectedRevision: profile.authorizationRevision)
    #expect(try fixture.visibility() == [false, false, false])
    profile = try #require(fixture.database.profiles().first)
    profile.allowedCallers = [.localMCP]
    try fixture.database.saveProfile(profile, expectedRevision: profile.authorizationRevision)
    #expect(throws: GatewayPermissionError.invalidBinding) { _ = try fixture.visibility() }
    try fixture.service.connect(subject: fixture.subject, id: "reviewed")
    #expect(try fixture.visibility(connectionID: "reviewed") == [true, true, true])
    try fixture.store.readWithDatabase { _, ledger in
      #expect(ledger.requests.isEmpty && ledger.authorizations.isEmpty)
    }
  }

  @Test func connectionCeilingsRemainSeparateFromManagedPolicy() throws {
    let fixture = try VisibilityFixture()
    #expect(try fixture.visibility() == [true, true, true])
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .machineInformation)
    try fixture.service.limitConnection(
      subject: fixture.subject, id: "visible",
      to: .init(permissionCeilings: ceilings, allowsFullAccess: false))
    #expect(try fixture.visibility() == [false, false, true])
    fixture.reader.set(
      .machineFile, .available(Data("[permissions]\nscreen = 'deny'\n".utf8)))
    #expect(try fixture.visibility() == [false, false, false])
    fixture.reader.set(.machineFile, .absent)
    #expect(try fixture.visibility() == [false, false, true])
  }

  @Test(arguments: ["missing", "foreign", "ended"])
  func invalidConnectionsCannotDropTheirCeilings(kind: String) throws {
    let fixture = try VisibilityFixture()
    var id = "visible"
    switch kind {
    case "missing": id = "missing"
    case "foreign":
      let other = try GatewayPermissionSubject(
        context: .init(
          caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "other"))
      try fixture.service.connect(subject: other, id: "foreign")
      id = "foreign"
    default:
      try fixture.service.endConnection(subject: fixture.subject, id: id)
    }
    #expect(throws: GatewayPermissionError.invalidBinding) {
      _ = try fixture.visibility(connectionID: id)
    }
  }
}

private struct VisibilityFixture {
  let database: GatewayDatabase
  let store: SQLitePermissionStore
  let reader = TestManagedPolicyReader()
  let service: GatewayPermissionService
  let subject: GatewayPermissionSubject
  let requirements: [GatewayToolVisibilityRequirement]

  init() throws {
    database = try GatewayDatabase(inMemory: ())
    store = database.permissionStore(counter: TestAuthorizationEpochCounter())
    try database.saveProfile(
      .init(id: .chatGPTOperate, fullAccess: true, allowedCallers: [.localMCP]))
    service = GatewayPermissionService(store: store, policyReader: reader)
    subject = try GatewayPermissionSubject(
      context: .init(
        caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "visible"))
    requirements = [
      .init(
        actions: [.init(requirement: try .init(.machineInformation, .access))],
        requiresFullAccess: false),
      .init(actions: [], requiresFullAccess: true),
      .init(
        actions: [.init(requirement: try .init(.screen, .access))], requiresFullAccess: false),
    ]
    try service.connect(subject: subject, id: "visible")
  }

  func visibility(connectionID: String = "visible") throws -> [Bool] {
    try service.canRequest(
      subject: subject, requirements: requirements, connectionID: connectionID)
  }
}
