import CryptoKit
import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayGenerationDispatchTests {
  @Test
  func managedManifestAndRollbackPublishWithoutDisconnectingOrLosingOldWork() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let original = try #require(try fixture.database.configurationRevisions().first)
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.control, gatewayService: fixture.service)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let startedAt = await fixture.service.snapshot().startedAt
      let oldPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(["handle": .string("old")]))
      )
      var proposed = try await fixture.control.activeConfiguration()
      proposed.mcp.servers[0].args[2] = "2"
      proposed.mcp.servers[0].toolRisks["generation_2"] = .readOnly
      let manifest = try proposed.exportedTOML()
      let applied = try await operations.activateManifest(manifest, expectedDigest: original.digest)
      let currentPID = try pid(await client.call(toolName: "fixture.identity"))
      #expect(currentPID != oldPID)
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_2" })
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.inspect", arguments: .object(["handle": .string("old")])))
          == oldPID)
      let before = try fixture.database.configurationState()
      let history = try fixture.database.configurationRevisions()
      var rejected = proposed
      rejected.mcp.servers[0].command = "/nonexistent/manifest-candidate"
      await #expect(throws: (any Error).self) {
        try await operations.activateManifest(
          rejected.exportedTOML(), expectedDigest: applied.digest)
      }
      #expect(try Data(contentsOf: fixture.control.directories.manifest) == Data(manifest.utf8))
      #expect(try fixture.database.configurationState() == before)
      #expect(try fixture.database.configurationRevisions() == history)
      #expect(try pid(await client.call(toolName: "fixture.identity")) == currentPID)
      let rollback = try await operations.rollbackManifest(to: original.id)
      #expect(rollback.id != original.id && rollback.digest == original.digest)
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_1" })
      #expect(await fixture.service.snapshot().connectionCount == 1)
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.finish", arguments: .object(["handle": .string("old")])))
          == oldPID)
      try await wait { !alive(oldPID) && !alive(currentPID) }
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(arguments: [1, 2, 3], [false, true])
  func repairRejectsLostSelectedAccessBeforePublication(resolveNumber: Int, replace: Bool)
    async throws
  {
    let bookmark = RepairFailureBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmark)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let destination = fixture.root.appendingPathComponent("selected")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    bookmark.arm(root: destination, resolveNumber: resolveNumber, replace: replace)
    let before = try fixture.database.configurationState()
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.control, gatewayService: fixture.service)
    await #expect(throws: (any Error).self) {
      try await operations.repairWorkspace(id: "fixture", at: destination)
    }
    #expect(bookmark.failureInjected)
    #expect(try fixture.database.configurationState() == before)
    #expect(await fixture.service.snapshot().state != .running)
    #expect(try fixture.pids().allSatisfy { !alive($0) })
    await fixture.service.stop()
  }

  @Test
  func connectedRepairRebindsCanonicalIdentityAndRetainsDeniedOldWork() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    var metadata = try #require(try fixture.database.workspace(id: "fixture"))
    metadata.displayName = "  原有 Project  "
    try fixture.database.saveWorkspace(metadata)
    try await fixture.activate(version: 1)
    let original = try #require(try fixture.database.workspace(id: "fixture"))
    var alias = original
    alias.id = "alias"
    alias.createdAt = original.createdAt.addingTimeInterval(1)
    try fixture.database.saveWorkspace(alias)
    _ = try fixture.database.applyWorkspaceDeduplication(
      expectedPlanDigest: fixture.database.workspaceDeduplicationPlan().planDigest,
      allowMetadataConflicts: false)
    let destination = fixture.root.appendingPathComponent("rebound")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.control, gatewayService: fixture.service)
    do {
      let startedAt = await fixture.service.snapshot().startedAt
      let arguments: [String: JSONValue] = ["handle": .string("original")]
      let oldPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(arguments)))
      let owner = try #require(try await owners(client, kind: "mcpResource").first)
      let before = try fixture.database.configurationState()
      let providerURL = fixture.root.appendingPathComponent("provider.py")
      let provider = try Data(contentsOf: providerURL)
      try Data("raise SystemExit(2)\n".utf8).write(to: providerURL)
      await #expect(throws: (any Error).self) {
        try await operations.repairWorkspace(id: alias.id, at: destination)
      }
      #expect(try fixture.database.configurationState() == before)
      #expect(
        try pid(await call(client, owner: owner, tool: "fixture.inspect", arguments: arguments))
          == oldPID)
      try provider.write(to: providerURL)
      let repaired = try await operations.repairWorkspace(id: alias.id, at: destination)
      #expect(repaired.id == original.id && repaired.createdAt == original.createdAt)
      #expect(repaired.displayName == original.displayName)
      #expect(
        repaired.rootPath == destination.resolvingSymlinksInPath().path
          && repaired.bookmarkData != nil)
      #expect(try fixture.database.workspace(id: alias.id) == repaired)
      #expect(
        try fixture.database.profiles().first?.workspaceIDs == before.profiles.first?.workspaceIDs)
      let currentPID = try pid(await client.call(toolName: "fixture.identity"))
      #expect(currentPID != oldPID && alive(oldPID))
      let calls = try fixture.calls()
      let denied = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: arguments)
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == calls)
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      #expect(await fixture.service.snapshot().connectionCount == 1)
      _ = try await operations.repairWorkspace(
        id: original.id, at: fixture.root, displayName: "Restored")
      #expect(try fixture.database.workspace(id: original.id)?.displayName == "Restored")
      #expect(
        try pid(await call(client, owner: owner, tool: "fixture.finish", arguments: arguments))
          == oldPID)
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func implicitContinuationRequiresOneExactOwnerAcrossWorkspaceChanges() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    var grant = try #require(try fixture.database.profiles().first)
    grant.workspaceIDs = ["*"]
    try fixture.database.saveProfile(grant)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let oldPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("shared")])))
      let root = fixture.root.appendingPathComponent("added")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let operations = AppControlPlaneOperations(
        controlPlane: fixture.control, gatewayService: fixture.service)
      let added = try await operations.registerWorkspace(at: root, displayName: "Added")
      let addedArguments = JSONValue.object([
        "workspace_id": .string(added.id), "handle": .string("shared"),
      ])
      let newPID = try pid(await client.call(toolName: "fixture.start", arguments: addedArguments))
      #expect(newPID != oldPID)
      let calls = try fixture.calls()
      let ambiguous = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("shared")]))
      #expect(ambiguous.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == calls)
      let originalArguments = JSONValue.object([
        "workspace_id": .string("fixture"), "handle": .string("shared"),
      ])
      #expect(
        try pid(await client.call(toolName: "fixture.inspect", arguments: originalArguments))
          == oldPID)
      #expect(
        try pid(await client.call(toolName: "fixture.inspect", arguments: addedArguments)) == newPID
      )
      grant = try #require(try fixture.database.profiles().first)
      grant.workspaceIDs = ["fixture"]
      try fixture.database.saveProfile(grant)
      let beforeDenial = try fixture.calls()
      let denied = try await client.call(toolName: "fixture.finish", arguments: addedArguments)
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == beforeDenial)
      #expect(alive(newPID))
      #expect(
        try pid(await client.call(toolName: "fixture.finish", arguments: originalArguments))
          == oldPID)
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func connectedDeduplicationPublishesAliasesAndGrantRevision() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let canonical = try #require(try fixture.database.workspace(id: "fixture"))
    var duplicate = canonical
    duplicate.id = "duplicate"
    duplicate.createdAt = canonical.createdAt.addingTimeInterval(1)
    try fixture.database.saveWorkspace(duplicate)
    var grant = ProfileGrant.cloudflareOperate
    grant.workspaceIDs = [duplicate.id]
    try fixture.database.saveProfile(grant)
    let before = try #require(try fixture.database.profiles().first { $0.id == grant.id })
    try fixture.database.saveOperationTicket(
      OperationTicket(
        id: "pending", capabilityID: "file.trash", caller: .cloudflareTunnel,
        profileID: grant.id, workspaceID: duplicate.id, inputDigest: "fixture", state: .approved,
        expiresAt: Date().addingTimeInterval(60),
        authorizationRevision: before.authorizationRevision))
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let arguments = JSONValue.object([
        "workspace_id": .string("fixture"), "handle": .string("old"),
      ])
      let oldPID = try pid(await client.call(toolName: "fixture.start", arguments: arguments))
      let plan = try fixture.database.workspaceDeduplicationPlan()
      let operations = AppControlPlaneOperations(
        controlPlane: fixture.control, gatewayService: fixture.service)
      let receipt = try await operations.applyWorkspaceDeduplication(
        expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
      #expect(receipt.aliasedWorkspaceIDs == [duplicate.id])
      #expect(try fixture.database.workspace(id: duplicate.id)?.id == canonical.id)
      let after = try #require(try fixture.database.profiles().first { $0.id == grant.id })
      #expect(after.workspaceIDs == [canonical.id])
      #expect(after.authorizationRevision == before.authorizationRevision + 1)
      #expect(try fixture.database.operationTicket(id: "pending")?.state == .denied)
      #expect(await fixture.service.snapshot().connectionCount == 1)
      #expect(try pid(await client.call(toolName: "fixture.identity")) != oldPID)
      #expect(
        try pid(await client.call(toolName: "fixture.finish", arguments: arguments)) == oldPID)
      try await wait { !alive(oldPID) }
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func connectedWorkspacePublicationPreservesNativeWorkAndRejectsFailedCandidates() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.control, gatewayService: fixture.service)
    let addedRoot = fixture.root.appendingPathComponent("added")
    try FileManager.default.createDirectory(at: addedRoot, withIntermediateDirectories: true)
    do {
      let startedAt = await fixture.service.snapshot().startedAt
      let oldPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(["handle": .string("old")]))
      )
      let added = try await operations.registerWorkspace(at: addedRoot, displayName: "Added")
      #expect(try fixture.database.workspace(id: added.id) != nil)
      let currentPID = try pid(await client.call(toolName: "fixture.identity"))
      #expect(currentPID != oldPID)
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.inspect", arguments: .object(["handle": .string("old")]))) == oldPID)
      let repeated = try await operations.registerWorkspace(at: addedRoot, displayName: "Added")
      #expect(repeated.id == added.id)
      #expect(try fixture.database.workspaces().count == 2)
      let before = try fixture.database.configurationState()
      let admittedPID = try pid(await client.call(toolName: "fixture.identity"))
      await #expect(throws: AppControlPlaneServiceError.self) {
        try await operations.registerWorkspace(at: addedRoot, displayName: "Conflicting")
      }
      #expect(try fixture.database.configurationState() == before)
      #expect(try pid(await client.call(toolName: "fixture.identity")) == admittedPID)
      let providerURL = fixture.root.appendingPathComponent("provider.py")
      let provider = try Data(contentsOf: providerURL)
      let failure = """
        import os, sys
        from pathlib import Path
        with (Path(sys.argv[1]) / "pids").open("a") as output: output.write(str(os.getpid()) + "\\n")
        raise SystemExit(2)
        """
      try Data(failure.utf8).write(to: providerURL)
      await #expect(throws: (any Error).self) { try await operations.removeWorkspace(id: added.id) }
      #expect(try fixture.database.configurationState() == before)
      #expect(try pid(await client.call(toolName: "fixture.identity")) == admittedPID)
      try provider.write(to: providerURL)
      try await operations.removeWorkspace(id: added.id)
      #expect(try fixture.database.workspace(id: added.id) == nil)
      #expect(await fixture.service.snapshot().connectionCount == 1)
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.finish", arguments: .object(["handle": .string("old")]))) == oldPID)
      try await wait { !alive(oldPID) }
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func connectedPluginPublicationPreservesNativeWorkAndRejectsFailedCandidates(managed: Bool)
    async throws
  {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    let archives = try ArchiveFixture()
    defer { archives.remove() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    let observer = MCP.Client(name: "publication-observer", version: "1")
    do {
      _ = try await observer.connect(
        transport: GatewaySocketTransport(configuration: fixture.service.socketConfiguration))
      var snapshot = try await fixture.installPlugin(
        version: 1, managed: managed, archives: archives)
      let settings = PluginSettings(
        enabled: false,
        mcp: [
          "native": .init(
            registrationID: "fixture", exposure: .reexport, prefix: "fixture", allowAnyTool: true,
            toolRisks: Dictionary(
              uniqueKeysWithValues: [
                "start", "inspect", "finish", "identity", "change", "wait", "generation_1",
                "generation_2",
              ]
              .map { ($0, CapabilityRisk.readOnly) }),
            args: [fixture.root.path, "unused", "yes"])
        ])
      snapshot = try await fixture.service.changePlugins(
        .settings(pluginID: "live-fixture", settings), expectedRevision: snapshot.state.revision)
      var configuration = try await fixture.control.activeConfiguration()
      configuration.mcp.servers = []
      _ = try await fixture.control.activateManifest(configuration.exportedTOML())
      #expect(try await !client.listTools().contains { $0.name == "fixture.identity" })
      let changes = GatewayToolChangeBroadcaster()
      let events = changes.stream()
      await observer.onNotification(ToolListChangedNotification.self) { _ in changes.send() }
      snapshot = try await fixture.service.changePlugins(
        .enabled(pluginID: "live-fixture", true), expectedRevision: snapshot.state.revision)
      let announced = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
          for await _ in events {
            if try await observer.listTools().tools.contains(where: {
              $0.name == "fixture.generation_1"
            }) {
              return true
            }
          }
          return false
        }
        group.addTask {
          try await Task.sleep(for: .seconds(5))
          return false
        }
        defer { group.cancelAll() }
        return try await group.next() ?? false
      }
      #expect(announced)
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_1" })
      let oldPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("old-plugin")])))
      let oldRecord = try #require(snapshot.state.installations.first)
      snapshot = try await fixture.service.changePlugins(
        .enabled(pluginID: "live-fixture", false), expectedRevision: snapshot.state.revision)
      #expect(try await !client.listTools().contains { $0.name == "fixture.identity" })
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.inspect", arguments: .object(["handle": .string("old-plugin")])))
          == oldPID)
      snapshot = try await fixture.service.changePlugins(
        .enabled(pluginID: "live-fixture", true), expectedRevision: snapshot.state.revision)
      snapshot = try await fixture.installPlugin(version: 2, managed: managed, archives: archives)
      let fresh = try await client.call(toolName: "fixture.identity")
      let newPID = try pid(fresh)
      #expect(value(fresh, "version") == .integer(2))
      let requestID = try #require(
        value(fresh, "gateway_execution")?.objectValue?["request_id"]?.stringValue)
      let audit = try #require(try fixture.database.auditEvent(requestID: requestID))
      #expect(audit.mcpRequestID == fresh.requestID)
      #expect(audit.socketConnectionID != nil)
      #expect(oldPID != newPID && alive(oldPID))
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_2" })
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.inspect", arguments: .object(["handle": .string("old-plugin")])))
          == oldPID)
      let beforeFailure = try fixture.database.configurationState()
      let directoriesBeforeFailure = try fixture.database.pluginOwnedDirectories()
      await #expect(throws: (any Error).self) {
        try await fixture.installPlugin(version: 3, managed: managed, archives: archives)
      }
      #expect(try fixture.database.configurationState() == beforeFailure)
      #expect(try fixture.database.pluginOwnedDirectories() == directoriesBeforeFailure)
      #expect(try pid(await client.call(toolName: "fixture.identity")) == newPID)
      #expect(alive(oldPID))
      snapshot = try await fixture.service.changePlugins(
        managed
          ? .uninstallArtifact(installationID: oldRecord.id)
          : .removeDevelopment(installationID: oldRecord.id),
        expectedRevision: snapshot.state.revision)
      #expect(FileManager.default.fileExists(atPath: oldRecord.source.root.path))
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.inspect", arguments: .object(["handle": .string("old-plugin")])))
          == oldPID)
      _ = try await client.call(
        toolName: "fixture.finish", arguments: .object(["handle": .string("old-plugin")]))
      try await wait { !alive(oldPID) }
      snapshot = try await fixture.service.changePlugins(
        .recover, expectedRevision: snapshot.state.revision)
      if managed {
        let deadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: oldRecord.source.root.path),
          ContinuousClock.now < deadline
        {
          try await Task.sleep(for: .milliseconds(10))
          snapshot = try await fixture.service.changePlugins(
            .recover, expectedRevision: snapshot.state.revision)
        }
      }
      #expect(FileManager.default.fileExists(atPath: oldRecord.source.root.path) == !managed)
      let retainedPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("removed-plugin")])))
      let selected = try #require(snapshot.state.selectedInstallations["live-fixture"])
      snapshot = try await fixture.service.changePlugins(
        managed
          ? .uninstallArtifact(installationID: selected)
          : .removeDevelopment(installationID: selected), expectedRevision: snapshot.state.revision)
      let removedCall = try await client.call(toolName: "fixture.identity")
      #expect(removedCall.result.objectValue?["isError"] == .bool(true))
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.inspect", arguments: .object(["handle": .string("removed-plugin")])))
          == retainedPID)
      _ = try await client.call(
        toolName: "fixture.finish", arguments: .object(["handle": .string("removed-plugin")]))
      try await wait { !alive(retainedPID) }
      _ = try await fixture.service.changePlugins(
        .recover, expectedRevision: snapshot.state.revision)
      await observer.disconnect()
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await observer.disconnect()
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(arguments: [false, true], ["plugin", "register", "repair", "manifest"])
  func listenerStopJoinsConfigurationPublication(cancel: Bool, change: String) async throws {
    let workspace = change != "plugin"
    let bookmark = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmark)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    var manifestCandidate = try await fixture.control.activeConfiguration()
    manifestCandidate.server.name = "published"
    let manifest = try manifestCandidate.exportedTOML()
    let addedRoot = fixture.root.appendingPathComponent("added")
    try FileManager.default.createDirectory(at: addedRoot, withIntermediateDirectories: true)
    bookmark.arm()
    let mutation = Task {
      if change == "manifest" {
        _ = try await fixture.service.changeManifest(manifest)
      } else if change == "repair" {
        _ = try await fixture.service.changeWorkspaces(
          .repair(id: "fixture", root: fixture.root, displayName: nil))
      } else if workspace {
        _ = try await fixture.service.changeWorkspaces(.register(addedRoot, displayName: "Added"))
      } else {
        _ = try await fixture.service.changePlugins(
          .enabled(pluginID: "future-plugin", true), expectedRevision: 0)
      }
    }
    do {
      try await wait { bookmark.entered }
      let stopping = Task { await fixture.service.stop() }
      if cancel { mutation.cancel() }
      bookmark.release()
      if cancel {
        await #expect(throws: CancellationError.self) { try await mutation.value }
      } else {
        try await mutation.value
      }
      await stopping.value
      #expect(await fixture.service.snapshot().state == .stopped)
      #expect(try fixture.database.pluginStoreSnapshot().revision == (cancel || workspace ? 0 : 1))
      #expect(try fixture.database.workspaces().count == (change == "register" && !cancel ? 2 : 1))
      #expect(try fixture.pids().allSatisfy { !alive($0) })
      await client.disconnect()
      try await fixture.service.start(profile: .chatGPTOperate)
      let reconnected = try await fixture.connect()
      _ = try pid(await reconnected.call(toolName: "fixture.identity"))
      await reconnected.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      mutation.cancel()
      bookmark.release()
      _ = await mutation.result
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func publicationCapacityIncludesEveryExistingAndPreparedRuntime() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    let profiles = try (0..<65).map { number in
      ProfileGrantConfig(
        id: try #require(GatewayProfileID(rawValue: "client-\(number)")),
        capabilities: ["workspace.list"], workspaces: ["fixture"], allowedCallers: [.localMCP])
    }
    let configuration = GatewayConfiguration(profiles: profiles, workspaceDirectory: fixture.root)
    _ = try await fixture.control.activateManifest(configuration.exportedTOML())
    for profile in profiles { try fixture.database.saveProfile(profile.grant) }
    try await fixture.service.start(profile: profiles[0].id)
    var clients: [GatewayClientSession] = []
    do {
      for profile in profiles {
        try await fixture.service.selectProfile(profile.id)
        clients.append(try await fixture.connect())
      }
      let before = try fixture.database.configurationState()
      await #expect(
        throws: GatewaySocketError.invalidConfiguration(
          "The gateway has reached its owned runtime capacity.")
      ) {
        try await fixture.service.changePlugins(
          .enabled(pluginID: "future-plugin", true), expectedRevision: 0)
      }
      #expect(try fixture.database.configurationState() == before)
      #expect(await fixture.service.snapshot().connectionCount == 65)
      for client in clients {
        #expect(
          try await client.call(toolName: "workspace.list").result.objectValue?["isError"]
            != .bool(true))
        await client.disconnect()
      }
      await fixture.service.stop()
    } catch {
      for client in clients { await client.disconnect() }
      await fixture.service.stop()
      throw error
    }
  }

  @Test(
    arguments: ["publish", "cancel", "profile", "manifest"],
    ["plugin", "register", "repair", "manifest"])
  func configurationPublicationCoordinatesExistingAndNewProfileAdmissions(
    outcome: String, change: String
  ) async throws {
    let workspace = change != "plugin"
    let bookmark = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmark)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let future = try #require(GatewayProfileID(rawValue: "future-client"))
    var configuration = try await fixture.control.activeConfiguration()
    let original = try #require(configuration.profiles.first)
    for id in [GatewayProfileID.cloudflareOperate, future] {
      var profile = original
      profile.id = id
      configuration.profiles.append(profile)
      try fixture.database.saveProfile(profile.grant)
    }
    _ = try await fixture.control.activateManifest(configuration.exportedTOML())
    configuration.server.name = "published"
    let manifestCandidate = try configuration.exportedTOML()
    try await fixture.service.start(profile: .chatGPTOperate)
    let first = try await fixture.connect()
    try await fixture.service.selectProfile(.cloudflareOperate)
    let second = try await fixture.connect()
    let previous = try pid(
      await first.call(toolName: "fixture.start", arguments: .object(["handle": .string("live")])))
    let secondPID = try pid(await second.call(toolName: "fixture.identity"))
    let before = try fixture.database.configurationState()
    let addedRoot = fixture.root.appendingPathComponent("added")
    try FileManager.default.createDirectory(at: addedRoot, withIntermediateDirectories: true)
    bookmark.arm()
    let mutation = Task {
      if change == "manifest" {
        _ = try await fixture.service.changeManifest(manifestCandidate)
      } else if change == "repair" {
        _ = try await fixture.service.changeWorkspaces(
          .repair(id: "fixture", root: fixture.root, displayName: nil))
      } else if workspace {
        _ = try await fixture.service.changeWorkspaces(.register(addedRoot, displayName: "Added"))
      } else {
        _ = try await fixture.service.changePlugins(
          .enabled(pluginID: "future-plugin", true), expectedRevision: 0)
      }
    }
    var connecting: Task<GatewayClientSession, any Error>?
    do {
      try await wait { bookmark.entered }
      #expect(try fixture.database.configurationState() == before)
      #expect(try pid(await first.call(toolName: "fixture.identity")) == previous)
      #expect(try pid(await second.call(toolName: "fixture.identity")) == secondPID)
      await #expect(throws: PluginHostError.changeInProgress) {
        try await fixture.service.changePlugins(
          .enabled(pluginID: "competing", true), expectedRevision: 0)
      }
      try await fixture.service.selectProfile(future)
      connecting = Task { try await fixture.connect() }
      let deadline = ContinuousClock.now + .seconds(5)
      while await fixture.service.snapshot().connectionCount < 3, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await fixture.service.snapshot().connectionCount == 3)
      if outcome == "cancel" { mutation.cancel() }
      if outcome == "profile" {
        var grant = try #require(before.profiles.first { $0.id == .chatGPTOperate })
        grant.capabilityIDs = []
        grant.mcpServerIDs = []
        try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
        let denied = try await first.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("live")]))
        #expect(denied.result.objectValue?["isError"] == .bool(true))
      }
      if outcome == "manifest" {
        let manifest = await fixture.control.manifestStore.manifestURL
        try "schema_version = 999\n".write(
          to: manifest, atomically: true, encoding: .utf8)
      }
      bookmark.release()
      if outcome == "publish" {
        try await mutation.value
        #expect(try fixture.database.pluginStoreSnapshot().revision == (workspace ? 0 : 1))
        #expect(try fixture.database.workspaces().count == (change == "register" ? 2 : 1))
      } else {
        await #expect(throws: (any Error).self) { try await mutation.value }
        #expect(try fixture.database.pluginStoreSnapshot() == before.plugins)
        #expect(try fixture.database.workspaces() == before.workspaces)
      }
      let third = try await #require(connecting).value
      _ = try pid(await third.call(toolName: "fixture.identity"))
      await third.disconnect()
      connecting = nil
      if outcome == "publish" {
        #expect(try pid(await first.call(toolName: "fixture.identity")) != previous)
        #expect(try pid(await second.call(toolName: "fixture.identity")) != secondPID)
        #expect(
          try pid(
            await first.call(
              toolName: "fixture.inspect", arguments: .object(["handle": .string("live")])))
            == previous)
        try await wait { !alive(secondPID) }
      } else {
        #expect(try pid(await second.call(toolName: "fixture.identity")) == secondPID)
        #expect(alive(previous))
      }
      await first.disconnect()
      await second.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      mutation.cancel()
      bookmark.release()
      _ = await mutation.result
      if let connecting, case .success(let third) = await connecting.result {
        await third.disconnect()
      }
      await first.disconnect()
      await second.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func connectedClientUsesNewConfigurationWhileOldNativeWorkKeepsItsOwner() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let started = try await client.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("old")]))
      let oldPID = try pid(started)
      try await fixture.activate(version: 2)
      let fresh = try await client.call(toolName: "fixture.identity")
      let currentPID = try pid(fresh)
      #expect(value(fresh, "version") == .integer(2))
      #expect(currentPID != oldPID && alive(oldPID))
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_2" })
      let inspected = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("old")]))
      #expect(try pid(inspected) == oldPID)
      #expect(value(inspected, "version") == .integer(1))

      var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      let capabilities = grant.capabilityIDs
      let servers = grant.mcpServerIDs
      grant.capabilityIDs = []
      grant.mcpServerIDs = []
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let denied = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("old")]))
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(alive(oldPID))
      grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.capabilityIDs = capabilities
      grant.mcpServerIDs = servers
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let finished = try await client.call(
        toolName: "fixture.finish", arguments: .object(["handle": .string("old")]))
      #expect(try pid(finished) == oldPID)
      try await wait { !alive(oldPID) }
      #expect(alive(currentPID))

      var previous = currentPID
      for version in 3...8 {
        try await fixture.activate(version: version)
        let next = try await client.call(toolName: "fixture.identity")
        #expect(value(next, "version") == .integer(Int64(version)))
        let obsolete = previous
        previous = try pid(next)
        #expect(previous != obsolete)
        try await wait { !alive(obsolete) }
      }
      let pids = try fixture.pids()
      #expect(pids.count >= 8)
      #expect(pids.filter(alive) == [previous])
      await client.disconnect()
      await fixture.service.stop()
      #expect(pids.allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func duplicateNativeHandlesRequireExactOwnerAndExpiredSelectionCannotBeReused() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let firstPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("same")])))
      try await fixture.activate(version: 2)
      let secondPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("same")])))
      let before = try fixture.calls()
      var rejected = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("same")]))
      let deadline = ContinuousClock.now + .seconds(5)
      while String(describing: rejected.result).contains("mcp.continuation_pending"),
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
        rejected = try await client.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("same")]))
      }
      #expect(rejected.result.objectValue?["isError"] == .bool(true))
      #expect(String(describing: rejected.result).contains("mcp.continuation_ambiguous"))
      #expect(try fixture.calls() == before)
      let request = try #require(
        rejected.result.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
          .objectValue?["request_id"]?.stringValue)
      let audit = try #require(try fixture.database.auditEvent(requestID: request))
      #expect(audit.capabilityID == "fixture.inspect")
      #expect(audit.mcpRequestID == rejected.requestID)
      let owners = try await owners(client, kind: "mcpResource", pageSize: 1)
      #expect(owners.count == 2)
      var routedPIDs = Set<Int32>()
      var previous: JSONValue?
      for owner in owners {
        let inspected = try await call(
          client, owner: owner, tool: "fixture.inspect",
          arguments: ["handle": .string("same")])
        let selectedPID = try pid(inspected)
        routedPIDs.insert(selectedPID)
        #expect(try pid(await call(client, owner: owner, tool: "fixture.identity")) == selectedPID)
        #expect(value(inspected, "target_execution")?.objectValue?["execution_owner"] == owner)
        #expect(value(inspected, "arguments") == .object(["handle": .string("same")]))
        let generic = try await call(
          client, owner: owner, tool: "mcp.tools.call",
          arguments: [
            "server": .string("fixture"), "tool": .string("inspect"),
            "arguments": .object(["handle": .string("same")]),
          ])
        #expect(
          value(generic, "result")?.objectValue?["structuredContent"]?.objectValue?["pid"]
            == .integer(Int64(selectedPID)))
        if selectedPID == firstPID { previous = owner }
      }
      #expect(routedPIDs == [firstPID, secondPID])
      let previousOwner = try #require(previous)
      #expect(
        try pid(
          await call(
            client, owner: previousOwner, tool: "fixture.finish",
            arguments: ["handle": .string("same")])) == firstPID)
      try await wait { !alive(firstPID) }
      let calls = try fixture.calls()
      let stale = try await call(
        client, owner: previousOwner, tool: "fixture.inspect",
        arguments: ["handle": .string("same")])
      #expect(stale.result.objectValue?["isError"] == .bool(true))
      #expect(String(describing: stale.result).contains("runtime.owner_unavailable"))
      #expect(try fixture.calls() == calls)
      #expect(alive(secondPID))
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func providerWithoutWorkReportingIsRetainedUntilExplicitShutdown() async throws {
    let fixture = try GenerationFixture(reportWork: false)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let previous = try pid(await client.call(toolName: "fixture.identity"))
      try await fixture.activate(version: 2)
      let current = try pid(await client.call(toolName: "fixture.identity"))
      #expect(previous != current)
      #expect(alive(previous))
      let owners = try await owners(client, kind: "mcpUnreportedWork")
      #expect(owners.count == 2)
      var pids = Set<Int32>()
      for owner in owners {
        pids.insert(try pid(await call(client, owner: owner, tool: "fixture.identity")))
      }
      #expect(pids == [previous, current])
      let starts = try fixture.pids()
      let calls = try fixture.calls()
      var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.mcpServerIDs = []
      grant.capabilityIDs = ["runtime.owners.list", "runtime.owners.call"]
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      #expect(try await self.owners(client, kind: "mcpUnreportedWork").isEmpty)
      for owner in owners {
        #expect(
          try await call(client, owner: owner, tool: "fixture.identity")
            .result.objectValue?["isError"] == .bool(true))
      }
      #expect(try fixture.calls() == calls)
      #expect(try fixture.pids() == starts)
      await client.disconnect()
      #expect(alive(previous) && alive(current))
      await fixture.service.stop()
      #expect(!alive(previous) && !alive(current))
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func stopJoinsCandidateConstructionAndCannotPublishItIntoRestartedListener() async throws {
    let bookmark = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmark)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    bookmark.arm()
    let connecting = Task { try await fixture.connect() }
    do {
      try await wait { bookmark.entered }
      let stopping = Task { await fixture.service.stop() }
      let deadline = ContinuousClock.now + .seconds(3)
      while await fixture.service.snapshot().state != .stopping && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await fixture.service.snapshot().state == .stopping)
      bookmark.release()
      await stopping.value
      switch await connecting.result {
      case .success(let client):
        await client.disconnect()
        Issue.record("A candidate published after listener stop.")
      case .failure: break
      }
      #expect(bookmark.returned)
      #expect(await fixture.service.snapshot().state == .stopped)
      for pid in try fixture.pids() { #expect(!alive(pid)) }
      try await fixture.service.start(profile: .chatGPTOperate)
      let client = try await fixture.connect()
      _ = try await client.call(toolName: "fixture.identity")
      await client.disconnect()
      await fixture.service.stop()
      for pid in try fixture.pids() { #expect(!alive(pid)) }
    } catch {
      bookmark.release()
      if case .success(let client) = await connecting.result { await client.disconnect() }
      await fixture.service.stop()
      throw error
    }
  }

  private func value(_ report: GatewayCallReport, _ key: String) -> JSONValue? {
    report.result.objectValue?["structuredContent"]?.objectValue?[key]
  }

  @Test
  func selectedLegacyConnectionCloseRequiresApprovalAndLeavesCurrentWorkAlive() async throws {
    let fixture = try GenerationFixture(reportWork: false)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let originalPID = try pid(await client.call(toolName: "fixture.identity"))
      let owner = try #require(try await owners(client, kind: "mcpUnreportedWork").first)
      try await fixture.activate(version: 2)
      let currentPID = try pid(await client.call(toolName: "fixture.identity"))
      var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.mode = .readOnly
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let arguments: [String: JSONValue] = ["server": .string("fixture")]
      let denied = try await call(
        client, owner: owner, tool: "mcp.connections.close", arguments: arguments)
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(alive(originalPID) && alive(currentPID))
      grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.mode = .workspaceOperations
      grant.confirmationPolicy = .riskBased
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let unbound = try await client.call(
        toolName: "mcp.connections.close", arguments: .object(arguments))
      #expect(String(describing: unbound.result).contains("mcp.connection_owner_required"))
      let prepared = try await call(
        client, owner: owner, tool: "operations.prepare",
        arguments: [
          "tool": .string("mcp.connections.close"), "arguments": .object(arguments),
        ])
      let ticket = try #require(value(prepared, "result")?.objectValue?["ticket_id"]?.stringValue)
      #expect(try fixture.database.operationTicket(id: ticket)?.state == .pendingApproval)
      let commit: [String: JSONValue] = [
        "tool": .string("mcp.connections.close"), "arguments": .object(arguments),
        "ticket_id": .string(ticket),
      ]
      let pending = try await call(
        client, owner: owner, tool: "operations.commit", arguments: commit)
      #expect(pending.result.objectValue?["isError"] == .bool(true))
      #expect(alive(originalPID) && alive(currentPID))
      try fixture.database.resolveOperationApproval(id: ticket, approved: true, resolver: .localCLI)
      let closed = try await call(
        client, owner: owner, tool: "operations.commit", arguments: commit)
      let result = try #require(value(closed, "result")?.objectValue)
      #expect(result["transport_closed"] == .bool(true))
      #expect(result["managed_process_exit_confirmed"] == .bool(true))
      #expect(result["work_cleanup"] == .string("confirmed"))
      #expect(result["remaining_owners"] == .integer(0))
      #expect(!alive(originalPID) && alive(currentPID))
      let repeated = try await call(
        client, owner: owner, tool: "mcp.connections.close", arguments: arguments)
      #expect(repeated.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.pids() == [originalPID, currentPID])
      #expect(try await owners(client, kind: "mcpUnreportedWork").count == 1)
      grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.confirmationPolicy = .never
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let currentOwner = try #require(try await owners(client, kind: "mcpUnreportedWork").first)
      async let firstClose = call(
        client, owner: currentOwner, tool: "mcp.connections.close", arguments: arguments)
      async let secondClose = call(
        client, owner: currentOwner, tool: "mcp.connections.close", arguments: arguments)
      let results = try await [firstClose, secondClose]
      #expect(results.filter { $0.result.objectValue?["isError"] != .bool(true) }.count == 1)
      #expect(!alive(currentPID))
      #expect(try fixture.pids() == [originalPID, currentPID])
      await client.disconnect()
      await fixture.service.stop()
      #expect(!alive(currentPID))
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func selectedProviderClosePreservesUncertainNativeResourceOwnership() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let originalPID = try pid(
        await client.call(
          toolName: "fixture.start",
          arguments: .object(["handle": .string("native")])))
      let owner = try #require(try await owners(client, kind: "mcpResource").first)
      let closed = try await call(
        client, owner: owner, tool: "mcp.connections.close",
        arguments: ["server": .string("fixture")])
      let result = try #require(value(closed, "result")?.objectValue)
      #expect(result["managed_process_exit_confirmed"] == .bool(true))
      #expect(result["work_cleanup"] == .string("unknown"))
      #expect(try #require(result["remaining_owners"]?.int64Value) > 0)
      #expect(!alive(originalPID))
      #expect(try await owners(client, kind: "mcpResource") == [owner])
      let repeated = try await call(
        client, owner: owner, tool: "mcp.connections.close",
        arguments: ["server": .string("fixture")])
      #expect(repeated.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.pids() == [originalPID])
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func physicalRootReplacementDeniesOldOwnerWithoutTerminatingItsWork() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    let root = fixture.root.appendingPathComponent("workspace")
    let moved = fixture.root.appendingPathComponent("original")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var workspace = try #require(try fixture.database.workspace(id: "fixture"))
    workspace.rootPath = root.path
    try fixture.database.saveWorkspace(workspace)
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let arguments: [String: JSONValue] = ["handle": .string("retained")]
      let originalPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(arguments)))
      let owner = try #require(try await owners(client, kind: "mcpResource").first)
      let startedAt = await fixture.service.snapshot().startedAt
      try FileManager.default.moveItem(at: root, to: moved)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let before = try fixture.calls()
      let ordinary = try await client.call(
        toolName: "fixture.inspect", arguments: .object(arguments))
      let selected = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: arguments)
      #expect(ordinary.result.objectValue?["isError"] == .bool(true))
      #expect(selected.result.objectValue?["isError"] == .bool(true))
      #expect(try await owners(client, kind: "mcpResource").isEmpty)
      #expect(try fixture.calls() == before)
      #expect(alive(originalPID))

      try await fixture.activate(version: 2)
      let currentPID = try pid(await client.call(toolName: "fixture.identity"))
      #expect(currentPID != originalPID)
      #expect(alive(originalPID))
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      let stillDenied = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: arguments)
      #expect(stillDenied.result.objectValue?["isError"] == .bool(true))

      try FileManager.default.removeItem(at: root)
      try FileManager.default.moveItem(at: moved, to: root)
      #expect(
        try pid(await call(client, owner: owner, tool: "fixture.finish", arguments: arguments))
          == originalPID)
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func metadataChangePreservesScopeWhileRevokedWorkspaceBlocksNewContinuations() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
    grant.workspaceIDs = ["*"]
    try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
    let original = try #require(try fixture.database.workspace(id: "fixture"))
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let arguments: [String: JSONValue] = ["handle": .string("original")]
      let originalPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(arguments)))
      let owner = try #require(try await owners(client, kind: "mcpResource").first)
      var renamed = original
      renamed.displayName = "Renamed"
      try fixture.database.saveWorkspace(renamed)
      #expect(
        try pid(await call(client, owner: owner, tool: "fixture.inspect", arguments: arguments))
          == originalPID)
      for change in ["remove", "rebind", "reregister"] {
        try fixture.database.saveWorkspace(original)
        switch change {
        case "remove": try fixture.database.deleteWorkspace(id: original.id)
        case "rebind":
          let other = fixture.root.appendingPathComponent("other")
          try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
          var rebound = original
          rebound.rootPath = other.path
          try fixture.database.saveWorkspace(rebound)
        default:
          try fixture.database.deleteWorkspace(id: original.id)
          var replacement = original
          replacement.createdAt = original.createdAt.addingTimeInterval(1)
          try fixture.database.saveWorkspace(replacement)
        }
        let before = try fixture.calls()
        let ordinary = try await client.call(
          toolName: "fixture.inspect", arguments: .object(arguments))
        let selected = try await call(
          client, owner: owner, tool: "fixture.inspect", arguments: arguments)
        let listed = try await client.call(
          toolName: "runtime.owners.list",
          arguments: .object([
            "workspace_id": .string("fixture")
          ]))
        #expect(ordinary.result.objectValue?["isError"] == .bool(true), "Scope mutation: \(change)")
        #expect(selected.result.objectValue?["isError"] == .bool(true), "Scope mutation: \(change)")
        #expect(
          listed.result.objectValue?["isError"] == .bool(true)
            || value(listed, "result")?.objectValue?["owners"] == .array([]),
          "Scope mutation: \(change)")
        #expect(try fixture.calls() == before)
        #expect(alive(originalPID))
        if change == "rebind" {
          let reboundPID = try pid(await client.call(toolName: "fixture.identity"))
          #expect(reboundPID != originalPID)
          #expect(try await owners(client, kind: "mcpResource").isEmpty)
          #expect(alive(originalPID))
        }
      }
      try fixture.database.saveWorkspace(original)
      #expect(
        try pid(await call(client, owner: owner, tool: "fixture.finish", arguments: arguments))
          == originalPID)
      #expect(try fixture.pids().count == 2)
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func explicitOwnerControlsOriginalBackgroundReceiptAfterReplacement() async throws {
    let fixture = try GenerationFixture(reportWork: false)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let started = try await client.call(
        toolName: "mcp.tools.call",
        arguments: .object([
          "server": .string("fixture"), "tool": .string("wait"), "arguments": .object([:]),
          "request_id": .string("original"), "wait_for_result": .bool(false),
        ]))
      #expect(started.result.objectValue?["isError"] != .bool(true))
      let originalPID = try #require(try fixture.pids().first)
      let owner = try #require(try await owners(client, kind: "mcpRequest").first)
      try await fixture.activate(version: 2)
      let currentPID = try pid(await client.call(toolName: "fixture.identity"))
      #expect(currentPID != originalPID)
      let receiptArguments: [String: JSONValue] = [
        "server": .string("fixture"), "request_id": .string("original"),
      ]
      let reading = try await call(
        client, owner: owner, tool: "mcp.requests.read", arguments: receiptArguments)
      #expect(value(reading, "result")?.objectValue?["request_id"] == .string("original"))
      let rejected = try await call(
        client, owner: owner, tool: "mcp.requests.cancel",
        arguments: [
          "server": .string("fixture"), "request_id": .string("foreign"),
        ])
      #expect(rejected.result.objectValue?["isError"] == .bool(true))
      let cancelled = try await call(
        client, owner: owner, tool: "mcp.requests.cancel", arguments: receiptArguments)
      #expect(value(cancelled, "result")?.objectValue?["cancellation_requested"] == .bool(true))
      #expect(alive(originalPID) && alive(currentPID))
      try Data().write(to: fixture.root.appendingPathComponent("release"))
      let deadline = ContinuousClock.now + .seconds(5)
      while !(try await owners(client, kind: "mcpRequest")).isEmpty, ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(try await owners(client, kind: "mcpRequest").isEmpty)
      #expect(try fixture.calls() == "1:wait\n2:identity\n")
      #expect(try fixture.pids() == [originalPID, currentPID])
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func resourceSelectionExpiresBeforeSameNativeHandleIsReacquired() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let arguments: [String: JSONValue] = ["handle": .string("reused")]
      let originalPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(arguments)))
      let old = try #require(try await owners(client, kind: "mcpResource").first)
      _ = try await call(client, owner: old, tool: "fixture.finish", arguments: arguments)
      _ = try await client.call(toolName: "fixture.start", arguments: .object(arguments))
      let fresh = try #require(try await owners(client, kind: "mcpResource").first)
      #expect(fresh != old)
      let calls = try fixture.calls()
      var forged = try #require(fresh.objectValue)
      forged["runtime_id"] = .string(UUID().uuidString)
      var foreign = try #require(fresh.objectValue)
      foreign["workspace_id"] = .string("another")
      for invalid in [old, .object(forged), .object(foreign)] {
        let rejected = try await call(
          client, owner: invalid, tool: "fixture.inspect", arguments: arguments)
        #expect(rejected.result.objectValue?["isError"] == .bool(true))
      }
      #expect(try fixture.calls() == calls)
      #expect(
        try pid(await call(client, owner: fresh, tool: "fixture.inspect", arguments: arguments))
          == originalPID)
      #expect(try fixture.pids() == [originalPID])
      _ = try await client.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("other")]))
      let wrongResource = try await call(
        client, owner: fresh, tool: "fixture.inspect",
        arguments: ["handle": .string("other")])
      #expect(wrongResource.result.objectValue?["isError"] == .bool(true))
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func operationTicketBindsExactResourceOwnerWithinOneProvider() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, destructiveFinish: true)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      _ = try await client.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("one")]))
      _ = try await client.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("two")]))
      let owners = try await owners(client, kind: "mcpResource")
      #expect(owners.count == 2)
      let first = try #require(owners.first)
      let second = try #require(owners.last)
      var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.confirmationPolicy = .riskBased
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      // An unscoped write can address either connection owner; the approval must still bind
      // the selected host lifetime even when registration, arguments and connection agree.
      let prepared = try await call(
        client, owner: first, tool: "operations.prepare",
        arguments: [
          "tool": .string("fixture.change"), "arguments": .object([:]),
        ])
      let ticket = try #require(value(prepared, "result")?.objectValue?["ticket_id"])
      let ticketID = try #require(ticket.stringValue)
      let saved = try #require(try fixture.database.operationTicket(id: ticketID))
      #expect(saved.reviewSummary?.contains("execution_owner") == true)
      #expect(saved.state == .pendingApproval)
      let arguments: [String: JSONValue] = [
        "tool": .string("fixture.change"), "arguments": .object([:]), "ticket_id": ticket,
      ]
      let before = try fixture.calls()
      let rejected = try await call(
        client, owner: second, tool: "operations.commit", arguments: arguments)
      #expect(rejected.result.objectValue?["isError"] == .bool(true))
      #expect(String(describing: rejected.result).contains("operations.ticket_arguments_mismatch"))
      #expect(try fixture.calls() == before)
      let unapproved = try await call(
        client, owner: first, tool: "operations.commit", arguments: arguments)
      #expect(unapproved.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == before)
      try fixture.database.resolveOperationApproval(
        id: ticketID, approved: true, resolver: .localCLI)
      let committed = try await call(
        client, owner: first, tool: "operations.commit", arguments: arguments)
      #expect(committed.result.objectValue?["isError"] != .bool(true))
      #expect(try fixture.calls() == before + "1:change\n")
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  private func call(
    _ client: GatewayClientSession, owner: JSONValue, tool: String,
    arguments: [String: JSONValue] = [:]
  ) async throws -> GatewayCallReport {
    try await client.call(
      toolName: "runtime.owners.call",
      arguments: .object([
        "workspace_id": .string("fixture"), "owner": owner, "tool": .string(tool),
        "arguments": .object(arguments),
      ]))
  }

  private func owners(_ client: GatewayClientSession, kind: String, pageSize: Int = 50)
    async throws -> [JSONValue]
  {
    var result: [JSONValue] = []
    var after: JSONValue?
    var seen = Set<String>()
    repeat {
      var arguments: [String: JSONValue] = [
        "workspace_id": .string("fixture"), "limit": .integer(Int64(pageSize)),
      ]
      arguments["after"] = after
      let report = try await client.call(
        toolName: "runtime.owners.list", arguments: .object(arguments))
      let page = try #require(value(report, "result")?.objectValue)
      let rows = try #require(page["owners"]?.arrayValue)
      #expect(rows.count <= pageSize)
      for row in rows where row.objectValue?["kind"] == .string(kind) {
        result.append(try #require(row.objectValue?["owner"]))
      }
      after = page["next_cursor"]?.stringValue.map(JSONValue.string)
      if let cursor = after?.stringValue { try #require(seen.insert(cursor).inserted) }
    } while after != nil
    return result
  }

  @Test
  func shellContinuationSurvivesReplacementAndListenerStopJoinsItsProcesses() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, fullShell: true)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    var children: [Int32] = []
    defer { for pid in children where alive(pid) { _ = kill(-pid, SIGKILL) } }
    func payload(_ report: GatewayCallReport) throws -> [String: JSONValue] {
      try #require(value(report, "result")?.objectValue)
    }
    func spawn() async throws -> (id: String, pid: Int32) {
      let started = try await client.call(
        toolName: "shell.spawn",
        arguments: .object([
          "mode": .string("argv"), "executable": .string("/bin/cat"),
        ]))
      let id = try #require(try payload(started)["session_id"]?.stringValue)
      let snapshot = try await client.call(
        toolName: "shell.read", arguments: .object(["session_id": .string(id)]))
      let rawPID = try #require(try payload(snapshot)["process_id"]?.int64Value)
      return (id, try #require(Int32(exactly: rawPID)))
    }
    do {
      let first = try await spawn()
      children.append(first.pid)
      let previousProvider = try #require(try fixture.pids().first)
      try await fixture.activate(version: 2, fullShell: true)
      #expect(value(try await client.call(toolName: "fixture.identity"), "version") == .integer(2))
      #expect(alive(first.pid) && alive(previousProvider))
      let owner = try #require(try await owners(client, kind: "shell").first)
      let selectedRead = try await call(
        client, owner: owner, tool: "shell.read",
        arguments: ["session_id": .string(first.id)])
      #expect(try payload(selectedRead)["process_id"] == .integer(Int64(first.pid)))
      _ = try await call(
        client, owner: owner, tool: "shell.write",
        arguments: [
          "session_id": .string(first.id), "text": .string("across-generations"),
          "close": .bool(true),
        ])
      try await wait { !alive(previousProvider) && !alive(first.pid) }
      let retained = try await client.call(
        toolName: "shell.read", arguments: .object(["session_id": .string(first.id)]))
      #expect(
        try payload(retained)["stdout"]?.objectValue?["text"] == .string("across-generations"))
      let second = try await spawn()
      children.append(second.pid)
      await client.disconnect()
      #expect(alive(second.pid))
      await fixture.service.stop()
      #expect(!alive(second.pid))
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  private func pid(_ report: GatewayCallReport) throws -> Int32 {
    let value = try #require(value(report, "pid")?.int64Value)
    return try #require(Int32(exactly: value))
  }

  private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

  private func wait(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try condition())
  }
}

