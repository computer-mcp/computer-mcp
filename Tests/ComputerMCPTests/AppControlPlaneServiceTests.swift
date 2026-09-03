import CryptoKit
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class AppControlPlaneServiceTests {
  @Test
  func testOwnerOnlyControlSocketOperatesTheAppControlPlaneWithoutStartingTransport() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(DefaultGatewayConfiguration.manifest)
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
      #expect(status.objectValue?["provider_count"] == .number(8))
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

      let addedWorkspace = try await client.call(
        "workspace.add",
        arguments: .object([
          "path": .string(fixture.root.path),
          "display_name": .string("Validation Workspace"),
        ])
      )
      #expect(addedWorkspace.objectValue?["id"]?.stringValue?.isEmpty == false)
      #expect(
        addedWorkspace.objectValue?["root_path"]
          == .string(fixture.root.resolvingSymlinksInPath().path)
      )
      #expect(addedWorkspace.objectValue?["bookmark_data"] == nil)
      let workspaces = try await client.call("workspace.list")
      let workspaceSummaries = try #require(workspaces.objectValue?["result"]?.arrayValue)
      #expect(workspaceSummaries.count == 1)
      #expect(workspaceSummaries[0].objectValue?["bookmark_data"] == nil)
      #expect(workspaceSummaries[0].objectValue?["display_name"] == .string("Validation Workspace"))

      let tools = try await client.call("tools.list")
      let listedTools = try #require(tools.objectValue?["tools"]?.arrayValue)
      #expect(listedTools.contains { $0.objectValue?["name"] == .string("workspace.list") })

      let inspectedTool = try await client.call(
        "tools.inspect",
        arguments: .object(["name": .string("workspace.list")])
      )
      #expect(inspectedTool.objectValue?["name"] == .string("workspace.list"))
      #expect(inspectedTool.objectValue?["inputSchema"]?.objectValue?["type"] == .string("object"))

      let toolCall = try await client.call(
        "tools.call",
        arguments: .object([
          "name": .string("workspace.list"),
          "arguments": .object([:]),
        ])
      )
      #expect(toolCall.objectValue?["isError"] == .bool(false))
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
        toolAudits.first { $0.capabilityID == "workspace.list" }
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
            "name": .string("workspace.list"),
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
          "workspace.enable",
          arguments: .object([
            "workspace_id": .string("workspace"),
            "profile": .string("chatgpt-observe"),
            "enabled": .string("true"),
          ])
        )
      ) { error in
        #expect(error.localizedDescription.contains("enabled"))
        #expect(error.localizedDescription.contains("Boolean"))
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
    _ = try await fixture.controlPlane.activateManifest(DefaultGatewayConfiguration.manifest)
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

      let workspaceURL = fixture.root.appendingPathComponent("Shared Operations")
      try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
      let workspace = try await client.call(
        "workspace.add",
        arguments: .object(["path": .string(workspaceURL.path)])
      )
      let workspaceID = try #require(workspace.objectValue?["id"]?.stringValue)
      #expect((await gatewayService.snapshot()).state == .running)

      let activated = try await client.call(
        "profile.activate",
        arguments: .object(["profile": .string(GatewayProfileID.chatGPTOperate.rawValue)])
      )
      #expect(activated.objectValue?["restarted"] == .bool(true))
      #expect(
        try await fixture.controlPlane.activeGatewayProfile() == GatewayProfileID.chatGPTOperate
      )

      let granted = try await client.call(
        "workspace.enable",
        arguments: .object([
          "workspace_id": .string(workspaceID),
          "profile": .string(GatewayProfileID.chatGPTOperate.rawValue),
          "enabled": .bool(true),
        ])
      )
      #expect(
        granted.objectValue?["workspace_ids"]?.arrayValue?.contains(.string(workspaceID)) == true
      )
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
  func testConfigExportProjectsPersistedWorkspaceAndFullShellRuntimeState() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      """
      schema_version = 1

      [server]
      name = "computer-mcp-export-test"

      [policy]
      shell_enabled = true

      [[workspaces]]
      id = "manifest-workspace"
      display_name = "Manifest Workspace"
      path = "Manifest Workspace"
      """
    )
    let workspaceURL = fixture.root.appendingPathComponent("Exported Workspace")
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    let workspace = try await fixture.controlPlane.registerWorkspace(
      at: workspaceURL,
      displayName: "Exported Workspace"
    )
    _ = try await fixture.controlPlane.setWorkspaceEnabled(
      true,
      workspaceID: workspace.id,
      profileID: .chatGPTOperate
    )
    _ = try await fixture.controlPlane.setFullShellEnabled(
      true,
      profileID: .chatGPTOperate
    )

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
      #expect(shownConfiguration.workspaces.map(\.id) == ["manifest-workspace"])
      #expect(shownConfiguration.profiles.isEmpty)

      let exported = try await client.call("config.export")
      let exportedTOML = try #require(exported.objectValue?["toml"]?.stringValue)
      let exportedConfiguration = try GatewayConfiguration.load(
        text: exportedTOML,
        baseURL: fixture.directories.configuration
      )
      let exportedWorkspace = try #require(
        exportedConfiguration.workspaces.first { $0.id == workspace.id }
      )
      #expect(exportedConfiguration.workspaces.map(\.id) == [workspace.id])
      #expect(exportedWorkspace.displayName == "Exported Workspace")
      #expect(exportedWorkspace.path == workspaceURL.standardizedFileURL.path)
      let exportedGrant = try #require(
        exportedConfiguration.profiles.first { $0.id == .chatGPTOperate }
      )
      #expect(exportedGrant.fullShellEnabled)
      #expect(exportedGrant.workspaces == [workspace.id])
      #expect(
        Set(exportedGrant.capabilities).isSuperset(of: ProfileGrant.fullShellCapabilities)
      )

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
      openAITunnelGatewayExecutablePath:
        "/Applications/Computer MCP.app/Contents/Resources/computer-mcp"
    )
    defer { fixture.cleanup() }
    try await fixture.controlPlane.start()
    _ = try await fixture.controlPlane.activateManifest(validManifest)

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
    _ = try await fixture.controlPlane.activateManifest(DefaultGatewayConfiguration.manifest)

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
    _ = try await fixture.controlPlane.activateManifest(validManifest)

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
    _ = try await fixture.controlPlane.activateManifest(validManifest)
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
    _ = try await fixture.controlPlane.activateManifest(validManifest)
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
  func testActiveProfileAndFullShellSettingsPersistThroughControlPlane() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(validManifest)

    let initialProfile = try await fixture.controlPlane.activeGatewayProfile()
    #expect((initialProfile) == (.chatGPTObserve))
    try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
    let selectedProfile = try await fixture.controlPlane.activeGatewayProfile()
    #expect((selectedProfile) == (.chatGPTOperate))

    do {
      _ = try await fixture.controlPlane.setFullShellEnabled(
        true,
        profileID: .chatGPTOperate
      )
      Issue.record("Expected manifest-level Full Shell denial.")
    } catch let error as AppControlPlaneServiceError {
      #expect((error) == (.fullShellManifestDisabled))
    }

    _ = try await fixture.controlPlane.activateManifest(
      """
      schema_version = 1

      [server]
      name = "computer-mcp-test"

      [policy]
      shell_enabled = true
      """
    )
    let grant = try await fixture.controlPlane.setFullShellEnabled(
      true,
      profileID: .chatGPTOperate
    )
    #expect(grant.fullShellEnabled)
    #expect(grant.capabilityIDs.contains("shell.run"))

    let localGrant = try await fixture.controlPlane.setFullShellEnabled(
      true,
      profileID: .localAdmin
    )
    #expect(localGrant.fullShellEnabled)
    #expect(localGrant.capabilityIDs.contains("shell.run"))

    do {
      try await fixture.controlPlane.setActiveGatewayProfile(.localAdmin)
      Issue.record("Expected local-admin socket profile denial.")
    } catch let error as AppControlPlaneServiceError {
      #expect((error) == (.localAdminCannotBeSocketProfile))
    }
  }

  @Test
  func testWorkspaceGrantCanBeChangedForAProfile() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(validManifest)
    let workspaceURL = fixture.root.appendingPathComponent("Granted Workspace")
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: true
    )
    let workspace = try await fixture.controlPlane.registerWorkspace(at: workspaceURL)

    var grant = try await fixture.controlPlane.setWorkspaceEnabled(
      true,
      workspaceID: workspace.id,
      profileID: .chatGPTOperate
    )
    #expect(grant.workspaceIDs.contains(workspace.id))

    grant = try await fixture.controlPlane.setWorkspaceEnabled(
      false,
      workspaceID: workspace.id,
      profileID: .chatGPTOperate
    )
    #expect(!(grant.workspaceIDs.contains(workspace.id)))

    do {
      _ = try await fixture.controlPlane.setWorkspaceEnabled(
        true,
        workspaceID: "missing",
        profileID: .chatGPTOperate
      )
      Issue.record("Expected unknown workspace rejection.")
    } catch let error as AppControlPlaneServiceError {
      #expect((error) == (.unknownWorkspace("missing")))
    }
  }

  @Test
  func testManifestCapabilitiesRemainAuthoritativeAfterWorkspaceGrantPersistence() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(
      profileManifest(
        observeCapabilities: ["workspace.list", "workspace.describe", "file.exists"],
        observeSecureTunnelAccess: true
      )
    )
    let workspaceURL = fixture.root.appendingPathComponent("Evolving Workspace")
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: true
    )
    let workspace = try await fixture.controlPlane.registerWorkspace(at: workspaceURL)
    _ = try await fixture.controlPlane.setWorkspaceEnabled(
      true,
      workspaceID: workspace.id,
      profileID: .chatGPTObserve
    )

    _ = try await fixture.controlPlane.activateManifest(
      profileManifest(
        observeCapabilities: ["workspace.list", "workspace.describe", "file.read"],
        observeSecureTunnelAccess: false
      )
    )

    let profileGrants = try await fixture.controlPlane.profileGrants()
    let grant = try #require(
      profileGrants.first { $0.id == .chatGPTObserve }
    )
    #expect(grant.workspaceIDs.contains(workspace.id))
    #expect(grant.capabilityIDs.contains("file.read"))
    #expect(!(grant.capabilityIDs.contains("file.exists")))
    #expect(!(grant.allowedCallers.contains(.secureTunnel)))

    let gateway = try GatewayRuntime(
      configuration: try await fixture.controlPlane.activeConfiguration(),
      context: ExecutionContext(
        caller: .localApp,
        profileID: .chatGPTObserve,
        workspaceID: workspace.id
      ),
      database: fixture.database,
      registeredWorkspaces: [workspace]
    )
    let toolNames = Set(try gateway.listTools().map(\.name))
    #expect(toolNames.contains("file.read"))
    #expect(!(toolNames.contains("file.exists")))
  }

  @Test
  func testGatewayAndTunnelDesiredStatePersistsAcrossRuntimeStops() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(validManifest)
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
    _ = try await fixture.controlPlane.activateManifest(validManifest)
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
    let workspaceURL = fixture.root.appendingPathComponent("Workspace", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: true
    )
    try fixture.database.saveWorkspace(
      RegisteredWorkspace(
        id: "workspace-1",
        displayName: "Workspace",
        rootPath: workspaceURL.path
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
      """
    )

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
  func testFreshInstallInitializesWithOnboardingToolsBeforeWorkspaceRegistration()
    async throws
  {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(validManifest)
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
    #expect((Set(tools.map(\.name))) == (["workspace.list", "workspace.describe"]))
    let result = try await client.callTool(name: "workspace.list")
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
    #expect(((payload["workspaces"] as? [Any])?.count) == (0))

    await client.disconnect()
    await service.stop()
    #expect(!(FileManager.default.fileExists(atPath: socketURL.path)))
  }

  @Test
  func testWorkspaceRegistrationIsIdempotentAcrossCanonicalAliases() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let workspaceURL = fixture.root.appendingPathComponent("Canonical Workspace")
    let aliasURL = fixture.root.appendingPathComponent("Workspace Alias")
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: workspaceURL)

    let first = try await fixture.controlPlane.registerWorkspace(
      at: workspaceURL,
      displayName: "Canonical Workspace"
    )
    let second = try await fixture.controlPlane.registerWorkspace(
      at: workspaceURL,
      displayName: "Canonical Workspace"
    )
    let alias = try await fixture.controlPlane.registerWorkspace(
      at: aliasURL,
      displayName: "Canonical Workspace"
    )

    #expect(second.id == first.id)
    #expect(alias.id == first.id)
    let registered = try await fixture.controlPlane.workspaces()
    #expect(registered.count == 1)
    #expect(registered.first?.id == first.id)
    #expect(registered.first?.rootPath == first.rootPath)
    #expect(first.rootPath == workspaceURL.resolvingSymlinksInPath().path)
  }

  @Test
  func testWorkspaceRegistrationRejectsConflictingExplicitMetadata() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let workspaceURL = fixture.root.appendingPathComponent("Metadata Workspace")
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    let first = try await fixture.controlPlane.registerWorkspace(
      at: workspaceURL,
      displayName: "Stable Name"
    )

    do {
      _ = try await fixture.controlPlane.registerWorkspace(
        at: workspaceURL,
        displayName: "Conflicting Name"
      )
      Issue.record("Expected duplicate canonical-root metadata to be rejected")
    } catch let error as AppControlPlaneServiceError {
      #expect(
        error
          == .workspaceMetadataConflict(
            workspaceID: first.id,
            existingDisplayName: "Stable Name",
            requestedDisplayName: "Conflicting Name"
          ))
    }

    let registered = try await fixture.controlPlane.workspaces()
    #expect(registered.count == 1)
    #expect(registered.first?.id == first.id)
    #expect(registered.first?.displayName == "Stable Name")
  }

  @Test
  func testRemovingWorkspaceAliasRemovesCanonicalProfileReference() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    let canonical = RegisteredWorkspace(
      id: "workspace-canonical",
      displayName: "Shared Workspace",
      rootPath: fixture.root.appendingPathComponent("Shared Workspace").path,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let duplicate = RegisteredWorkspace(
      id: "workspace-duplicate",
      displayName: canonical.displayName,
      rootPath: canonical.rootPath,
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    try fixture.database.saveWorkspace(canonical)
    try fixture.database.saveWorkspace(duplicate)
    var profile = ProfileGrant.operate
    profile.workspaceIDs = [duplicate.id]
    try fixture.database.saveProfile(profile)
    let plan = try await fixture.controlPlane.workspaceDeduplicationPlan()
    _ = try await fixture.controlPlane.applyWorkspaceDeduplication(
      expectedPlanDigest: plan.planDigest,
      allowMetadataConflicts: false
    )

    try await fixture.controlPlane.removeWorkspace(id: duplicate.id)

    #expect(try fixture.database.workspaces().isEmpty)
    #expect(try fixture.database.workspace(id: canonical.id) == nil)
    #expect(try fixture.database.workspace(id: duplicate.id) == nil)
    #expect(try fixture.database.profiles().first?.workspaceIDs.isEmpty == true)
  }

  @Test
  func testWorkspaceAndProfileDisablementInvalidateElevationGrants() async throws {
    let fixture = try AppControlPlaneServiceFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.controlPlane.activateManifest(DefaultGatewayConfiguration.manifest)
    let workspaceURL = fixture.root.appendingPathComponent("Elevation Workspace")
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    let workspace = try await fixture.controlPlane.registerWorkspace(at: workspaceURL)
    let localAdmin = CodexRuntimeOwner(
      workspaceID: workspace.id,
      profileID: GatewayProfileID.localAdmin.rawValue,
      caller: GatewayCallerKind.localCLI.rawValue,
      transport: "control_socket",
      socketConnectionID: "local-control",
      tunnelInstanceID: nil,
      tunnelProfileID: nil
    )
    let operateOwner = CodexRuntimeOwner(
      workspaceID: workspace.id,
      profileID: GatewayProfileID.chatGPTOperate.rawValue,
      caller: GatewayCallerKind.secureTunnel.rawValue,
      transport: "gateway_socket",
      socketConnectionID: "operate-connection",
      tunnelInstanceID: "tunnel-1",
      tunnelProfileID: "computer-mcp"
    )
    let workspaceGrant = try CodexElevationGrantService.request(
      owner: operateOwner,
      database: fixture.database,
      threadID: nil,
      mode: .nextTurn,
      reason: "Workspace disablement fixture.",
      maximumDurationSeconds: 300,
      maximumTurnCount: nil
    )
    _ = try CodexElevationGrantService.approve(
      id: workspaceGrant.id,
      owner: localAdmin,
      database: fixture.database
    )
    _ = try await fixture.controlPlane.setWorkspaceEnabled(
      false,
      workspaceID: workspace.id,
      profileID: .chatGPTOperate
    )
    #expect(
      try fixture.database.codexElevationGrant(id: workspaceGrant.id)?.state == .invalidated
    )

    let observeOwner = CodexRuntimeOwner(
      workspaceID: workspace.id,
      profileID: GatewayProfileID.chatGPTObserve.rawValue,
      caller: GatewayCallerKind.secureTunnel.rawValue,
      transport: "gateway_socket",
      socketConnectionID: "observe-connection",
      tunnelInstanceID: "tunnel-1",
      tunnelProfileID: "computer-mcp"
    )
    let profileGrant = try CodexElevationGrantService.request(
      owner: observeOwner,
      database: fixture.database,
      threadID: nil,
      mode: .nextTurn,
      reason: "Profile change fixture.",
      maximumDurationSeconds: 300,
      maximumTurnCount: nil
    )
    _ = try CodexElevationGrantService.approve(
      id: profileGrant.id,
      owner: localAdmin,
      database: fixture.database
    )
    try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
    #expect(
      try fixture.database.codexElevationGrant(id: profileGrant.id)?.state == .invalidated
    )
  }

  private var validManifest: String {
    """
    schema_version = 1

    [server]
    name = "computer-mcp-test"
    """
  }

  private func profileManifest(
    observeCapabilities: [String],
    observeSecureTunnelAccess: Bool
  ) -> String {
    let capabilities = observeCapabilities.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
      schema_version = 1

      [server]
      name = "computer-mcp-profile-test"

      [[profiles]]
      id = "chatgpt-observe"
      capabilities = [\(capabilities)]
      allowed_callers = \(observeSecureTunnelAccess ? "[\"secure-tunnel\"]" : "[\"local-app\"]")
      full_shell_enabled = false

      [builtin]
      enabled = ["file.exists", "file.read"]
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

  init(
    keychainAdapter: (any KeychainAdapter)? = nil,
    launchAtLoginController: any LaunchAtLoginControlling = MemoryLaunchAtLoginController(),
    openAITunnelGatewayExecutablePath: String = "computer-mcp"
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
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest,
      database: database
    )
    secretStore = try KeychainSecretStore(adapter: keychainAdapter ?? MemoryKeychainAdapter())
    let openAITunnelSupervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: TestOpenAITunnelProcessManager()
    )
    controlPlane = AppControlPlaneService(
      directories: directories,
      database: database,
      manifestStore: manifestStore,
      secretStore: secretStore,
      openAITunnelSupervisor: openAITunnelSupervisor,
      openAITunnelGatewayExecutablePath: openAITunnelGatewayExecutablePath,
      providerDiscovery: TestProviderDiscovery(),
      launchAtLoginController: launchAtLoginController
    )
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
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
