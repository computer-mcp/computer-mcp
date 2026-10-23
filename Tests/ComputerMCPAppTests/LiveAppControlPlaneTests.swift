import ComputerMCPMacOS
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPTransport
import ComputerMCPTunnels
import Darwin
import Foundation
import Testing

@testable import ComputerMCPApp
@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@MainActor
@Suite(.serialized)
final class LiveAppControlPlaneTests {
  @Test
  func tunnelEditorPassesItsOpenedDigestThroughToTheControlPlane() async throws {
    try await withAppControlPlaneFixture { fixture in
      var initial = CloudflareEditorPresentation.new.draft
      initial.tunnelName = "named"
      initial.publicHostname = "gateway.example"
      initial.cloudflaredPath = "/tools/cloudflared"
      initial.tunnelToken = "synthetic-tunnel"
      initial.oauthEnabled = true
      initial.oauthClientAllowlist = ["client.example", "second.example"]
      #expect(initial.expectedTunnelDigest == nil)
      _ = try await fixture.app.saveCloudflareTunnelConfiguration(initial)

      let summary = try #require(try await fixture.app.fetchCloudflareTunnels().first)
      let profile = try #require(
        try await fixture.controlPlane.cloudflareTunnelConfigurations().first)
      #expect(try summary.configurationDigest == profile.configurationDigest)
      var draft = CloudflareEditorPresentation.edit(summary).draft
      #expect(draft.expectedTunnelDigest == summary.configurationDigest)
      #expect(draft.cloudflaredPath == initial.cloudflaredPath)
      draft.tunnelName = "first-edit"
      _ = try await fixture.app.saveCloudflareTunnelConfiguration(draft)

      let opened = try #require(try await fixture.app.fetchCloudflareTunnels().first)
      var stale = CloudflareEditorPresentation.edit(opened).draft
      var disabled = profile
      disabled.tunnelName = opened.tunnelName
      disabled.oauthEnabled = false
      _ = try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
        disabled, tunnelToken: nil)
      stale.tunnelName = "unrelated-edit"
      await #expect(throws: CloudflareTunnelError.staleConfiguration(opened.id)) {
        try await fixture.app.saveCloudflareTunnelConfiguration(stale)
      }
      let current = try #require(try await fixture.app.fetchCloudflareTunnels().first)
      #expect(current.tunnelName == opened.tunnelName)
      #expect(!current.oauthEnabled)
      #expect(current.oauthClientAllowlist == opened.oauthClientAllowlist)
      #expect(current.configurationDigest != opened.configurationDigest)
    }
  }

  @Test
  func manifestEditorSavesOnlyAgainstTheManifestItOpened() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.app.startApplication()
      let opened = try await fixture.app.fetchDiagnostics().manifest
      let first = opened.content + "\n# first edit\n"
      try await fixture.app.saveManifest(first, expectedDigest: opened.digest)
      await #expect(throws: (any Error).self) {
        try await fixture.app.saveManifest(
          opened.content + "\n# stale edit\n", expectedDigest: opened.digest)
      }
      let current = try await fixture.app.fetchDiagnostics().manifest
      #expect(current.content == first)
      #expect(current.digest != opened.digest)
    }
  }

  @Test
  func codexConfirmationAppliesOnlyTheReviewedPlan() async throws {
    let temporary = try ScopedTemporaryDirectory()
    let executable = temporary.url.appendingPathComponent("server")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = temporary.url.appendingPathComponent("codex")
    try FileManager.default.copyItem(at: executable, to: client)
    let runner = AppRegistrationTestRunner()
    let service = ClientRegistrationService(
      homeDirectory: temporary.url, stateDirectory: temporary.url.appendingPathComponent("state"),
      executableSearchDirectories: [temporary.url.path], environment: [:], processRunner: runner)
    let fixture = try AppControlPlaneFixture(
      registrationService: service, gatewayExecutablePath: executable.path)
    let model = ComputerMCPAppModel(controlPlane: fixture.app)
    await model.localClients.beginReview(.codex, operation: .register)
    let reviewed = try #require(model.localClients.review)
    #expect(reviewed.plan.display.state == .notRegistered)
    runner.changeEntry()
    await model.localClients.confirm(reviewed)
    #expect(
      model.localClients.outcome?.message
        == LocalClientsModel.message(for: .changedSincePreview, client: .codex))
    #expect(runner.writeCount == 0)
    await fixture.cleanup()
  }

  @Test
  func incompatibleCallerConsentCannotEnableTheShellFacility() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.app.startApplication()
      try await fixture.app.startGateway()
      let client = try await GatewayClientSession.connectSocket(socketURL: fixture.socketURL)
      let snapshot = try #require(try await fixture.app.fetchClientAccess().sessions.first)
      #expect(snapshot.profile?.grant.allowedCallers.contains(snapshot.caller) == false)
      let before = try await fixture.controlPlane.activeConfiguration()
      #expect(!before.policy.shellEnabled)
      await #expect(throws: (any Error).self) {
        try await fixture.app.grantClientFullAccess(
          id: snapshot.id, lifetime: .thisSession, expectedRevision: snapshot.revision,
          expectedTrustRevision: 0)
      }
      #expect(try await fixture.controlPlane.activeConfiguration() == before)
      #expect(try await fixture.app.fetchClientAccess().sessions.first?.fullAccessConsent == nil)
      await client.disconnect()
    }
  }

  @Test
  func ownerPresentationControlsTheConnectedSessionAndSeparatePersistentTrust() async throws {
    try await withAppControlPlaneFixture { fixture in
      let configuration = GatewayConfiguration(
        profiles: [
          .init(
            id: .chatGPTOperate, capabilities: ["file.read"], projects: ["*"],
            allowedCallers: [.localMCP], mode: .projectOperations)
        ], projectDirectory: fixture.root)
      _ = try await fixture.controlPlane.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try? await fixture.controlPlane.configurationDigest())
      try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
      try await fixture.app.startApplication()
      try await fixture.app.registerProject(at: fixture.root)
      try await fixture.app.startGateway()
      let client = try await GatewayClientSession.connectSocket(socketURL: fixture.socketURL)
      do {
        let initial = try #require(try await fixture.app.fetchClientAccess().sessions.first)
        #expect(initial.fullAccessConsent == nil)
        try await fixture.app.grantClientFullAccess(
          id: initial.id, lifetime: .thisSession, expectedRevision: initial.revision,
          expectedTrustRevision: 0)
        #expect(try await client.listToolNames().contains("shell.run"))
        let approved = try #require(try await fixture.app.fetchClientAccess().sessions.first)
        try await fixture.app.limitClientAccess(
          id: approved.id, mode: .readOnly, expectedRevision: approved.revision)
        #expect(try await !client.listToolNames().contains("shell.run"))
        let limited = try #require(try await fixture.app.fetchClientAccess().sessions.first)
        try await fixture.app.grantClientFullAccess(
          id: limited.id, lifetime: .alwaysAllowClient, expectedRevision: limited.revision,
          expectedTrustRevision: 0)
        let trusted = try await fixture.app.fetchClientAccess()
        let trust = try #require(trusted.trusts.first)
        #expect(trust.fullAccessAllowed)
        #expect(try await client.listToolNames().contains("shell.run"))
        try await fixture.app.revokeClientTrust(id: trust.id, expectedRevision: trust.revision)
        #expect(try await !client.listToolNames().contains("shell.run"))
        let revoked = try #require(try await fixture.app.fetchClientAccess().sessions.first)
        try await fixture.app.endClientAccess(id: revoked.id, expectedRevision: revoked.revision)
        #expect(try await client.listToolNames().isEmpty)
        await client.disconnect()
      } catch {
        await client.disconnect()
        throw error
      }
    }
  }

  @Test(arguments: [false, true])
  func applicationStopJoinsOwnerWorkWithEitherGatewayState(gatewayRunning: Bool) async throws {
    try await withAppControlPlaneFixture { fixture in
      let database = await fixture.controlPlane.database
      try database.saveProject(
        .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
      _ = try await fixture.controlPlane.activateManifest(
        GatewayConfiguration(policy: .init(shellEnabled: true), projectDirectory: fixture.root)
          .exportedTOML(), expectedDigest: try? await fixture.controlPlane.configurationDigest())
      try await fixture.controlPlane.setGatewayDesiredRunning(gatewayRunning)
      try await fixture.app.startApplication()
      let client = AppControlPlaneServiceClient(
        socketURL: fixture.controlSocket.socketConfiguration.socketURL)
      let arguments: JSONValue = .object([
        "mode": .string("argv"), "executable": .string("/bin/cat"),
      ])
      let prepared = try await client.call(
        "tools.call",
        arguments: .object([
          "name": .string("operations.prepare"),
          "arguments": .object([
            "tool": .string("shell.spawn"), "arguments": arguments,
          ]),
        ]))
      try #require(prepared.objectValue?["isError"] != .bool(true), "\(prepared)")
      let ticket = try #require(
        prepared.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
          "ticket_id"])
      _ = try await client.call("approvals.approve", arguments: .object(["id": ticket]))
      let spawned = try await client.call(
        "tools.call",
        arguments: .object([
          "name": .string("operations.commit"),
          "arguments": .object([
            "tool": .string("shell.spawn"), "arguments": arguments, "ticket_id": ticket,
          ]),
        ]))
      let session = try #require(
        spawned.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
          "session_id"])
      let readArguments: JSONValue = .object(["session_id": session])
      let readPrepared = try await client.call(
        "tools.call",
        arguments: .object([
          "name": .string("operations.prepare"),
          "arguments": .object([
            "tool": .string("shell.read"), "arguments": readArguments,
          ]),
        ]))
      let readTicket = try #require(
        readPrepared.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
          "ticket_id"])
      _ = try await client.call("approvals.approve", arguments: .object(["id": readTicket]))
      let read = try await client.call(
        "tools.call",
        arguments: .object([
          "name": .string("operations.commit"),
          "arguments": .object([
            "tool": .string("shell.read"), "arguments": readArguments, "ticket_id": readTicket,
          ]),
        ]))
      let pid = try #require(
        read.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["process_id"]?
          .int64Value.flatMap(Int32.init(exactly:)))
      #expect(kill(pid, 0) == 0)
      await fixture.app.stopApplication()
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
      #expect(await fixture.controlSocket.snapshot().state == .stopped)
      #expect(await fixture.gatewayService.snapshot().state == .stopped)
    }
  }

  @Test
  func localMCPConnectionTargetsTheOwningAppInstance() async throws {
    try await withAppControlPlaneFixture { fixture in
      let connection = try await fixture.app.localMCPConnection()
      #expect(connection.command == fixture.controlPlane.gatewayExecutablePath)
      #expect(
        connection.arguments == [
          "bridge", "--client-identity", "local-mcp", "--socket", fixture.socketURL.path,
        ])
    }
  }

  @Test
  func projectHealthChecksBookmarkAccessAndMissingFolders() async throws {
    try await withAppControlPlaneFixture { fixture in
      let database = await fixture.controlPlane.database
      try database.saveProject(
        RegisteredProject(
          id: "available", displayName: "Available", rootPath: fixture.root.path))
      try database.saveProject(
        RegisteredProject(
          id: "missing", displayName: "Missing",
          rootPath: fixture.root.appendingPathComponent("missing").path))
      try database.saveProject(
        RegisteredProject(
          id: "bad-bookmark", displayName: "Bad bookmark", rootPath: fixture.root.path,
          bookmarkData: Data("invalid-bookmark".utf8)))
      let reports = try await fixture.app.fetchProjects()
      let available = try #require(reports.first { $0.id == "available" })
      let missing = try #require(reports.first { $0.id == "missing" })
      let badBookmark = try #require(reports.first { $0.id == "bad-bookmark" })
      #expect(available.health == .available)
      #expect(available.lastResolvedAt != nil)
      #expect(available.healthDetail == nil)
      #expect(missing.health == .missing)
      #expect(missing.lastResolvedAt == nil)
      #expect(missing.healthDetail != nil)
      #expect(badBookmark.health == .unavailable)
      #expect(badBookmark.lastResolvedAt == nil)
      #expect(badBookmark.healthDetail != nil)
    }
  }

  @Test
  func testPermissionStateDistinguishesNotGrantedFromNotDetermined() {
    #expect((PermissionState.notGranted.label) == ("Not granted"))
    #expect((PermissionState.notDetermined.label) == ("Not determined"))
  }

  @Test
  func testPermissionRequestUsesInjectedLocalRequester() async throws {
    let requester = AppTestPermissionRequester(
      outcome: PermissionRequestOutcome(
        permissionID: "screen-recording",
        state: .notGranted,
        systemPromptRequested: true
      )
    )
    try await withAppControlPlaneFixture(permissionRequester: requester) { fixture in
      let outcome = try await fixture.app.requestPermission(id: "screen-recording")

      #expect((outcome.permissionID) == ("screen-recording"))
      #expect((outcome.state) == (.notGranted))
      #expect(outcome.systemPromptRequested)
      #expect((requester.requestedIDs) == (["screen-recording"]))
    }
  }

  @Test
  func testPermissionLinksTargetCurrentPrivacySettingsExtension() async throws {
    try await withAppControlPlaneFixture { fixture in
      let permissions = try await fixture.app.fetchPermissions()
      let links = Dictionary(
        uniqueKeysWithValues: permissions.compactMap { permission in
          permission.settingsURL.map { (permission.id, $0.absoluteString) }
        }
      )

      #expect(
        links["accessibility"]
          == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
      )
      #expect(
        links["screen-recording"]
          == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
      )
    }
  }

  @Test
  func testPermissionRequesterRejectsUnknownPermission() {
    expectThrows(
      try MacOSSystemPermissionRequester().requestPermission(id: "camera")
    ) { error in
      #expect((error.localizedDescription) == ("Unknown macOS permission: camera"))
    }
  }

  @Test
  func profilePermissionEditorRoundTripsWithoutRestartingTheGateway() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.app.startApplication()
      let original = await fixture.gatewayService.snapshot()
      let profile = try #require(
        try await fixture.app.fetchProfiles().first { $0.id == "chatgpt-operate" })
      var grant = profile.permissions
      grant.mode = .readOnly
      grant.confirmationPolicy = .allWrites
      grant.capabilityIDs = ["system.time"]
      grant.allowedCallers = [.localMCP]
      let options = try await fixture.app.fetchProfilePermissionOptions(id: grant.id)
      try await fixture.app.saveProfilePermissions(grant, reviewed: options)
      let updated = try #require(
        try await fixture.app.fetchProfiles().first { $0.id == profile.id })
      #expect(updated.permissions.mode == .readOnly)
      #expect(updated.permissions.confirmationPolicy == .allWrites)
      #expect(updated.permissions.capabilityIDs == ["system.time"])
      #expect(updated.permissions.allowedCallers == [.localMCP])
      #expect(updated.permissions.authorizationRevision > grant.authorizationRevision)
      let current = await fixture.gatewayService.snapshot()
      #expect(current.state == .running)
      #expect(current.startedAt == original.startedAt)
    }
  }

  @Test
  func restrictedSelectionRequiresDeliberateCallerAdmissionAndUpdatesTheSameConnection()
    async throws
  {
    try await withAppControlPlaneFixture { fixture in
      let configuration = GatewayConfiguration(
        runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
        profiles: [
          .init(
            id: .chatGPTOperate, capabilities: ["system.time"], projects: ["project"],
            allowedCallers: [.secureTunnel], mode: .projectOperations)
        ], builtin: .init(enabled: ["system.time", "file.read", "file.write"]),
        projectDirectory: fixture.root)
      _ = try await fixture.controlPlane.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try? await fixture.controlPlane.configurationDigest())
      try await fixture.controlPlane.database.saveProject(
        .init(id: "project", displayName: "My Project", rootPath: fixture.root.path))
      try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
      try await fixture.app.startApplication()
      let started = await fixture.gatewayService.snapshot().startedAt
      let client = try await GatewayClientSession.connectSocket(socketURL: fixture.socketURL)
      do {
        #expect(try await client.listToolNames().isEmpty)
        let first = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
        var draft = ProfilePermissionsDraft(options: first)
        draft.grant.capabilityIDs = ["system.time", "file.read"]
        try await fixture.app.saveProfilePermissions(draft.savedGrant, reviewed: first)
        #expect(try await client.listToolNames().isEmpty)
        let reviewed = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
        draft = ProfilePermissionsDraft(options: reviewed)
        draft.grant.allowedCallers.insert(.localMCP)
        try await fixture.app.saveProfilePermissions(draft.savedGrant, reviewed: reviewed)
        let tools = try await client.listToolNames()
        #expect(tools.contains("system.time") && tools.contains("file.read"))
        #expect(!tools.contains("file.write") && !tools.contains("shell.run"))
        #expect(
          try await client.call(toolName: "system.time").result.objectValue?["isError"]
            != .bool(true))
        #expect(await fixture.gatewayService.snapshot().startedAt == started)
        #expect(try await fixture.app.fetchClientAccess().sessions.first?.fullAccessConsent == nil)
        #expect(try await fixture.app.fetchClientAccess().trusts.isEmpty)
        await client.disconnect()
      } catch {
        await client.disconnect()
        throw error
      }
    }
  }

  @Test
  func projectWildcardIsShownAsEnabledAndCanBeRevoked() async throws {
    try await withAppControlPlaneFixture { fixture in
      let database = await fixture.controlPlane.database
      try database.saveProject(.init(id: "one", displayName: "One", rootPath: fixture.root.path))
      try database.saveProject(.init(id: "two", displayName: "Two", rootPath: fixture.root.path))
      _ = try await fixture.controlPlane.updateProfilePermissions(
        profileID: .chatGPTObserve, projectIDs: ["*"])
      let before = try await fixture.app.fetchProjects()
      #expect(before.allSatisfy { $0.isSelected && $0.isEnabled })
      try await fixture.app.setProjectEnabled(
        false, projectID: "one", profileID: GatewayProfileID.chatGPTObserve.rawValue)
      let after = try await fixture.app.fetchProjects()
      #expect(after.first { $0.id == "one" }?.isSelected == false)
      #expect(after.first { $0.id == "one" }?.isEnabled == false)
      #expect(after.first { $0.id == "two" }?.isSelected == true)
    }
  }

  @Test
  func testProfileActivationUpdatesAdmissionAndRejectedProfileRollsBack() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.app.startApplication()
      var status = try await fixture.app.fetchStatus()
      #expect((status.serviceState) == (.running))
      #expect((status.activeProfileName) == (GatewayProfileID.chatGPTObserve.rawValue))

      try await fixture.app.activateProfile(id: GatewayProfileID.chatGPTOperate.rawValue)
      status = try await fixture.app.fetchStatus()
      #expect((status.serviceState) == (.running))
      #expect((status.activeProfileName) == (GatewayProfileID.chatGPTOperate.rawValue))
      let activeAfterOperate = try await fixture.controlPlane.activeGatewayProfile()
      #expect((activeAfterOperate) == (.chatGPTOperate))

      do {
        try await fixture.app.activateProfile(id: GatewayProfileID.localAdmin.rawValue)
        Issue.record("Expected local-admin App socket activation to fail.")
      } catch let error as AppControlPlaneServiceError {
        #expect((error) == (.localAdminCannotBeSocketProfile))
      }
      status = try await fixture.app.fetchStatus()
      #expect((status.serviceState) == (.running))
      #expect((status.activeProfileName) == (GatewayProfileID.chatGPTOperate.rawValue))
      let activeAfterRejection = try await fixture.controlPlane.activeGatewayProfile()
      #expect((activeAfterRejection) == (.chatGPTOperate))
    }
  }

  @Test
  func testTunnelListsDoNotQueryKeychain() async throws {
    let keychainAdapter = AppTestKeychainAdapter()
    try await withAppControlPlaneFixture(keychainAdapter: keychainAdapter) { fixture in
      let reference = try SecretReference(account: "tunnel.current.openai-api-key")
      try await fixture.controlPlane.saveOpenAITunnelConfiguration(
        OpenAITunnelConfiguration(
          id: "current",
          tunnelClientProfile: "computer-mcp",
          tunnelID: "tunnel_current",
          manifestPath: fixture.controlPlane.directories.manifest.path,
          gatewayExecutablePath: "computer-mcp",
          gatewaySocketPath: fixture.controlPlane.directories.gatewaySocket.path,
          apiKeyReference: reference
        )
      )

      _ = try await fixture.app.fetchOpenAITunnels()
      _ = try await fixture.app.fetchCloudflareTunnels()

      #expect(keychainAdapter.secretReadCount == 0)
    }
  }

  @Test
  func pluginScreenUsesSharedHostTransactionsAndRetainsFilesOnRemoval() async throws {
    try await withAppControlPlaneFixture { fixture in
      let package = fixture.root.appendingPathComponent("Local Package", isDirectory: true)
      let skill = package.appendingPathComponent("skills/guide", isDirectory: true)
      try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
      try "---\nname: guide\ndescription: Test guide\n---\nRead only.".write(
        to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
      try """
      id = 'screen-package'
      name = 'Screen package'
      version = '1.0.0'
      plugin_api = 1
      [[skills]]
      id = 'guide'
      path = 'skills'
      """.write(
        to: package.appendingPathComponent(PluginManifest.filename), atomically: true,
        encoding: .utf8)
      let model = PluginManagementModel(controlPlane: fixture.app)
      await model.reload()
      #expect(model.snapshot?.state.revision == 0)
      #expect(await model.apply(.registerDevelopment(package), expectedRevision: 0))
      let registered = try #require(model.snapshot)
      let installation = try #require(registered.state.installations.first)
      #expect(registered.state.settings["screen-package"]?.enabled == false)
      #expect(model.selectedID == "screen-package")
      let draft = PluginSettingsDraft(id: "screen-package", snapshot: registered)
      #expect(await model.apply(.enabled(pluginID: "screen-package", true), expectedRevision: 1))
      #expect(model.snapshot?.contributions.map(\.componentID) == ["guide"])
      #expect(try await fixture.controlPlane.pluginSnapshot().state == model.snapshot?.state)

      #expect(
        !(await model.apply(
          .settings(pluginID: draft.id, try draft.settings()), expectedRevision: draft.revision)))
      #expect(model.snapshot?.state.revision == 2)
      #expect(
        await model.apply(.removeDevelopment(installationID: installation.id), expectedRevision: 2))
      let removed = try #require(model.snapshot)
      #expect(removed.state.installations.isEmpty)
      #expect(removed.state.settings["screen-package"]?.enabled == true)
      #expect(removed.contributions.isEmpty)
      #expect(!removed.issues.isEmpty)
      #expect(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
      #expect(try await fixture.app.fetchPlugins().state == removed.state)
    }
  }

  @Test
  func applicationRecoversPluginFilesWhileGatewayRemainsDisabled() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.controlPlane.setGatewayDesiredRunning(false)
      let directories = fixture.controlPlane.directories
      let database = try GatewayDatabase(path: directories.database.path)
      let identity: PluginDirectoryIdentity
      do {
        let storage = try PluginInstallationStorage(
          at: directories.plugins,
          directoryFactory: MacOSPlatform.services(launcher: testExecutionLauncher())
            .pluginDirectories)
        defer { storage.finishTransaction() }
        identity = try storage.createInstallation()
        try database.recordPluginDirectory(
          .init(
            installationID: identity.url.lastPathComponent, pluginID: "interrupted-install",
            identity: identity))
      }
      try await fixture.app.startApplication()
      #expect(try await fixture.app.fetchStatus().serviceState == .stopped)
      #expect(try database.pluginOwnedDirectories().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: identity.url.path))
      #expect(try await fixture.app.fetchPlugins().recoveryError == nil)
      #expect(try database.pluginStoreSnapshot().revision == 0)
    }
  }

  private func withAppControlPlaneFixture<T>(
    permissionRequester: any SystemPermissionRequesting = MacOSSystemPermissionRequester(),
    keychainAdapter: any KeychainAdapter = AppTestKeychainAdapter(),
    operation: (AppControlPlaneFixture) async throws -> T
  ) async throws -> T {
    let fixture = try AppControlPlaneFixture(
      permissionRequester: permissionRequester,
      keychainAdapter: keychainAdapter
    )
    do {
      let result = try await operation(fixture)
      await fixture.cleanup()
      return result
    } catch {
      await fixture.cleanup()
      throw error
    }
  }
}

