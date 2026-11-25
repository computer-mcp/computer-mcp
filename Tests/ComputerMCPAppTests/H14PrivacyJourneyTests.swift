import ComputerMCPDarwinTestSupport
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import ComputerMCPTunnels
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

@MainActor
@Suite struct H14PrivacyJourneyTests {
  @Test func packageGrantsAndRevokesFromBothPerspectives() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (app, _, _) = try makeApp(root: root)
    let package = root.appendingPathComponent("package")
    let skill = package.appendingPathComponent("skills/guide")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try "---\nname: guide\ndescription: A local guide\n---\nRead only.".write(
      to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try """
    id = 'h14-package'
    name = 'H14 package'
    version = '1.0.0'
    plugin_api = 1
    [[permissions]]
    id = 'screen'
    access = 'allow'
    purpose = 'Read the screen'
    [[permissions]]
    id = 'project'
    access = 'read'
    purpose = 'Read the selected project'
    [[skills]]
    id = 'guide'
    path = 'skills'
    """.write(
      to: package.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8
    )
    let registered = try await app.changePlugins(.registerDevelopment(package), expectedRevision: 0)
    let service = LivePrivacySecurityService(controlPlane: app)
    let model = PrivacySecurityModel(service: service)
    let id = "plugin/h14-package"
    await model.refresh()
    let pending = try #require(model.snapshot.reviewedProviders[id])
    let unavailableScreen = try #require(
      model.grants(for: .screen, includingUnset: true).first { $0.principalID == id })
    #expect(unavailableScreen.effectiveValue == nil)
    #expect(!model.canEdit(unavailableScreen))
    try await service.approveProvider(
      pending, permissions: .init(), execution: .sandbox, sandboxSettings: .init())
    #expect(try await app.fetchPlugins().state.revision > registered.state.revision)
    await model.refresh()
    let principal = try #require(model.principal(id))
    #expect(principal.providerAvailability == .active)
    #expect(principal.effectiveExecution == .sandbox)

