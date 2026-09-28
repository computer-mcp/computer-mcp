import Foundation
import Testing

@testable import ComputerMCP

@Suite(.nativeIntegration, .timeLimit(.minutes(2)))
struct GatewayRemoteManagementTests {
  @Test
  func connectedWorkspaceManagementUsesConsentAndPreservesItAcrossPublication() async throws {
    let fixture = try PluginControlFixture(bundled: .load(directory: nil))
    defer { fixture.remove() }
    let client = try await connect(fixture)
    do {
      #expect(try await client.listToolNames().contains("profile.show"))
      #expect(try await !client.listToolNames().contains("workspace.add"))
      _ = try await call(client, "workspace.add", ["path": .string(fixture.root.path)], fails: true)
      let approved = try await approve(fixture)
      #expect(try await client.listToolNames().contains("workspace.add"))
      let sibling = try await GatewayClientSession.connectSocket(
        socketURL: fixture.directories.gatewaySocket)
      #expect(try await !sibling.listToolNames().contains("workspace.add"))
      let root = fixture.root.appendingPathComponent("project")
      let replacement = fixture.root.appendingPathComponent("replacement")
      for path in [root, replacement] {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
      }
      _ = try await call(
        client, "workspace.add",
        [
          "path": .string(root.path), "principal_id": .string("forged"),
        ], fails: true)
      let added = try await call(client, "workspace.add", ["path": .string(root.path)])
      let id = try #require(added.objectValue?["workspace"]?.objectValue?["id"]?.stringValue)
      #expect(try fixture.database.workspaces().contains { $0.id == id })
      let listed = try await call(client, "workspace.list")
      #expect(
        listed.objectValue?["workspaces"]?.arrayValue?.contains {
          $0.objectValue?["id"] == .string(id)
        } == true)
      let afterAdd = try #require(
        await fixture.gateway.controlSessions().first { $0.id == approved.id })
      #expect(
        afterAdd.revision == approved.revision
          && afterAdd.fullAccessConsent == approved.fullAccessConsent)
      _ = try await call(
        client, "workspace.remove",
        [
          "id": .string(id), "expected_root_path": .string(replacement.path),
        ], fails: true)
      let reviewedRoot = try #require(
        added.objectValue?["workspace"]?.objectValue?["root_path"]?.stringValue)
      #expect(
        try WorkspaceRootIdentity(URL(fileURLWithPath: reviewedRoot)) == WorkspaceRootIdentity(root)
      )
      let repaired = try await call(
        client, "workspace.repair",
        [
          "id": .string(id), "expected_root_path": .string(reviewedRoot),
          "path": .string(replacement.path),
        ])
      let repairedRoot = try #require(
        repaired.objectValue?["workspace"]?.objectValue?["root_path"]?.stringValue)
      #expect(
        try WorkspaceRootIdentity(URL(fileURLWithPath: repairedRoot))
          == WorkspaceRootIdentity(replacement))
      _ = try await call(
        client, "workspace.remove",
        [
          "id": .string(id), "expected_root_path": .string(repairedRoot),
        ])
      #expect(try fixture.database.workspaces().allSatisfy { $0.id != id })
      #expect(FileManager.default.fileExists(atPath: replacement.path))
      _ = try await call(
        client, "profile.limit",
        [
          "mode": .string("full"), "expected_revision": .integer(approved.revision),
        ], fails: true)
      _ = try await call(
        client, "profile.limit",
        [
          "mode": .string("observe"), "expected_revision": .integer(approved.revision),
        ])
      #expect(try await !client.listToolNames().contains("workspace.add"))
      let limited = try await call(client, "profile.show")
      #expect(limited.objectValue?["access_limit"] == .string("read-only"))
      _ = try await call(
        client, "profile.limit",
        [
          "mode": .string("restricted"), "expected_revision": .integer(approved.revision + 1),
        ], fails: true)
      let events = try fixture.database.auditEvents(limit: 100)
      #expect(
        events.contains {
          $0.capabilityID == "workspace.add" && $0.decision == .allowed && $0.caller == .localMCP
        })
      #expect(try fixture.database.clientTrusts().isEmpty)
      await sibling.disconnect()
      await client.disconnect()
      await fixture.gateway.stop()
    } catch {
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
  }

  @Test
  func workspaceGrantChangesOnlyCurrentProfileWithExactRevisionAndInvalidatesConsent() async throws
  {
    let fixture = try PluginControlFixture(bundled: .load(directory: nil))
    defer { fixture.remove() }
    let client = try await connect(fixture)
    do {
      let approved = try await approve(fixture)
      let profile = try #require(approved.profile)
      _ = try await call(
        client, "workspace.grant",
        [
          "id": .string("fixture"), "enabled": .bool(false),
          "expected_profile_revision": .integer(profile.grant.authorizationRevision + 1),
        ], fails: true)
      #expect(try fixture.database.profiles().isEmpty)
      _ = try await call(
        client, "workspace.grant",
        [
          "id": .string("fixture"), "enabled": .bool(false),
          "expected_profile_revision": .integer(profile.grant.authorizationRevision),
        ])
      let profiles = try fixture.database.profiles()
      #expect(profiles.count == 1 && profiles.first?.id == .chatGPTOperate)
      #expect(profiles.first?.workspaceIDs.isEmpty == true)
      let current = try #require(await fixture.gateway.controlSessions().first)
      #expect(current.fullAccessConsent == nil)
      #expect(try await !client.listToolNames().contains("workspace.grant"))
      await client.disconnect()
      await fixture.gateway.stop()
    } catch {
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
  }

  @Test
  func officialInstallationUsesTypedRemoteDispatchAndUnknownSourceNeedsLocalTrust() async throws {
    let manifest = PreparationFixture.manifest.replacingOccurrences(
      of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']")
    let archive = try await PreparationFixture.make(manifest: manifest, format: "zip")
    defer { archive.files.remove() }
    let bytes = try Data(contentsOf: archive.archive)
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let http = ReleaseHTTPFake(manifest: manifest, artifactBytes: bytes)
    let fixture = try PluginControlFixture(
      worker: archive.preparation.workerExecutable.path, releases: GitHubPluginReleases(http: http),
      download: GitHubPluginDownload(origin: server.origin), bundled: .load(directory: nil))
    defer { fixture.remove() }
    let client = try await connect(fixture)
    do {
      let approved = try await approve(fixture)
      let artifact = pluginArtifactFixture(bytes: bytes, manifest: manifest)
      let installed = try await call(
        client, "plugin.install",
        [
          "artifact": try ControlToolResponse.encodedPayload(artifact),
          "expected_revision": .integer(0),
        ])
      #expect(installed.objectValue?["revision"] == .integer(1))
      let record = try #require(fixture.database.pluginStoreSnapshot().installations.first)
      #expect(record.source.githubRelease == artifact)
      _ = try await call(
        client, "plugin.configure",
        [
          "id": .string("combined"), "expected_revision": .integer(0), "settings": .object([:]),
        ], fails: true)
      _ = try await call(
        client, "plugin.configure",
        [
          "id": .string("combined"), "expected_revision": .integer(1),
          "settings": .object(["mcp": .object(["native": .object(["authentication": .null])])]),
        ], fails: true)
      #expect(try fixture.database.pluginStoreSnapshot().revision == 1)
      _ = try await call(
        client, "plugin.configure",
        [
          "id": .string("combined"), "expected_revision": .integer(1),
          "settings": .object(["mcp": .object(["native": .object(["enabled": .bool(false)])])]),
        ])
      let shown = try await call(client, "plugin.describe", ["id": .string("combined")])
      #expect(shown.objectValue?["revision"] == .integer(2))
      _ = try await call(
        client, "plugin.enable", ["id": .string("combined"), "expected_revision": .integer(2)])
      #expect(try fixture.database.pluginStoreSnapshot().settings["combined"]?.enabled == true)
      _ = try await call(
        client, "plugin.disable", ["id": .string("combined"), "expected_revision": .integer(3)])
      _ = try await call(
        client, "plugin.uninstall",
        [
          "installation_id": .string(record.id), "expected_revision": .integer(4),
        ])
      #expect(try fixture.database.pluginStoreSnapshot().installations.isEmpty)
      let after = try #require(await fixture.gateway.controlSessions().first)
      #expect(
        after.revision == approved.revision && after.fullAccessConsent == approved.fullAccessConsent
      )
      let files = try PluginStoreFixture()
      defer { files.cleanup() }
      let state = try await fixture.gateway.changePlugins(
        .registerDevelopment(files.packageRoot), expectedRevision: 5)
      _ = try await call(
        client, "plugin.enable",
        [
          "id": .string("test-package"), "expected_revision": .integer(state.state.revision),
        ], fails: true)
      _ = try await call(client, "plugin.list", ["limit": .integer(201)], fails: true)
      #expect(try fixture.database.pluginStoreSnapshot() == state.state)
      let events = try fixture.database.auditEvents(limit: 100)
      #expect(
        events.contains {
          $0.capabilityID == "plugin.install" && $0.decision == .allowed && $0.caller == .localMCP
        })
      await client.disconnect()
      await fixture.gateway.stop()
    } catch {
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
  }

  @Test
  func admittedShellWorkCompletesAcrossRemoteWorkspacePublication() async throws {
    let fixture = try PluginControlFixture(bundled: .load(directory: nil))
    defer { fixture.remove() }
    let client = try await connect(fixture)
    _ = try await approve(fixture)
    let work = Task {
      try await call(
        client, "shell.run",
        [
          "workspace_id": .string("fixture"), "mode": .string("argv"),
          "executable": .string("/bin/sh"), "cwd": .string(fixture.root.path),
          "argv": .array([
            .string("-c"),
            .string(
              "printf started > started; for i in $(seq 1 100); do test -f release && break; sleep 0.05; done; test -f release && printf finished > finished"
            ),
          ]),
        ])
    }
    do {
      let deadline = ContinuousClock.now + .seconds(5)
      while !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("started").path)
      {
        try #require(ContinuousClock.now < deadline, "Shell work did not start")
        try await Task.sleep(for: .milliseconds(5))
      }
      let project = fixture.root.appendingPathComponent("new-project")
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      _ = try await call(client, "workspace.add", ["path": .string(project.path)])
      try Data().write(to: fixture.root.appendingPathComponent("release"))
      _ = try await work.value
      #expect(
        try String(contentsOf: fixture.root.appendingPathComponent("finished"), encoding: .utf8)
          == "finished")
      await client.disconnect()
      await fixture.gateway.stop()
    } catch {
      try? Data().write(to: fixture.root.appendingPathComponent("release"))
      work.cancel()
      _ = try? await work.value
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func revocationDuringVerifiedDownloadCannotPublish(endSession: Bool) async throws {
    let manifest = PreparationFixture.manifest.replacingOccurrences(
      of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']")
    let archive = try await PreparationFixture.make(manifest: manifest, format: "zip")
    defer { archive.files.remove() }
    let bytes = try Data(contentsOf: archive.archive)
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let http = SuspendedReleaseValidation(
      base: ReleaseHTTPFake(manifest: manifest, artifactBytes: bytes))
    let fixture = try PluginControlFixture(
      worker: archive.preparation.workerExecutable.path, releases: GitHubPluginReleases(http: http),
      download: GitHubPluginDownload(origin: server.origin), bundled: .load(directory: nil))
    defer { fixture.remove() }
    let client = try await connect(fixture)
    let approved = try await approve(fixture)
    let original = try fixture.database.pluginStoreSnapshot()
    let artifact = try ControlToolResponse.encodedPayload(
      pluginArtifactFixture(bytes: bytes, manifest: manifest))
    let pending = Task {
      try await call(
        client, "plugin.install", ["artifact": artifact, "expected_revision": .integer(0)],
        fails: true)
    }
    do {
      try await http.waitUntilPaused()
      #expect(try fixture.database.pluginOwnedDirectories().count == 1)
      if endSession {
        try await fixture.gateway.endControlSession(
          id: approved.id, expectedRevision: approved.revision)
      } else {
        _ = try await fixture.gateway.limitControlSession(
          id: approved.id, to: .readOnly, expectedRevision: approved.revision)
      }
      await http.release()
      let error = try await pending.value
      #expect(error.objectValue?["code"] == .string("policy.control_session_denied"))
      #expect(try fixture.database.pluginStoreSnapshot() == original)
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      await client.disconnect()
      await fixture.gateway.stop()
    } catch {
      await http.release()
      pending.cancel()
      _ = try? await pending.value
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
  }

  @Test
  func observeCanDiscoverOfficialArtifactsAndFullCanUpdateSelectedCode() async throws {
    let manifest = PreparationFixture.manifest.replacingOccurrences(
      of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']")
    let nextManifest = manifest.replacingOccurrences(
      of: "version = '1.2.3'", with: "version = '1.2.4'")
    let first = try await PreparationFixture.make(manifest: manifest, format: "zip")
    defer { first.files.remove() }
    let next = try await PreparationFixture.make(manifest: nextManifest, format: "zip")
    defer { next.files.remove() }
    let body = first.files.root.appendingPathComponent("download-body")
    let firstBytes = try Data(contentsOf: first.archive)
    let nextBytes = try Data(contentsOf: next.archive)
    try firstBytes.write(to: body)
    let server = try await CatalogHTTPFixture.start(
      script:
        pluginDownloadHTTPFixture(bytes: firstBytes).replacingOccurrences(
          of: "body = base64.b64decode('\(firstBytes.base64EncodedString())')",
          with: "body = open('\(body.path)', 'rb').read()"))
    defer { server.stop() }
    let http = RemoteReleaseSelection(
      base: ReleaseHTTPFake(manifest: manifest, artifactBytes: firstBytes))
    let fixture = try PluginControlFixture(
      worker: first.preparation.workerExecutable.path, releases: GitHubPluginReleases(http: http),
      download: GitHubPluginDownload(origin: server.origin), bundled: .load(directory: nil))
    defer { fixture.remove() }
    try await StaticPluginCatalogCache(
      url: fixture.directories.applicationSupport.appendingPathComponent(
        "Cache/PluginCatalog/index.json")
    ).write(.init(body: staticCatalogFixture(), validators: .init(), validatedAt: .now))
    let client = try await connect(fixture)
    do {
      let scope = try #require(await fixture.gateway.controlSessions().first)
      _ = try await fixture.gateway.limitControlSession(
        id: scope.id, to: .readOnly, expectedRevision: scope.revision)
      let search = try await call(client, "plugin.search", ["query": .string("example")])
      #expect(search.objectValue?["entries"]?.arrayValue?.count == 1)
      let artifacts = try await call(
        client, "plugin.artifacts",
        [
          "repository": .string("computer-mcp/plugin-example"), "repository_id": .integer(10),
        ])
      #expect(artifacts.objectValue?["artifacts"]?.arrayValue?.count == 1)
      _ = try await call(client, "plugin.search", ["page": .integer(0)], fails: true)
      _ = try await call(client, "profile.show", ["id": .string("other-principal")], fails: true)
      let approved = try await approve(fixture)
      _ = try await call(
        client, "plugin.install",
        [
          "artifact": try ControlToolResponse.encodedPayload(
            pluginArtifactFixture(bytes: firstBytes, manifest: manifest)),
          "expected_revision": .integer(0),
        ])
      _ = try await call(
        client, "plugin.configure",
        [
          "id": .string("combined"), "expected_revision": .integer(1),
          "settings": .object(["cli": .object(["commands": .object(["allowAnyArgs": .bool(true)])])]
          ),
        ])
      let old = try fixture.database.pluginStoreSnapshot()
      let parsed = pluginArtifactFixture(bytes: nextBytes, assetID: 31, manifest: nextManifest)
      let selection = GitHubPluginArtifact(
        declaration: parsed.declaration, releaseID: 19, tag: "v1.2.4", prerelease: false,
        assetID: 31, name: parsed.name, size: parsed.size, sha256: parsed.sha256)
      let replacement = ReleaseHTTPFake(
        manifest: nextManifest, artifactBytes: nextBytes, tag: "v1.2.4")
      await replacement.setAssets([releaseAssetFixture(id: 31, artifact: selection)], page: 1)
      await http.select(replacement, releaseID: 19)
      try nextBytes.write(to: body, options: .atomic)
      _ = try await call(
        client, "plugin.update",
        [
          "id": .string("other-plugin"),
          "artifact": try ControlToolResponse.encodedPayload(selection),
          "expected_revision": .integer(2),
        ], fails: true)
      _ = try await call(
        client, "plugin.update",
        [
          "id": .string("combined"), "artifact": try ControlToolResponse.encodedPayload(selection),
          "expected_revision": .integer(2),
        ])
      let updated = try fixture.database.pluginStoreSnapshot()
      #expect(updated.revision == 3 && updated.installations.count == 2)
      #expect(
        updated.selectedInstallations != old.selectedInstallations
          && updated.settings == old.settings)
      let selected = try #require(
        updated.installations.first { $0.id == updated.selectedInstallations["combined"] })
      #expect(
        selected.version == (try PluginVersion("1.2.4"))
          && selected.source.githubRelease == selection)
      let after = try #require(await fixture.gateway.controlSessions().first)
      #expect(after.fullAccessConsent == approved.fullAccessConsent)
      await client.disconnect()
      await fixture.gateway.stop()
    } catch {
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
  }

  private func connect(_ fixture: PluginControlFixture) async throws -> GatewayClientSession {
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
      profiles: [
        .init(
          id: .chatGPTOperate, capabilities: ["*"], workspaces: ["fixture"],
          allowedCallers: [.localMCP], mode: .workspaceOperations, confirmationPolicy: .never)
      ],
      workspaceDirectory: fixture.root)
    configuration.policy.shellEnabled = true
    _ = try await fixture.host.activateManifest(configuration.exportedTOML())
    try fixture.database.saveWorkspace(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    try await fixture.gateway.start(profile: .chatGPTOperate)
    return try await GatewayClientSession.connectSocket(
      socketURL: fixture.directories.gatewaySocket)
  }

  private func approve(_ fixture: PluginControlFixture) async throws
    -> GatewayControlSessionSnapshot
  {
    let session = try #require(await fixture.gateway.controlSessions().first)
    return try await fixture.gateway.approveControlSession(
      id: session.id, expectedRevision: session.revision)
  }

  private func call(
    _ client: GatewayClientSession, _ name: String, _ arguments: [String: JSONValue] = [:],
    fails: Bool = false
  ) async throws -> JSONValue {
    let result = try await client.call(toolName: name, arguments: .object(arguments)).result
    try #require(result.objectValue?["isError"] == .bool(fails), "\(name): \(result)")
    return result.objectValue?["structuredContent"]?.objectValue?[fails ? "error" : "result"]
      ?? .null
  }
}

struct GatewayRemoteManagementAuthorityTests {
  @Test
  func pluginSummariesStaySmallAndInstallationPagesUseStableIDs() throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    var state = PluginStoreSnapshot()
    state.revision = 9_007_199_254_740_993
    state.installations = try (0..<3).map { index in
      PluginInstallationRecord(
        id: "install-\(index)", pluginID: "test-package",
        version: try PluginVersion("1.0.\(index)"),
        source: .init(kind: .development, root: files.packageRoot),
        manifestDigest: String(repeating: "a", count: 64), registeredAt: .now)
    }
    let snapshot = try PluginHostSnapshot(state: state, bundled: .load(directory: nil))
    let summary = try GatewayRemoteManagement.plugin(
      "test-package", snapshot: snapshot, details: false)
    #expect(summary.objectValue?["revision"] == .integer(9_007_199_254_740_993))
    #expect(summary.objectValue?["installation_count"] == .integer(3))
    #expect(summary.objectValue?["settings"] == nil && summary.objectValue?["installations"] == nil)
    let first = try GatewayRemoteManagement.plugin("test-package", snapshot: snapshot, limit: 2)
    #expect(first.objectValue?["installations"]?.arrayValue?.count == 2)
    #expect(first.objectValue?["next_after_id"] == .string("install-1"))
    let last = try GatewayRemoteManagement.plugin(
      "test-package", snapshot: snapshot, afterID: "install-1", limit: 2)
    #expect(last.objectValue?["installations"]?.arrayValue?.count == 1)
    #expect(last.objectValue?["next_after_id"] == .null)
    #expect(throws: (any Error).self) {
      try GatewayRemoteManagement.plugin("test-package", snapshot: snapshot, limit: 201)
    }
  }

  @Test
  func credentialConfigurationAndArgumentValuesDoNotEscapeInspection() throws {
    let authentication = MCPHTTPAuthentication(
      endpoint: "https://example.test/mcp", keychainAccount: "private-binding")
    let current = PluginSettings(mcp: [
      "remote": .init(args: ["private-argument"], authentication: authentication)
    ])
    let patched = try GatewayRemoteManagement.patchSettings(
      .object(["enabled": .bool(true)]), current: current)
    #expect(patched.mcp["remote"]?.authentication == authentication)
    #expect(patched.mcp["remote"]?.args == ["private-argument"])
    for patch: JSONValue in [
      .object(["mcp": .null]),
      .object(["mcp": .object(["remote": .object(["authentication": .null])])]),
      .object(["unknown": .bool(true)]),
    ] {
      #expect(throws: (any Error).self) {
        try GatewayRemoteManagement.patchSettings(patch, current: current)
      }
    }
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let bundle = BundledPlugins(
      packages: [try PluginPackage.load(at: files.packageRoot)], issues: [])
    var state = PluginStoreSnapshot()
    state.settings["test-package"] = current
    let report = try GatewayRemoteManagement.plugin(
      "test-package", snapshot: .init(state: state, bundled: bundle))
    let text = ControlToolResponse.payloadText(report)
    #expect(!text.contains("private-binding") && !text.contains("private-argument"))
  }

  @Test(arguments: ["plugin", "workspace", "profile"])
  func persistentTrustRevocationBetweenSessionCheckAndSQLCommitCannotWrite(kind: String) throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let database = try GatewayDatabase(path: files.databaseURL.path)
    try database.saveWorkspace(
      .init(id: "project", displayName: "Project", rootPath: files.root.path))
    let profile = GatewayControlProfile(
      grant: .init(
        id: .chatGPTOperate, capabilityIDs: ["*"], workspaceIDs: ["project"],
        allowedCallers: [.localMCP], mode: .workspaceOperations), persisted: false)
    let session = GatewayControlSession(
      principalID: "verified", profileID: .chatGPTOperate, caller: .localMCP, database: database,
      profile: profile)
    var context = ExecutionContext(
      caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "verified")
    context.controlSession = session
    let consent = try session.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let trust = try #require(database.clientTrusts().first)
    let authorization = GatewayManagementAuthorization(
      session: session, context: context, revision: consent.revision, requiresFullAccess: true)
    let before = try database.configurationState()
    let prepared = try database.prepareWorkspaceChange(.remove("project"), expected: before)
    var changed = before.plugins
    changed.revision += 1
    #expect(throws: (any Error).self) {
      try authorization.perform {
        try database.revokeClientTrust(id: trust.id, expectedRevision: trust.revision)
        switch kind {
        case "plugin":
          _ = try database.savePluginStoreSnapshot(
            changed, expectedRevision: 0, expectedConfiguration: before,
            authorization: authorization)
        case "workspace":
          _ = try database.saveWorkspaceChange(
            prepared, resolution: .init(), authorization: authorization)
        default:
          try database.saveProfile(
            profile.grant, expectedRevision: 0, expectedConfiguration: before,
            authorization: authorization)
        }
      }
    }
    #expect(try database.configurationState() == before)
    #expect(try database.clientTrusts().first?.fullAccessAllowed == false)
  }

  @Test
  func finalCommitRejectsRevokedEndedStaleAndSerializedScope() throws {
    let database = try GatewayDatabase(inMemory: ())
    let profile = GatewayControlProfile(
      grant: .init(
        id: .chatGPTOperate, capabilityIDs: ["*"], workspaceIDs: ["*"],
        allowedCallers: [.localMCP], mode: .workspaceOperations), persisted: false)
    let session = GatewayControlSession(
      principalID: "verified", profileID: .chatGPTOperate, caller: .localMCP, database: database,
      profile: profile)
    var context = ExecutionContext(
      caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "verified")
    context.controlSession = session
    let consent = try session.approveFullAccess(expectedRevision: 0)
    let authorization = GatewayManagementAuthorization(
      session: session, context: context, revision: consent.revision, requiresFullAccess: true)
    #expect(try authorization.perform { 42 } == 42)
    let serialized = try JSONDecoder().decode(
      ExecutionContext.self, from: JSONEncoder().encode(context))
    #expect(throws: (any Error).self) {
      try session.withManagementAuthorization(
        context: serialized, expectedRevision: consent.revision, requiresFullAccess: true
      ) { Issue.record("Invalid scope committed") }
    }
    try session.limitAccess(to: .readOnly, expectedRevision: consent.revision)
    #expect(throws: (any Error).self) {
      try authorization.perform { Issue.record("Revoked write committed") }
    }
    #expect(throws: (any Error).self) {
      try session.limitAccess(
        to: .workspaceOperations, expectedRevision: session.snapshot.revision, allowIncrease: false)
    }
    session.end()
    #expect(throws: (any Error).self) {
      try authorization.perform { Issue.record("Ended write committed") }
    }
  }
}