@MainActor
private final class AppControlPlaneFixture {
  let root: URL
  let socketURL: URL
  let controlPlane: AppControlPlaneService
  let gatewayService: AppGatewayService
  let controlSocket: ControlSocketService
  let app: LiveAppControlPlane

  init(
    permissionRequester: any SystemPermissionRequesting = MacOSSystemPermissionRequester(),
    keychainAdapter: any KeychainAdapter = AppTestKeychainAdapter(),
    registrationService: ClientRegistrationService? = nil,
    gatewayExecutablePath: String = "computer-mcp"
  ) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let socketDirectory = URL(
      fileURLWithPath: "/private/tmp/cm-app-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: socketDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    socketURL = socketDirectory.appendingPathComponent("gateway.sock")
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("Application Support/Computer MCP"),
      logs: root.appendingPathComponent("Logs/Computer MCP")
    )
    try directories.prepare()
    let database = try GatewayDatabase(path: directories.database.path)
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest,
      database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    _ = try manifestStore.activate(manifest: DefaultGatewayConfiguration.manifest)
    let secretStore = try KeychainSecretStore(
      service: "com.showxu.computer-mcp.tests.\(UUID().uuidString)",
      accessGroup: "TESTTEAMID.com.showxu.computer-mcp.tests",
      adapter: keychainAdapter
    )
    controlPlane = AppControlPlaneService(
      directories: directories,
      database: database,
      manifestStore: manifestStore,
      defaultManifest: DefaultGatewayConfiguration.manifest,
      secretStore: secretStore,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: testExecutionLauncher(),
        secretStore: secretStore,
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()
      ),
      gatewayExecutablePath: gatewayExecutablePath,
      launchAtLoginController: AppTestLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(),
      platform: MacOSPlatform.services(launcher: testExecutionLauncher())
    )
    gatewayService = AppGatewayService(
      controlPlane: controlPlane,
      socketConfiguration: GatewaySocketConfiguration(socketURL: socketURL)
    )
    controlSocket = ControlSocketService(
      controlPlane: controlPlane, gatewayService: gatewayService,
      socketURL: socketDirectory.appendingPathComponent("control.sock"))
    app = LiveAppControlPlane(
      controlPlane: controlPlane,
      gatewayService: gatewayService,
      fileLogger: try AppFileLogger(directory: directories.logs),
      controlSocketService: controlSocket,
      permissionRequester: permissionRequester,
      registrationService: registrationService
    )
  }

  func cleanup() async {
    await app.stopApplication()
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
  }
}

