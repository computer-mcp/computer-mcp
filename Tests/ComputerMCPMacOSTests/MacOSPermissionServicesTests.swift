import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPMacOS

@Suite struct MacOSPermissionServicesTests {
  @Test func gatewayAndOwnerControlShareTheSameDurableAuthority() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let counter = TestAuthorizationEpochCounter()
    let reader = TestManagedPolicyReader()
    let owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
      validate: {})
    let database = GatewayDatabase(connection: connection)
    var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    platform.permissionPolicyReader = reader
    let services = try MacOSPermissionServices(
      database: database, counter: counter, platform: platform, owner: { owner })
    let store = SQLitePermissionStore(connection: connection, counter: counter)
    let now = Date()
    var view = try services.control.view(now: now)
    let epoch = try #require(view.epoch)
    try store.transactionWithDatabase { _, ledger in try ledger.acknowledgeEpochRecovery(epoch) }
    view = try services.control.view(now: now)
    try services.control.confirmAuthority(
      epoch: epoch, expectedRevision: view.revision, profileEdits: view.profiles, now: now)
    try services.control.updateProfile(
      .init(id: .chatGPTOperate, allowedCallers: [.secureTunnel]), expectedProfileRevision: nil,
      expectedRevision: services.control.view(now: now).revision, now: now)
    let subject = try GatewayPermissionSubject(
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "client"))
    let requirements = try InvocationRequirements(actions: [
      .init(requirement: .init(.screen, .access))
    ])
    guard
      case .requests(let requests) = try services.gateway.admit(
        subject: subject, tool: "fixture", projectID: nil, argumentsDigest: "digest",
        requirements: requirements, now: now)
    else {
      Issue.record("Expected a request")
      return
    }
    let request = try #require(requests.first)
    _ = try services.control.answerRequest(
      request.id, answer: .always, expectedRevision: services.control.view(now: now).revision,
      now: now)
    guard
      case .allowed = try services.gateway.admit(
        subject: subject, tool: "fixture", projectID: nil, argumentsDigest: "digest",
        requirements: requirements, now: now)
    else {
      Issue.record("Owner grant did not reach gateway")
      return
    }
    reader.set(.machineFile, .unreadable("fixture"))
    let diagnostics = try services.control.view(now: now)
    #expect(diagnostics.sources.contains { $0.source == .machine && $0.failure != nil })
    #expect(
      try services.gateway.admit(
        subject: subject, tool: "fixture", projectID: nil, argumentsDigest: "digest",
        requirements: requirements, now: now) == .denied(.managedLimit([.machine])))
  }
}

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif
