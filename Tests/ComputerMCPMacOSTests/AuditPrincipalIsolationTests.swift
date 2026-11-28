import ComputerMCPConfiguration
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct AuditPrincipalIsolationTests {
  @Test
  func unboundHistoryIsNotAttributedToAVerifiedPrincipal() throws {
    let database = try GatewayDatabase(inMemory: ())
    let unbound = AuditEvent(
      id: "unbound",
      occurredAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
      requestID: "unbound",
      caller: .secureTunnel, transport: "http", profileID: .chatGPTOperate,
      projectID: "fixture", capabilityID: "file.read", decision: .allowed)
    try database.recordAudit(unbound)
    let remote = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate, projectID: "fixture",
      transportTrace: .init(transport: "http"), trustedPrincipalID: "credential:first")
    #expect(try database.hostDiagnosticAudits(context: remote, limit: 100).isEmpty)
    var bound = unbound
    bound.id = "bound"
    bound.requestID = "verified"
    bound.principalDigest = AuditEvent.verifiedPrincipalDigest(remote.trustedPrincipalID)
    try database.recordAudit(bound)
    #expect(try database.hostDiagnosticAudits(context: remote, limit: 100) == [bound])
    #expect(try database.auditEvents().count == 2)
  }

  @Test
  func httpAuditsUseVerifiedPrincipalWhenConnectionTracesAreNil() async throws {
    let fixture = try AuditPrincipalFixture()
    defer { fixture.remove() }
    let firstContext = fixture.context(principal: "credential:first", connection: nil)
    let secondContext = fixture.context(principal: "credential:second", connection: nil)
    let first = try fixture.runtime(context: firstContext)
    let second = try fixture.runtime(context: secondContext)
    do {
      try await fixture.inspect(first, context: firstContext, requestID: "first-http")
      try await fixture.inspect(second, context: secondContext, requestID: "second-http")
      let database = try fixturePermissionDatabase(path: fixture.databasePath)
      let firstAudits = try database.hostDiagnosticAudits(context: firstContext, limit: 100)
      let secondAudits = try database.hostDiagnosticAudits(context: secondContext, limit: 100)
      fixture.expectAuditPair(firstAudits, context: firstContext, requestID: "first-http")
      fixture.expectAuditPair(secondAudits, context: secondContext, requestID: "second-http")
      var unverified = firstContext
      unverified.trustedPrincipalID = nil
      #expect(try database.hostDiagnosticAudits(context: unverified, limit: 100).isEmpty)
      unverified.trustedPrincipalID = " "
      #expect(try database.hostDiagnosticAudits(context: unverified, limit: 100).isEmpty)
      var wrongProject = firstContext
      wrongProject.projectID = "different-project"
      #expect(try database.hostDiagnosticAudits(context: wrongProject, limit: 100).isEmpty)
      var wrongProfile = firstContext
      wrongProfile.profileID = .chatGPTObserve
      #expect(try database.hostDiagnosticAudits(context: wrongProfile, limit: 100).isEmpty)
      await first.shutdown()
      await second.shutdown()
    } catch {
      await first.shutdown()
      await second.shutdown()
      throw error
    }
  }

  @Test
  func reconnectReadsTheSamePrincipalHistoryWithoutTreatingTraceAsAuthority() async throws {
    let fixture = try AuditPrincipalFixture()
    defer { fixture.remove() }
    let original = fixture.context(principal: "tunnel-bridge:fixture", connection: "old-connection")
    let reconnect = fixture.context(
      principal: "tunnel-bridge:fixture", connection: "new-connection")
    let runtime = try fixture.runtime(context: original)
    do {
      try await fixture.inspect(runtime, context: original, requestID: "before-reconnect")
      try await fixture.inspect(runtime, context: reconnect, requestID: "after-reconnect")
      let audits = try fixture.database.hostDiagnosticAudits(context: reconnect, limit: 100)
      #expect(Set(audits.map(\.requestID)) == ["before-reconnect", "after-reconnect"])
      fixture.expectAuditPair(
        audits.filter { $0.requestID == "before-reconnect" }, context: original,
        requestID: "before-reconnect")
      fixture.expectAuditPair(
        audits.filter { $0.requestID == "after-reconnect" }, context: reconnect,
        requestID: "after-reconnect")
      var impostor = reconnect
      impostor.trustedPrincipalID = "tunnel-bridge:another"
      #expect(try fixture.database.hostDiagnosticAudits(context: impostor, limit: 100).isEmpty)
      var anotherChannel = reconnect
      anotherChannel.caller = .localCLI
      #expect(
        Set(
          try fixture.database.hostDiagnosticAudits(context: anotherChannel, limit: 100).map(\.id))
          == Set(audits.map(\.id)))
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

}

private struct AuditPrincipalFixture {
  let root: URL
  let database: GatewayDatabase
  let project: ComputerMCPCore.RegisteredProject
  let configuration: GatewayConfiguration
  var databasePath: String { root.appendingPathComponent("audits.sqlite").path }

  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    root = directory.resolvingSymlinksInPath()
    project = .init(id: "fixture", displayName: "Fixture", rootPath: root.path)
    database = try fixturePermissionDatabase(
      path: root.appendingPathComponent("audits.sqlite").path)
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate,
      permissions: fixturePermissions([.project("fixture"): .granted(.read)]),
      allowedCallers: [.secureTunnel])
    configuration = .init(profiles: [profile])
    try database.bootstrapPermissionProfiles([profile.grant], declarations: [profile.grant])
    try database.saveProject(project)
  }

  func context(principal: String, connection: String?) -> ExecutionContext {
    .init(
      caller: .secureTunnel, profileID: .chatGPTOperate, projectID: "fixture",
      transportTrace: .init(
        transport: connection == nil ? "http" : "gateway_socket", socketConnectionID: connection),
      trustedPrincipalID: principal)
  }

  func runtime(context: ExecutionContext) throws -> GatewayRuntime {
    var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    platform.permissionPolicyReader = TestManagedPolicyReader()
    return try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: [project], platform: platform, plugins: [])
  }

  func inspect(_ runtime: GatewayRuntime, context: ExecutionContext, requestID: String) async throws
  {
    var request = context
    request.requestID = requestID
    _ = try await runtime.callToolAsync(
      name: "project.describe", arguments: .object(["project_id": .string("fixture")]),
      context: request, invocationContext: .empty)
  }

  func expectAuditPair(_ events: [AuditEvent], context: ExecutionContext, requestID: String) {
    #expect(events.count == 2)
    #expect(events.filter { $0.errorCode == "permission.admitted" }.count == 1)
    #expect(events.filter { $0.errorCode == nil }.count == 1)
    #expect(
      Set(events.compactMap { $0.errorDetails?.objectValue?["admission"]?.stringValue })
        == ["allowed", "completed"])
    for event in events {
      #expect(event.requestID == requestID)
      #expect(
        event.principalDigest == AuditEvent.verifiedPrincipalDigest(context.trustedPrincipalID))
      #expect(event.caller == context.caller)
      #expect(event.transport == context.transportTrace?.transport)
      #expect(event.socketConnectionID == context.transportTrace?.socketConnectionID)
      #expect(event.profileID == context.profileID)
      #expect(event.projectID == context.projectID)
      #expect(event.capabilityID == "project.describe")
      #expect(event.decision == .allowed)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