private actor SuspendedReleaseValidation: PluginCatalogHTTPFetching {
  let base: ReleaseHTTPFake
  private var validations = 0
  private var paused = false
  private var released = false

  init(base: ReleaseHTTPFake) { self.base = base }

  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
  {
    if path == "/repos/computer-mcp/combined" {
      validations += 1
      if validations == 2 {
        paused = true
        let deadline = ContinuousClock.now + .seconds(10)
        while !released {
          guard ContinuousClock.now < deadline else { throw PluginCatalogError.timedOut }
          try await Task.sleep(for: .milliseconds(5))
        }
      }
    }
    return try await base.fetch(path: path, query: query, accept: accept, maxBytes: maxBytes)
  }

  func waitUntilPaused() async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !paused {
      guard ContinuousClock.now < deadline else { throw PluginCatalogError.timedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  func release() { released = true }
}

private actor RemoteReleaseSelection: PluginCatalogHTTPFetching {
  var base: ReleaseHTTPFake
  var releaseID: Int64 = 9

  init(base: ReleaseHTTPFake) { self.base = base }

  func select(_ base: ReleaseHTTPFake, releaseID: Int64) {
    self.base = base
    self.releaseID = releaseID
  }

  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
  {
    let response = try await base.fetch(
      path: path, query: query, accept: accept, maxBytes: maxBytes)
    guard path == "/repos/computer-mcp/combined/releases/\(releaseID)" else { return response }
    var object = try #require(response.decode(JSONValue.self).objectValue)
    object["id"] = .integer(releaseID)
    return .init(
      status: response.status, headers: response.headers,
      body: try ControlToolResponse.encodedJSON(.object(object)))
  }
}