private final class GatedBookmarkService: WorkspaceBookmarkServicing, @unchecked Sendable {
  private let condition = NSCondition()
  private var armed = false
  private var _entered = false
  private var _returned = false
  private var released = false
  private let base = WorkspaceBookmarkService()

  var entered: Bool { condition.withLock { _entered } }
  var returned: Bool { condition.withLock { _returned } }
  func arm() { condition.withLock { armed = true } }
  func release() {
    condition.withLock {
      released = true
      condition.broadcast()
    }
  }

  func registerFolder(at url: URL, displayName: String?) throws -> RegisteredWorkspace {
    try base.registerFolder(at: url, displayName: displayName)
  }

  func resolve(_ workspace: RegisteredWorkspace) throws -> ResolvedWorkspaceAccess {
    condition.lock()
    if armed && !_entered {
      _entered = true
      condition.broadcast()
      while !released { condition.wait() }
      _returned = true
    }
    condition.unlock()
    return try base.resolve(workspace)
  }
}

private struct GenerationFixture: Sendable {
  let root: URL
  let database: GatewayDatabase
  let control: AppControlPlaneService
  let service: AppGatewayService
  let reportWork: Bool

  init(
    reportWork: Bool = true,
    bookmarkService: any WorkspaceBookmarkServicing = WorkspaceBookmarkService()
  ) throws {
    self.reportWork = reportWork
    root = URL(fileURLWithPath: "/private/tmp/cm-gen-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("state"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    control = AppControlPlaneService(
      directories: directories, database: database,
      manifestStore: try AtomicManifestStore(manifestURL: directories.manifest, database: database),
      secretStore: secrets, openAITunnelSupervisor: OpenAITunnelSupervisor(secretStore: secrets),
      gatewayExecutablePath: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/computer-mcp").path,
      bookmarkService: bookmarkService, bundledPlugins: .init(packages: [], issues: []))
    service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
    try database.saveWorkspace(.init(id: "fixture", displayName: "Fixture", rootPath: root.path))
    try Data(Self.provider.utf8).write(to: root.appendingPathComponent("provider.py"))
  }