@MainActor
private final class AppTestPermissionRequester: SystemPermissionRequesting,
  @unchecked Sendable
{
  let outcome: PermissionRequestOutcome
  private(set) var requestedIDs: [String] = []

  init(outcome: PermissionRequestOutcome) {
    self.outcome = outcome
  }

  func requestPermission(id: String) throws -> PermissionRequestOutcome {
    requestedIDs.append(id)
    return outcome
  }
}

private final class AppTestKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var readCount = 0

  var secretReadCount: Int {
    lock.withLock { readCount }
  }

  func set(service: String, account: String, data: Data) {
    lock.withLock {
      values["\(service)\u{1f}\(account)"] = data
    }
  }

  func get(service: String, account: String) -> Data? {
    lock.withLock {
      readCount += 1
      return values["\(service)\u{1f}\(account)"]
    }
  }

  func delete(service: String, account: String) {
    _ = lock.withLock {
      values.removeValue(forKey: "\(service)\u{1f}\(account)")
    }
  }
}

private struct AppTestLaunchAtLoginController: LaunchAtLoginControlling {
  func state() -> LaunchAtLoginState {
    .disabled
  }

  func setEnabled(_ enabled: Bool) throws {}
}

/// Lock-protected state is shared with the control plane's blocking executor.
private final class AppRegistrationTestRunner: RegistrationProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false
  private var writes = 0
  var writeCount: Int { lock.withLock { writes } }
  func changeEntry() { lock.withLock { changed = true } }
  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.withLock {
      let get = arguments.contains("get")
      if arguments.contains("add") { writes += 1 }
      return .init(
        executable: executable, arguments: arguments, exitCode: get && !changed ? 1 : 0,
        timedOut: false,
        stdout: get && changed
          ? "{\"transport\":{\"type\":\"stdio\",\"command\":\"changed\",\"args\":[]}}" : "",
        stderr: get && !changed ? "No MCP server named computer-mcp" : "",
        stdoutTruncated: false, stderrTruncated: false)
    }
  }
}