    for (kind, objectID, level, permission) in [
      (PrivacyPermissionKind.screen, nil, PrivacyGrantValue.Level.allow, Permission.screen),
      (.projects, "project", .read, .project("project")),
    ] {
      func categoryRow() throws -> PrivacyGrant {
        try #require(
          model.grants(for: kind, includingUnset: true).first {
            $0.principalID == id && $0.object?.id == objectID
          })
      }
      func principalRow() throws -> PrivacyGrant {
        try #require(
          model.grants(for: principal).first { $0.permission == kind && $0.object?.id == objectID })
      }
      let initial = try categoryRow()
      #expect(!initial.isStored && initial.effectiveValue == .ask)
      #expect(initial == (try principalRow()))
      #expect(model.canEdit(initial))
      if kind == .projects { #expect(initial.availableLevels == [.read]) }
      let stale = model.snapshot
      await model.set(initial, to: .granted(level))
      #expect(model.failure == nil)
      #expect(try principalRow().effectiveValue == .granted(level))
      await model.set(try principalRow(), to: .denied, reviewed: stale)
      #expect(model.failure != nil)
      #expect(try categoryRow().effectiveValue == .granted(level))
      model.failure = nil
      await model.set(try principalRow(), to: .denied)
      #expect(model.failure == nil)
      #expect(try categoryRow().effectiveValue == .denied)
      await model.set(try principalRow(), to: .granted(level))
      #expect(model.failure == nil)
      await model.set(try categoryRow(), to: .denied)
      #expect(model.failure == nil)
      #expect(try principalRow().effectiveValue == .denied)
      let saved = try #require(model.snapshot.reviewedProviders[id]?.approval)
      #expect(saved.permissions.state(for: permission) == .denied)
    }
    let screen = try #require(model.grant(principalID: id, permission: .screen, objectID: nil))
    await model.set(screen, to: .granted(.allow))
    #expect(model.failure == nil)
    await model.revokeAll(principal)
    #expect(model.failure == nil)
    let revoked = try #require(model.grant(principalID: id, permission: .screen, objectID: nil))
    #expect(revoked.value == .granted(.allow) && revoked.effectiveValue == nil)
    #expect(!model.canEdit(revoked))
  }

  @Test func directClientAndServerUseTheSameInventoryAndOwnTheirEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (app, host, authority) = try makeApp(root: root)
    var configuration = try await host.activeConfiguration()
    configuration.mcp.servers.append(
      .init(id: "h14-local", transport: .stdio, command: "/usr/bin/true"))
    _ = try await host.activateManifest(
      configuration.exportedTOML(), expectedDigest: host.configurationDigest())
    let profileID = GatewayProfileID.chatGPTOperate
    let subject = try GatewayPermissionSubject(
      context: .init(
        caller: .secureTunnel, profileID: profileID, trustedPrincipalID: "h14-client"))
    let requirements = InvocationRequirements(actions: [
      .init(requirement: try .init(.screen, .access))
    ])
    guard
      case .requests = try authority.admit(
        subject: subject, tool: "screen.capture", projectID: nil, argumentsDigest: "h14-screen",
        requirements: requirements)
    else {
      Issue.record("The new direct client should ask for screen access")
      return
    }
    let service = LivePrivacySecurityService(controlPlane: app)
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let request = try #require(model.snapshot.requests.first { $0.tool == "screen.capture" })
    let client = request.principal
    #expect(client.sharedProfileID == profileID)
    #expect(request.sharedProfileName == model.principal(profileID.rawValue)?.name)
    let serverID = "server/h14-local"
    try await service.approveProvider(
      #require(model.snapshot.reviewedProviders[serverID]), permissions: .init(),
      execution: .sandbox, sandboxSettings: .init())
    await model.refresh()
    let server = try #require(model.principal(serverID))
    let cases: [(PrivacyPermissionKind, String?, PrivacyGrantValue.Level)] = [
      (.projects, "project", .readWrite), (.filesAndFolders, "documents", .read),
      (.screen, nil, .allow), (.desktopControl, nil, .allow), (.localNetwork, nil, .allow),
      (.plugins, "*", .use), (.mcpServers, "h14-local", .all),
      (.machineInformation, nil, .allow), (.unifiedLogs, nil, .allow), (.skills, nil, .allow),
    ]
    for principal in [client, server] {
      for (kind, objectID, level) in cases {
        func categoryRow() throws -> PrivacyGrant {
          try #require(
            model.grants(for: kind, includingUnset: true).first {
              $0.principalID == principal.id && $0.object?.id == objectID
            })
        }
        func principalRow() throws -> PrivacyGrant {
          try #require(
            model.grants(for: principal).first {
              $0.permission == kind && $0.object?.id == objectID
            })
        }
        func editable(_ grant: PrivacyGrant) -> PrivacyGrant {
          model.sourceGrant(for: grant) ?? grant
        }
        let unedited = try categoryRow()
        #expect(unedited == (try principalRow()))
        #expect(model.canEdit(unedited) == (principal.id == serverID))
        let categorySource = editable(unedited)
        #expect(categorySource.principalID == (principal.sharedProfileID?.rawValue ?? principal.id))
        #expect(model.canEdit(categorySource))
        await model.set(categorySource, to: .granted(level))
        #expect(model.failure == nil)
        #expect(try principalRow().effectiveValue == .granted(level))
        await model.set(editable(try principalRow()), to: .denied)
        #expect(model.failure == nil)
        #expect(try categoryRow().effectiveValue == .denied)
        await model.set(editable(try principalRow()), to: .granted(level))
        #expect(model.failure == nil)
        await model.set(editable(try categoryRow()), to: .denied)
        #expect(model.failure == nil)
        #expect(try principalRow().effectiveValue == .denied)
      }
    }
    let serverProject = try #require(
      model.grant(principalID: serverID, permission: .projects, objectID: "project"))
    #expect(await model.setNetwork(serverProject, to: .full))
    await model.setExecution(server, .fullAccessAllowed)
    #expect(model.failure == nil)
    #expect(model.principal(serverID)?.effectiveExecution == .fullAccessAllowed)
    await model.setExecution(server, .sandbox)
    #expect(model.failure == nil)
    #expect(model.principal(serverID)?.effectiveExecution == .sandbox)
    #expect(
      model.grant(principalID: serverID, permission: .projects, objectID: "project")?.network
        == PrivacyNetworkAccess.none)
  }

  private func makeApp(root: URL) throws -> (
    LiveAppControlPlane, AppControlPlaneService, GatewayPermissionService
  ) {
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("Support"),
      logs: root.appendingPathComponent("Logs"))
    try directories.prepare()

    let database = try GatewayDatabase(path: directories.database.path)
    _ = database.permissionStore(counter: TestAuthorizationEpochCounter())
    try database.bootstrapPermissionProfiles(
      GatewayProfileID.builtIns.map { GatewayConfiguration().profileGrant(for: $0) },
      declarations: [])
    let launcher = testExecutionLauncher()
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let permissionService = try database.permissionRuntime(platform: platform).service
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "h14-test-owner"),
      validate: {})
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, applications: platform.applications))
    _ = try manifestStore.activate(manifest: DefaultGatewayConfiguration.manifest)
    let secrets = try KeychainSecretStore(
      service: "h14-package-fixture", accessGroup: "TESTTEAMID.com.showxu.computer-mcp.tests",
      adapter: MemoryKeychainAdapter())
    let host = AppControlPlaneService(
      directories: directories, database: database,
      permissionControl: PermissionControlService(service: permissionService, owner: { owner }),
      manifestStore: manifestStore, defaultManifest: DefaultGatewayConfiguration.manifest,
      secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: launcher, secretStore: secrets,
        executableSearchDirectories: platform.executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      launchAtLoginController: H14NoLaunchAtLogin(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(), platform: platform)
    let app = LiveAppControlPlane(
      controlPlane: host,
      gatewayService: AppGatewayService.live(controlPlane: host, directories: directories),
      fileLogger: try AppFileLogger(directory: directories.logs))

    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    try database.saveProject(.init(id: "project", displayName: "Project", rootPath: project.path))
    return (app, host, permissionService)
  }

}

private struct H14NoLaunchAtLogin: LaunchAtLoginControlling {
  func state() -> LaunchAtLoginState { .unavailable }
  func setEnabled(_ enabled: Bool) throws {}
}
