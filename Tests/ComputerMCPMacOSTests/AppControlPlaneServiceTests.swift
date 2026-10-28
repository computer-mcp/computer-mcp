import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPTransport
import ComputerMCPTunnels
import CryptoKit
import Darwin
import Foundation
import GRDB
import MCP
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)

final class AppControlPlaneServiceTests {
  @Test
  func rollbackUpgradesHistoricalManifestWithoutChangingHistory() async throws {
    let projectRoot = try ScopedTemporaryDirectory()
    let text = """
      schema_version = 1
      [server]
      name = "historical"
      [builtin]
      enabled = ["workspace.instructions"]
      [[workspaces]]
      id = "workspace-id"
      display_name = "workspace.list"
      path = "\(projectRoot.url.path)"
      [[profiles]]
      id = "local-admin"
      mode = "workspace-operations"
      capabilities = ["workspace.list"]
      workspaces = ["workspace-id"]
      allowed_callers = ["local-cli"]
      """
    let fixture = try AppControlPlaneServiceFixture(initialManifest: text)
    defer { fixture.cleanup() }
    let history = try await fixture.controlPlane.configurationHistory()
    try #require(history.count == 2)
    let historical = try #require(history.first { $0.manifest == text })
    let upgraded = try #require(history.first { $0.id != historical.id })
    let configuration = try await fixture.controlPlane.activeConfiguration()
    #expect(configuration.projects.first?.id == "workspace-id")
    #expect(configuration.projects.first?.displayName == "workspace.list")
    #expect(configuration.projects.first?.path == projectRoot.url.path)
    #expect(
      configuration.profiles.first?.grant.permissions.state(for: .project("workspace-id"))
        == .granted(.read))
    #expect(configuration.builtin.enabled == ["project.instructions"])

    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.controlPlane, gatewayService: gateway)
    var changed = configuration
    changed.server.name = "changed"
    let activated = try await operations.activateManifest(
      changed.exportedTOML(), expectedDigest: upgraded.digest)
    await #expect(throws: (any Error).self) {
      try await operations.rollbackManifest(to: historical.id)
    }
    #expect(try fixture.database.configurationRevision(id: historical.id) == historical)
    #expect(try await fixture.controlPlane.activeConfiguration() == changed)
    #expect(activated.id != historical.id)
  }

  @Test(arguments: [
    ComputerUsePermissionSnapshot(accessibility: .granted, screenRecording: .notGranted),
    ComputerUsePermissionSnapshot(accessibility: .notGranted, screenRecording: .granted),
  ])
  func computerUsePermissionsReadsInjectedSnapshot(snapshot: ComputerUsePermissionSnapshot)
    async throws
  {
    let fixture = try AppControlPlaneServiceFixture(
      computerUsePermissionReader: FixedComputerUsePermissionReader(snapshot: snapshot))
    defer { fixture.cleanup() }

    #expect(await fixture.controlPlane.computerUsePermissions() == snapshot)
  }

  @Test
  func clientControlCommandsShareAppAuthorityWithoutRestarting() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let configuration = GatewayConfiguration(
      policy: .init(shellEnabled: true),
      profiles: [
        .init(
          id: .chatGPTOperate,
          permissions: fixturePermissions([
            .machineInformation: .granted(.access), .project("fixture"): .granted(.read),
          ]), fullAccess: true, allowedCallers: [.localMCP])
      ],
      builtin: .init(enabled: ["system.time"]), projectDirectory: fixture.root)
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    try fixture.database.saveProject(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let socket = ControlSocketService(
      controlPlane: fixture.controlPlane, gatewayService: gateway,
      socketURL: fixture.directories.controlSocket)
    try await socket.start()
    do {
      try await gateway.start(profile: .chatGPTOperate)
      let before = await gateway.snapshot()
      let remote = try await GatewayClientSession.connectSocket(
        socketURL: fixture.directories.gatewaySocket)
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      let listed = try await client.call("clients.list")
      let selected = try #require(listed.objectValue?["sessions"]?.arrayValue?.first?.objectValue)
      let id = try #require(selected["id"]?.stringValue)
      let revision = try #require(selected["revision"]?.intValue)
      let trustRevision = try #require(selected["trust_revision"]?.intValue)
      let approved = try await client.call(
        "clients.allow",
        arguments: .object([
          "id": .string(id), "expected_revision": .integer(Int64(revision)),
          "expected_trust_revision": .integer(Int64(trustRevision)), "full_access": .bool(true),
        ]))
      #expect(try await remote.listToolNames().contains("shell.run"))
      #expect(
        approved.objectValue?["full_access_consent"]?.objectValue?["lifetime"]
          == .string("this-session"))
      #expect(try fixture.database.clientTrusts().isEmpty)
      #expect(await gateway.snapshot().startedAt == before.startedAt)
      let approvedRevision = try #require(approved.objectValue?["revision"]?.intValue)
      let limited = try await client.call(
        "clients.limit",
        arguments: .object([
          "id": .string(id), "expected_revision": .integer(Int64(approvedRevision)),
          "limits": try ControlToolResponse.encodedPayload(ManagedPolicy(allowsFullAccess: false)),
        ]))
      #expect(try await remote.listToolNames().contains("shell.run"))
      let limitedSession = try #require(await gateway.controlSessions().first { $0.id == id })
      #expect(
        !limitedSession.accessLimit.allowsFullAccess && limitedSession.fullAccessConsent == nil)
      _ = try await client.call(
        "clients.end",
        arguments: .object([
          "id": .string(id), "expected_revision": try #require(limited.objectValue?["revision"]),
        ]))
      #expect(try await remote.listToolNames().isEmpty)
      await remote.disconnect()
      await gateway.stop()
      await socket.stop()
    } catch {
      await gateway.stop()
      await socket.stop()
      throw error
    }
  }

  @Test
  func permissionChoicesUseTheHostCatalogWithoutPersistingAuthority() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    var configuration = GatewayConfiguration(
      mcp: .init(servers: [
        .init(id: "notes", transport: .stdio, command: "/usr/bin/false", enabled: false)
      ]),
      builtin: .init(enabled: ["system.time", "file.read", "file.write"]),
      projectDirectory: fixture.root)
    configuration.policy.shellEnabled = true
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    try fixture.database.saveProject(
      .init(id: "project", displayName: "My Project", rootPath: fixture.root.path))
    let before = try fixture.database.configurationState()
    let options = try await fixture.controlPlane.profilePermissionOptions(
      profileID: .chatGPTOperate)
    #expect(try fixture.database.configurationState() == before)
    #expect(options.projects.map(\.displayName) == ["My Project"])
    #expect(options.integrations.contains { $0.id == "notes" && !$0.isEnabled })
    #expect(options.permissionRevision > 0)
    #expect(options.grant.id == .chatGPTOperate)
  }

  @Test(arguments: ["profile", "manifest", "external-edit", "project", "plugin"])
  func permissionSelectionRefusesChangedReviewedInputs(change: String) async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    var configuration = GatewayConfiguration(projectDirectory: fixture.root)
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let options = try await fixture.controlPlane.profilePermissionOptions(
      profileID: .chatGPTOperate)
    switch change {
    case "profile":
      _ = try fixture.editProfile(.chatGPTOperate) {
        try $0.permissions.set(.granted(.access), for: .screen)
      }
    case "manifest":
      configuration.policy.shellEnabled = true
      _ = try await fixture.controlPlane.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try? await fixture.controlPlane.configurationDigest())
    case "external-edit":
      try (configuration.exportedTOML() + "\n# Unadmitted external edit\n").write(
        to: fixture.directories.manifest, atomically: true, encoding: .utf8)
    case "project":
      try fixture.database.saveProject(
        .init(id: "new", displayName: "New Project", rootPath: fixture.root.path))
    case "plugin":
      var state = try fixture.database.pluginStoreSnapshot()
      let revision = state.revision
      state.revision += 1
      try fixture.database.savePluginStoreSnapshot(state, expectedRevision: revision)
    default: Issue.record("Unexpected test input")
    }
    let profiles = try fixture.database.profiles()
    let manifest = try Data(contentsOf: fixture.directories.manifest)
    await #expect(throws: (any Error).self) {
      try await fixture.controlPlane.updateProfilePermissions(
        options.grant, expectedRevision: options.permissionRevision, reviewedOptions: options)
    }
    #expect(try fixture.database.profiles() == profiles)
    #expect(try Data(contentsOf: fixture.directories.manifest) == manifest)
  }

  @Test
  func explicitFullAccessFollowsTheSelectedSocketSessionAndPersistentClientTrust() async throws {
    let program =
      "from pathlib import Path\np = Path('consent.txt')\np.write_text((p.read_text() if p.exists() else '') + 'approved')\n"
    let fixture = try AppControlPlaneServiceFixture(executionLauncher: { root in
      fixtureProtocolExecutionLauncher(root: root, scripts: [program], arguments: [[]])
    })
    defer { fixture.cleanup() }
    let script = fixture.root.appendingPathComponent("consent.py")
    try program.write(to: script, atomically: true, encoding: .utf8)
    let run = JSONValue.object([
      "project_id": .string("fixture"), "mode": .string("argv"),
      "executable": .string("/usr/bin/python3"), "argv": .array([.string(script.path)]),
      "cwd": .string(fixture.root.path),
    ])
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
      policy: .init(shellEnabled: true),
      profiles: [
        .init(
          id: .chatGPTOperate,
          permissions: fixturePermissions([
            .machineInformation: .granted(.access), .project("fixture"): .granted(.write),
          ]), fullAccess: true, allowedCallers: [.localMCP])
      ], projectDirectory: fixture.root)
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    try fixture.database.saveProject(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    let service = AppGatewayService(
      controlPlane: fixture.controlPlane,
      socketConfiguration: .init(socketURL: fixture.root.appendingPathComponent("gateway.sock")))
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.controlPlane, gatewayService: service)
    try await service.start(profile: .chatGPTOperate)
    do {
      let first = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      let firstScope = try #require(await operations.controlSessions().first)
      #expect(try await first.listToolNames().contains("shell.run"))
      #expect(
        try await first.call(toolName: "shell.run", arguments: run).result.objectValue?["isError"]
          == .bool(true))
      let approved = try await operations.approveControlSession(
        id: firstScope.id, expectedRevision: firstScope.revision)
      #expect(approved.fullAccessConsent?.lifetime == .thisSession)
      #expect(try operations.clientTrusts().isEmpty)
      #expect(try await first.listToolNames().contains("shell.run"))
      #expect(
        try await first.call(toolName: "shell.run", arguments: run).result.objectValue?["isError"]
          != .bool(true))
      let sibling = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      let siblingScope = try #require(
        await operations.controlSessions().first { $0.id != firstScope.id })
      #expect(try await sibling.listToolNames().contains("shell.run"))
      #expect(
        try await sibling.call(toolName: "shell.run", arguments: run).result.objectValue?["isError"]
          == .bool(true))
      _ = try await operations.approveControlSession(
        id: firstScope.id, lifetime: .alwaysAllowClient, expectedRevision: approved.revision)
      let trust = try #require(operations.clientTrusts().first)
      await first.disconnect()
      let reconnected = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      let reconnectedScope = try #require(
        await operations.controlSessions().first {
          $0.id != siblingScope.id && $0.id != firstScope.id
        })
      #expect(try await reconnected.listToolNames().contains("shell.run"))
      #expect(try await sibling.listToolNames().contains("shell.run"))
      #expect(
        try await reconnected.call(toolName: "shell.run", arguments: run).result.objectValue?[
          "isError"]
          != .bool(true))
      try operations.revokeClientTrust(id: trust.id, expectedRevision: trust.revision)
      #expect(try await reconnected.listToolNames().contains("shell.run"))
      #expect(
        try await reconnected.call(toolName: "shell.run", arguments: run).result.objectValue?[
          "isError"]
          == .bool(true))
      #expect(
        try String(contentsOf: fixture.root.appendingPathComponent("consent.txt"), encoding: .utf8)
          == "approvedapproved")
      let limited = try #require(
        await operations.controlSessions().first { $0.id == reconnectedScope.id })
      let revokedTrust = try #require(operations.clientTrusts().first)
      _ = try await operations.approveControlSession(
        id: limited.id, lifetime: .alwaysAllowClient, expectedRevision: limited.revision,
        expectedTrustRevision: revokedTrust.revision)
      configuration.profiles[0].grant.fullAccess = false
      _ = try await operations.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try await operations.controlPlane.configurationDigest())
      let changed = try #require(
        await operations.controlSessions().first { $0.id == limited.id })
      #expect(changed.fullAccessConsent == nil)
      #expect(changed.profile?.grant.fullAccess == false)
      #expect(try !fixture.database.profiles().isEmpty)
      await reconnected.disconnect()
      await sibling.disconnect()
      await service.stop()
      #expect(await operations.controlSessions().isEmpty)
    } catch {
      await service.stop()
      throw error
    }
  }

  @Test
  func ownerLimitsOneVerifiedSessionWithoutChangingOtherConnectionsOrTheProfile() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
      profiles: [
        .init(
          id: .chatGPTOperate,
          permissions: fixturePermissions([
            .machineInformation: .granted(.access), .skills: .granted(.access),
            .screen: .granted(.access), .desktopControl: .granted(.access),
            .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
            .project("fixture"): .granted(.write), .mcpServer("*"): .granted(.all),
            .plugin("*"): .granted(.use),
          ]), allowedCallers: [.localMCP])
      ], builtin: .init(enabled: ["system.time", "file.read"]), projectDirectory: fixture.root)
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    try fixture.database.saveProject(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    try Data("second".utf8).write(to: fixture.root.appendingPathComponent("session.txt"))
    let service = AppGatewayService(
      controlPlane: fixture.controlPlane,
      socketConfiguration: .init(socketURL: fixture.root.appendingPathComponent("gateway.sock")))
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.controlPlane, gatewayService: service)
    try await service.start(profile: .chatGPTOperate)
    do {
      let first = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      let firstScope = try #require(await operations.controlSessions().first)
      let second = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      let secondScope = try #require(
        await operations.controlSessions().first { $0.id != firstScope.id })
      #expect(firstScope.principalID == secondScope.principalID)
      let saved = try fixture.database.profiles()
      _ = try await operations.limitControlSession(
        id: firstScope.id,
        to: ManagedPolicy(permissionCeilings: fixturePermissions([.project("fixture"): .denied])),
        expectedRevision: firstScope.revision)
      #expect(try await first.listToolNames().contains("file.read"))
      #expect(try await second.listToolNames().contains("file.read"))
      let target = JSONValue.object([
        "project_id": .string("fixture"), "path": .string("session.txt"),
      ])
      #expect(
        try await first.call(toolName: "file.read", arguments: target).result.objectValue?[
          "isError"] == .bool(true))
      #expect(
        try await second.call(toolName: "file.read", arguments: target).result.objectValue?[
          "isError"] != .bool(true))
      #expect(
        try String(contentsOf: fixture.root.appendingPathComponent("session.txt"), encoding: .utf8)
          == "second")
      try await operations.endControlSession(
        id: secondScope.id, expectedRevision: secondScope.revision)
      #expect(
        try await second.call(toolName: "system.time").result.objectValue?["isError"] == .bool(true)
      )
      #expect(
        try await first.call(toolName: "system.time").result.objectValue?["isError"] != .bool(true))
      #expect(try fixture.database.profiles() == saved)
      #expect(await service.snapshot().state == .running)
      await first.disconnect()
      await second.disconnect()
      await service.stop()
      #expect(await operations.controlSessions().isEmpty)
    } catch {
      await service.stop()
      throw error
    }
  }

  @Test
  func projectRemovalRollsBackGrantsWhenDeletionFails() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    try fixture.database.saveProject(
      ComputerMCPCore.RegisteredProject(
        id: "removed", displayName: "Removed", rootPath: fixture.root.path))
    for id in [GatewayProfileID.chatGPTObserve, .chatGPTOperate] {
      try fixture.database.saveProfile(
        ProfileGrant(
          id: id, permissions: fixturePermissions([.project("removed"): .granted(.read)]),
          allowedCallers: [.secureTunnel]))
    }
    let before = try fixture.database.configurationState()
    try await fixture.database.connection.writer.write {
      try $0.execute(
        sql: """
          CREATE TRIGGER refuse_project_deletion BEFORE DELETE ON projects
          BEGIN SELECT RAISE(ABORT, 'fixture deletion failure'); END
          """)
    }
    do {
      try await fixture.controlPlane.removeProject(id: "removed")
      Issue.record("Expected the final deletion to fail")
    } catch is DatabaseError {}
    #expect(try fixture.database.configurationState() == before)
  }

  @Test(arguments: [false, true])
  func startJoinsOwnedListenerCleanup(stopBeforeObservation: Bool) async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    _ = try fixture.editProfile(.chatGPTObserve) { $0.allowedCallers.insert(.localMCP) }
    let socketURL = fixture.root.appendingPathComponent("gateway.sock")
    let service = AppGatewayService(
      controlPlane: fixture.controlPlane,
      socketConfiguration: GatewaySocketConfiguration(socketURL: socketURL)
    )
    try await service.start()
    let stopping = Task { await service.stop() }
    if stopBeforeObservation { await stopping.value }
    let deadline = ContinuousClock.now + .seconds(3)
    while await service.snapshot().state == .running, ContinuousClock.now < deadline {
      await Task.yield()
    }
    let stopState = await service.snapshot().state
    // Cleanup can finish before observation; start must join it and own the next listener.
    #expect(stopState == .stopping || stopState == .stopped)
    do {
      try await service.start()
      await stopping.value
      #expect(await service.snapshot().state == .running)
      let catalog = try await GatewaySocketCatalogInspector().inspect(socketURL: socketURL)
      #expect(catalog.toolNames.contains("project.list"))
      await service.stop()
      #expect(await service.snapshot().state == .stopped)
      #expect(!FileManager.default.fileExists(atPath: socketURL.path))
      try await service.start()
      await service.stop()
    } catch {
      await stopping.value
      await service.stop()
      throw error
    }
  }

  @Test
  func permissionEditsRoundTripAndRejectStaleAuthorization() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let options = try await fixture.controlPlane.profilePermissionOptions(
      profileID: .chatGPTOperate)
    var proposed = options.grant
    try proposed.permissions.set(.granted(.access), for: .screen)
    proposed.allowedCallers = [.cloudflareTunnel]
    let saved = try await fixture.controlPlane.updateProfilePermissions(
      proposed, expectedRevision: options.permissionRevision)
    #expect(saved.authorizationRevision > options.grant.authorizationRevision)
    #expect(saved.permissions.state(for: .screen) == .granted(.access))
    let exported = try await fixture.controlPlane.effectiveConfigurationForExport()
    let reloaded = try GatewayConfiguration.load(
      text: exported.exportedTOML(), baseURL: fixture.root)
    #expect(reloaded.profileGrant(for: saved.id).permissions.entries == saved.permissions.entries)
    #expect(reloaded.profileGrant(for: saved.id).allowedCallers == saved.allowedCallers)
    await #expect(throws: GatewayPermissionError.revisionConflict) {
      try await fixture.controlPlane.updateProfilePermissions(
        proposed, expectedRevision: options.permissionRevision)
    }
  }

  @Test
  func permissionRequestAnswerRequiresTheReviewedDurableRevision() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let subject = try GatewayPermissionSubject(
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "client"))
    let requirements = InvocationRequirements(actions: [
      PermissionAction(
        requirement: try .init(.screen, .access))
    ])
    let decision = try fixture.permissionGateway.admit(
      subject: subject, tool: "computer.screenshot", projectID: nil,
      argumentsDigest: "request", requirements: requirements)
    guard case .requests(let requests) = decision else {
      Issue.record("Expected a permission request")
      return
    }
    let request = try #require(requests.first)
    let reviewed = try fixture.permissionControl.view()
    try await fixture.controlPlane.answerPermissionRequest(
      request.id, answer: .onlyThisTime, expectedRevision: reviewed.revision)
    #expect(
      try fixture.permissionControl.view().requests.first { $0.request.id == request.id }?.request
        .status == .onlyThisTime)
    #expect(throws: GatewayPermissionError.revisionConflict) {
      try fixture.permissionControl.answerRequest(
        request.id, answer: .always, expectedRevision: reviewed.revision)
    }
  }

  @Test
  func projectRevocationNarrowsAnExplicitProjectWildcard() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    for id in ["one", "two"] {
      let root = fixture.root.appendingPathComponent(id, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try fixture.database.saveProject(
        .init(id: id, displayName: id, rootPath: root.path))
    }
    _ = try fixture.editProfile(.chatGPTOperate) {
      try $0.permissions.set(.granted(.write), for: .project("*"))
    }
    let grant = try await fixture.setProjectAccess(
      .deny, projectID: "one", profileID: .chatGPTOperate)
    #expect(grant.permissions.state(for: .project("one")) == .denied)
    #expect(grant.permissions.state(for: .project("two")) == .granted(.write))
    let inherited = try await fixture.setProjectAccess(
      .ask, projectID: "one", profileID: .chatGPTOperate)
    #expect(inherited.permissions.entries[.project("one")] == nil)
    #expect(inherited.permissions.state(for: .project("one")) == .granted(.write))
  }

  @Test
  func tunnelPrincipalIsStableAcrossControlPlaneReads() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let first = try await fixture.controlPlane.gatewayTunnelPrincipalID()
    let second = try await fixture.controlPlane.gatewayTunnelPrincipalID()
    #expect(first.hasPrefix("tunnel-bridge:"))
    #expect(first == second)
  }

  @Test
  func localControlRoundTripsPermissionChangesAndRequests() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let service = ControlSocketService(
      controlPlane: fixture.controlPlane, gatewayService: gateway,
      socketURL: fixture.directories.controlSocket)
    try await service.start()
    do {
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      _ = try fixture.editProfile(.chatGPTOperate) {
        try $0.permissions.set(.granted(.write), for: .project("saved-project"))
        try $0.permissions.set(.granted(.use), for: .plugin("saved-plugin"))
        try $0.permissions.set(.granted(.all), for: .mcpServer("saved-server"))
        $0.projectNetworks["saved-project"] = .custom(
          hosts: ["api.example.com"], includesTrusted: true)
      }
      let options = try await fixture.controlPlane.profilePermissionOptions(
        profileID: .chatGPTOperate)
      let shown = try await client.call(
        "profile.show",
        arguments: .object(["profile": .string(GatewayProfileID.chatGPTOperate.rawValue)]))
      let response = try await client.call(
        "profile.permissions",
        arguments: .object([
          "grant": shown,
          "expected_permission_revision": .integer(Int64(options.permissionRevision)),
        ]))
      #expect(
        response.objectValue?["allowedCallers"] != nil
          || response.objectValue?["allowed_callers"] != nil)
      let decoded = try CanonicalJSONCoding.decoder().decode(
        ProfileGrant.self, from: JSONEncoder().encode(response))
      #expect(decoded.permissions.state(for: .project("saved-project")) == .granted(.write))
      #expect(decoded.permissions.state(for: .plugin("saved-plugin")) == .granted(.use))
      #expect(decoded.permissions.state(for: .mcpServer("saved-server")) == .granted(.all))
      #expect(
        decoded.projectNetworks["saved-project"]?.configuration
          == options.grant.projectNetworks["saved-project"]?.configuration)
      let listed = try await client.call("permissions.requests")
      #expect(listed.objectValue?["revision"]?.intValue != nil)
      #expect(listed.objectValue?["requests"]?.arrayValue != nil)
      await #expect(throws: ControlSocketCallError.self) {
        try await client.call("profile.permissions", arguments: .object(["grant": .object([:])]))
      }
      #expect((await gateway.snapshot()).state == .stopped)
      await service.stop()
    } catch {
      await service.stop()
      throw error
    }
  }

  @Test
  func stoppedAndRestartedOwnerRejectsCapturedPermissionRouters() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let project = ComputerMCPCore.RegisteredProject(
      id: "permission-project", displayName: "Permission Project", rootPath: fixture.root.path)
    try fixture.database.saveProject(project)
    _ = try fixture.editProfile(.chatGPTOperate) {
      $0.allowedCallers = [.localMCP]
      try $0.permissions.set(.notGranted, for: .screen)
    }
    let subject = try GatewayPermissionSubject(
      context: .init(
        caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "permission-client"))
    let requirements = try InvocationRequirements(actions: [
      .init(requirement: .init(.screen, .access))
    ])
    guard
      case .requests(let requests) = try fixture.permissionGateway.admit(
        subject: subject, tool: "screen.capture", projectID: nil,
        argumentsDigest: "permission-input", requirements: requirements),
      let request = requests.first
    else {
      Issue.record("Expected a pending request")
      return
    }
    let owner = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let epoch = try await owner.startLocalAdministration()
    let identity = GatewaySocketConnectionIdentity(trustedPrincipalID: "owner", origin: .localCLI)
    func registry(_ epoch: UUID) -> ControlToolRegistry {
      ControlToolRegistry(
        controlPlane: fixture.controlPlane, gatewayService: owner,
        operations: AppControlPlaneOperations(
          controlPlane: fixture.controlPlane, gatewayService: owner),
        identity: identity, administrationEpoch: epoch)
    }
    let stale = registry(epoch)
    let activeView = try await stale.callToolAsync(
      name: "permissions.requests", arguments: nil, context: .empty)
    #expect(activeView.objectValue?["isError"]?.boolValue != true)
    let reviewed = try fixture.permissionControl.view()
    let reviewedProfile = try #require(reviewed.profiles.first { $0.id == .chatGPTOperate })
    let answer: JSONValue = .object([
      "id": .string(request.id.uuidString), "answer": .string("always"),
      "expected_revision": .integer(Int64(reviewed.revision)),
    ])
    let confirmation: JSONValue = .object([
      "epoch": .string(try #require(reviewed.epoch).uuidString),
      "expected_permission_revision": .integer(Int64(reviewed.revision)),
      "profiles": try ControlToolResponse.encodedPayload(reviewed.profiles),
    ])
    let projectAccess: JSONValue = .object([
      "project_id": .string(project.id), "profile": .string(reviewedProfile.id.rawValue),
      "access": .string("write"),
      "expected_profile_revision": .integer(reviewedProfile.authorizationRevision),
      "expected_permission_revision": .integer(Int64(reviewed.revision)),
    ])
    var proposed = reviewedProfile
    try proposed.permissions.set(.denied, for: .skills)
    let profilePermissions: JSONValue = .object([
      "grant": try ControlToolResponse.encodedPayload(proposed),
      "expected_permission_revision": .integer(Int64(reviewed.revision)),
    ])
    await owner.stopLocalAdministration(epoch: epoch)
    var currentEpoch: UUID?
    do {
      for restarted in [false, true] {
        if restarted { currentEpoch = try await owner.startLocalAdministration() }
        for (name, arguments) in [
          ("permissions.requests", JSONValue.object([:])), ("permissions.answer", answer),
          ("permissions.confirm_authority", confirmation),
          ("project.access", projectAccess), ("profile.permissions", profilePermissions),
        ] {
          let rejected = try await stale.callToolAsync(
            name: name, arguments: arguments, context: .empty)
          #expect(rejected.objectValue?["isError"]?.boolValue == true)
          let unchanged = try fixture.permissionControl.view()
          #expect(unchanged.revision == reviewed.revision)
          #expect(unchanged.profiles == reviewed.profiles)
        }
      }
      let current = registry(try #require(currentEpoch))
      let answered = try await current.callToolAsync(
        name: "permissions.answer", arguments: answer, context: .empty)
      #expect(answered.objectValue?["isError"]?.boolValue != true)
      #expect(
        try fixture.permissionControl.view().profiles.first { $0.id == .chatGPTOperate }?
          .permissions.state(for: .screen) == .granted(.access))
      let projectReview = try fixture.permissionControl.view()
      let currentProfile = try #require(
        projectReview.profiles.first { $0.id == reviewedProfile.id })
      var projectArguments = try #require(projectAccess.objectValue)
      projectArguments["expected_profile_revision"] = .integer(currentProfile.authorizationRevision)
      projectArguments["expected_permission_revision"] = .integer(Int64(projectReview.revision))
      let granted = try await current.callToolAsync(
        name: "project.access", arguments: .object(projectArguments), context: .empty)
      #expect(granted.objectValue?["isError"]?.boolValue != true)
      let profileReview = try fixture.permissionControl.view()
      var edited = try #require(profileReview.profiles.first { $0.id == reviewedProfile.id })
      #expect(edited.permissions.state(for: .project(project.id)) == .granted(.write))
      try edited.permissions.set(.denied, for: .skills)
      let updated = try await current.callToolAsync(
        name: "profile.permissions",
        arguments: .object([
          "grant": try ControlToolResponse.encodedPayload(edited),
          "expected_permission_revision": .integer(Int64(profileReview.revision)),
        ]), context: .empty)
      #expect(updated.objectValue?["isError"]?.boolValue != true)
      #expect(
        try fixture.permissionControl.view().profiles.first { $0.id == reviewedProfile.id }?
          .permissions.state(for: .skills) == .denied)
      if let currentEpoch { await owner.stopLocalAdministration(epoch: currentEpoch) }
    } catch {
      if let currentEpoch { await owner.stopLocalAdministration(epoch: currentEpoch) }
      throw error
    }
  }

  @Test
  func unconfirmedSavedProfilesRequireCompleteEpochBoundOwnerReview() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    _ = try fixture.editProfile(.chatGPTOperate) {
      $0.allowedCallers = [.localMCP]
      try $0.permissions.set(.granted(.access), for: .screen)
    }
    try await fixture.database.connection.writer.write {
      try $0.execute(
        sql: "UPDATE permissionProfiles SET authorityEpoch = NULL WHERE id = ?",
        arguments: [GatewayProfileID.chatGPTOperate.rawValue])
    }
    let subject = try GatewayPermissionSubject(
      context: .init(
        caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "review-client"))
    let requirements = try InvocationRequirements(actions: [
      .init(requirement: .init(.screen, .access))
    ])
    func admission() throws -> AuthorizationDecision {
      try fixture.permissionGateway.admit(
        subject: subject, tool: "screen.capture", projectID: nil,
        argumentsDigest: "review-input", requirements: requirements)
    }
    #expect(try admission() == .denied(.authoritySuspended))
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let socket = ControlSocketService(
      controlPlane: fixture.controlPlane, gatewayService: gateway,
      socketURL: fixture.directories.controlSocket)
    try await socket.start()
    do {
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      let response = try await client.call("permissions.requests")
      let row = try #require(response.objectValue)
      let epoch = try #require(row["epoch"]?.stringValue)
      let revision = try #require(row["revision"]?.int64Value)
      let profiles = try #require(row["profiles"])
      #expect(
        row["unconfirmed_profile_ids"]?.arrayValue?.contains(
          .string(GatewayProfileID.chatGPTOperate.rawValue)) == true)
      let reviewed: [String: JSONValue] = [
        "epoch": .string(epoch), "expected_permission_revision": .integer(revision),
        "profiles": profiles,
      ]
      var missingProfiles = reviewed
      missingProfiles.removeValue(forKey: "profiles")
      var incomplete = reviewed
      incomplete["profiles"] = .array([])
      var wrongEpoch = reviewed
      wrongEpoch["epoch"] = .string(UUID().uuidString)
      var stale = reviewed
      stale["expected_permission_revision"] = .integer(revision - 1)
      for invalid in [missingProfiles, incomplete, wrongEpoch, stale] {
        await #expect(throws: ControlSocketCallError.self) {
          try await client.call("permissions.confirm_authority", arguments: .object(invalid))
        }
        #expect(try admission() == .denied(.authoritySuspended))
      }
      _ = try await client.call("permissions.confirm_authority", arguments: .object(reviewed))
      #expect(try fixture.permissionControl.view().unconfirmedProfileIDs.isEmpty)
      guard case .allowed = try admission() else {
        Issue.record("Explicit reviewed authority was not activated")
        await socket.stop()
        return
      }
      await socket.stop()
    } catch {
      await socket.stop()
      throw error
    }
  }

  @Test(
    arguments: ["tools", "call", "call-error", "socket", "tunnel", "tunnel-invalid-metadata"],
    ["complete", "cancel", "configuration", "project", "grant", "plugin"])
  func gatewayConstructionKeepsManagementResponsiveAndDiscardsObsoleteInputs(
    operation: String, change: String
  ) async throws {
    let bookmarks = GatedConstructionBookmarkService()
    let fixture = try AppControlPlaneServiceFixture(
      projectBookmarks: bookmarks, invalidCatalogMetadata: operation == "tunnel-invalid-metadata")
    defer { fixture.cleanup() }
    let script = fixture.root.appendingPathComponent("catalog.py")
    try Data(Self.gatedCatalogScript.utf8).write(to: script)
    let configuration = GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, fixture.root.path, operation], exposure: .reexport, prefix: "fixture",
          allowAnyTool: true, startupTimeoutMs: 5000, requestTimeoutMs: 5000,
          toolRisks: ["inspect": .readOnly])
      ]),
      builtin: .init(enabled: ["system.time", "file.write"]),
      projectDirectory: fixture.root)
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: fixture.root.path,
      bookmarkIsStale: change == "project")
    try fixture.database.saveProject(project)
    if operation.hasPrefix("tunnel") {
      try await fixture.controlPlane.saveOpenAITunnelConfiguration(
        OpenAITunnelConfiguration(
          id: "fixture", tunnelClientProfile: "fixture", tunnelID: "tunnel_fixture",
          gatewayProfile: .chatGPTObserve,
          manifestPath: fixture.directories.manifest.path,
          gatewayExecutablePath: "/tmp/computer-mcp",
          gatewaySocketPath: fixture.directories.gatewaySocket.path))
    }
    let owner = AppGatewayService(
      controlPlane: fixture.controlPlane,
      socketConfiguration: .init(socketURL: fixture.root.appendingPathComponent("gateway.sock")))
    let ownerEpoch = try await owner.startLocalAdministration()
    let identity = GatewaySocketConnectionIdentity(
      trustedPrincipalID: "test-owner", origin: .localCLI)
    let originalProfiles = try fixture.database.profiles()
    bookmarks.arm()
    let pending = Task {
      switch operation {
      case "tools":
        let tools = try await owner.localAdminTools(identity: identity, epoch: ownerEpoch)
        #expect(tools.contains { $0.name == "system.time" })
      case "call", "call-error":
        let result = try await owner.callLocalAdminTool(
          name: operation == "call" ? "system.time" : "fixture.missing",
          arguments: .object([:]), identity: identity, epoch: ownerEpoch)
        #expect(result.objectValue?["isError"] == .bool(operation == "call-error"))
      case "socket":
        let session = try await fixture.controlPlane.makeGatewaySocketSession(
          caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "socket-fixture")
        await session.server.stop()
        await session.shutdown()
      default:
        do {
          _ = try await fixture.controlPlane.doctorOpenAITunnel(profileID: "fixture")
          #expect(operation == "tunnel")
        } catch let error as ChatGPTProfileAuditError where operation == "tunnel-invalid-metadata" {
          #expect(error == .missingReadOnlyAnnotations(["fixture.unannotated"]))
        }
      }
    }
    do {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(5))
      while !bookmarks.entered, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(bookmarks.entered)
      var current = try await fixture.controlPlane.activeConfiguration()
      switch change {
      case "cancel": pending.cancel()
      case "configuration":
        current.server.name = "changed-during-construction"
        _ = try await fixture.controlPlane.activateManifest(
          current.exportedTOML(),
          expectedDigest: try? await fixture.controlPlane.configurationDigest())
      case "project":
        var updated = project
        updated.displayName = "Changed during construction"
        try fixture.database.saveProject(updated)
      case "grant":
        try fixture.database.saveProfile(
          ProfileGrant(id: .chatGPTOperate, allowedCallers: []))
      case "plugin":
        var snapshot = try fixture.database.pluginStoreSnapshot()
        snapshot.revision += 1
        try fixture.database.savePluginStoreSnapshot(
          snapshot, expectedRevision: snapshot.revision - 1)
      default: break
      }
      let profilesBeforeCompletion = try fixture.database.profiles()
      let projectsBeforeCompletion = try fixture.database.projects()
      bookmarks.release()
      switch await pending.result {
      case .success:
        #expect(change == "complete")
      case .failure(let error):
        if change == "cancel" {
          #expect(error is CancellationError)
        } else if change != "complete" {
          #expect(error as? AppControlPlaneServiceError == .gatewayInputsChanged, "\(error)")
        } else {
          Issue.record("Unexpected management failure: \(error)")
        }
      }
      if change != "complete" {
        #expect(try fixture.database.profiles() == profilesBeforeCompletion)
        #expect(try fixture.database.projects() == projectsBeforeCompletion)
      } else {
        #expect(try fixture.database.profiles() == originalProfiles)
      }
      await owner.stopLocalAdministration(epoch: ownerEpoch)
      #expect(bookmarks.opened > 0)
      #expect(bookmarks.closed == bookmarks.opened)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
          .allSatisfy { !$0.hasPrefix("pid-") })
    } catch {
      pending.cancel()
      bookmarks.release()
      _ = await pending.result
      await owner.stopLocalAdministration(epoch: ownerEpoch)
      throw error
    }
  }

  @Test(arguments: ["chatgpt-observe", "custom-editor"])
  func tunnelCatalogListsRequestableWritesAndCallsRequireLiveAuthority(profileName: String)
    async throws
  {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let profileID = try #require(GatewayProfileID(rawValue: profileName))
    let script = fixture.root.appendingPathComponent("catalog.py")
    try Data(Self.gatedCatalogScript.utf8).write(to: script)
    let configuration = GatewayConfiguration(
      profiles: [.init(id: profileID, fullAccess: true, allowedCallers: [.secureTunnel])],
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, fixture.root.path, "catalog"], exposure: .reexport, prefix: "fixture",
          allowAnyTool: true)
      ]), builtin: .init(enabled: ["file.write"]), projectDirectory: fixture.root)
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    try fixture.database.saveProject(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    try await fixture.controlPlane.saveOpenAITunnelConfiguration(
      .init(
        id: "catalog", tunnelClientProfile: "catalog", tunnelID: "tunnel_catalog",
        gatewayProfile: profileID, manifestPath: fixture.directories.manifest.path,
        gatewayExecutablePath: "/tmp/computer-mcp",
        gatewaySocketPath: fixture.directories.gatewaySocket.path))
    _ = try await fixture.controlPlane.doctorOpenAITunnel(profileID: "catalog")
    var socket = GatewaySocketConfiguration(
      socketURL: fixture.root.appendingPathComponent("gateway.sock"))
    let credential = fixture.root.appendingPathComponent("tunnel-credential")
    socket.tunnelCredentialFile = credential
    let service = AppGatewayService(controlPlane: fixture.controlPlane, socketConfiguration: socket)
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.controlPlane, gatewayService: service)
    try await service.start(profile: profileID)
    var authenticated = socket
    authenticated.clientIdentity = .secureTunnel(
      credentialFile: credential, tunnelInstanceID: "catalog-client", tunnelProfileID: "catalog")
    let client = try await GatewayClientSession.connectSocket(configuration: authenticated)
    do {
      let tools = try await client.listTools()
      let write = try #require(tools.first { $0.name == "file.write" })
      #expect(write.readOnlyHint == false)
      let metadata = try #require(
        write.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"])
      let requirement = try JSONDecoder().decode(
        ToolRequirement.self, from: JSONEncoder().encode(metadata))
      #expect(requirement.access == .projectWrite)
      #expect(requirement.paths.contains { $0.operation == .write })
      #expect(!requirement.requiresFullAccess)
      let session = try #require(await operations.controlSessions().first)
      #expect(session.caller == .secureTunnel)
      _ = try await operations.approveControlSession(
        id: session.id, expectedRevision: session.revision)
      let target = JSONValue.object([
        "project_id": .string("fixture"), "path": .string("requested.txt"),
        "content": .string("reviewed"),
      ])
      let pending = try await client.call(toolName: "file.write", arguments: target)
      let requested = try #require(
        pending.result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
      #expect(requested["code"] == .string("permission.required"), "\(pending.result)")
      #expect(requested["request_ids"]?.arrayValue?.isEmpty == false)
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("requested.txt").path))
      _ = try fixture.editProfile(profileID) {
        try $0.permissions.set(.denied, for: .project("fixture"))
      }
      let denied = try await client.call(toolName: "file.write", arguments: target)
      #expect(
        denied.result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]
          == .string("permission.denied"), "\(denied.result)")
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("requested.txt").path))
      _ = try fixture.editProfile(profileID) {
        try $0.permissions.set(.granted(.write), for: .project("fixture"))
        try $0.permissions.set(.granted(.read), for: .mcpServer("fixture"))
      }
      let current = try #require(await operations.controlSessions().first { $0.id == session.id })
      _ = try await operations.approveControlSession(
        id: current.id, expectedRevision: current.revision)
      try Data().write(to: fixture.root.appendingPathComponent("release"))
      let admitted = try await client.call(
        toolName: "mcp.tools.list",
        arguments: .object([
          "project_id": .string("fixture"), "server": .string("fixture"),
        ]))
      #expect(admitted.result.objectValue?["isError"] != .bool(true), "\(admitted.result)")
      #expect(
        admitted.result.objectValue?["structuredContent"]?.objectValue?["result"]?.arrayValue?
          .compactMap { $0.objectValue?["name"]?.stringValue } == ["inspect"], "\(admitted.result)")
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains {
          $0.hasPrefix("pid-")
        })
      await client.disconnect()
      await service.stop()
    } catch {
      await client.disconnect()
      await service.stop()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func admittedCatalogJoinsItsProcessAfterCompletionOrOwnerStop(ownerStop: Bool) async throws {
    let fixture = try AppControlPlaneServiceFixture(executionLauncher: { root in
      fixtureProtocolExecutionLauncher(
        root: root, scripts: [Self.gatedCatalogScript], arguments: [[root.path, "admitted"]])
    })
    defer { fixture.cleanup() }
    let script = fixture.root.appendingPathComponent("catalog.py")
    try Data(Self.gatedCatalogScript.utf8).write(to: script)
    let waiting = fixture.root.appendingPathComponent("waiting")
    let release = fixture.root.appendingPathComponent("release")
    let configuration = GatewayConfiguration(
      profiles: [
        .init(
          id: .chatGPTOperate,
          permissions: fixturePermissions([
            .project("fixture"): .granted(.write), .mcpServer("fixture"): .granted(.all),
          ]), fullAccess: true, allowedCallers: [.localMCP])
      ],
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, fixture.root.path, "admitted"], exposure: .reexport,
          prefix: "fixture", allowAnyTool: true, startupTimeoutMs: 5000, requestTimeoutMs: 5000)
      ]), projectDirectory: fixture.root)
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    try fixture.database.saveProject(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    let service = AppGatewayService(
      controlPlane: fixture.controlPlane,
      socketConfiguration: .init(socketURL: fixture.root.appendingPathComponent("gateway.sock")))
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.controlPlane, gatewayService: service)
    try await service.start(profile: .chatGPTOperate)
    let client = try await GatewayClientSession.connectSocket(
      socketURL: service.socketConfiguration.socketURL)
    let session = try #require(await operations.controlSessions().first)
    _ = try await operations.approveControlSession(
      id: session.id, expectedRevision: session.revision)
    let pending = Task {
      try await client.call(
        toolName: "mcp.tools.list",
        arguments: .object([
          "project_id": .string("fixture"), "server": .string("fixture"),
        ]))
    }
    do {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(5))
      while !FileManager.default.fileExists(atPath: waiting.path), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(FileManager.default.fileExists(atPath: waiting.path))
      #expect(
        try await fixture.controlPlane.activeConfiguration().mcp.servers.first?.id == "fixture")
      #expect(
        !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("expired").path)
      )
      if ownerStop { await service.stop() } else { try Data().write(to: release) }
      switch await pending.result {
      case .success(let report):
        #expect(
          (report.result.objectValue?["isError"] == .bool(true)) == ownerStop,
          "\(report.result)")
      case .failure(let error):
        #expect(ownerStop, "\(error)")
      }
      await client.disconnect()
      await service.stop()
      let pids = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        .filter { $0.hasPrefix("pid-") }.compactMap { Int32($0.dropFirst(4)) }
      #expect(!pids.isEmpty)
      for pid in pids {
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "Owned catalog process \(pid) must be joined")
      }
      #expect(
        !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("expired").path)
      )
    } catch {
      pending.cancel()
      try? Data().write(to: release)
      _ = await pending.result
      await client.disconnect()
      await service.stop()
      throw error
    }
  }

  private static let gatedCatalogScript = #"""
    import json, os, pathlib, sys, time
    root = pathlib.Path(sys.argv[1])
    (root / ("pid-" + str(os.getpid()))).touch()
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if method == "initialize":
            result = {"protocolVersion":"2025-11-25", "capabilities":{"tools":{}}, "serverInfo":{"name":"gated", "version":"1"}}
        elif method == "tools/list":
            (root / "waiting").touch()
            deadline = time.monotonic() + 3
            while not (root / "release").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not (root / "release").exists():
                (root / "expired").touch()
            result = {"tools":[{"name":"inspect", "description":"Inspect fixture", "inputSchema":{"type":"object"}, "annotations":{"readOnlyHint":True}}]}
        elif method == "tools/call":
            result = {"content":[{"type":"text", "text":"fixture"}], "isError":False}
        else:
            continue
        print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":result}), flush=True)
    """#

  @Test
  func rejectedManagementChangesAndProfileSelectionDoNotDiscoverDownstreamTools() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let script = fixture.root.appendingPathComponent("catalog.py")
    try Data(Self.gatedCatalogScript.utf8).write(to: script)
    let configuration = GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, fixture.root.path, "tools"], exposure: .reexport,
          prefix: "fixture", allowAnyTool: true, startupTimeoutMs: 5000)
      ]), projectDirectory: fixture.root)
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    try fixture.database.saveProject(
      ComputerMCPCore.RegisteredProject(
        id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    await #expect(throws: AppControlPlaneServiceError.unknownProject("missing")) {
      _ = try await fixture.setProjectAccess(
        .read, projectID: "missing", profileID: .chatGPTOperate)
    }
    try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
    #expect(try await fixture.controlPlane.activeGatewayProfile() == .chatGPTOperate)
    let owner = AppGatewayService(
      controlPlane: fixture.controlPlane,
      socketConfiguration: .init(socketURL: fixture.root.appendingPathComponent("gateway.sock")))
    let epoch = try await owner.startLocalAdministration()
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      _ = try await owner.localAdminTools(
        identity: .init(trustedPrincipalID: "test-owner", origin: .localCLI), epoch: epoch)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    await owner.stopLocalAdministration(epoch: epoch)
    #expect(try !fixture.database.profiles().isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        .allSatisfy { !$0.hasPrefix("pid-") })
  }

  @Test(arguments: [false, true])
  func providerProbeLeavesControlPlaneResponsiveAndDiscardsObsoleteResults(cancel: Bool)
    async throws
  {
    let probe = GatedProviderDiscovery()
    let started = probe.started.stream()
    let fixture = try AppControlPlaneServiceFixture(providerDiscovery: probe)
    defer { fixture.cleanup() }
    try await fixture.controlPlane.start()
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let refreshing = Task { try await fixture.controlPlane.refreshProviders() }
    do {
      var events = started.makeAsyncIterator()
      _ = await events.next()
      #expect(try await fixture.controlPlane.providerStates().isEmpty)
      #expect(probe.isWaiting)
      if cancel {
        refreshing.cancel()
      } else {
        _ = try await fixture.controlPlane.activateManifest(
          validManifest.replacingOccurrences(
            of: "computer-mcp-test", with: "changed-provider-config"),
          expectedDigest: try? await fixture.controlPlane.configurationDigest())
      }
      probe.release.signal()
      switch await refreshing.result {
      case .success: Issue.record("An obsolete provider probe must not publish its result")
      case .failure(let error):
        if cancel {
          #expect(error is CancellationError)
        } else {
          #expect(error as? AtomicManifestStoreError == .staleDigest)
        }
      }
      #expect(try await fixture.controlPlane.providerStates().isEmpty)
    } catch {
      refreshing.cancel()
      probe.release.signal()
      _ = await refreshing.result
      throw error
    }
  }

  @Test
  func testOfficialPluginSearchCLIUsesSharedServiceAndStructuredFailures() async throws {
    let catalog = ControlPlaneCatalogFake()
    let fixture = try AppControlPlaneServiceFixture(pluginCatalog: catalog)
    defer { fixture.cleanup() }
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let socket = ControlSocketService(
      controlPlane: fixture.controlPlane, gatewayService: gateway,
      socketURL: fixture.directories.controlSocket)
    try await socket.start()
    do {
      let before = try fixture.database.pluginStoreSnapshot()
      let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/computer-mcp")
      let args = [
        "plugins", "search", "工作", "--kind", "mcp", "--page", "2", "--refresh",
        "--control-socket", fixture.directories.controlSocket.path,
      ]
      let success = try fixture.runCLI(
        executable: executable.path, arguments: args,
        workingDirectory: fixture.root, environment: [:], timeoutMilliseconds: 30_000,
        maxOutputBytes: 1_048_576)
      #expect(success.exitCode == 0, "\(success.stderr)")
      let json = try JSONDecoder().decode(JSONValue.self, from: Data(success.stdout.utf8))
      #expect(json.objectValue?["query"] == .string("工作"))
      #expect(json.objectValue?["kind"] == .string("mcp"))
      #expect(json.objectValue?["page"] == .number(2))
      #expect(json.objectValue?["next_page"] == .number(3))
      #expect(json.objectValue?["publisher_id"] == .number(315_005_910))
      #expect(AppControlCapabilityCatalog.all.first { $0.id == "plugin.search" }?.readOnly == true)
      #expect(json.objectValue?["entries"]?.arrayValue?.count == 1)
      #expect(await catalog.refreshRequested)
      await catalog.fail()
      let failure = try fixture.runCLI(
        executable: executable.path, arguments: args,
        workingDirectory: fixture.root, environment: [:], timeoutMilliseconds: 30_000,
        maxOutputBytes: 1_048_576)
      #expect(failure.exitCode != 0)
      let error = try JSONDecoder().decode(JSONValue.self, from: Data(failure.stdout.utf8))
      #expect(
        error.objectValue?["error"]?.objectValue?["code"] == .string("plugin.catalog.rate_limited"))
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      await #expect(throws: ControlSocketCallError.self) {
        try await client.call("plugin.search", arguments: .object(["kind": .string("unknown")]))
      }
      await #expect(throws: ControlSocketCallError.self) {
        try await client.call("plugin.search", arguments: .object(["page": .number(1.5)]))
      }
      #expect(await catalog.calls == 2)
      #expect(try fixture.database.pluginStoreSnapshot() == before)
      let events = try fixture.database.auditEvents(limit: 10).filter {
        $0.capabilityID == "plugin.search"
      }
      #expect(events.contains { $0.decision == .allowed && $0.caller == .localCLI })
      #expect(events.contains { $0.errorCode == "plugin.catalog.rate_limited" })
      await socket.stop()
      await gateway.stop()
    } catch {
      await socket.stop()
      await gateway.stop()
      throw error
    }
  }

  @Test
  func staticCatalogCacheFeedsDefaultAppAndActualCLIWithoutGitHubDiscovery() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let data = try staticCatalogData { root in
      var release = root["releases"]!.arrayValue![0].objectValue!
      var compatibility = release["compatibility"]!.objectValue!
      compatibility["minimum_host"] = .string(ComputerMCPCLI.version)
      release["compatibility"] = .object(compatibility)
      root["releases"] = .array([.object(release)])
    }
    let server = try await CatalogHTTPFixture.start(
      script: """
        import base64, http.server, json, os, threading
        threading.Timer(40, lambda: os._exit(0)).start()
        paths = []
        body = base64.b64decode('\(data.base64EncodedString())')
        class Handler(http.server.BaseHTTPRequestHandler):
          def log_message(self, *args): pass
          def do_GET(self):
            if self.path == '/stats': content = json.dumps(paths).encode()
            else:
              paths.append(self.path)
              content = body
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('ETag', '"fixture-v1"')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """)
    defer { server.stop() }
    let cacheURL = fixture.directories.applicationSupport
      .appendingPathComponent("Cache/PluginCatalog/index.json")
    let publisher = StaticPluginCatalog(
      cacheURL: cacheURL,
      http: StaticPluginCatalogHTTP(
        endpoint: server.origin.appendingPathComponent("plugins/index.json")))
    _ = try await publisher.load()
    let before = try fixture.database.pluginStoreSnapshot()
    let appResult = try await fixture.controlPlane.searchPlugins(
      query: "工具", kind: .mcp, page: 1, refresh: false)
    #expect(appResult.entries.map(\.pluginID) == ["example"])
    #expect(appResult.cached && appResult.catalog?.generation == 1)
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let socket = ControlSocketService(
      controlPlane: fixture.controlPlane, gatewayService: gateway,
      socketURL: fixture.directories.controlSocket)
    try await socket.start()
    do {
      let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/computer-mcp")
      for arguments in [
        ["plugins", "search", "工具", "--kind", "mcp"],
        [
          "plugins", "artifacts", "computer-mcp/plugin-example", "--repository-id", "10", "--tag",
          "v1.0.0",
        ],
      ] {
        let command = try fixture.runCLI(
          executable: executable.path,
          arguments: arguments + ["--control-socket", fixture.directories.controlSocket.path],
          workingDirectory: fixture.root, environment: [:], timeoutMilliseconds: 30_000,
          maxOutputBytes: 1_048_576)
        try #require(command.exitCode == 0, "\(command.stdout) \(command.stderr)")
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(command.stdout.utf8))
        #expect(result.objectValue?["catalog"]?.objectValue?["generation"] == .integer(1))
        #expect(result.objectValue?["catalog"]?.objectValue?["stale"] == .bool(false))
        if arguments[1] == "search" {
          #expect(
            result.objectValue?["entries"]?.arrayValue?.first?.objectValue?["plugin_id"]
              == .string("example"))
        } else {
          #expect(result.objectValue?["artifacts"]?.arrayValue?.count == 1)
          #expect(
            result.objectValue?["versions"]?.arrayValue?.first?.objectValue?["tag"]
              == .string("v1.0.0"))
        }
      }
      let stats = try await StaticPluginCatalogHTTP(
        endpoint: server.origin.appendingPathComponent("stats")
      )
      .fetch(validators: .init())
      #expect(try stats.decode([String].self) == ["/plugins/index.json"])
      #expect(try fixture.database.pluginStoreSnapshot() == before)
      await socket.stop()
      await gateway.stop()
    } catch {
      await socket.stop()
      await gateway.stop()
      throw error
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPUTER_MCP_LIVE_CATALOG_TEST"] == "1"))
  func testOfficialPluginSearchAgainstPublicCatalogFromIsolatedCLI() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let socket = ControlSocketService(
      controlPlane: fixture.controlPlane, gatewayService: gateway,
      socketURL: fixture.directories.controlSocket)
    try await socket.start()
    do {
      let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/computer-mcp")
      let command = try fixture.runCLI(
        executable: executable.path,
        arguments: [
          "plugins", "search", "--refresh", "--control-socket",
          fixture.directories.controlSocket.path,
        ],
        workingDirectory: fixture.root, environment: [:], timeoutMilliseconds: 30_000,
        maxOutputBytes: 1_048_576)
      #expect(
        command.exitCode == 0, "Live official catalog response: \(command.stdout) \(command.stderr)"
      )
      let json = try JSONDecoder().decode(JSONValue.self, from: Data(command.stdout.utf8))
      #expect(json.objectValue?["publisher_id"] == .number(315_005_910))
      #expect(json.objectValue?["cached"] == .bool(false))
      #expect(json.objectValue?["issues"]?.arrayValue?.isEmpty == true)
      print("Live official catalog via isolated CLI: \(command.stdout)")
      #expect(try fixture.database.pluginStoreSnapshot().revision == 0)
      await socket.stop()
      await gateway.stop()
    } catch {
      await socket.stop()
      await gateway.stop()
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_LIVE_PLUGIN_RELEASE_TEST"] == "1"))
  func publishedComputerUseInstallsAndUninstallsThroughIsolatedHost() async throws {
    try await checkPublishedPluginInstallation(
      pluginID: "computer-use", archiveName: "computer-use.zip")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_LIVE_PLUGIN_RELEASE_TEST"] == "1"))
  func publishedSwiftFormatInstallsAndUninstallsThroughIsolatedHost() async throws {
    try await checkPublishedPluginInstallation(
      pluginID: "swift-format", archiveName: "swift-format.zip")
  }

  private func checkPublishedPluginInstallation(
    pluginID: String, archiveName: String
  ) async throws {
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/computer-mcp")
    let fixture = try AppControlPlaneServiceFixture(gatewayExecutablePath: executable.path)
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      GatewayConfiguration(projectDirectory: fixture.root).exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let socket = ControlSocketService(
      controlPlane: fixture.controlPlane, gatewayService: gateway,
      socketURL: fixture.directories.controlSocket)
    try await socket.start()
    do {
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      let search = try await client.call(
        "plugin.search",
        arguments: .object(["query": .string(pluginID), "refresh": .bool(true)]))
      let entry = try #require(
        search.objectValue?["entries"]?.arrayValue?.first {
          $0.objectValue?["repository"] == .string("computer-mcp/plugin-\(pluginID)")
        })
      let repositoryID = try #require(entry.objectValue?["repository_id"])
      let release = try await client.call(
        "plugin.artifacts",
        arguments: .object([
          "repository": .string("computer-mcp/plugin-\(pluginID)"),
          "repository_id": repositoryID,
        ]))
      let artifact = try #require(
        release.objectValue?["artifacts"]?.arrayValue?.first {
          $0.objectValue?["name"] == .string(archiveName)
        })
      _ = try await client.call(
        "plugin.install_release",
        arguments: .object(["artifact": artifact, "expected_revision": .number(0)]))
      let installed = try fixture.database.pluginStoreSnapshot()
      let record = try #require(installed.installations.first { $0.pluginID == pluginID })
      #expect(installed.settings[pluginID]?.enabled == false)
      let provenance = try #require(record.source.githubRelease)
      #expect(record.version == provenance.declaration.version)
      print("Verified official install: \(pluginID) \(provenance.tag) sha256=\(provenance.sha256)")
      #expect(FileManager.default.fileExists(atPath: record.source.root.path))
      _ = try await client.call(
        "plugin.uninstall",
        arguments: .object([
          "installation_id": .string(record.id),
          "expected_revision": .number(Double(installed.revision)),
        ]))
      let removed = try fixture.database.pluginStoreSnapshot()
      #expect(removed.installations.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: record.source.root.path))
      await socket.stop()
      await gateway.stop()
    } catch {
      await socket.stop()
      await gateway.stop()
      throw error
    }
  }

  @Test
  func testPluginControlSocketPreflightsCompositionAndRuntimeLoadsRecordedSettings() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    var configuration = GatewayConfiguration(projectDirectory: fixture.root)
    configuration.cli.commands = [.init(id: "personal", executable: "/bin/echo")]
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let packageRoot = fixture.root.appendingPathComponent("package")
    try FileManager.default.createDirectory(
      at: packageRoot.appendingPathComponent("skills"), withIntermediateDirectories: true)
    try PluginManifestFixture.combined.replacingOccurrences(
      of: "tree = { kind = 'introspection', args = ['schema', '--json'] }\n", with: ""
    )
    .write(
      to: packageRoot.appendingPathComponent(PluginManifest.filename), atomically: true,
      encoding: .utf8)
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    let service = ControlSocketService(
      controlPlane: fixture.controlPlane, gatewayService: gateway,
      socketURL: fixture.directories.controlSocket)
    try await service.start()
    do {
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let executable = repository.appendingPathComponent(".build/debug/computer-mcp")
      #expect(FileManager.default.isExecutableFile(atPath: executable.path))
      let command = try fixture.runCLI(
        executable: executable.path,
        arguments: [
          "plugins", "register", packageRoot.path, "--expected-revision", "0", "--control-socket",
          fixture.directories.controlSocket.path,
        ],
        workingDirectory: fixture.root, environment: [:], timeoutMilliseconds: 15_000,
        maxOutputBytes: 1_048_576)
      #expect(command.exitCode == 0, "\(command.stderr)")
      let registered = try JSONDecoder().decode(JSONValue.self, from: Data(command.stdout.utf8))
      #expect(registered.objectValue?["state"]?.objectValue?["revision"] == .number(1))
      var settings = PluginSettings(
        enabled: true,
        mcp: ["native": .init(enabled: false)],
        cli: ["commands": .init(registrationID: "personal", allowAnyArgs: true)],
        skills: ["guidance": .init(registrationID: "package-skills")],
        dependencyExecutables: ["vendor": "/usr/bin/printf"])
      await #expect(throws: ControlSocketCallError.self) {
        try await client.call(
          "plugin.configure",
          arguments: .object([
            "id": .string("test-package"), "settings": try .encoded(settings),
            "expected_revision": .number(1),
          ]))
      }
      #expect(try fixture.database.pluginStoreSnapshot().revision == 1)
      let stale = try fixture.runCLI(
        executable: executable.path,
        arguments: [
          "plugins", "enable", "test-package", "--expected-revision", "0", "--control-socket",
          fixture.directories.controlSocket.path,
        ],
        workingDirectory: fixture.root, environment: [:], timeoutMilliseconds: 15_000,
        maxOutputBytes: 1_048_576)
      #expect(stale.exitCode != 0)
      #expect(stale.stdout.contains("Reload"))
      settings.cli["commands"]?.registrationID = "package-cli"
      _ = try await client.call(
        "plugin.configure",
        arguments: .object([
          "id": .string("test-package"), "settings": try .encoded(settings),
          "expected_revision": .number(1),
        ]))
      let source = try await fixture.controlPlane.activeConfiguration()
      #expect(source.cli.commands.map(\.id) == ["personal"])
      #expect(source.knownPluginMCPServerIDs.contains("plugin-12-test-package-native"))
      let runtime = try GatewayRuntime(
        configuration: source, database: fixture.database,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher()))
      #expect(runtime.pluginOrigins.count == 2)
      #expect(runtime.pluginDiagnostics.isEmpty && runtime.pluginIssues.isEmpty)
      #expect(
        runtime.pluginOrigins[.init(kind: .cli, id: "package-cli")]?.pluginID == "test-package")
      await runtime.shutdown()
      let inspected = try await client.call(
        "plugin.show", arguments: .object(["id": .string("test-package")]))
      #expect(inspected.objectValue?["contributions"]?.arrayValue?.count == 2)
      let exportedSettings = try #require(
        inspected.objectValue?["state"]?.objectValue?["settings"]?.objectValue?["test-package"])
      #expect(exportedSettings == (try JSONValue.encoded(settings)))
      #expect(
        inspected.objectValue?["effective_settings"]?.objectValue?["test-package"]
          == exportedSettings)
      let settingsFile = fixture.root.appendingPathComponent("settings.json")
      try JSONEncoder().encode(exportedSettings).write(to: settingsFile)
      let configured = try fixture.runCLI(
        executable: executable.path,
        arguments: [
          "plugins", "configure", "test-package", "--settings-file", settingsFile.path,
          "--expected-revision", "2", "--control-socket", fixture.directories.controlSocket.path,
        ],
        workingDirectory: fixture.root, environment: [:], timeoutMilliseconds: 15_000,
        maxOutputBytes: 1_048_576)
      #expect(configured.exitCode == 0, "\(configured.stderr)")
      let configuredReport = try JSONDecoder().decode(
        JSONValue.self, from: Data(configured.stdout.utf8))
      #expect(
        configuredReport.objectValue?["state"]?.objectValue?["settings"]?.objectValue?[
          "test-package"]
          == exportedSettings)
      #expect(try fixture.database.pluginStoreSnapshot().settings["test-package"] == settings)
      _ = try await client.call(
        "plugin.disable",
        arguments: .object(["id": .string("test-package"), "expected_revision": .number(3)]))
      let disabled = try fixture.database.pluginStoreSnapshot()
      #expect(disabled.settings["test-package"]?.enabled == false)
      #expect(
        disabled.settings["test-package"]?.dependencyExecutables == settings.dependencyExecutables)
      let disabledRuntime = try GatewayRuntime(
        configuration: source, database: fixture.database,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher()))
      #expect(disabledRuntime.pluginOrigins.isEmpty)
      await disabledRuntime.shutdown()
      let audit = try #require(
        fixture.database.auditEvents(limit: 50).first {
          $0.capabilityID == "plugin.configure"
        })
      #expect(audit.caller == .localCLI && audit.profileID == .localAdmin)
      await service.stop()
      await gateway.stop()
    } catch {
      await service.stop()
      await gateway.stop()
      throw error
    }
  }

  @Test
  func testPluginChangesPreserveConnectedClientsAndAdmissionRecoversAfterFailure() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      GatewayConfiguration(projectDirectory: fixture.root).exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let gateway = AppGatewayService.live(
      controlPlane: fixture.controlPlane, directories: fixture.directories)
    try await gateway.start(profile: .chatGPTOperate)
    let client = Client(name: "plugin-client", version: "1")
    do {
      let transport = GatewaySocketTransport(
        configuration: .init(
          socketURL: fixture.directories.gatewaySocket, clientIdentity: .localCLI))
      _ = try await client.connect(transport: transport)
      let initial = try await gateway.changePlugins(
        .enabled(pluginID: "test-package", true), expectedRevision: 0)
      #expect(initial.state.revision == 1)
      #expect(try fixture.database.pluginStoreSnapshot().revision == 1)
      try await client.ping()
      await client.disconnect()
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(5))
      while await gateway.snapshot().connectionCount != 0, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await gateway.snapshot().connectionCount == 0)
      await #expect(throws: PluginStoreError.staleRevision(expected: 0, actual: 1)) {
        try await gateway.changePlugins(
          .enabled(pluginID: "test-package", true), expectedRevision: 0)
      }
      let result = try await gateway.changePlugins(
        .enabled(pluginID: "test-package", true), expectedRevision: 1)
      #expect(result.state.revision == 2)
      #expect(result.issues.count == 1)
      let next = Client(name: "plugin-next", version: "1")
      _ = try await next.connect(
        transport: GatewaySocketTransport(
          configuration: .init(
            socketURL: fixture.directories.gatewaySocket, clientIdentity: .localCLI)))
      try await next.ping()
      await next.disconnect()
      await gateway.stop()
    } catch {
      await client.disconnect()
      await gateway.stop()
      throw error
    }
  }

  @Test
  func testPluginMCPGrantCanBeExportedAndReloadedWhileDisabledWithoutCopyingRegistrations()
    async throws
  {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      GatewayConfiguration().exportedTOML(),
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let store = PluginStore(
      database: fixture.database,
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()))
    _ = try await store.setSettings(
      .init(mcp: ["native": .init(registrationID: "plugin-native")]), for: "test-package",
      expectedRevision: 0)
    let text = """
      schema_version = 1
      [[profiles]]
      id = 'chatgpt-operate'
      allowed_callers = ['secure-tunnel']
      [profiles.mcp_servers]
      plugin-native = 'all'
      """
    let standalone = try GatewayConfiguration.load(
      text: text, knownPluginMCPServerIDs: ["plugin-native"])
    #expect(
      standalone.profiles.first?.grant.permissions.state(for: .mcpServer("plugin-native"))
        == .granted(.all))
    _ = try await fixture.controlPlane.activateManifest(
      text, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let exported = try await fixture.controlPlane.effectiveConfigurationForExport().exportedTOML()
    let loaded = try await fixture.controlPlane.parseManifest(exported)
    #expect(loaded.mcp.servers.isEmpty)
    #expect(
      loaded.profiles.first { $0.id == .chatGPTOperate }?.grant.permissions.state(
        for: .mcpServer("plugin-native")) == .granted(.all))
    #expect(!exported.contains("knownPluginMCPServerIDs"))
  }

  @Test
  func testOwnerOnlyControlSocketOperatesTheAppControlPlaneWithoutStartingTransport() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      DefaultGatewayConfiguration.manifest,
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let gatewayService = AppGatewayService.live(
      controlPlane: fixture.controlPlane,
      directories: fixture.directories
    )
    let service = ControlSocketService(
      controlPlane: fixture.controlPlane,
      gatewayService: gatewayService,
      socketURL: fixture.directories.controlSocket
    )
    try await service.start()
    do {
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      let status = try await client.call("app.status")
      #expect(
        status.objectValue?["control_socket"] == .string(fixture.directories.controlSocket.path))
      #expect(
        status.objectValue?["gateway_socket"] == .string(fixture.directories.gatewaySocket.path))
      #expect(fixture.directories.controlSocket != fixture.directories.gatewaySocket)
      #expect(try permissions(at: fixture.directories.controlSocket) == 0o600)
      #expect(status.objectValue?["provider_count"] == .number(6))
      #expect(status.objectValue?["launch_at_login"] == .string("unavailable"))

      let readiness = try await client.call(
        "readiness",
        arguments: .object(["journey": .string("local")])
      )
      #expect(readiness.objectValue?["schema_version"] == .number(1))
      #expect(readiness.objectValue?["journey"] == .string("local"))
      #expect(readiness.objectValue?["status"]?.stringValue?.isEmpty == false)
      #expect(readiness.objectValue?["checks"]?.arrayValue?.isEmpty == false)
      #expect(String(describing: readiness).contains("api_key") == false)

      await expectThrowsAsync(
        try await client.call(
          "readiness",
          arguments: .object(["journey": .string("unsupported")])
        )
      ) { error in
        #expect(error.localizedDescription.contains("local, chatgpt, or cloudflare"))
      }

      let statusAudit = try #require(
        fixture.database.auditEvents(limit: 10).first { $0.capabilityID == "app.status" }
      )
      #expect(statusAudit.caller == .localCLI)
      #expect(statusAudit.profileID == .localAdmin)
      #expect(statusAudit.transport == "control_socket")
      #expect(statusAudit.socketConnectionID?.isEmpty == false)
      #expect(statusAudit.mcpRequestID?.isEmpty == false)
      #expect(statusAudit.inputDigest?.count == 64)
      #expect(statusAudit.outputDigest?.count == 64)

      let addedProject = try await client.call(
        "project.add",
        arguments: .object([
          "path": .string(fixture.root.path),
          "display_name": .string("Validation Project"),
        ])
      )
      #expect(addedProject.objectValue?["id"]?.stringValue?.isEmpty == false)
      #expect(
        addedProject.objectValue?["root_path"]
          == .string(fixture.root.resolvingSymlinksInPath().path)
      )
      #expect(addedProject.objectValue?["bookmark_data"] == nil)
      let projects = try await client.call("project.list")
      let projectSummaries = try #require(projects.objectValue?["result"]?.arrayValue)
      #expect(projectSummaries.count == 1)
      #expect(projectSummaries[0].objectValue?["bookmark_data"] == nil)
      #expect(projectSummaries[0].objectValue?["display_name"] == .string("Validation Project"))
      #expect(
        projectSummaries[0].objectValue?["access"]?.objectValue?["status"] == .string("available")
      )

      let tools = try await client.call("tools.list")
      let listedTools = try #require(tools.objectValue?["tools"]?.arrayValue)
      #expect(listedTools.contains { $0.objectValue?["name"] == .string("project.list") })

      let inspectedTool = try await client.call(
        "tools.inspect",
        arguments: .object(["name": .string("project.list")])
      )
      #expect(inspectedTool.objectValue?["name"] == .string("project.list"))
      #expect(inspectedTool.objectValue?["inputSchema"]?.objectValue?["type"] == .string("object"))

      let toolCall = try await client.call(
        "tools.call",
        arguments: .object([
          "name": .string("project.list"),
          "arguments": .object([:]),
        ])
      )
      #expect(toolCall.objectValue?["isError"] == .bool(false), "\(toolCall)")
      let calledToolExecution = try #require(
        toolCall.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
          .objectValue
      )
      #expect(calledToolExecution["caller"] == .string("local-cli"))
      #expect(calledToolExecution["profile_id"] == .string("local-admin"))
      #expect(calledToolExecution["transport"] == .string("control_socket"))
      let calledToolSocketConnectionID = try #require(
        calledToolExecution["socket_connection_id"]?.stringValue
      )

      let toolAudits = try fixture.database.auditEvents(limit: 50)
      let outerToolCallAudit = try #require(
        toolAudits.first { $0.capabilityID == "tools.call" }
      )
      let innerToolCallAudit = try #require(
        toolAudits.first { $0.capabilityID == "project.list" }
      )
      #expect(outerToolCallAudit.caller == .localCLI)
      #expect(outerToolCallAudit.profileID == .localAdmin)
      #expect(outerToolCallAudit.transport == "control_socket")
      #expect(innerToolCallAudit.caller == .localCLI)
      #expect(innerToolCallAudit.profileID == .localAdmin)
      #expect(innerToolCallAudit.transport == "control_socket")
      #expect(innerToolCallAudit.socketConnectionID == outerToolCallAudit.socketConnectionID)
      #expect(innerToolCallAudit.socketConnectionID == calledToolSocketConnectionID)

      await expectThrowsAsync(
        try await client.call(
          "tools.call",
          arguments: .object([
            "name": .string("project.list"),
            "arguments": .string("{}"),
          ])
        )
      ) { error in
        #expect(error.localizedDescription.contains("arguments"))
        #expect(error.localizedDescription.contains("object"))
      }

      let exported = try await client.call("config.export")
      let toml = try #require(exported.objectValue?["toml"]?.stringValue)
      let preview = try await client.call(
        "config.import",
        arguments: .object([
          "toml": .string(toml),
          "apply": .bool(false),
        ])
      )
      #expect(preview.objectValue?["schema_version"] == .number(1))
      #expect(preview.objectValue?["transport_will_restart"] == .bool(false))
      #expect(preview.objectValue?["applied_revision"] == nil)

      let dormantProfile = OpenAITunnelConfiguration(
        id: "dormant",
        tunnelClientProfile: "computer-mcp",
        tunnelID: "tunnel_dormant",
        manifestPath: fixture.directories.manifest.path,
        gatewayExecutablePath: "/tmp/computer-mcp",
        gatewaySocketPath: fixture.directories.gatewaySocket.path
      )
      try await fixture.controlPlane.saveOpenAITunnelConfiguration(dormantProfile)
      let proposedManifest = """
        schema_version = 1

        [server]
        name = "computer-mcp-imported"
        """
      let changedPreview = try await client.call(
        "config.import",
        arguments: .object([
          "toml": .string(proposedManifest),
          "apply": .bool(false),
        ])
      )
      let expectedCurrentDigest = try #require(
        changedPreview.objectValue?["current_digest"]?.stringValue
      )
      #expect(changedPreview.objectValue?["changed"] == .bool(true))
      #expect(
        changedPreview.objectValue?["diff"]?.objectValue?["changes"]?.arrayValue?.isEmpty
          == false
      )
      let applied = try await client.call(
        "config.import",
        arguments: .object([
          "toml": .string(proposedManifest),
          "apply": .bool(true),
          "expected_current_digest": .string(expectedCurrentDigest),
        ])
      )
      #expect(applied.objectValue?["applied_revision"]?.stringValue?.isEmpty == false)
      #expect(applied.objectValue?["transport_restarted"] == .bool(false))
      #expect(
        try await fixture.controlPlane.activeConfiguration().server.name == "computer-mcp-imported")
      #expect((try await fixture.controlPlane.desiredOpenAITunnelConfigurationIDs()).isEmpty)
      let postImportSnapshot = try await fixture.controlPlane.snapshot()
      #expect(postImportSnapshot.openAITunnelStatuses.isEmpty)
      #expect(postImportSnapshot.cloudflareStatuses.isEmpty)

      await expectThrowsAsync(
        try await client.call(
          "app.status",
          arguments: .object(["deprecated_argument": .bool(true)])
        )
      ) { error in
        #expect(error.localizedDescription.contains("Unknown control argument"))
        #expect(error.localizedDescription.contains("deprecated_argument"))
      }

      await expectThrowsAsync(
        try await client.call(
          "project.access",
          arguments: .object([
            "project_id": .string("project"),
            "profile": .string("chatgpt-observe"),
            "access": .bool(true),
            "expected_profile_revision": .integer(1),
            "expected_permission_revision": .integer(0),
          ])
        )
      ) { error in
        #expect(error.localizedDescription.contains("access"))
        #expect(error.localizedDescription.contains("string"))
      }

      await expectThrowsAsync(
        try await client.call(
          "config.import",
          arguments: .object(["apply": .bool(false)])
        )
      ) { error in
        #expect(error.localizedDescription.contains("Missing required control argument"))
        #expect(error.localizedDescription.contains("toml"))
      }

      await expectThrowsAsync(
        try await client.call(
          "config.import",
          arguments: .object([
            "toml": .string(toml),
            "apply": .bool(true),
          ])
        )
      ) { error in
        #expect(error.localizedDescription.contains("expected_current_digest"))
      }

      let invalidRemoteLocalAdminManifest = """
        schema_version = 1

        [server]
        name = "computer-mcp-invalid-remote-local-admin"

        [runtime]
        caller = "secure-tunnel"
        profile = "local-admin"
        """
      await expectThrowsAsync(
        try await client.call(
          "config.validate",
          arguments: .object(["toml": .string(invalidRemoteLocalAdminManifest)])
        )
      ) { error in
        #expect(error.localizedDescription.contains("policy.local_admin_remote"))
        #expect(error.localizedDescription.contains("local-admin"))
      }

      let controlAudits = try fixture.database.auditEvents(limit: 100)
      let invalidArgumentAudit = try #require(
        controlAudits.first {
          $0.capabilityID == "app.status" && $0.decision == .failed
        }
      )
      #expect(invalidArgumentAudit.errorCode == "control.invalid_arguments")
      #expect(invalidArgumentAudit.mcpRequestID?.isEmpty == false)
      #expect(invalidArgumentAudit.outputDigest?.count == 64)
      let policyAudit = try #require(
        controlAudits.first {
          $0.capabilityID == "config.validate" && $0.decision == .denied
        }
      )
      #expect(policyAudit.errorCode == "policy.local_admin_remote")
      #expect(policyAudit.mcpRequestID?.isEmpty == false)
      #expect(policyAudit.inputDigest?.count == 64)
      #expect(policyAudit.outputDigest?.count == 64)

      try await fixture.controlPlane.saveOpenAITunnelConfiguration(
        OpenAITunnelConfiguration(
          id: "current",
          tunnelClientProfile: "computer-mcp",
          tunnelID: "tunnel_current",
          manifestPath: fixture.directories.manifest.path,
          gatewayExecutablePath: "/tmp/computer-mcp",
          gatewaySocketPath: fixture.directories.gatewaySocket.path
        )
      )
      let tunnels = try await client.call("tunnel.openai.list")
      let profile = try #require(
        tunnels.objectValue?["profiles"]?.arrayValue?.first?.objectValue
      )
      #expect(profile["tunnel_client_profile"] == .string("computer-mcp"))
      #expect(profile["gateway_executable_path"] == .string("computer-mcp"))
      #expect(profile["tunnelClientProfile"] == nil)
      #expect(profile["gatewayExecutablePath"] == nil)
      await service.stop()
    } catch {
      await service.stop()
      throw error
    }
  }

  @Test
  func testControlSocketAndAppAdapterShareLifecycleAwareOperations() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      DefaultGatewayConfiguration.manifest,
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let gatewayService = AppGatewayService.live(
      controlPlane: fixture.controlPlane,
      directories: fixture.directories
    )
    let service = ControlSocketService(
      controlPlane: fixture.controlPlane,
      gatewayService: gatewayService,
      socketURL: fixture.directories.controlSocket
    )
    try await service.start()
    do {
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      let capabilities = try await client.call("app.capabilities")
      let capabilityIDs = Set(
        try #require(capabilities.objectValue?["capabilities"]?.arrayValue).compactMap {
          $0.objectValue?["id"]?.stringValue
        }
      )
      #expect(capabilityIDs == Set(AppControlCapabilityCatalog.all.map(\.id)))
      #expect(
        capabilities.objectValue?["schema_version"] == .number(1)
      )

      let started = try await client.call("app.start")
      #expect(started.objectValue?["state"] == .string("running"))

      let projectURL = fixture.root.appendingPathComponent("Shared Operations")
      try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
      let project = try await client.call(
        "project.add",
        arguments: .object(["path": .string(projectURL.path)])
      )
      let projectID = try #require(project.objectValue?["id"]?.stringValue)
      #expect((await gatewayService.snapshot()).state == .running)

      let activated = try await client.call(
        "profile.activate",
        arguments: .object(["profile": .string(GatewayProfileID.chatGPTOperate.rawValue)])
      )
      #expect(activated.objectValue?["restarted"] == .bool(false))
      #expect(
        try await fixture.controlPlane.activeGatewayProfile() == GatewayProfileID.chatGPTOperate
      )

      let reviewed = try await client.call(
        "profile.show",
        arguments: .object(["profile": .string(GatewayProfileID.chatGPTOperate.rawValue)]))
      let profileRevision = try #require(
        reviewed.objectValue?["authorization_revision"]?.int64Value)
      let permissionRevision = try #require(
        reviewed.objectValue?["permission_revision"]?.int64Value)
      let granted = try await client.call(
        "project.access",
        arguments: .object([
          "project_id": .string(projectID),
          "profile": .string(GatewayProfileID.chatGPTOperate.rawValue),
          "access": .string("read"),
          "expected_profile_revision": .integer(profileRevision),
          "expected_permission_revision": .integer(permissionRevision),
        ])
      )
      let savedGrant = try CanonicalJSONCoding.decoder().decode(
        ProfileGrant.self, from: JSONEncoder().encode(granted))
      #expect(savedGrant.permissions.state(for: .project(projectID)) == .granted(.read))
      #expect((await gatewayService.snapshot()).state == .running)

      let permissions = try await client.call("permissions.status")
      #expect(permissions.objectValue?["accessibility"] != nil)
      #expect(permissions.objectValue?["screen_recording"] != nil)

      let history = try await client.call(
        "config.history",
        arguments: .object(["limit": .number(10)])
      )
      #expect(history.objectValue?["result"]?.arrayValue?.isEmpty == false)

      let audit = try await client.call(
        "audit.list",
        arguments: .object(["limit": .number(50)])
      )
      #expect(audit.objectValue?["result"]?.arrayValue?.isEmpty == false)

      let openAISaved = try await client.call(
        "tunnel.openai.save",
        arguments: .object([
          "id": .string("shared-openai"),
          "tunnel_client_profile": .string("computer-mcp"),
          "tunnel_id": .string("tunnel_shared"),
          "gateway_profile": .string(GatewayProfileID.chatGPTOperate.rawValue),
          "api_key": .string("openai-secret"),
        ])
      )
      #expect(
        openAISaved.objectValue?["configuration"]?.objectValue?["id"]
          == .string("shared-openai")
      )
      #expect(!String(describing: openAISaved).contains("openai-secret"))
      #expect(
        try await fixture.controlPlane.hasOpenAITunnelAPIKey(
          reference: SecretReference(account: "tunnel.shared-openai.openai-api-key")
        )
      )
      _ = try await client.call(
        "tunnel.openai.remove",
        arguments: .object(["id": .string("shared-openai")])
      )

      let cloudflareSaved = try await client.call(
        "tunnel.cloudflare.save",
        arguments: .object([
          "id": .string("shared-cloudflare"),
          "tunnel_name": .string("shared-tunnel"),
          "public_hostname": .string("shared.example.com"),
          "gateway_profile": .string(GatewayProfileID.cloudflareObserve.rawValue),
          "tunnel_token": .string("cloudflare-secret"),
        ])
      )
      #expect(
        cloudflareSaved.objectValue?["profile"]?.objectValue?["id"] == .string("shared-cloudflare"))
      #expect(!String(describing: cloudflareSaved).contains("cloudflare-secret"))
      _ = try await client.call(
        "tunnel.cloudflare.remove",
        arguments: .object(["id": .string("shared-cloudflare")])
      )

      let stopped = try await client.call("app.stop")
      #expect(stopped.objectValue?["state"] == .string("stopped"))
    } catch {
      _ = try? await AppControlPlaneOperations(
        controlPlane: fixture.controlPlane,
        gatewayService: gatewayService
      ).stopGateway()
      await service.stop()
      throw error
    }
    await service.stop()
  }

  @Test
  func testConfigExportPreservesMCPRegistrationGrants() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      """
      schema_version = 1
      [[mcp.servers]]
      id = "fixture-mcp"
      transport = "stdio"
      command = "/bin/cat"
      allow_any_tool = true
      [[profiles]]
      id = "chatgpt-operate"
      allowed_callers = ["secure-tunnel"]
      [profiles.mcp_servers]
      fixture-mcp = "all"
      """, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let exported = try await fixture.controlPlane.effectiveConfigurationForExport()
    let reloaded = try GatewayConfiguration.load(text: exported.exportedTOML())
    let grant = try #require(reloaded.profiles.first { $0.id == .chatGPTOperate })
    #expect(grant.grant.permissions.entries == [.mcpServer("fixture-mcp"): .granted(.all)])
    #expect(reloaded.mcp.servers.first?.allowAnyTool == true)
  }

  @Test
  func testConfigExportIncludesPersistedProjectsAndPermissions() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      """
      schema_version = 1

      [server]
      name = "computer-mcp-export-test"

      [policy]
      shell_enabled = true

      [[projects]]
      id = "manifest-project"
      display_name = "Manifest Project"
      path = "Manifest Project"
      """, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let projectURL = fixture.root.appendingPathComponent("Exported Project")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let project = try await fixture.controlPlane.registerProject(
      at: projectURL,
      displayName: "Exported Project"
    )
    _ = try await fixture.setProjectAccess(
      .read,
      projectID: project.id,
      profileID: .chatGPTOperate
    )
    _ = try fixture.editProfile(.chatGPTOperate) { $0.fullAccess = true }

    let gatewayService = AppGatewayService.live(
      controlPlane: fixture.controlPlane,
      directories: fixture.directories
    )
    let service = ControlSocketService(
      controlPlane: fixture.controlPlane,
      gatewayService: gatewayService,
      socketURL: fixture.directories.controlSocket
    )
    try await service.start()
    do {
      let client = AppControlPlaneServiceClient(socketURL: fixture.directories.controlSocket)
      let shown = try await client.call("config.show")
      let shownTOML = try #require(shown.objectValue?["toml"]?.stringValue)
      let shownConfiguration = try GatewayConfiguration.load(
        text: shownTOML,
        baseURL: fixture.directories.configuration
      )
      #expect(shownConfiguration.projects.map(\.id) == ["manifest-project"])
      #expect(shownConfiguration.profiles.isEmpty)

      let exported = try await client.call("config.export")
      let exportedTOML = try #require(exported.objectValue?["toml"]?.stringValue)
      let exportedConfiguration = try GatewayConfiguration.load(
        text: exportedTOML,
        baseURL: fixture.directories.configuration
      )
      let exportedProject = try #require(
        exportedConfiguration.projects.first { $0.id == project.id }
      )
      #expect(exportedConfiguration.projects.map(\.id) == [project.id])
      #expect(exportedProject.displayName == "Exported Project")
      #expect(exportedProject.path == projectURL.standardizedFileURL.path)
      let exportedGrant = try #require(
        exportedConfiguration.profiles.first { $0.id == .chatGPTOperate }
      )
      #expect(exportedGrant.grant.fullAccess)
      #expect(exportedGrant.grant.permissions.state(for: .project(project.id)) == .granted(.read))

      let preview = try await client.call(
        "config.import",
        arguments: .object([
          "toml": .string(exportedTOML),
          "apply": .bool(false),
        ])
      )
      #expect(preview.objectValue?["ok"] == .bool(true))
      await service.stop()
    } catch {
      await service.stop()
      throw error
    }
  }

  @Test
  func testDirectoriesProfilesProvidersAndLaunchAtLoginComposeThroughFacade() async throws {
    let fixture = try AppControlPlaneServiceFixture(
      gatewayExecutablePath:
        "/Applications/Computer MCP.app/Contents/Resources/computer-mcp"
    )
    defer { fixture.cleanup() }
    try await fixture.controlPlane.start()
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())

    let states = try await fixture.controlPlane.refreshProviders()
    #expect((states.map(\.id)) == (["tunnel-client"]))
    #expect((states.first?.health) == ("ready"))

    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    let profile = OpenAITunnelConfiguration(
      id: "primary",
      tunnelClientProfile: "computer-mcp",
      tunnelID: "tunnel_123",
      manifestPath: fixture.directories.manifest.path,
      gatewayExecutablePath: "/tmp/computer-mcp",
      gatewaySocketPath: fixture.directories.gatewaySocket.path,
      profileDirectory: fixture.directories.tunnelClientProfiles.path,
      apiKeyReference: reference
    )
    try await fixture.controlPlane.saveOpenAITunnelConfiguration(profile)
    try await fixture.controlPlane.setOpenAITunnelAPIKey("secret", reference: reference)

    let hasAPIKey = try await fixture.controlPlane.hasOpenAITunnelAPIKey(reference: reference)
    let profiles = try await fixture.controlPlane.openAITunnelConfigurations()
    let launchState = try await fixture.controlPlane.setLaunchAtLoginEnabled(true)
    #expect(hasAPIKey)
    #expect(profiles.map(\.id) == [profile.id])
    #expect(profiles.first?.apiKeyReference == reference)
    #expect(
      profiles.first?.gatewayExecutablePath
        == "/Applications/Computer MCP.app/Contents/Resources/computer-mcp"
    )
    #expect((launchState) == (.enabled))

    let snapshot = try await fixture.controlPlane.snapshot()
    #expect((snapshot.launchAtLogin) == (.enabled))
    #expect((snapshot.providerStates.map(\.id)) == (["tunnel-client"]))
    #expect(snapshot.openAITunnelConfigurations.map(\.id) == [profile.id])
    #expect(snapshot.configurationRevisionCount >= 2)
    let activeConfiguration = try await fixture.controlPlane.activeConfiguration()
    #expect(activeConfiguration.transports.openAI.map(\.id) == [profile.id])
    for directory in [
      fixture.directories.applicationSupport,
      fixture.directories.logs,
      fixture.directories.configuration,
      fixture.directories.tunnelClientProfiles,
    ] {
      #expect((try permissions(at: directory)) == (0o700))
    }
  }

  @Test
  func testSnapshotDoesNotWaitForLaunchAtLoginSystemService() async throws {
    let controller = BlockingLaunchAtLoginController()
    let fixture = try AppControlPlaneServiceFixture(launchAtLoginController: controller)
    defer {
      controller.resumeStateQuery()
      fixture.cleanup()
    }
    _ = try await fixture.controlPlane.activateManifest(
      DefaultGatewayConfiguration.manifest,
      expectedDigest: try? await fixture.controlPlane.configurationDigest())

    let clock = ContinuousClock()
    let startedAt = clock.now
    let snapshot = try await fixture.controlPlane.snapshot()
    let elapsed = startedAt.duration(to: clock.now)

    #expect(elapsed < .seconds(1))
    #expect(snapshot.launchAtLogin == .unavailable)
    for _ in 0..<100 where !controller.stateQueryStarted {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.stateQueryStarted)
  }

  @Test
  func testUnknownTunnelProfileFailsClosedAndSecretIsNotPersistedInFiles() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())

    do {
      _ = try await fixture.controlPlane.startOpenAITunnel(profileID: "missing")
      Issue.record("Expected unknown tunnel profile.")
    } catch let error as AppControlPlaneServiceError {
      #expect((error) == (.unknownOpenAITunnelConfiguration("missing")))
    }

    let reference = try SecretReference(account: "key")
    try await fixture.controlPlane.setOpenAITunnelAPIKey("never-write-this", reference: reference)
    let files = try FileManager.default.contentsOfDirectory(
      at: fixture.directories.applicationSupport,
      includingPropertiesForKeys: nil
    )
    for file in files where !file.hasDirectoryPath {
      let data = try Data(contentsOf: file)
      #expect(!(String(decoding: data, as: UTF8.self).contains("never-write-this")))
    }
  }

  @Test
  func testDeletingTunnelProfileAlsoDeletesItsKeychainCredential() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let reference = try SecretReference(account: "tunnel.deletable.openai-api-key")
    let profile = OpenAITunnelConfiguration(
      id: "deletable",
      tunnelClientProfile: "computer-mcp",
      tunnelID: "tunnel_delete",
      manifestPath: fixture.directories.manifest.path,
      gatewayExecutablePath: "/tmp/computer-mcp",
      gatewaySocketPath: fixture.directories.gatewaySocket.path,
      apiKeyReference: reference
    )
    try await fixture.controlPlane.setOpenAITunnelAPIKey("secret", reference: reference)
    try await fixture.controlPlane.saveOpenAITunnelConfiguration(profile)
    let credentialExists = try await fixture.controlPlane.hasOpenAITunnelAPIKey(
      reference: reference
    )
    #expect(credentialExists)

    try await fixture.controlPlane.deleteOpenAITunnelConfiguration(id: profile.id)

    let credentialRemains = try await fixture.controlPlane.hasOpenAITunnelAPIKey(
      reference: reference
    )
    let profiles = try await fixture.controlPlane.openAITunnelConfigurations()
    #expect(!(credentialRemains))
    #expect(profiles.isEmpty)
  }

  @Test
  func testOpenAITunnelAPIKeyCheckpointRestoresPreviousOrMissingSecret() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let existingReference = try SecretReference(account: "tunnel.existing")
    try await fixture.controlPlane.setOpenAITunnelAPIKey(
      "old-key",
      reference: existingReference
    )
    let existingCheckpoint = try await fixture.controlPlane.checkpointOpenAITunnelAPIKey(
      reference: existingReference
    )
    try await fixture.controlPlane.setOpenAITunnelAPIKey(
      "new-key",
      reference: existingReference
    )
    try await fixture.controlPlane.restoreOpenAITunnelAPIKey(existingCheckpoint)
    #expect((try fixture.secretStore.value(for: existingReference)) == ("old-key"))

    let missingReference = try SecretReference(account: "tunnel.missing")
    let missingCheckpoint = try await fixture.controlPlane.checkpointOpenAITunnelAPIKey(
      reference: missingReference
    )
    try await fixture.controlPlane.setOpenAITunnelAPIKey(
      "temporary-key",
      reference: missingReference
    )
    try await fixture.controlPlane.restoreOpenAITunnelAPIKey(missingCheckpoint)
    let hasMissingKey = try await fixture.controlPlane.hasOpenAITunnelAPIKey(
      reference: missingReference
    )
    #expect(!(hasMissingKey))
    #expect((try fixture.secretStore.value(for: missingReference)) == nil)
  }

  @Test
  func testKeychainAuthorizationDoesNotBlockControlPlaneSnapshot() async throws {
    let adapter = BlockingControlPlaneKeychainAdapter(secret: "super-secret")
    let fixture = try AppControlPlaneServiceFixture(keychainAdapter: adapter)
    defer {
      adapter.resumeSecretRead()
      fixture.cleanup()
    }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    let credentialTask = Task {
      try await fixture.controlPlane.hasOpenAITunnelAPIKey(reference: reference)
    }

    for _ in 0..<100 where !adapter.secretReadStarted {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(adapter.secretReadStarted)

    let completion = ControlPlaneSnapshotCompletion()
    let snapshotTask = Task {
      let snapshot = try await fixture.controlPlane.snapshot()
      completion.complete(with: snapshot)
      return snapshot
    }
    for _ in 0..<50 where completion.snapshot == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    let snapshotWasResponsive = completion.snapshot

    adapter.resumeSecretRead()
    #expect(try await credentialTask.value)
    _ = try await snapshotTask.value

    #expect(snapshotWasResponsive != nil)
  }

  @Test
  func activeProfileAndFullAccessPersistThroughControlPlane() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
    #expect(try await fixture.controlPlane.activeGatewayProfile() == .chatGPTOperate)
    let saved = try fixture.editProfile(.chatGPTOperate) { $0.fullAccess = true }
    #expect(saved.fullAccess)
    #expect(
      try await fixture.controlPlane.profileGrants().first { $0.id == saved.id }?.fullAccess == true
    )
    #expect(try await fixture.controlPlane.activeConfiguration().policy.shellEnabled == false)
    await #expect(throws: AppControlPlaneServiceError.localAdminCannotBeSocketProfile) {
      try await fixture.controlPlane.setActiveGatewayProfile(.localAdmin)
    }
  }

  @Test
  func projectAccessSupportsAskDenyReadAndWrite() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let projectURL = fixture.root.appendingPathComponent("Granted Project")
    try FileManager.default.createDirectory(
      at: projectURL,
      withIntermediateDirectories: true
    )
    let project = try await fixture.controlPlane.registerProject(at: projectURL)

    var grant = try await fixture.setProjectAccess(
      .read,
      projectID: project.id,
      profileID: .chatGPTOperate
    )
    #expect(grant.permissions.state(for: .project(project.id)) == .granted(.read))
    for _ in 0..<2 {
      grant = try await fixture.setProjectAccess(
        .write, projectID: project.id, profileID: .chatGPTOperate)
      #expect(grant.permissions.state(for: .project(project.id)) == .granted(.write))
    }

    grant = try await fixture.setProjectAccess(
      .deny,
      projectID: project.id,
      profileID: .chatGPTOperate
    )
    #expect(grant.permissions.state(for: .project(project.id)) == .denied)
    grant = try await fixture.setProjectAccess(
      .ask, projectID: project.id, profileID: .chatGPTOperate)
    #expect(grant.permissions.entries[.project(project.id)] == nil)
    #expect(grant.permissions.state(for: .project(project.id)) == .notGranted)

    do {
      _ = try await fixture.setProjectAccess(
        .read,
        projectID: "missing",
        profileID: .chatGPTOperate
      )
      Issue.record("Expected unknown project rejection.")
    } catch let error as AppControlPlaneServiceError {
      #expect((error) == (.unknownProject("missing")))
    }
  }

  @Test(arguments: ["profile", "permission"])
  func projectAccessRejectsEitherStaleReviewedRevision(revision: String) async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let project = try await fixture.controlPlane.registerProject(at: fixture.root)
    let prior = try fixture.permissionControl.view()
    let priorProfile = try #require(prior.profiles.first { $0.id == .chatGPTOperate })
    _ = try await fixture.setProjectAccess(
      .write, projectID: project.id, profileID: .chatGPTOperate)
    let current = try fixture.permissionControl.view()
    let currentProfile = try #require(current.profiles.first { $0.id == .chatGPTOperate })
    await #expect(throws: GatewayPermissionError.revisionConflict) {
      try await fixture.controlPlane.setProjectAccess(
        .deny, projectID: project.id, profileID: .chatGPTOperate,
        expectedProfileRevision: revision == "profile"
          ? priorProfile.authorizationRevision : currentProfile.authorizationRevision,
        expectedPermissionRevision: revision == "permission" ? prior.revision : current.revision)
    }
    let after = try fixture.permissionControl.view()
    #expect(after.revision == current.revision)
    #expect(after.profiles.first { $0.id == .chatGPTOperate } == currentProfile)
  }

  @Test
  func explicitPermissionsRemainAuthoritativeAfterManifestUpdates() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let saved = try fixture.editProfile(.chatGPTObserve) {
      try $0.permissions.set(.denied, for: .screen)
      $0.allowedCallers = [.secureTunnel]
    }
    var configuration = try await fixture.controlPlane.activeConfiguration()
    configuration.server.name = "updated"
    _ = try await fixture.controlPlane.activateManifest(
      configuration.exportedTOML(),
      expectedDigest: try await fixture.controlPlane.configurationDigest())
    let current = try #require(
      try await fixture.controlPlane.profileGrants().first { $0.id == saved.id })
    #expect(current.permissions.entries == saved.permissions.entries)
    #expect(current.allowedCallers == saved.allowedCallers)
    #expect(current.authorizationRevision == saved.authorizationRevision)
  }

  @Test
  func testGatewayAndTunnelDesiredStatePersistsAcrossRuntimeStops() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest + "\n[builtin]\nenabled = ['system.time']\n",
      expectedDigest: try? await fixture.controlPlane.configurationDigest())
    let profile = OpenAITunnelConfiguration(
      id: "recoverable",
      tunnelClientProfile: "computer-mcp",
      tunnelID: "tunnel_recover",
      manifestPath: fixture.directories.manifest.path,
      gatewayExecutablePath: "/tmp/computer-mcp",
      gatewaySocketPath: fixture.directories.gatewaySocket.path
    )
    try await fixture.controlPlane.saveOpenAITunnelConfiguration(profile)

    let initiallyDesiredGateway = try await fixture.controlPlane.gatewayDesiredRunning()
    let initiallyDesiredTunnels = try await fixture.controlPlane
      .desiredOpenAITunnelConfigurationIDs()
    #expect(initiallyDesiredGateway)
    #expect((initiallyDesiredTunnels) == ([]))

    _ = try await fixture.controlPlane.startOpenAITunnel(profileID: profile.id)
    let desiredAfterStart = try await fixture.controlPlane.desiredOpenAITunnelConfigurationIDs()
    #expect((desiredAfterStart) == ([profile.id]))

    try await fixture.controlPlane.stop()
    let desiredAfterRuntimeStop = try await fixture.controlPlane
      .desiredOpenAITunnelConfigurationIDs()
    #expect((desiredAfterRuntimeStop) == ([profile.id]))

    _ = try await fixture.controlPlane.suspendOpenAITunnel(profileID: profile.id)
    let desiredAfterSuspension = try await fixture.controlPlane
      .desiredOpenAITunnelConfigurationIDs()
    #expect((desiredAfterSuspension) == ([profile.id]))

    _ = try await fixture.controlPlane.stopOpenAITunnel(profileID: profile.id)
    let desiredAfterExplicitStop = try await fixture.controlPlane
      .desiredOpenAITunnelConfigurationIDs()
    #expect((desiredAfterExplicitStop) == ([]))

    try await fixture.controlPlane.setGatewayDesiredRunning(false)
    let gatewayDesiredAfterStop = try await fixture.controlPlane.gatewayDesiredRunning()
    #expect(!(gatewayDesiredAfterStop))
  }

  @Test
  func testOperateTunnelRefusesAnEmptyCapabilitySurface() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    _ = try fixture.editProfile(.chatGPTOperate) { $0.allowedCallers = [] }
    let profile = OpenAITunnelConfiguration(
      id: "empty-operate",
      tunnelClientProfile: "computer-mcp",
      tunnelID: "tunnel_empty",
      gatewayProfile: .chatGPTOperate,
      manifestPath: fixture.directories.manifest.path,
      gatewayExecutablePath: "/tmp/computer-mcp",
      gatewaySocketPath: fixture.directories.gatewaySocket.path
    )
    try await fixture.controlPlane.saveOpenAITunnelConfiguration(profile)

    do {
      _ = try await fixture.controlPlane.startOpenAITunnel(profileID: profile.id)
      Issue.record("Expected an empty Tunnel surface to be rejected.")
    } catch let error as ChatGPTProfileAuditError {
      #expect((error) == (.noTools))
    }
  }

  @Test
  func testAppGatewayServiceRoundTripsThroughOfficialMCPClient() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let projectURL = fixture.root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(
      at: projectURL,
      withIntermediateDirectories: true
    )
    try fixture.database.saveProject(
      ComputerMCPCore.RegisteredProject(
        id: "project-1",
        displayName: "Project",
        rootPath: projectURL.path
      )
    )
    _ = try await fixture.controlPlane.activateManifest(
      """
      schema_version = 1

      [server]
      name = "computer-mcp-gateway-test"

      [runtime]
      caller = "secure-tunnel"
      profile = "chatgpt-observe"

      [builtin]
      enabled = ["system.time"]
      """, expectedDigest: try? await fixture.controlPlane.configurationDigest())

    _ = try fixture.editProfile(.chatGPTObserve) { $0.allowedCallers.insert(.localMCP) }

    let socketURL = URL(
      fileURLWithPath: "/tmp/cm-\(UUID().uuidString.prefix(8))/gateway.sock"
    )
    var socketConfiguration = GatewaySocketConfiguration(socketURL: socketURL)
    socketConfiguration.tunnelCredentialFile = URL(
      fileURLWithPath: socketURL.path + ".openai-tunnel-auth"
    )
    let service = AppGatewayService(
      controlPlane: fixture.controlPlane,
      socketConfiguration: socketConfiguration
    )
    try await service.start()
    defer {
      Task {
        await service.stop()
      }
    }

    let transport = GatewaySocketTransport(
      configuration: service.socketConfiguration
    )
    let client = Client(name: "gateway-service-test", version: "1")
    let initialization = try await client.connect(transport: transport)
    #expect((initialization.serverInfo.name) == ("computer-mcp-gateway-test"))

    let (tools, _) = try await client.listTools()
    #expect(tools.map(\.name).contains("system.time"))
    let result = try await client.callTool(name: "system.time")
    #expect((result.isError) != (true))
    #expect(!(result.content.isEmpty))

    await client.disconnect()
    let catalog = try await GatewaySocketCatalogInspector().inspect(
      socketURL: service.socketConfiguration.socketURL,
      generatedAt: Date(timeIntervalSince1970: 0)
    )
    #expect((catalog.generatedAt) == ("1970-01-01T00:00:00Z"))
    #expect((catalog.serverName) == ("computer-mcp-gateway-test"))
    #expect(catalog.toolNames.contains("system.time"))
    #expect((catalog.toolNames) == (catalog.toolNames.sorted()))

    let call = try await GatewayCallInspector().callSocket(
      socketURL: service.socketConfiguration.socketURL,
      toolName: "system.time",
      generatedAt: Date(timeIntervalSince1970: 0)
    )
    #expect((call.generatedAt) == ("1970-01-01T00:00:00Z"))
    #expect((call.transport) == ("gateway_socket"))
    #expect((call.serverName) == ("computer-mcp-gateway-test"))
    #expect((call.toolName) == ("system.time"))
    #expect(!(call.requestID.isEmpty))
    #expect((call.result.objectValue?["isError"]) == (.bool(false)))
    #expect(
      (call.result.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]) != nil)

    let session = try await GatewayClientSession.connectSocket(
      socketURL: service.socketConfiguration.socketURL
    )
    let firstSessionCall = try await session.call(toolName: "system.time")
    let secondSessionCall = try await session.call(toolName: "system.time")
    #expect((firstSessionCall.requestID) != (secondSessionCall.requestID))
    #expect((firstSessionCall.serverName) == ("computer-mcp-gateway-test"))
    #expect((secondSessionCall.serverName) == ("computer-mcp-gateway-test"))
    await session.disconnect()

    let credentialFile = try #require(service.socketConfiguration.tunnelCredentialFile)
    var tunnelConfiguration = service.socketConfiguration
    tunnelConfiguration.clientIdentity = .secureTunnel(
      credentialFile: credentialFile,
      tunnelInstanceID: "gateway-test-tunnel-instance",
      tunnelProfileID: "gateway-test-tunnel"
    )
    let tunnelSession = try await GatewayClientSession.connectSocket(
      configuration: tunnelConfiguration
    )
    let tunnelCall = try await tunnelSession.call(toolName: "system.time")
    let tunnelExecution = try #require(
      tunnelCall.result.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
        .objectValue
    )
    #expect((tunnelExecution["caller"]) == (.string("secure-tunnel")))
    #expect((tunnelExecution["transport"]) == (.string("gateway_socket")))
    #expect((tunnelExecution["socket_connection_id"]?.stringValue) != nil)
    #expect((tunnelExecution["tunnel_instance_id"]) == (.string("gateway-test-tunnel-instance")))
    #expect((tunnelExecution["tunnel_profile_id"]) == (.string("gateway-test-tunnel")))

    let rejectedCall = try await tunnelSession.call(toolName: "not.a.real.tool")
    #expect((rejectedCall.result.objectValue?["isError"]) == (.bool(true)))
    let rejectedExecution = try #require(
      rejectedCall.result.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
        .objectValue
    )
    let rejectedRequestID = try #require(rejectedExecution["request_id"]?.stringValue)
    let rejectedAudit = try #require(
      try fixture.database.auditEvent(requestID: rejectedRequestID)
    )
    #expect((rejectedAudit.capabilityID) == ("not.a.real.tool"))
    #expect((rejectedAudit.decision) == (.failed))
    #expect((rejectedAudit.errorCode) == ("gateway.tool_unknown"))
    #expect((rejectedAudit.mcpRequestID) == (rejectedCall.requestID))
    await tunnelSession.disconnect()

    let audits = try fixture.database.auditEvents(limit: 100)
      .filter { $0.capabilityID == "system.time" }
    #expect(audits.contains { $0.caller == .localMCP })
    let secureAudit = try #require(audits.first { $0.caller == .secureTunnel })
    #expect((secureAudit.transport) == ("gateway_socket"))
    #expect(
      (secureAudit.socketConnectionID) == (tunnelExecution["socket_connection_id"]?.stringValue))
    #expect((secureAudit.tunnelInstanceID) == ("gateway-test-tunnel-instance"))
    #expect((secureAudit.tunnelProfileID) == ("gateway-test-tunnel"))
    #expect((secureAudit.mcpRequestID) == (tunnelCall.requestID))
    #expect((secureAudit.outputDigest?.count) == (64))
    let resultEncoder = JSONEncoder()
    resultEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let expectedOutputDigest = SHA256.hash(data: try resultEncoder.encode(tunnelCall.result))
      .map { String(format: "%02x", $0) }
      .joined()
    #expect((secureAudit.outputDigest) == (expectedOutputDigest))

    await service.stop()
    let snapshot = await service.snapshot()
    #expect((snapshot.state) == (.stopped))
    #expect(
      !(FileManager.default.fileExists(
        atPath: service.socketConfiguration.socketURL.path
      )))
  }

  @Test
  func freshInstallListsOnboardingAndRequestableToolsBeforeProjectRegistration()
    async throws
  {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      validManifest, expectedDigest: try? await fixture.controlPlane.configurationDigest())
    _ = try fixture.editProfile(.chatGPTObserve) { $0.allowedCallers.insert(.localMCP) }
    let socketURL = URL(
      fileURLWithPath: "/tmp/cm-\(UUID().uuidString.prefix(8))/gateway.sock"
    )
    let service = AppGatewayService(
      controlPlane: fixture.controlPlane,
      socketConfiguration: GatewaySocketConfiguration(socketURL: socketURL)
    )
    try await service.start()
    defer {
      Task {
        await service.stop()
      }
    }

    let client = Client(name: "fresh-install-test", version: "1")
    let initialization = try await client.connect(
      transport: GatewaySocketTransport(configuration: service.socketConfiguration)
    )
    #expect((initialization.serverInfo.name) == ("computer-mcp-test"))

    let (tools, _) = try await client.listTools()
    let onboarding: Set<String> = [
      "project.list", "project.describe", "profile.show", "plugin.list", "plugin.describe",
      "plugin.search", "plugin.artifacts",
    ]
    #expect(onboarding.isSubset(of: Set(tools.map(\.name))))
    let requestable = try #require(tools.first { $0.name == "computer.keyboard.text" })
    let metadata = try #require(
      GatewaySocketCatalogTool(tool: requestable).meta?.objectValue?["computer_mcp"]?
        .objectValue?["requirements"])
    let requirement = try JSONDecoder().decode(
      ToolRequirement.self, from: JSONEncoder().encode(metadata))
    #expect(requirement.permissions.contains { $0.permission == .desktopControl })
    let privacyRequest: RequestContext<CallTool.Result> = try await client.callTool(
      name: requestable.name, arguments: ["text": .string("Unadmitted input")])
    let privacy = try await privacyRequest.value
    let privacyEnvelope = try JSONValue.sdkToolResult(
      content: privacy.content, structuredContent: privacy.structuredContent,
      isError: privacy.isError, meta: privacy._meta)
    #expect(
      privacyEnvelope.objectValue?["structuredContent"]?.objectValue?["error"]?
        .objectValue?["code"] == .string("permission.required"), "\(privacyEnvelope)")
    let result = try await client.callTool(name: "project.list")
    #expect((result.isError) != (true))
    let text = try #require(
      result.content.compactMap { content -> String? in
        guard case .text(let text, _, _) = content else {
          return nil
        }
        return text
      }.first
    )
    let payload = try #require(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    )
    #expect(((payload["projects"] as? [Any])?.count) == (0))

    await client.disconnect()
    await service.stop()
    #expect(!(FileManager.default.fileExists(atPath: socketURL.path)))
  }

  @Test
  func testProjectRegistrationIsIdempotentAcrossCanonicalAliases() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let projectURL = fixture.root.appendingPathComponent("Canonical Project")
    let aliasURL = fixture.root.appendingPathComponent("Project Alias")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: projectURL)

    let first = try await fixture.controlPlane.registerProject(
      at: projectURL,
      displayName: "Canonical Project"
    )
    let second = try await fixture.controlPlane.registerProject(
      at: projectURL,
      displayName: "Canonical Project"
    )
    let alias = try await fixture.controlPlane.registerProject(
      at: aliasURL,
      displayName: "Canonical Project"
    )

    #expect(second.id == first.id)
    #expect(alias.id == first.id)
    let registered = try await fixture.controlPlane.projects()
    #expect(registered.count == 1)
    #expect(registered.first?.id == first.id)
    #expect(registered.first?.rootPath == first.rootPath)
    #expect(first.rootPath == projectURL.resolvingSymlinksInPath().path)
  }

  @Test
  func testProjectRegistrationRejectsConflictingExplicitMetadata() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let projectURL = fixture.root.appendingPathComponent("Metadata Project")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let first = try await fixture.controlPlane.registerProject(
      at: projectURL,
      displayName: "Stable Name"
    )

    do {
      _ = try await fixture.controlPlane.registerProject(
        at: projectURL,
        displayName: "Conflicting Name"
      )
      Issue.record("Expected duplicate canonical-root metadata to be rejected")
    } catch let error as AppControlPlaneServiceError {
      #expect(
        error
          == .projectMetadataConflict(
            projectID: first.id,
            existingDisplayName: "Stable Name",
            requestedDisplayName: "Conflicting Name"
          ))
    }

    let registered = try await fixture.controlPlane.projects()
    #expect(registered.count == 1)
    #expect(registered.first?.id == first.id)
    #expect(registered.first?.displayName == "Stable Name")
  }

  @Test
  func testRemovingProjectAliasRemovesCanonicalProfileReference() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let canonical = ComputerMCPCore.RegisteredProject(
      id: "project-canonical",
      displayName: "Shared Project",
      rootPath: fixture.root.appendingPathComponent("Shared Project").path,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let duplicate = ComputerMCPCore.RegisteredProject(
      id: "project-duplicate",
      displayName: canonical.displayName,
      rootPath: canonical.rootPath,
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    try fixture.database.saveProject(canonical)
    try fixture.database.saveProject(duplicate)
    var profile = ProfileGrant.operate
    try profile.permissions.set(.granted(.write), for: .project(duplicate.id))
    try fixture.database.saveProfile(profile)
    let plan = try await fixture.controlPlane.projectDeduplicationPlan()
    _ = try await fixture.controlPlane.applyProjectDeduplication(
      expectedPlanDigest: plan.planDigest,
      allowMetadataConflicts: false
    )

    try await fixture.controlPlane.removeProject(id: duplicate.id)

    #expect(try fixture.database.projects().isEmpty)
    #expect(try fixture.database.project(id: canonical.id) == nil)
    #expect(try fixture.database.project(id: duplicate.id) == nil)
    #expect(
      try fixture.database.profiles().first { $0.id == profile.id }?.permissions.entries[
        .project(canonical.id)] == nil)
  }

  private var validManifest: String {
    """
    schema_version = 1

    [server]
    name = "computer-mcp-test"
    """
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }
}

private final class AppControlPlaneServiceFixture: @unchecked Sendable {
  let root: URL
  let directories: AppControlPlaneServiceDirectories
  let database: GatewayDatabase
  let secretStore: KeychainSecretStore
  let controlPlane: AppControlPlaneService
  let permissionGateway: GatewayPermissionService
  let permissionControl: PermissionControlService

  init(
    keychainAdapter: (any KeychainAdapter)? = nil,
    launchAtLoginController: any LaunchAtLoginControlling = MemoryLaunchAtLoginController(),
    computerUsePermissionReader: any ComputerUsePermissionReading =
      FixedComputerUsePermissionReader(),
    gatewayExecutablePath: String = "computer-mcp",
    pluginCatalog: (any PluginCatalogBrowsing)? = nil,
    providerDiscovery: any ControlPlaneProviderDiscovering = TestProviderDiscovery(),
    initialManifest: String? = nil,
    executionLauncher: ((URL) -> ExecutionLauncher)? = nil,
    projectBookmarks: (any ProjectBookmarkServicing)? = nil,
    invalidCatalogMetadata: Bool = false
  ) throws {
    root = URL(
      fileURLWithPath: "/private/tmp/cm-cp-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("Application Support/Computer MCP"),
      logs: root.appendingPathComponent("Logs/Computer MCP")
    )
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    try directories.secureDatabaseFiles()
    _ = database.permissionStore(counter: TestAuthorizationEpochCounter())
    let launcher = executionLauncher?(root) ?? testExecutionLauncher()
    let native = MacOSPlatform.services(launcher: launcher)
    let platform = PlatformServices(
      launcher: launcher, projectGrants: projectBookmarks ?? native.projectGrants,
      pluginDirectories: native.pluginDirectories, applications: native.applications,
      toolProviders: invalidCatalogMetadata
        ? UnannotatedCatalogProviderFactory(base: native.toolProviders) : native.toolProviders,
      managementToolNames: native.managementToolNames,
      executableSearchDirectories: native.executableSearchDirectories,
      gitExecutable: native.gitExecutable, fileChanges: native.fileChanges,
      permissionPolicyReader: TestManagedPolicyReader(), executionProxy: native.executionProxy)
    if let initialManifest {
      _ = try database.activatePermissionMigration(
        manifest: initialManifest, baseURL: directories.configuration,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications)
    } else {
      try database.bootstrapPermissionProfiles(
        GatewayProfileID.builtIns.map { GatewayConfiguration().profileGrant(for: $0) },
        declarations: [])
    }
    permissionGateway = try database.permissionRuntime(platform: platform).service
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "fixture-owner"),
      validate: {})
    permissionControl = PermissionControlService(service: permissionGateway, owner: { owner })

    if let initialManifest {
      let data = Data(initialManifest.utf8)
      try data.write(to: directories.manifest)
      try database.saveConfigurationRevision(
        ConfigurationRevision(
          digest: try AtomicManifestStore.digest(of: data), manifest: initialManifest))
    }
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest,
      database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    secretStore = try KeychainSecretStore(adapter: keychainAdapter ?? MemoryKeychainAdapter())
    let openAITunnelSupervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
        .executableSearchDirectories,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: TestOpenAITunnelProcessManager()
    )
    controlPlane = AppControlPlaneService(
      directories: directories,
      database: database,
      permissionControl: permissionControl,
      manifestStore: manifestStore,
      defaultManifest: DefaultGatewayConfiguration.manifest,
      secretStore: secretStore,
      openAITunnelSupervisor: openAITunnelSupervisor,
      gatewayExecutablePath: gatewayExecutablePath,
      providerDiscovery: providerDiscovery,
      launchAtLoginController: launchAtLoginController,
      computerUsePermissionReader: computerUsePermissionReader,
      platform: platform,
      pluginCatalog: pluginCatalog
    )
  }

  func runCLI(
    executable: String, arguments: [String], workingDirectory: URL,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let expected = repository.appendingPathComponent(".build/debug/computer-mcp")
      .standardizedFileURL
    guard URL(fileURLWithPath: executable).standardizedFileURL == expected else {
      throw CocoaError(.fileReadNoPermission)
    }
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try ExecutionEnvironment(fullAccessVariables: ["PATH": "/usr/bin:/bin"]))
    return try ExecutionAdministration.$current.withValue(administration) {
      try ProcessCommandRunner(launcher: testExecutionLauncher()).run(
        executable: executable, arguments: arguments, workingDirectory: workingDirectory,
        environment: environment, timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes)
    }
  }

  func setProjectAccess(
    _ access: ProjectAccess, projectID: String, profileID: GatewayProfileID
  ) async throws -> ProfileGrant {
    let review = try permissionControl.view()
    let profile = try #require(review.profiles.first { $0.id == profileID })
    return try await controlPlane.setProjectAccess(
      access, projectID: projectID, profileID: profileID,
      expectedProfileRevision: profile.authorizationRevision,
      expectedPermissionRevision: review.revision)
  }

  func editProfile(_ id: GatewayProfileID, edit: (inout ProfileGrant) throws -> Void) throws
    -> ProfileGrant
  {
    let view = try permissionControl.view()
    guard var grant = view.profiles.first(where: { $0.id == id }) else {
      throw GatewayPermissionError.unknownProfile
    }
    try edit(&grant)
    try permissionControl.updateProfile(
      grant, expectedProfileRevision: grant.authorizationRevision, expectedRevision: view.revision)
    return try permissionControl.view().profiles.first { $0.id == id }!
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor ControlPlaneCatalogFake: PluginCatalogBrowsing {
  func artifacts(repository: String, repositoryID: Int64, tag: String?, page: Int) async throws
    -> GitHubPluginReleaseArtifacts
  {
    throw PluginCatalogError.httpStatus(404)
  }
  private var failing = false
  private(set) var refreshRequested = false
  private(set) var calls = 0
  func fail() { failing = true }
  func search(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async throws
    -> PluginCatalogSearchResult
  {
    calls += 1
    refreshRequested = refresh
    if failing { throw PluginCatalogError.rateLimited(retryAfterSeconds: 60) }
    return PluginCatalogSearchResult(
      publisher: "computer-mcp", publisherID: 315_005_910, query: query, kind: kind, page: page,
      nextPage: page + 1, checkedRepositories: 1,
      fetchedAt: Date(timeIntervalSince1970: 1_788_846_000),
      cached: false,
      entries: [
        PluginCatalogEntry(
          repositoryID: 1234, repository: "computer-mcp/fixture", publisherID: 315_005_910,
          revision: String(repeating: "a", count: 40),
          manifestBlobSHA: String(repeating: "b", count: 40),
          manifestSHA256: String(repeating: "c", count: 64), pluginID: "fixture",
          name: "工作 fixture",
          version: try PluginVersion("1.0.0"), summary: nil, mcp: ["native"], cli: [], skills: [])
      ], issues: [])
  }
}

private final class BlockingLaunchAtLoginController: LaunchAtLoginControlling,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let resumeSemaphore = DispatchSemaphore(value: 0)
  private var started = false
  private var resumed = false

  var stateQueryStarted: Bool {
    lock.withLock { started }
  }

  func resumeStateQuery() {
    let shouldSignal = lock.withLock {
      guard !resumed else {
        return false
      }
      resumed = true
      return true
    }
    if shouldSignal {
      resumeSemaphore.signal()
    }
  }

  func state() -> LaunchAtLoginState {
    lock.withLock {
      started = true
    }
    _ = resumeSemaphore.wait(timeout: .now() + 5)
    return .disabled
  }

  func setEnabled(_ enabled: Bool) throws {}
}

private final class BlockingControlPlaneKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  private let secret: Data
  private let lock = NSLock()
  private let resumeSemaphore = DispatchSemaphore(value: 0)
  private var started = false
  private var resumed = false

  init(secret: String) {
    self.secret = Data(secret.utf8)
  }

  var secretReadStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started
  }

  func resumeSecretRead() {
    lock.lock()
    guard !resumed else {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    resumeSemaphore.signal()
  }

  func set(service: String, account: String, data: Data) throws {}

  func get(service: String, account: String) throws -> Data? {
    lock.lock()
    started = true
    lock.unlock()
    _ = resumeSemaphore.wait(timeout: .now() + 5)
    return secret
  }

  func delete(service: String, account: String) throws {}
}

private final class ControlPlaneSnapshotCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var completedSnapshot: AppControlPlaneServiceSnapshot?

  var snapshot: AppControlPlaneServiceSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return completedSnapshot
  }

  func complete(with snapshot: AppControlPlaneServiceSnapshot) {
    lock.lock()
    completedSnapshot = snapshot
    lock.unlock()
  }
}

private struct TestProviderDiscovery: ControlPlaneProviderDiscovering {
  func discover(configuration: GatewayConfiguration) throws
    -> [ExternalProviderDiscoveryResult]
  {
    [
      ExternalProviderDiscoveryResult(
        providerID: "tunnel-client",
        kind: .tunnelClient,
        resolvedPath: "/fake/tunnel-client",
        launchArguments: [],
        version: "1.0",
        doctorStatus: ExternalProviderDoctorStatus(
          state: .notApplicable,
          message: "ready"
        ),
        diagnostics: []
      )
    ]
  }
}

private final class GatedProviderDiscovery: ControlPlaneProviderDiscovering, @unchecked Sendable {
  let started = GatewayToolChangeBroadcaster()
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var waiting = false
  var isWaiting: Bool { lock.withLock { waiting } }

  func discover(configuration: GatewayConfiguration) throws -> [ExternalProviderDiscoveryResult] {
    lock.withLock { waiting = true }
    started.send()
    _ = release.wait(timeout: .now() + .seconds(5))
    lock.withLock { waiting = false }
    return try TestProviderDiscovery().discover(configuration: configuration)
  }
}

private final class MemoryLaunchAtLoginController: LaunchAtLoginControlling, @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = false

  func state() -> LaunchAtLoginState {
    lock.lock()
    defer { lock.unlock() }
    return enabled ? .enabled : .disabled
  }

  func setEnabled(_ enabled: Bool) throws {
    lock.lock()
    self.enabled = enabled
    lock.unlock()
  }
}

private final class GatedConstructionBookmarkService: ProjectBookmarkServicing, @unchecked Sendable
{
  private let condition = NSCondition()
  private let base = ProjectBookmarkService()
  private var armed = false
  private var isEntered = false
  private var isReleased = false
  private var openCount = 0
  private var closeCount = 0

  var entered: Bool { condition.withLock { isEntered } }
  var opened: Int { condition.withLock { openCount } }
  var closed: Int { condition.withLock { closeCount } }

  func arm() { condition.withLock { armed = true } }
  func release() {
    condition.withLock {
      isReleased = true
      condition.broadcast()
    }
  }

  func registerFolder(at url: URL, displayName: String?) throws -> ComputerMCPCore.RegisteredProject
  {
    try base.registerFolder(at: url, displayName: displayName)
  }

  func resolve(_ project: ComputerMCPCore.RegisteredProject) throws -> ResolvedProjectAccess {
    condition.lock()
    if armed && !isEntered {
      isEntered = true
      condition.broadcast()
      let deadline = Date().addingTimeInterval(5)
      while !isReleased && condition.wait(until: deadline) {}
    }
    condition.unlock()
    let access = try base.resolve(project)
    condition.withLock { openCount += 1 }
    return try ResolvedProjectAccess(
      project: access.project, rootURL: access.rootURL,
      bookmarkWasRefreshed: access.bookmarkWasRefreshed,
      stopAccessing: {
        access.close()
        self.condition.withLock { self.closeCount += 1 }
      })
  }
}

private struct UnannotatedCatalogProviderFactory: GatewayToolProviderFactory {
  let base: any GatewayToolProviderFactory
  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    let registry = base.makeProviders(
      configuration: configuration, commandRunner: commandRunner, processManager: processManager,
      shellManager: shellManager, mcpClient: mcpClient, hostContext: hostContext)
    return GatewayToolRegistry(
      providers: { try registry.providers() + [UnannotatedCatalogProvider()] },
      refreshInterval: registry.refreshInterval, downstreamPolicy: registry.downstreamPolicy,
      shutdown: { await registry.shutdown() })
  }
}

private struct UnannotatedCatalogProvider: GatewayToolProvider {
  let id = "fixture-metadata"
  func definitions() throws -> [ToolDefinition] {
    [
      .init(
        tool: .init(
          name: "fixture.unannotated", description: "Metadata fixture",
          inputSchema: .object(["type": .string("object")])),
        capability: .init(id: "fixture.unannotated", risk: .readOnly, requirement: .none))
    ]
  }
  func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    throw GatewayToolError.unknownTool(invocation.name)
  }
}
