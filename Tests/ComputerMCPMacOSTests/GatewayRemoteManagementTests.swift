import ComputerMCPMacOS
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(2)))
struct GatewayRemoteManagementTests {
  @Test
  func pluginRefusalSurvivesGatewayResponsesAndAuditStorage() async throws {
    let archive = try await PreparationFixture.make(
      launcher: testExecutionLauncher(),
      directoryFactory: MacOSPlatform.services(launcher: testExecutionLauncher()).pluginDirectories)
    defer { archive.files.remove() }
    let http = ReleaseHTTPFake()
    await http.setManifest(
      releaseManifestFixture.replacingOccurrences(
        of: "plugin_api = 1", with: "plugin_api = 2\nfuture = true"))
    let fixture = try PluginControlFixture(
      worker: archive.preparation.workerExecutable.path,
      releases: GitHubPluginReleases(http: http), bundled: .load(directory: nil))
    defer { fixture.remove() }
    let client = try await connect(fixture)
    do {
      _ = try await approve(fixture)
      let refusal = try #require(
        PluginAPIVersions.supported.refusal(
          pluginID: "combined", version: PluginVersion("1.2.3"), declared: 2))
      let error = try await call(
        client, "plugin.install",
        [
          "artifact": try ControlToolResponse.encodedPayload(pluginArtifactFixture()),
          "expected_revision": .integer(0),
        ], fails: true)
      let encoded = try ControlToolResponse.encodedPayload(refusal)
      #expect(error.objectValue?["code"] == .string(refusal.code))
      #expect(error.objectValue?["refusal"] == encoded)
      let event = try #require(
        fixture.database.auditEvents(limit: 20).first { $0.capabilityID == "plugin.install" })
      #expect(event.errorCode == refusal.code)
      #expect(event.errorDetails?.objectValue?["refusal"] == encoded)
      #expect(try fixture.database.pluginStoreSnapshot() == PluginStoreSnapshot())
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      #expect(await http.assetPages.isEmpty)
    } catch {
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
    await client.disconnect()
    await fixture.gateway.stop()
  }

  @Test
  func pluginInventoryRetainsRefusalsWithoutALoadableBundledManifest() throws {
    let refusal = try #require(
      PluginAPIVersions.supported.refusal(
        pluginID: "future", version: PluginVersion("1.0.0"), declared: 2))
    let snapshot = try PluginHostSnapshot(
      state: PluginStoreSnapshot(),
      bundled: .init(
        packages: [],
        issues: [
          .init(pluginID: "future", message: refusal.message, refusal: refusal)
        ]), applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications)
    #expect(GatewayRemoteManagement.pluginIDs(snapshot) == ["future"])
    let expected = try ControlToolResponse.encodedPayload(refusal)
    for details in [true, false] {
      let value = try GatewayRemoteManagement.plugin("future", snapshot: snapshot, details: details)
      #expect(value.objectValue?["refusals"]?.arrayValue == [expected])
    }
  }

  @Test
  func connectedProjectManagementUsesConsentAndPreservesItAcrossPublication() async throws {
    let fixture = try PluginControlFixture(bundled: .load(directory: nil))
    defer { fixture.remove() }
    let client = try await connect(fixture)
    do {
      #expect(try await client.listToolNames().contains("profile.show"))
      #expect(try await client.listToolNames().contains("project.add"))
      _ = try await call(client, "project.add", ["path": .string(fixture.root.path)], fails: true)
      let approved = try await approve(fixture)
      #expect(try await client.listToolNames().contains("project.add"))
      let sibling = try await GatewayClientSession.connectSocket(
        socketURL: fixture.directories.gatewaySocket)
      #expect(try await sibling.listToolNames().contains("project.add"))
      _ = try await call(sibling, "project.add", ["path": .string(fixture.root.path)], fails: true)
      let root = fixture.root.appendingPathComponent("project")
      let replacement = fixture.root.appendingPathComponent("replacement")
      for path in [root, replacement] {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
      }
      let beforeFailedPublication = try fixture.database.configurationState()
      _ = try await call(
        client, "project.add",
        [
          "path": .string(root.path), "principal_id": .string("forged"),
        ], fails: true)
      #expect(try fixture.database.configurationState() == beforeFailedPublication)
      let afterFailedPublication = try #require(
        await fixture.gateway.controlSessions().first { $0.id == approved.id })
      #expect(afterFailedPublication == approved)
      let added = try await call(client, "project.add", ["path": .string(root.path)])
      let id = try #require(added.objectValue?["project"]?.objectValue?["id"]?.stringValue)
      #expect(try fixture.database.projects().contains { $0.id == id })
      let listed = try await call(client, "project.list")
      #expect(
        listed.objectValue?["projects"]?.arrayValue?.contains {
          $0.objectValue?["id"] == .string(id)
        } == true)
      let afterAdd = try #require(
        await fixture.gateway.controlSessions().first { $0.id == approved.id })
      #expect(
        afterAdd.revision == approved.revision
          && afterAdd.fullAccessConsent == approved.fullAccessConsent)
      _ = try await call(
        client, "project.remove",
        [
          "id": .string(id), "expected_root_path": .string(replacement.path),
        ], fails: true)
      let reviewedRoot = try #require(
        added.objectValue?["project"]?.objectValue?["root_path"]?.stringValue)
      #expect(
        try ProjectRootIdentity(URL(fileURLWithPath: reviewedRoot)) == ProjectRootIdentity(root)
      )
      let repaired = try await call(
        client, "project.repair",
        [
          "id": .string(id), "expected_root_path": .string(reviewedRoot),
          "path": .string(replacement.path),
        ])
      let repairedRoot = try #require(
        repaired.objectValue?["project"]?.objectValue?["root_path"]?.stringValue)
      #expect(
        try ProjectRootIdentity(URL(fileURLWithPath: repairedRoot))
          == ProjectRootIdentity(replacement))
      _ = try await call(
        client, "project.remove",
        [
          "id": .string(id), "expected_root_path": .string(repairedRoot),
        ])
      #expect(try fixture.database.projects().allSatisfy { $0.id != id })
      #expect(FileManager.default.fileExists(atPath: replacement.path))
      let beforeNoOp = try fixture.database.configurationState()
      _ = try await call(
        client, "profile.limit",
        [
          "limits": try .encoded(ManagedPolicy()), "expected_revision": .integer(approved.revision),
        ])
      let afterNoOp = try #require(
        await fixture.gateway.controlSessions().first { $0.id == approved.id })
      #expect(afterNoOp.revision == approved.revision + 1)
      #expect(afterNoOp.fullAccessConsent == approved.fullAccessConsent)
      #expect(afterNoOp.accessLimit == approved.accessLimit)
      #expect(try fixture.database.configurationState() == beforeNoOp)
      _ = try await call(
        client, "profile.limit",
        [
          "limits": try .encoded(ManagedPolicy(allowsFullAccess: false)),
          "expected_revision": .integer(approved.revision),
        ], fails: true)
      #expect(
        await fixture.gateway.controlSessions().first { $0.id == approved.id } == afterNoOp)
      _ = try await call(
        client, "profile.limit",
        [
          "limits": try .encoded(ManagedPolicy(allowsFullAccess: false)),
          "expected_revision": .integer(afterNoOp.revision),
        ])
      #expect(try await !client.listToolNames().contains("project.add"))
      let limited = try await call(client, "profile.show")
      #expect(
        limited.objectValue?["access_limit"]?.objectValue?["allows_full_access"] == .bool(false))
      let afterLimit = try #require(
        await fixture.gateway.controlSessions().first { $0.id == approved.id })
      #expect(afterLimit.fullAccessConsent == nil)
      _ = try await call(
        client, "profile.limit",
        [
          "limits": try .encoded(ManagedPolicy()),
          "expected_revision": .integer(afterLimit.revision),
        ], fails: true)
      #expect(
        await fixture.gateway.controlSessions().first { $0.id == approved.id } == afterLimit)
      let events = try fixture.database.auditEvents(limit: 100)
      #expect(
        events.contains {
          $0.capabilityID == "project.add" && $0.decision == .allowed && $0.caller == .localMCP
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
  func projectGrantChangesOnlyCurrentProfileWithExactRevisionAndInvalidatesConsent() async throws {
    let fixture = try PluginControlFixture(bundled: .load(directory: nil))
    defer { fixture.remove() }
    let client = try await connect(fixture)
    do {
      let approved = try await approve(fixture)
      let profile = try #require(approved.profile)
      let before = try fixture.database.profiles()
      _ = try await call(
        client, "project.grant",
        [
          "id": .string("fixture"), "access": .string("deny"),
          "expected_profile_revision": .integer(profile.grant.authorizationRevision + 1),
        ], fails: true)
      #expect(try fixture.database.profiles() == before)
      _ = try await call(
        client, "project.grant",
        [
          "id": .string("fixture"), "access": .string("deny"),
          "expected_profile_revision": .integer(profile.grant.authorizationRevision),
        ])
      let profiles = try fixture.database.profiles()
      #expect(
        profiles.first { $0.id == .chatGPTOperate }?.permissions.state(for: .project("fixture"))
          == .denied)
      #expect(
        profiles.filter { $0.id != .chatGPTOperate } == before.filter { $0.id != .chatGPTOperate })
      let current = try #require(await fixture.gateway.controlSessions().first)
      #expect(current.fullAccessConsent == nil)
      #expect(try await client.listToolNames().contains("project.grant"))
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
    let archive = try await PreparationFixture.make(
      launcher: testExecutionLauncher(),
      directoryFactory: MacOSPlatform.services(launcher: testExecutionLauncher()).pluginDirectories,
      manifest: manifest, format: "zip")
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

  @Test(arguments: ["cliMetadata", "nestedProject", "disjointProject"])
  func publicationPreservesUnchangedAuthorityAndRetiresNewProjectBoundaries(change: String)
    async throws
  {
    let addsProject = change != "cliMetadata"
    let nested = change == "nestedProject"
    let packageFiles = try ScopedTemporaryDirectory()
    let manifest = """
      id = 'publication-fixture'
      name = 'Publication fixture'
      version = '1.0.0'
      plugin_api = 1
      [[cli]]
      id = 'metadata'
      executable = { path = 'metadata.sh' }
      """
    try manifest.write(
      to: packageFiles.url.appendingPathComponent(PluginManifest.filename), atomically: true,
      encoding: .utf8)
    let helper = packageFiles.url.appendingPathComponent("metadata.sh")
    try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let package = try PluginPackage.load(at: packageFiles.url)
    #expect(package.manifest.mcp.isEmpty && package.manifest.skills.isEmpty)
    #expect(package.manifest.cli.count == 1 && package.manifest.cli[0].tree == nil)
    let program = """
      #!/usr/bin/python3
      import pathlib, time
      pathlib.Path("started").write_text("started")
      deadline = time.monotonic() + 5
      while not pathlib.Path("release").exists():
          if time.monotonic() >= deadline:
              raise SystemExit(64)
          time.sleep(0.05)
      pathlib.Path("finished").write_text("finished")
      """
    let fixture = try PluginControlFixture(
      bundled: .init(packages: [package], issues: []),
      executionLauncher: { root in
        let executable = root.appendingPathComponent("retained.py")
        try program.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return fixtureProtocolExecutionLauncher(root: root, scripts: [program], arguments: [[]])
      })
    defer { fixture.remove() }
    let outside = try ScopedTemporaryDirectory()
    let client = try await connect(fixture)
    let approved = try await approve(fixture)
    var work: Task<JSONValue, any Error>?
    do {
      _ = try await call(
        client, "plugin.configure",
        [
          "id": .string(package.manifest.id), "expected_revision": .integer(0),
          "settings": .object([
            "enabled": .bool(true),
            "cli": .object(["metadata": .object(["allowAnyArgs": .bool(false)])]),
          ]),
        ])
      let beforePublication = try fixture.database.configurationState()
      #expect(beforePublication.plugins.revision == 1)
      #expect(beforePublication.plugins.settings[package.manifest.id]?.enabled == true)
      #expect(
        beforePublication.plugins.settings[package.manifest.id]?.cli["metadata"]?.allowAnyArgs
          == false)
      let running = Task {
        try await call(
          client, "shell.run",
          [
            "project_id": .string("fixture"), "mode": .string("argv"),
            "executable": .string(fixture.root.appendingPathComponent("retained.py").path),
            "cwd": .string(fixture.root.path), "argv": .array([]),
          ], fails: addsProject)
      }
      work = running
      let deadline = ContinuousClock.now + .seconds(5)
      while !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("started").path)
      {
        try #require(ContinuousClock.now < deadline, "Shell work did not start")
        try await Task.sleep(for: .milliseconds(5))
      }
      let authority = try fixture.database.permissionRuntime(platform: fixture.host.platform)
      let admitted = try authority.store.readWithDatabase { database, ledger in
        let proof = try #require(
          ledger.authorizations.values.first {
            $0.invocation.tool == "shell.run" && $0.executionID != nil
          })
        let executionID = try #require(proof.executionID)
        let native = try #require(try ExecutionRuntimeRecord.load(executionID, database))
        let child = try #require(native.children.values.first)
        #expect(native.children.count == 1)
        #expect((child.recovery?.root.processID ?? 0) > 0)
        #expect(!child.completed && !native.completed)
        var copy = ledger
        #expect(try copy.invocationAccess(proof.id) == proof)
        return (
          proof: proof, environment: ledger.environment,
          permissions: ledger.permissions(for: proof.invocation.principal),
          settings: ledger.sandboxSettings, epoch: ledger.authorizationEpochID
        )
      }
      let proof = admitted.proof
      let executionID = try #require(proof.executionID)
      var introducedBoundary: CanonicalPath?
      var coveringBasis: PathAccessBasis?
      if addsProject {
        let project = (nested ? fixture.root : outside.url).appendingPathComponent("new-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let boundary = try CanonicalPath(ProjectPathResolver.canonicalProject(project).path)
        let originalRoot = try ProjectPathResolver.canonicalProject(fixture.root)
        #expect(boundary.string.hasPrefix(originalRoot.path + "/") == nested)
        let coveringCandidates = proof.basis.compactMap { element -> PathAccessBasis? in
          guard case .path(let basis) = element,
            basis.path.contains(boundary),
            basis.operation == (nested ? .write : .read),
            nested || basis.path.string == "/",
            basis.excludedSubtrees?.contains(where: { $0.contains(boundary) }) == false
          else { return nil }
          return basis
        }
        let covering = try #require(coveringCandidates.first)
        if nested {
          #expect(covering.path.string == originalRoot.path)
        } else {
          #expect(covering.location == .outsideUserData)
        }
        let paths = try #require(admitted.environment.paths)
        var limits = admitted.environment.limits[proof.invocation.principal] ?? .init()
        let connection = try #require(admitted.environment.connections[approved.id])
        limits.sources[.connection] = .available(connection.attenuation)
        let sandbox =
          covering.sandboxProjectID.flatMap {
            admitted.settings.entries[
              SandboxSettingsKey(principal: proof.invocation.principal, projectID: $0)]
          } ?? .init()
        #expect(
          PathPermissions(environment: paths).validate(
            covering, principal: proof.invocation.principal, permissions: admitted.permissions,
            mode: proof.mode, limits: limits, sandbox: sandbox))
        introducedBoundary = boundary
        coveringBasis = covering
        _ = try await call(client, "project.add", ["path": .string(project.path)])
      } else {
        let changed = try await call(
          client, "plugin.configure",
          [
            "id": .string(package.manifest.id),
            "expected_revision": .integer(beforePublication.plugins.revision),
            "settings": .object([
              "cli": .object(["metadata": .object(["allowAnyArgs": .bool(true)])])
            ]),
          ])
        #expect(
          changed.objectValue?["revision"] == .integer(beforePublication.plugins.revision + 1))
        let after = try fixture.database.configurationState()
        #expect(after != beforePublication)
        #expect(after.projects == beforePublication.projects)
        #expect(after.profiles == beforePublication.profiles)
        #expect(after.plugins.revision == beforePublication.plugins.revision + 1)
        #expect(after.plugins.settings[package.manifest.id]?.cli["metadata"]?.allowAnyArgs == true)
      }
      let afterPublication = try #require(
        await fixture.gateway.controlSessions().first { $0.id == approved.id })
      #expect(afterPublication.revision == approved.revision)
      #expect(afterPublication.fullAccessConsent == approved.fullAccessConsent)
      try authority.store.readWithDatabase { _, ledger in
        var copy = ledger
        if addsProject {
          let boundary = try #require(introducedBoundary)
          let covering = try #require(coveringBasis)
          let paths = try #require(copy.environment.paths)
          let location = try #require(paths.projects.location(at: boundary))
          #expect(PathAccessBasis.Location.project(location) != covering.location)
          var limits = copy.environment.limits[proof.invocation.principal] ?? .init()
          let connection = try #require(copy.environment.connections[approved.id])
          limits.sources[.connection] = .available(connection.attenuation)
          let sandbox =
            covering.sandboxProjectID.flatMap {
              copy.sandboxSettings.entries[
                SandboxSettingsKey(principal: proof.invocation.principal, projectID: $0)]
            } ?? .init()
          #expect(
            !PathPermissions(environment: paths).validate(
              covering, principal: proof.invocation.principal,
              permissions: copy.permissions(for: proof.invocation.principal), mode: proof.mode,
              limits: limits, sandbox: sandbox))
          #expect(throws: PermissionModelError.invalidAuthorization) {
            try copy.invocationAccess(proof.id)
          }
          #expect(
            copy.executionAccess(
              executionID, principal: proof.invocation.principal, operation: .readResult,
              connectionID: approved.id, now: Date()) == .denied(.authorizationRevoked))
        } else {
          #expect(copy.authorizationEpochID == admitted.epoch)
          #expect(copy.environment == admitted.environment)
          #expect(copy.environment.paths == admitted.environment.paths)
          #expect(copy.permissions(for: proof.invocation.principal) == admitted.permissions)
          #expect(copy.sandboxSettings == admitted.settings)
          let currentProof = try copy.invocationAccess(proof.id)
          #expect(currentProof == proof)
          #expect(
            copy.executionAccess(
              executionID, principal: proof.invocation.principal, operation: .readResult,
              connectionID: approved.id, now: Date()) == .allowed)
        }
      }
      if addsProject {
        let refusal = try await running.value
        #expect(refusal.objectValue?["code"] == .string("permission.invalid_authorization"))
        try await authority.coordinator.reconcile()
        try authority.store.readWithDatabase { database, ledger in
          let native = try #require(try ExecutionRuntimeRecord.load(executionID, database))
          try #require(
            native.completed && native.children.values.allSatisfy { $0.completed && $0.released })
          #expect(ledger.executions[executionID]?.revoked == true)
        }
        #expect(
          !FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("finished").path))
      }
      try Data().write(to: fixture.root.appendingPathComponent("release"))
      if addsProject {
        try authority.store.readWithDatabase { _, ledger in
          var copy = ledger
          #expect(throws: PermissionModelError.invalidAuthorization) {
            try copy.invocationAccess(proof.id)
          }
        }
        #expect(
          !FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("finished").path))
      } else {
        _ = try await running.value
        #expect(
          try String(contentsOf: fixture.root.appendingPathComponent("finished"), encoding: .utf8)
            == "finished")
        try await authority.coordinator.reconcile()
        try authority.store.readWithDatabase { database, _ in
          let native = try #require(try ExecutionRuntimeRecord.load(executionID, database))
          #expect(
            native.completed && native.children.values.allSatisfy { $0.completed && $0.released })
        }
      }
      await client.disconnect()
      await fixture.gateway.stop()
    } catch {
      try? Data().write(to: fixture.root.appendingPathComponent("release"))
      work?.cancel()
      _ = try? await work?.value
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func revocationDuringVerifiedDownloadCannotPublish(endSession: Bool) async throws {
    let manifest = PreparationFixture.manifest.replacingOccurrences(
      of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']")
    let archive = try await PreparationFixture.make(
      launcher: testExecutionLauncher(),
      directoryFactory: MacOSPlatform.services(launcher: testExecutionLauncher()).pluginDirectories,
      manifest: manifest, format: "zip")
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
          id: approved.id, to: .init(allowsFullAccess: false), expectedRevision: approved.revision)
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
  func managedFullAccessChangeDuringVerifiedDownloadCannotPublish() async throws {
    let manifest = PreparationFixture.manifest.replacingOccurrences(
      of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']")
    let archive = try await PreparationFixture.make(
      launcher: testExecutionLauncher(),
      directoryFactory: MacOSPlatform.services(launcher: testExecutionLauncher()).pluginDirectories,
      manifest: manifest, format: "zip")
    defer { archive.files.remove() }
    let bytes = try Data(contentsOf: archive.archive)
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let http = SuspendedReleaseValidation(
      base: ReleaseHTTPFake(manifest: manifest, artifactBytes: bytes))
    let reader = TestManagedPolicyReader()
    let fixture = try PluginControlFixture(
      worker: archive.preparation.workerExecutable.path, releases: GitHubPluginReleases(http: http),
      download: GitHubPluginDownload(origin: server.origin), bundled: .load(directory: nil),
      permissionPolicyReader: reader)
    defer { fixture.remove() }
    let client = try await connect(fixture)
    let approved = try await approve(fixture)
    let before = try fixture.database.configurationState()
    let originalManifest = try Data(contentsOf: fixture.directories.manifest)
    let artifact = try ControlToolResponse.encodedPayload(
      pluginArtifactFixture(bytes: bytes, manifest: manifest))
    let pending = Task {
      try await call(
        client, "plugin.install", ["artifact": artifact, "expected_revision": .integer(0)],
        fails: true)
    }
    do {
      try await http.waitUntilPaused()
      let owned = try #require(fixture.database.pluginOwnedDirectories().first)
      #expect(FileManager.default.fileExists(atPath: owned.identity.url.path))
      reader.set(.machineFile, .available(Data("full_access = false\n".utf8)))
      let selected = try #require(
        await fixture.gateway.controlSessions().first { $0.id == approved.id })
      #expect(selected.fullAccessConsent == approved.fullAccessConsent)
      await http.release()
      let error = try await pending.value
      #expect(error.objectValue?["code"] == .string("permission.invalid_authorization"))
      #expect(try fixture.database.configurationState() == before)
      #expect(try Data(contentsOf: fixture.directories.manifest) == originalManifest)
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: owned.identity.url.path))
      let after = try #require(
        await fixture.gateway.controlSessions().first { $0.id == approved.id })
      #expect(after.fullAccessConsent == approved.fullAccessConsent)
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
  func restrictedClientDiscoversArtifactsAndNewConsentAuthorizesUpdates() async throws {
    let manifest = PreparationFixture.manifest.replacingOccurrences(
      of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']")
    let nextManifest = manifest.replacingOccurrences(
      of: "version = '1.2.3'", with: "version = '1.2.4'")
    let first = try await PreparationFixture.make(
      launcher: testExecutionLauncher(),
      directoryFactory: MacOSPlatform.services(launcher: testExecutionLauncher()).pluginDirectories,
      manifest: manifest, format: "zip")
    defer { first.files.remove() }
    let next = try await PreparationFixture.make(
      launcher: testExecutionLauncher(),
      directoryFactory: MacOSPlatform.services(launcher: testExecutionLauncher()).pluginDirectories,
      manifest: nextManifest,
      format: "zip")
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
    let catalogData = try staticCatalogData { root in
      var release = root["releases"]!.arrayValue![0].objectValue!
      var compatibility = release["compatibility"]!.objectValue!
      compatibility["minimum_host"] = .string(ComputerMCPCLI.version)
      release["compatibility"] = .object(compatibility)
      root["releases"] = .array([.object(release)])
    }
    try await StaticPluginCatalogCache(
      url: fixture.directories.applicationSupport.appendingPathComponent(
        "Cache/PluginCatalog/index.json")
    ).write(.init(body: catalogData, validators: .init(), validatedAt: .now))
    var client = try await connect(fixture)
    do {
      let scope = try #require(await fixture.gateway.controlSessions().first)
      _ = try await fixture.gateway.limitControlSession(
        id: scope.id, to: .init(allowsFullAccess: false), expectedRevision: scope.revision)
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
      await #expect(throws: (any Error).self) {
        try await fixture.gateway.approveControlSession(
          id: scope.id, expectedRevision: scope.revision + 1)
      }
      await client.disconnect()
      client = try await GatewayClientSession.connectSocket(
        socketURL: fixture.directories.gatewaySocket)
      let fresh = try #require(await fixture.gateway.controlSessions().first { $0.id != scope.id })
      let approved = try await fixture.gateway.approveControlSession(
        id: fresh.id, expectedRevision: fresh.revision)
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
          id: .chatGPTOperate,
          permissions: fixturePermissions([
            .machineInformation: .granted(.access), .skills: .granted(.access),
            .screen: .granted(.access), .desktopControl: .granted(.access),
            .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
            .project("fixture"): .granted(.write), .mcpServer("*"): .granted(.all),
            .plugin("*"): .granted(.use),
          ]), fullAccess: true, allowedCallers: [.localMCP])
      ],
      projectDirectory: fixture.root)
    configuration.policy.shellEnabled = true
    _ = try await fixture.host.activateManifest(
      configuration.exportedTOML(), expectedDigest: try? await fixture.host.configurationDigest())
    try fixture.database.saveProject(
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
  func managementWithoutProviderFailsBeforeDispatch() async throws {
    #expect(
      MacOSPlatform.services(launcher: testExecutionLauncher()).managementToolNames
        == Set(GatewayRemoteManagement.definitions.map(\.tool.name)))
    let root = try ScopedTemporaryDirectory()
    let runtime = try GatewayRuntime(
      configuration: GatewayConfiguration(projectDirectory: root.url),
      registeredProjects: [
        .init(id: "fixture", displayName: "Fixture", rootPath: root.url.path)
      ],
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
      bundledPlugins: .load(directory: nil))
    for name in GatewayRemoteManagement.definitions.map(\.tool.name) {
      #expect(throws: GatewayToolError.unknownTool(name)) {
        try runtime.capabilityDescriptor(named: name)
      }
      #expect(throws: GatewayToolError.unknownTool(name)) {
        try runtime.callTool(name: name, arguments: .object([:]), context: .empty)
      }
      await #expect(throws: GatewayToolError.unknownTool(name)) {
        try await runtime.callToolAsync(name: name, arguments: .object([:]), context: .empty)
      }
    }
    await runtime.shutdown()
  }

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
    let snapshot = try PluginHostSnapshot(
      state: state, bundled: .load(directory: nil),
      applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications)
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
      "test-package",
      snapshot: .init(
        state: state, bundled: bundle,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    let text = ControlToolResponse.payloadText(report)
    #expect(!text.contains("private-binding") && !text.contains("private-argument"))
  }

  @Test(arguments: [false, true])
  func admittedManagementScopeCannotLaunchProgramsOrBorrowAdministration(
    withAdministration: Bool
  ) async throws {
    let files = try ScopedTemporaryDirectory()
    let home = files.url.appendingPathComponent("home", isDirectory: true)
    let temporary = files.url.appendingPathComponent("tmp", isDirectory: true)
    for directory in [home, temporary] {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let database = try GatewayDatabase(inMemory: ())
    let grant = ProfileGrant(id: .chatGPTOperate, fullAccess: true, allowedCallers: [.localMCP])
    try database.saveProfile(grant)
    let stored = try #require(database.profiles().first { $0.id == grant.id })
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let service = try database.permissionRuntime(platform: platform).service
    let session = GatewayControlSession(
      principalID: "management-launch-fixture", profileID: grant.id, caller: .localMCP,
      database: database, profile: .init(grant: stored, persisted: true), permissionService: service
    )
    defer { session.end() }
    var context = ExecutionContext(
      caller: .localMCP, profileID: grant.id, trustedPrincipalID: "management-launch-fixture")
    context.controlSession = session
    let consent = try session.approveFullAccess(expectedRevision: 0)
    let authorization = try admittedManagementAuthorization(
      service: service, session: session, context: context, revision: consent.revision)
    try authorization.perform { try database.validateManagementAuthorization(authorization) }
    let scope = GatewayManagementInvocation(
      authorization: authorization.invocation, pathAccess: nil)
    let administration = try ExecutionAdministration(
      mode: .fullAccess,
      environment: .init(fullAccessVariables: [
        "PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": temporary.path,
      ]))
    let observations = ExecutionObservations()
    let launcher = testExecutionLauncher(observations: observations)
    let marker = files.url.appendingPathComponent("launched")
    try await ExecutionAdministration.$current.withValue(withAdministration ? administration : nil)
    {
      try await InvocationExecution.$current.withValue(scope) {
        #expect(
          throws: ExecutionEnvironmentError.unavailable(
            "Execution authority has no prepared launch context")
        ) {
          try PreparedExecutionContext.current()
        }
        do {
          let child = try await launcher.start(
            executable: SandboxPath("/usr/bin/touch"), arguments: [marker.path],
            directory: SandboxPath(files.url.path), environment: administration.environment,
            mode: .fullAccess)
          _ = try await child.wait()
          Issue.record("A management invocation launched a provider program")
        } catch let error as ExecutionEnvironmentError {
          #expect(error == .unavailable("Execution authority has no prepared launch context"))
        }
      }
    }
    #expect(observations.members.isEmpty && observations.ownerships.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    try authorization.perform { try database.validateManagementAuthorization(authorization) }
  }

  @Test(arguments: ["plugin", "project", "profile"])
  func persistentTrustRevocationBetweenSessionCheckAndSQLCommitCannotWrite(kind: String) throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let database = try fixturePermissionDatabase(path: files.databaseURL.path)
    try database.saveProject(
      .init(id: "project", displayName: "Project", rootPath: files.root.path))
    var profile = GatewayControlProfile(
      grant: .init(
        id: .chatGPTOperate,
        permissions: fixturePermissions([
          .machineInformation: .granted(.access), .skills: .granted(.access),
          .screen: .granted(.access), .desktopControl: .granted(.access),
          .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
          .project("project"): .granted(.write), .mcpServer("*"): .granted(.all),
          .plugin("*"): .granted(.use),
        ]), fullAccess: true, allowedCallers: [.localMCP]), persisted: true)
    try database.saveProfile(profile.grant)
    profile = GatewayControlProfile(
      grant: try #require(database.profiles().first { $0.id == profile.grant.id }), persisted: true)
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let service = try database.permissionRuntime(platform: platform).service
    let session = GatewayControlSession(
      principalID: "verified", profileID: .chatGPTOperate, caller: .localMCP, database: database,
      profile: profile,
      permissionService: service)
    var context = ExecutionContext(
      caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "verified")
    context.controlSession = session
    let consent = try session.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let trust = try #require(database.clientTrusts().first)
    defer { session.end() }
    let authorization = try admittedManagementAuthorization(
      service: service, session: session, context: context, revision: consent.revision,
      tool: kind == "plugin"
        ? "plugin.disable" : kind == "project" ? "project.remove" : "project.grant")
    #expect(
      try authorization.perform {
        try database.validateManagementAuthorization(authorization)
        return true
      })
    let before = try database.configurationState()
    let prepared = try database.prepareProjectChange(.remove("project"), expected: before)
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
        case "project":
          _ = try database.saveProjectChange(
            prepared, resolution: .init(), authorization: authorization)
        default:
          try database.saveProfile(
            profile.grant, expectedRevision: profile.grant.authorizationRevision,
            expectedConfiguration: before,
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
    var profile = GatewayControlProfile(
      grant: .init(
        id: .chatGPTOperate,
        permissions: fixturePermissions([
          .machineInformation: .granted(.access), .skills: .granted(.access),
          .screen: .granted(.access), .desktopControl: .granted(.access),
          .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
          .project("*"): .granted(.write), .mcpServer("*"): .granted(.all),
          .plugin("*"): .granted(.use),
        ]), fullAccess: true, allowedCallers: [.localMCP]), persisted: true)
    try database.saveProfile(profile.grant)
    profile = GatewayControlProfile(
      grant: try #require(database.profiles().first { $0.id == profile.grant.id }), persisted: true)
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let service = try database.permissionRuntime(platform: platform).service
    let session = GatewayControlSession(
      principalID: "verified", profileID: .chatGPTOperate, caller: .localMCP, database: database,
      profile: profile,
      permissionService: service)
    var context = ExecutionContext(
      caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "verified")
    context.controlSession = session
    let consent = try session.approveFullAccess(expectedRevision: 0)
    defer { session.end() }
    let authorization = try admittedManagementAuthorization(
      service: service, session: session, context: context, revision: consent.revision)
    #expect(
      try authorization.perform {
        try database.validateManagementAuthorization(authorization)
        return 42
      } == 42)
    let serialized = try JSONDecoder().decode(
      ExecutionContext.self, from: JSONEncoder().encode(context))
    #expect(throws: (any Error).self) {
      try session.withManagementAuthorization(
        context: serialized, expectedRevision: consent.revision, requiresFullAccess: true
      ) { Issue.record("Invalid scope committed") }
    }
    try session.limitAccess(
      to: .init(
        permissionCeilings: fixturePermissions([
          .project("*"): .granted(.read), .mcpServer("*"): .granted(.read),
        ]), allowsFullAccess: false), expectedRevision: consent.revision)
    #expect(throws: (any Error).self) {
      try authorization.perform { Issue.record("Revoked write committed") }
    }
    #expect(throws: (any Error).self) {
      try session.limitAccess(
        to: .init(
          permissionCeilings: fixturePermissions([
            .project("*"): .granted(.write), .mcpServer("*"): .granted(.all),
          ]), allowsFullAccess: false),
        expectedRevision: session.snapshot.revision, allowIncrease: false)
    }
    session.end()
    #expect(throws: (any Error).self) {
      try authorization.perform { Issue.record("Ended write committed") }
    }
  }

  @Test(arguments: ["plugin", "project", "profile", "controlProfile"])
  func managedCeilingIsRecheckedInsideEveryManagementWriter(kind: String) throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let database = try fixturePermissionDatabase(path: files.databaseURL.path)
    try database.saveProject(
      .init(id: "project", displayName: "Project", rootPath: files.root.path))
    let reader = TestManagedPolicyReader()
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = reader
    let grant = ProfileGrant(
      id: .chatGPTOperate,
      permissions: fixturePermissions([.project("project"): .granted(.write)]),
      fullAccess: true, allowedCallers: [.localMCP])
    try database.saveProfile(grant)
    let stored = try #require(database.profiles().first { $0.id == grant.id })
    let service = try database.permissionRuntime(platform: platform).service
    let session = GatewayControlSession(
      principalID: "writer-fixture", profileID: grant.id, caller: .localMCP, database: database,
      profile: .init(grant: stored, persisted: true), permissionService: service)
    defer { session.end() }
    var context = ExecutionContext(
      caller: .localMCP, profileID: grant.id, trustedPrincipalID: "writer-fixture")
    context.controlSession = session
    let consent = try session.approveFullAccess(expectedRevision: 0)
    let tool =
      kind == "plugin" ? "plugin.disable" : kind == "project" ? "project.remove" : "project.grant"
    let authorization = try admittedManagementAuthorization(
      service: service, session: session, context: context, revision: consent.revision, tool: tool)
    try authorization.perform { try database.validateManagementAuthorization(authorization) }
    let before = try database.configurationState()
    let prepared = try database.prepareProjectChange(.remove("project"), expected: before)
    var plugins = before.plugins
    plugins.revision += 1
    var proposed = stored
    try proposed.permissions.set(.denied, for: .project("project"))
    let owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "unit-owner"),
      validate: {})
    let control = PermissionControlService(service: service, owner: { owner })
    let revision = try control.view().revision
    #expect(session.snapshot.fullAccessConsent == consent.fullAccessConsent)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try authorization.perform {
        reader.set(.machineFile, .available(Data("full_access = false\n".utf8)))
        switch kind {
        case "plugin":
          _ = try database.savePluginStoreSnapshot(
            plugins, expectedRevision: 0, expectedConfiguration: before,
            authorization: authorization)
        case "project":
          _ = try database.saveProjectChange(
            prepared, resolution: .init(), authorization: authorization)
        case "profile":
          try database.saveProfile(
            proposed, expectedRevision: stored.authorizationRevision, expectedConfiguration: before,
            authorization: authorization)
        default:
          try control.updateProfile(
            proposed, expectedProfileRevision: stored.authorizationRevision,
            expectedRevision: revision,
            authorization: authorization)
        }
      }
    }
    #expect(try database.configurationState() == before)
    #expect(session.snapshot.fullAccessConsent == consent.fullAccessConsent)
    reader.set(.machineFile, .absent)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try authorization.perform { try database.validateManagementAuthorization(authorization) }
    }
    let reviewed = try session.approveFullAccess(expectedRevision: session.revision)
    let fresh = try admittedManagementAuthorization(
      service: service, session: session, context: context, revision: reviewed.revision, tool: tool)
    try fresh.perform { try database.validateManagementAuthorization(fresh) }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try database.validateManagementAuthorization(authorization)
    }
    #expect(try database.configurationState() == before)
  }

  @Test
  func managementProfileEditCommitsBeforeRetiringItsOwnProof() throws {
    let database = try GatewayDatabase(inMemory: ())
    let reader = TestManagedPolicyReader()
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = reader
    let original = ProfileGrant(
      id: .chatGPTOperate,
      permissions: fixturePermissions([.project("project"): .granted(.write)]),
      fullAccess: true, allowedCallers: [.localMCP])
    try database.saveProfile(original)
    let stored = try #require(database.profiles().first)
    let service = try database.permissionRuntime(platform: platform).service
    let session = GatewayControlSession(
      principalID: "profile-fixture", profileID: stored.id, caller: .localMCP, database: database,
      profile: .init(grant: stored, persisted: true), permissionService: service)
    defer { session.end() }
    var context = ExecutionContext(
      caller: .localMCP, profileID: stored.id, trustedPrincipalID: "profile-fixture")
    context.controlSession = session
    let consent = try session.approveFullAccess(expectedRevision: 0)
    let authorization = try admittedManagementAuthorization(
      service: service, session: session, context: context, revision: consent.revision)
    let owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "unit-owner"),
      validate: {})
    let control = PermissionControlService(service: service, owner: { owner })
    let revision = try control.view().revision
    var proposed = stored
    try proposed.permissions.set(.denied, for: .project("project"))
    try authorization.perform {
      try control.updateProfile(
        proposed, expectedProfileRevision: stored.authorizationRevision, expectedRevision: revision,
        authorization: authorization)
    }
    let changed = try #require(database.profiles().first { $0.id == stored.id })
    #expect(changed.permissions.state(for: .project("project")) == .denied)
    #expect(changed.authorizationRevision == stored.authorizationRevision + 1)
    #expect(session.snapshot.fullAccessConsent == nil)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try database.validateManagementAuthorization(authorization)
    }
  }

  @Test
  func managementProofCannotMoveToAnotherConnectionOfTheSamePrincipal() throws {
    let database = try GatewayDatabase(inMemory: ())
    let grant = ProfileGrant(id: .chatGPTOperate, fullAccess: true, allowedCallers: [.localMCP])
    try database.saveProfile(grant)
    let stored = try #require(database.profiles().first)
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let service = try database.permissionRuntime(platform: platform).service
    let first = GatewayControlSession(
      principalID: "same-principal", profileID: stored.id, caller: .localMCP, database: database,
      profile: .init(grant: stored, persisted: true), permissionService: service)
    let second = GatewayControlSession(
      principalID: "same-principal", profileID: stored.id, caller: .localMCP, database: database,
      profile: .init(grant: stored, persisted: true), permissionService: service)
    defer {
      first.end()
      second.end()
    }
    var original = ExecutionContext(
      caller: .localMCP, profileID: stored.id, trustedPrincipalID: "same-principal")
    original.controlSession = first
    var sibling = original
    sibling.controlSession = second
    let approved = try first.approveFullAccess(expectedRevision: 0)
    let other = try second.approveFullAccess(expectedRevision: 0)
    let authorization = try admittedManagementAuthorization(
      service: service, session: first, context: original, revision: approved.revision)
    try authorization.perform { try database.validateManagementAuthorization(authorization) }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try GatewayManagementAuthorization(
        session: second, context: sibling, revision: other.revision, requiresFullAccess: true,
        invocation: .init(authorization: authorization.invocation, pathAccess: nil))
    }
    try authorization.perform { try database.validateManagementAuthorization(authorization) }
  }

  private func admittedManagementAuthorization(
    service: GatewayPermissionService, session: GatewayControlSession,
    context: ExecutionContext, revision: Int64, tool: String = "project.grant"
  ) throws -> GatewayManagementAuthorization {
    let decision = try service.admit(
      subject: GatewayPermissionSubject(context: context), tool: tool,
      projectID: context.projectID, argumentsDigest: "management-fixture",
      requirements: .init(mode: .fullAccess(.standing)), connectionID: session.id)
    guard case .allowed(let proof) = decision else {
      Issue.record("The management fixture did not obtain a real invocation admission")
      throw PermissionModelError.invalidAuthorization
    }
    return try GatewayManagementAuthorization(
      session: session, context: context, revision: revision, requiresFullAccess: true,
      invocation: .init(authorization: proof, pathAccess: nil))
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