  func activate(version: Int, fullShell: Bool = false, destructiveFinish: Bool = false) async throws
  {
    let names = [
      "start", "inspect", "finish", "identity", "change", "wait", "generation_\(version)",
    ]
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate,
      capabilities: [
        "mcp.tools.call", "mcp.requests.read", "mcp.requests.cancel",
        "runtime.owners.list", "runtime.owners.call", "operations.prepare", "operations.commit",
      ]
        + (fullShell ? ["shell.spawn", "shell.read", "shell.write", "shell.cancel"] : []),
      workspaces: ["fixture"], allowedCallers: [.localMCP], fullShellEnabled: fullShell,
      mcpServers: ["fixture"],
      mode: fullShell ? .localFullAccess : .workspaceOperations, confirmationPolicy: .never)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
      policy: .init(shellEnabled: fullShell), profiles: [profile],
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [
            root.appendingPathComponent("provider.py").path, root.path, String(version),
            reportWork ? "yes" : "no",
          ],
          exposure: .reexport, prefix: "fixture", allowAnyTool: true,
          startupTimeoutMs: 5_000, requestTimeoutMs: 5_000,
          toolRisks: Dictionary(
            uniqueKeysWithValues: names.map {
              (
                $0,
                destructiveFinish && ($0 == "finish" || $0 == "change") ? .destructive : .readOnly
              )
            }))
      ]), workspaceDirectory: root)
    if try database.profiles().isEmpty { try database.saveProfile(profile.grant) }
    _ = try await control.activateManifest(configuration.exportedTOML())
  }

  func installPlugin(version: Int, managed: Bool, archives: ArchiveFixture) async throws
    -> PluginHostSnapshot
  {
    let manifest = """
      id = 'live-fixture'
      name = 'Live Fixture'
      version = '\(version).0.0'
      [compatibility]
      minimum_host = '1.0.0'
      architectures = ['arm64', 'x86_64']
      [[mcp]]
      id = 'native'
      transport = 'stdio'
      executable = { path = 'provider' }
      """
    let provider =
      "#!/usr/bin/python3\n"
      + Self.provider.replacingOccurrences(
        of: "int(sys.argv[2])", with: String(version)
      ).replacingOccurrences(
        of: "uri, instance, revision, resources =",
        with: "if version == 3: sys.exit(2)\nuri, instance, revision, resources =")
    let revision = try database.pluginStoreSnapshot().revision
    if managed {
      let archive = try await BlockingOperationExecutor(label: "live-plugin-archive").perform {
        try archives.archive([
          .init(name: PluginManifest.filename, content: manifest),
          .init(name: "provider", content: provider, mode: 0o755),
        ])
      }
      let digest = SHA256.hash(data: try Data(contentsOf: archive)).map {
        String(format: "%02x", $0)
      }.joined()
      return try await service.changePlugins(
        .installArchive(
          archive: archive, sha256: digest, pluginID: "live-fixture",
          version: PluginVersion("\(version).0.0")),
        expectedRevision: revision)
    }
    let package = root.appendingPathComponent("plugin-\(version)")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try manifest.write(
      to: package.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8
    )
    let executable = package.appendingPathComponent("provider")
    try provider.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return try await service.changePlugins(
      .registerDevelopment(package), expectedRevision: revision)
  }

  func connect() async throws -> GatewayClientSession {
    try await GatewayClientSession.connectSocket(socketURL: service.socketConfiguration.socketURL)
  }

  func pids() throws -> [Int32] {
    let path = root.appendingPathComponent("pids")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap {
      Int32($0)
    }
  }

  func calls() throws -> String {
    try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
  }

  func removeFiles() { try? FileManager.default.removeItem(at: root) }

  private static let provider = #"""
    import json, os, sys, time, uuid
    from pathlib import Path
    root, version, reporting = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3] == "yes"
    with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\n")
    uri, instance, revision, resources = "computer-mcp://runtime/work/v1", str(uuid.uuid4()), 0, []
    names = ["start", "inspect", "finish", "identity", "change", "wait", "generation_" + str(version)]
    for line in sys.stdin:
        message = json.loads(line)
        if "id" not in message: continue
        method, params = message["method"], message.get("params", {})
        if method == "initialize":
            capabilities = {"tools": {}}
            if reporting: capabilities["resources"] = {}
            result = {"protocolVersion": "2025-11-25", "capabilities": capabilities, "serverInfo": {"name": "generation-fixture", "version": str(version)}}
        elif method == "tools/list":
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in names]}
            if reporting:
                for tool in result["tools"]:
                    tool["_meta"] = {"io.github.computer-mcp/work": {"format_version": 1, "uri": uri}}
                    if tool["name"] in ["inspect", "finish"]:
                        tool["_meta"]["io.github.computer-mcp/continuation"] = {"format_version": 1, "selectors": [{"kind": "session", "handles": {"id": "/handle"}}]}
        elif method == "resources/read":
            body = {"format_version": 1, "instance_id": instance, "revision": revision, "resources": resources}
            result = {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(body)}]}
        elif method == "tools/call":
            name, arguments = params["name"], params.get("arguments", {})
            with (root / "calls").open("a") as f: f.write(str(version) + ":" + name + "\n")
            handle = arguments.get("handle")
            if name == "start":
                if reporting:
                    acquisition = params["_meta"]["io.github.computer-mcp/work-invocation"]
                    resources.append({"kind": "session", "id": handle, "acquired_by": acquisition, "state": "active"})
                    revision += 1
            elif name == "finish":
                resources = [r for r in resources if r["id"] != handle]
                revision += 1
            elif name == "wait":
                while not (root / "release").exists(): time.sleep(0.01)
            result = {"content": [], "structuredContent": {"pid": os.getpid(), "version": version, "arguments": arguments}}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
    """#
}

private final class RepairFailureBookmarkService: WorkspaceBookmarkServicing, @unchecked Sendable {
  private let base = WorkspaceBookmarkService()
  private let lock = NSLock()
  private var root: URL?
  private var resolveNumber = 0
  private var calls = 0
  private var replace = false
  var failureInjected: Bool { lock.withLock { calls >= resolveNumber && resolveNumber > 0 } }

  func arm(root: URL, resolveNumber: Int, replace: Bool) {
    lock.withLock {
      self.root = root
      self.resolveNumber = resolveNumber
      self.replace = replace
    }
  }

  func registerFolder(at url: URL, displayName: String?) throws -> RegisteredWorkspace {
    try base.registerFolder(at: url, displayName: displayName)
  }

  func resolve(_ workspace: RegisteredWorkspace) throws -> ResolvedWorkspaceAccess {
    let failure = lock.withLock { () -> (URL, Bool)? in
      guard let root,
        URL(fileURLWithPath: workspace.rootPath).resolvingSymlinksInPath().path
          == root.resolvingSymlinksInPath().path
      else { return nil }
      calls += 1
      return calls == resolveNumber ? (root, replace) : nil
    }
    if let (root, replace) = failure {
      if replace {
        try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("original"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      } else {
        throw WorkspaceBookmarkError.securityScopeAccessDenied(workspaceID: workspace.id)
      }
    }
    return try base.resolve(workspace)
  }
}
