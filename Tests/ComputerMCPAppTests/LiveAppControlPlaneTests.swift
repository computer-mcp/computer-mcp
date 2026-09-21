import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPApp

@MainActor
@Suite(.serialized)
final class LiveAppControlPlaneTests {
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
  func workspaceHealthChecksBookmarkAccessAndMissingFolders() async throws {
    try await withAppControlPlaneFixture { fixture in
      let database = await fixture.controlPlane.database
      try database.saveWorkspace(
        RegisteredWorkspace(
          id: "available", displayName: "Available", rootPath: fixture.root.path))
      try database.saveWorkspace(
        RegisteredWorkspace(
          id: "missing", displayName: "Missing",
          rootPath: fixture.root.appendingPathComponent("missing").path))
      try database.saveWorkspace(
        RegisteredWorkspace(
          id: "bad-bookmark", displayName: "Bad bookmark", rootPath: fixture.root.path,
          bookmarkData: Data("invalid-bookmark".utf8)))
      let reports = try await fixture.app.fetchWorkspaces()
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
      try await fixture.app.updateProfilePermissions(grant)
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
  func workspaceWildcardIsShownAsEnabledAndCanBeRevoked() async throws {
    try await withAppControlPlaneFixture { fixture in
      let database = await fixture.controlPlane.database
      try database.saveWorkspace(.init(id: "one", displayName: "One", rootPath: fixture.root.path))
      try database.saveWorkspace(.init(id: "two", displayName: "Two", rootPath: fixture.root.path))
      _ = try await fixture.controlPlane.updateProfilePermissions(
        profileID: .chatGPTObserve, workspaceIDs: ["*"])
      let before = try await fixture.app.fetchWorkspaces()
      #expect(before.allSatisfy { $0.isSelected && $0.isEnabled })
      try await fixture.app.setWorkspaceEnabled(
        false, workspaceID: "one", profileID: GatewayProfileID.chatGPTObserve.rawValue)
      let after = try await fixture.app.fetchWorkspaces()
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
        let storage = try PluginInstallationStorage(at: directories.plugins)
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
  let app: LiveAppControlPlane

  init(
    permissionRequester: any SystemPermissionRequesting = MacOSSystemPermissionRequester(),
    keychainAdapter: any KeychainAdapter = AppTestKeychainAdapter()
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
      database: database
    )
    _ = try manifestStore.activate(manifest: DefaultGatewayConfiguration.manifest)
    let secretStore = try KeychainSecretStore(
      service: "com.showxu.computer-mcp.tests.\(UUID().uuidString)",
      adapter: keychainAdapter
    )
    controlPlane = AppControlPlaneService(
      directories: directories,
      database: database,
      manifestStore: manifestStore,
      secretStore: secretStore,
      openAITunnelSupervisor: OpenAITunnelSupervisor(secretStore: secretStore),
      launchAtLoginController: AppTestLaunchAtLoginController()
    )
    gatewayService = AppGatewayService(
      controlPlane: controlPlane,
      socketConfiguration: GatewaySocketConfiguration(socketURL: socketURL)
    )
    app = LiveAppControlPlane(
      controlPlane: controlPlane,
      gatewayService: gatewayService,
      fileLogger: try AppFileLogger(directory: directories.logs),
      permissionRequester: permissionRequester
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
