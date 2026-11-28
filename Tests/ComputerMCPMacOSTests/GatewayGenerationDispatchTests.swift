import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPProcess
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
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct GatewayGenerationDispatchTests {

  @Test(.timeLimit(.minutes(1)))
  func controlPlaneCatalogTracksPersistentPluginRevision() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.cloudflareTunnel])
    let inputs = try await fixture.control.gatewayInputs()
    let gateway = try await fixture.control.makeGateway(
      inputs: inputs, caller: .cloudflareTunnel, profileID: .chatGPTOperate)
    do {
      #expect(try gateway.hasCurrentDirectoryInputs())
      var plugins = inputs.plugins
      plugins.revision += 1
      try fixture.database.savePluginStoreSnapshot(
        plugins, expectedRevision: inputs.plugins.revision)
      #expect(try !gateway.hasCurrentDirectoryInputs())
      await gateway.shutdown()
    } catch {
      await gateway.shutdown()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func standaloneCatalogRefreshKeepsItsManifestRevision() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.cloudflareTunnel])
    let runtime = try await GatewayRuntime.make(
      configuration: fixture.control.activeConfiguration(),
      context: .init(
        caller: .cloudflareTunnel, profileID: .chatGPTOperate,
        trustedPrincipalID: "catalog-client"),
      database: fixture.database, platform: fixture.platform,
      bundledPlugins: .init(packages: [], issues: []))
    let generations = GatewayStandaloneGenerations(runtime)
    func advancePluginRevision() throws {
      var snapshot = try fixture.database.pluginStoreSnapshot()
      let previous = snapshot.revision
      snapshot.revision += 1
      try fixture.database.savePluginStoreSnapshot(snapshot, expectedRevision: previous)
    }
    do {
      try advancePluginRevision()
      let catalog = try await generations.listToolsAsync(context: .empty)
      #expect(catalog.contains { $0.name == "project.describe" })
      try await fixture.activate(version: 2, callers: [.cloudflareTunnel])
      try advancePluginRevision()
      await #expect(throws: GatewayDatabaseError.configurationChanged) {
        _ = try await generations.listToolsAsync(context: .empty)
      }
      await generations.shutdown()
    } catch {
      await generations.shutdown()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func standaloneRegistrationRevisionRefreshPreservesOwnersAndRefusesFailedConstruction()
    async throws
  {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.cloudflareTunnel])
    let child = fixture.root.appendingPathComponent("derived")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    try fixtureRemovingDerivedProject(
      database: fixture.database, id: "derived", sourceID: "fixture", root: child,
      displayName: "Derived")
    let failing = GenerationFailureProviders(base: fixture.platform.toolProviders)
    let platform = PlatformServices(
      launcher: fixture.platform.launcher, projectGrants: fixture.platform.projectGrants,
      pluginDirectories: fixture.platform.pluginDirectories,
      applications: fixture.platform.applications,
      toolProviders: failing, managementToolNames: fixture.platform.managementToolNames,
      executableSearchDirectories: fixture.platform.executableSearchDirectories,
      gitExecutable: fixture.platform.gitExecutable,
      fileChanges: fixture.platform.fileChanges,
      permissionPolicyReader: fixture.platform.permissionPolicyReader,
      executionProxy: fixture.platform.executionProxy)
    let initial = try await GatewayRuntime.make(
      configuration: fixture.control.activeConfiguration(),
      context: .init(
        caller: .cloudflareTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "revision-client"
      ),
      database: fixture.database, platform: platform,
      bundledPlugins: .init(packages: [], issues: []), requiresControlSession: true)
    let generations = GatewayStandaloneGenerations(initial)
    let serving = GatewayControlSessionServing(
      base: generations, session: try await generations.makeControlSession())
    let lease = initial.ownedWork.retainShell(projectID: "fixture", sessionID: "retained-owner")
    do {
      #expect(try initial.hasCurrentDirectoryInputs())
      let projects = try fixture.database.projects()
      var record = try #require(fixture.database.derivedProjects().first)
      let revision = record.revision
      record.revision += 1
      try SQLiteDerivedProjectStore(connection: fixture.database.connection).commit(
        record, expecting: revision)
      #expect(try fixture.database.projects() == projects)
      #expect(try !initial.hasCurrentDirectoryInputs())
      failing.fail(true)
      await #expect(throws: GenerationFailureProviders.Failure.self) {
        _ = try await serving.callToolAsync(
          name: "project.describe", arguments: .object(["project_id": .string("derived")]),
          context: .empty)
      }
      #expect(initial.ownedWork.snapshot.contains { $0.resourceID == "retained-owner" })
      failing.fail(false)
      let result = try await serving.callToolAsync(
        name: "runtime.owners.list", arguments: .object(["project_id": .string("fixture")]),
        context: .empty)
      #expect(String(describing: result).contains(initial.generationID.uuidString))
      lease.finish()
      await serving.shutdown()
      await generations.shutdown()
    } catch {
      lease.finish()
      await serving.shutdown()
      await generations.shutdown()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func derivedDirectoryRefreshesOnTheSameSession(managed: Bool) async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.cloudflareTunnel])
    let serving: GatewayControlSessionServing
    let shutdown: @Sendable () async -> Void
    if managed {
      let sessions = try await fixture.service.makeHTTPSessions(
        profileID: .chatGPTOperate, trace: .init(transport: "http"))
      serving = try await sessions.makeSession("derived-client")
      shutdown = { await sessions.shutdown() }
    } else {
      var configuration = try await fixture.control.activeConfiguration()
      configuration.projects = [
        .init(id: "fixture", displayName: "Fixture", path: fixture.root.path)
      ]
      let initial = try await GatewayRuntime.make(
        configuration: configuration,
        context: .init(
          caller: .cloudflareTunnel, profileID: .chatGPTOperate,
          trustedPrincipalID: "derived-client"),
        database: fixture.database, registeredProjects: try fixture.database.projects(),
        platform: fixture.platform,
        bundledPlugins: .init(packages: [], issues: []),
        requiresControlSession: true)
      let generations = GatewayStandaloneGenerations(initial)
      serving = GatewayControlSessionServing(
        base: generations, session: try await generations.makeControlSession())
      shutdown = {
        await serving.shutdown()
        await generations.shutdown()
      }
    }
    do {
      let sessionID = serving.session.id
      let child = fixture.root.appendingPathComponent("derived-content")
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
      let profiles = try fixture.database.profiles()
      try fixtureRemovingDerivedProject(
        database: fixture.database, id: "derived", sourceID: "fixture", root: child,
        displayName: "Derived")
      let result = try await serving.callToolAsync(
        name: "project.describe", arguments: .object(["project_id": .string("derived")]),
        context: .empty)
      #expect(
        result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["root_path"]
          == .string(child.standardizedFileURL.path))
      #expect(!String(describing: result).contains("project.not_found"))
      #expect(serving.session.id == sessionID)
      #expect(try fixture.database.profiles() == profiles)
      try fixture.database.deleteProject(id: "fixture")
      await #expect(throws: (any Error).self) {
        _ = try await serving.callToolAsync(
          name: "project.describe", arguments: .object(["project_id": .string("derived")]),
          context: .empty)
      }
      #expect(FileManager.default.fileExists(atPath: child.path))
      #expect(try fixture.database.project(id: "fixture") == nil)
      await shutdown()
    } catch {
      await shutdown()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func managedDispatchKeepsAnExplicitContinuation(cachedOwner: Bool) async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.cloudflareTunnel])
    let source = try await fixture.service.makeHTTPSessions(
      profileID: .chatGPTOperate, trace: .init(transport: "http"))
    do {
      let serving = try await source.makeSession("verified-generation-client")
      let session = try #require(await fixture.service.controlSessions().first)
      _ = try await fixture.consent(session)
      let discovery = try await serving.callToolAsync(
        name: "mcp.tools.list",
        arguments: .object(["project_id": .string("fixture"), "server": .string("fixture")]),
        context: .empty)
      try #require(discovery.objectValue?["isError"] != .bool(true), "\(discovery)")
      _ = try await serving.listToolsAsync(context: .empty)
      let handle = JSONValue.string("selected")
      _ = try await serving.callToolAsync(
        name: cachedOwner ? "fixture.start" : "fixture.identity",
        arguments: .object(["handle": handle]), context: .empty)
      if cachedOwner {
        let deadline = ContinuousClock.now + .seconds(5)
        var acquired = false
        repeat {
          let result = try await serving.callToolAsync(
            name: "runtime.owners.list", arguments: .object(["project_id": .string("fixture")]),
            context: .empty)
          acquired =
            result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
              "owners"]?
            .arrayValue?.contains { $0.objectValue?["kind"] == .string("mcpResource") } == true
          if !acquired { try await Task.sleep(for: .milliseconds(10)) }
        } while !acquired && ContinuousClock.now < deadline
        try #require(acquired)
      }
      let calls = try fixture.calls()
      let starts = try fixture.pids()
      let selected = MCPContinuationTarget(
        projectID: "fixture", reference: .init(serverID: "fixture", toolName: "inspect"),
        connectionID: UUID(), instanceID: UUID(), resources: [:])
      let continuationDeadline = ContinuousClock.now + .seconds(5)
      var result: JSONValue
      repeat {
        result = try await serving.callToolForMCPAsync(
          name: "fixture.inspect",
          arguments: .object(["project_id": .string("fixture"), "handle": handle]),
          context: .init(continuation: selected))
        guard
          result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]
            == .string("mcp.continuation_pending")
        else { break }
        try #require(ContinuousClock.now < continuationDeadline, "Work observation did not settle")
        try await Task.sleep(for: .milliseconds(10))
      } while true
      #expect(result.objectValue?["isError"] == .bool(true))
      #expect(String(describing: result).contains("mcp.continuation_unavailable"))
      #expect(try fixture.calls() == calls)
      #expect(try fixture.pids() == starts)
      await source.shutdown()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await source.shutdown()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func nativeFullAccessBackendAdmitsConsentedDownstreamAndEndsItsGroup() async throws {
    let fixture = try GenerationFixture(executionLauncher: testExecutionLauncher())
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect(consent: false)
    do {
      let session = try #require(await fixture.service.controlSessions().first)
      _ = try await fixture.consent(session)
      let allowed = try await client.call(
        toolName: "mcp.tools.list",
        arguments: .object(["project_id": .string("fixture"), "server": .string("fixture")]))
      #expect(allowed.result.objectValue?["isError"] != .bool(true), "\(allowed.result)")
      #expect(try !fixture.pids().isEmpty)
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func ownerConsentPreservesAnUnadmittedExternalManifestEdit() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect(consent: false)
    do {
      let scope = try #require(await fixture.service.controlSessions().first)
      let manifest = fixture.control.directories.manifest
      let external = "schema_version = 999\n"
      try external.write(to: manifest, atomically: true, encoding: .utf8)
      await #expect(throws: AtomicManifestStoreError.staleDigest) {
        _ = try await fixture.service.approveControlSession(
          id: scope.id, expectedRevision: scope.revision)
      }
      #expect(try String(contentsOf: manifest, encoding: .utf8) == external)
      #expect(try await !fixture.control.activeConfiguration().policy.shellEnabled)
      #expect(await fixture.service.controlSessions().first?.fullAccessConsent == nil)
      #expect(try fixture.database.clientTrusts().isEmpty)
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func explicitOwnerConsentSelectsFullAccessWithConfiguredShell(http: Bool) async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(
      version: 1, shellEnabled: true, callers: [.localMCP, .cloudflareTunnel])
    let before = try await fixture.control.activeConfiguration()
    let profiles = try fixture.database.profiles()
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.control, gatewayService: fixture.service)
    var origin: GatewayHTTPRuntime?
    let client: GatewayClientSession
    if http {
      let source = try await fixture.service.makeHTTPSessions(
        profileID: .chatGPTOperate, trace: .init(transport: "http"))
      let runtime = GatewayHTTPRuntime(
        configuration: before, source: .managed(source), host: "127.0.0.1", port: 0,
        publicBaseURL: nil, accessToken: "fixture-credential")
      origin = runtime
      try await runtime.startListening()
      let port = try #require(await runtime.boundPort())
      client = try await GatewayClientSession.connectHTTP(
        endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
        accessToken: "fixture-credential")
    } else {
      try await fixture.service.start(profile: .chatGPTOperate)
      client = try await fixture.connect(consent: false)
    }
    do {
      let scope = try #require(await operations.controlSessions().first)
      #expect(before.policy.shellEnabled)
      let shell = try #require(try await client.listTools().first { $0.name == "shell.run" })
      #expect(shell.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
      let refused = try await client.call(
        toolName: "shell.run",
        arguments: .object(["mode": .string("argv"), "executable": .string("/bin/cat")]))
      #expect(refused.result.objectValue?["isError"] == .bool(true))
      #expect(value(refused, "error")?.objectValue?["code"] == .string("permission.denied"))
      #expect(value(refused, "error")?.objectValue?["reason"] == .string("mainProjectWrite"))
      #expect(value(refused, "error")?.objectValue?["request_ids"] == nil)
      #expect(try fixture.pids().isEmpty)
      let permissions = try fixture.database.permissionRuntime(platform: fixture.platform)
      #expect(try await permissions.store.read().executions.isEmpty)
      let approved = try await operations.approveControlSession(
        id: scope.id, expectedRevision: scope.revision)
      #expect(approved.fullAccessConsent?.lifetime == .thisSession)
      try await fixture.discover(client)
      let pid = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("retained")])))
      let owner = try #require(try await owners(client, kind: "mcpResource").first)
      #expect(try await fixture.control.activeConfiguration() == before)
      #expect(try fixture.database.profiles() == profiles)
      #expect(try fixture.database.clientTrusts().isEmpty)
      #expect(try await client.listToolNames().contains("shell.run"))
      #expect(alive(pid))
      let retained = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: ["handle": .string("retained")])
      #expect(value(retained, "pid") == .integer(Int64(pid)), "\(retained.result)")
      await client.disconnect()
      await origin?.stop()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await origin?.stop()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: [GatewayFullAccessLifetime.thisSession, .alwaysAllowClient])
  func httpReconnectRespectsOwnedWorkConsentLifetime(lifetime: GatewayFullAccessLifetime)
    async throws
  {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(
      version: 1, shellEnabled: true, callers: [.localMCP, .cloudflareTunnel])
    let configuration = try await fixture.control.activeConfiguration()
    let source = try await fixture.service.makeHTTPSessions(
      profileID: .chatGPTOperate, trace: .init(transport: "http"))
    let origin = GatewayHTTPRuntime(
      configuration: configuration, source: .managed(source), host: "127.0.0.1", port: 0,
      publicBaseURL: nil, accessToken: "fixture-credential")
    try await origin.startListening()
    let port = try #require(await origin.boundPort())
    let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
    let client = try await GatewayClientSession.connectHTTP(
      endpoint: endpoint, accessToken: "fixture-credential")
    var reconnected: GatewayClientSession?
    do {
      let original = try #require(await origin.controlSessions().first)
      let approved = try await fixture.consent(original, lifetime: lifetime)
      #expect(approved.fullAccessConsent?.lifetime == lifetime)
      try await fixture.discover(client)
      let process = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("retained")])))
      let owner = try #require(try await owners(client, kind: "mcpResource").first)
      await client.disconnect()
      try await waitUntil { await origin.controlSessions().isEmpty }
      #expect(await origin.controlSessions().isEmpty)
      if lifetime == .thisSession {
        try await wait { !alive(process) }
      } else {
        #expect(alive(process))
      }
      let next = try await GatewayClientSession.connectHTTP(
        endpoint: endpoint, accessToken: "fixture-credential")
      reconnected = next
      let scope = try #require(await origin.controlSessions().first)
      #expect(scope.id != original.id)
      #expect(scope.principalID == original.principalID)
      if lifetime == .thisSession {
        #expect(scope.fullAccessConsent == nil)
        let beforeRetry = try fixture.calls()
        let retired = try await call(
          next, owner: owner, tool: "fixture.inspect", arguments: ["handle": .string("retained")])
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == beforeRetry)
        #expect(!alive(process))
        _ = try await fixture.consent(scope, lifetime: .thisSession)
        try await fixture.discover(next)
        let fresh = try pid(
          await next.call(
            toolName: "fixture.start", arguments: .object(["handle": .string("fresh")])))
        #expect(fresh != process && alive(fresh))
        await next.disconnect()
        try await wait { !alive(fresh) }
        #expect(!alive(process))
      } else {
        #expect(scope.fullAccessConsent?.lifetime == .alwaysAllowClient)
        let retained = try await call(
          next, owner: owner, tool: "fixture.inspect", arguments: ["handle": .string("retained")])
        #expect(value(retained, "pid") == .integer(Int64(process)), "\(retained.result)")
        await next.disconnect()
        #expect(alive(process))
      }
      await origin.stop()
      try await wait { !alive(process) }
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await reconnected?.disconnect()
      await origin.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func managedHTTPProviderUpdateRevokesOldWorkAndPreservesIndependentListenerConsent() async throws
  {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(
      version: 1, shellEnabled: true, callers: [.localMCP, .cloudflareTunnel])
    let operations = AppControlPlaneOperations(
      controlPlane: fixture.control, gatewayService: fixture.service)
    let configuration = try await fixture.control.activeConfiguration()
    func origin() async throws -> GatewayHTTPRuntime {
      let source = try await fixture.service.makeHTTPSessions(
        profileID: .chatGPTOperate,
        trace: .init(transport: "http", tunnelInstanceID: UUID().uuidString))
      let origin = GatewayHTTPRuntime(
        configuration: configuration, source: .managed(source), host: "127.0.0.1", port: 0,
        publicBaseURL: nil, accessToken: "shared-fixture-credential")
      try await origin.startListening()
      return origin
    }
    func connect(_ origin: GatewayHTTPRuntime) async throws -> GatewayClientSession {
      let port = try #require(await origin.boundPort())
      return try await GatewayClientSession.connectHTTP(
        endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
        accessToken: "shared-fixture-credential")
    }
    var phase = "create first listener"
    let firstOrigin = try await origin()
    var secondOrigin: GatewayHTTPRuntime?
    do {
      phase = "create second listener"
      let second = try await origin()
      secondOrigin = second
      phase = "connect first listener"
      let firstClient = try await connect(firstOrigin)
      phase = "connect second listener"
      let secondClient = try await connect(second)
      let firstScope = try #require(await firstOrigin.controlSessions().first)
      var secondScope = try #require(await second.controlSessions().first)
      #expect(firstScope.principalID == secondScope.principalID)
      #expect(await operations.controlSessions().count == 2)
      phase = "approve first listener"
      _ = try await operations.approveControlSession(
        id: firstScope.id, expectedRevision: firstScope.revision)
      #expect(try await firstClient.listToolNames().contains("shell.run"))
      phase = "verify second listener remains unconsented"
      let shell = try #require(try await secondClient.listTools().first { $0.name == "shell.run" })
      #expect(shell.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
      let refused = try await secondClient.call(
        toolName: "shell.run",
        arguments: .object(["mode": .string("argv"), "executable": .string("/bin/cat")]))
      #expect(refused.result.objectValue?["isError"] == .bool(true))
      #expect(value(refused, "error")?.objectValue?["code"] == .string("permission.denied"))
      #expect(value(refused, "error")?.objectValue?["reason"] == .string("mainProjectWrite"))
      #expect(value(refused, "error")?.objectValue?["request_ids"] == nil)
      #expect(try fixture.pids().isEmpty)
      let permissions = try fixture.database.permissionRuntime(platform: fixture.platform)
      #expect(try await permissions.store.read().executions.isEmpty)
      #expect(await firstOrigin.controlSessions().first?.fullAccessConsent != nil)
      #expect(await second.controlSessions().first?.fullAccessConsent == nil)
      phase = "approve second listener"
      secondScope = try await operations.approveControlSession(
        id: secondScope.id, expectedRevision: secondScope.revision)
      phase = "discover first provider"
      try await fixture.discover(firstClient)
      phase = "discover second provider"
      try await fixture.discover(secondClient)
      phase = "start first owned resource"
      let firstStarted = try await firstClient.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("first")]))
      let firstPID = try pid(firstStarted)
      phase = "start second owned resource"
      let secondPID = try pid(
        await secondClient.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("second")])))
      #expect(firstPID != secondPID)
      phase = "capture first owner"
      let firstOwner = try #require(try await owners(firstClient, kind: "mcpResource").first)
      phase = "publish version 2"
      _ = try await operations.activateManifest(
        fixture.externalManifest(version: 2),
        expectedDigest: try await operations.controlPlane.configurationDigest())
      phase = "discover first version 2 provider"
      let firstCurrent = try await fixture.identity(firstClient)
      phase = "discover second version 2 provider"
      let secondCurrent = try await fixture.identity(secondClient)
      #expect(value(firstCurrent, "version") == .integer(2))
      #expect(value(secondCurrent, "version") == .integer(2))
      let firstCurrentPID = try pid(firstCurrent)
      let secondCurrentPID = try pid(secondCurrent)
      try await wait { !alive(firstPID) && !alive(secondPID) }
      #expect(await firstOrigin.controlSessions().first?.fullAccessConsent != nil)
      phase = "reject first original owner"
      let callsBefore = try fixture.calls()
      for tool in ["fixture.inspect", "fixture.finish"] {
        let retired = try await call(
          firstClient, owner: firstOwner, tool: tool, arguments: ["handle": .string("first")])
        #expect(retired.result.objectValue?["isError"] == .bool(true))
      }
      #expect(try fixture.calls() == callsBefore)
      phase = "stop first listener"
      await firstOrigin.stop()
      await firstClient.disconnect()
      #expect(!alive(firstCurrentPID))
      #expect(!alive(secondPID) && alive(secondCurrentPID))
      #expect(await operations.controlSessions().map(\.id) == [secondScope.id])
      phase = "end second listener session"
      try await operations.endControlSession(
        id: secondScope.id, expectedRevision: secondScope.revision)
      #expect(
        try await secondClient.call(toolName: "fixture.identity").result.objectValue?["isError"]
          == .bool(true))
      phase = "join second original provider"
      try await wait { !alive(secondPID) }
      phase = "stop second listener"
      await second.stop()
      await secondClient.disconnect()
      #expect(await operations.controlSessions().isEmpty)
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      Issue.record("HTTP publication failed during \(phase): \(error)")
      await firstOrigin.stop()
      await secondOrigin?.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func managedHTTPStopInvalidatesPendingAdmissionBeforeJoiningItsConstruction() async throws {
    let bookmarks = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmarks)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.cloudflareTunnel])
    let configuration = try await fixture.control.activeConfiguration()
    let source = try await fixture.service.makeHTTPSessions(
      profileID: .chatGPTOperate, trace: .init(transport: "http"))
    let (stoppingEvents, stoppingSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let instrumented = GatewayHTTPManagedSessions(
      makeSession: source.makeSession, closeSession: source.closeSession,
      shutdown: {
        stoppingSignal.yield(())
        await source.shutdown()
      })
    let origin = GatewayHTTPRuntime(
      configuration: configuration, source: .managed(instrumented), host: "127.0.0.1", port: 0,
      publicBaseURL: nil, accessToken: "fixture-credential")
    try await origin.startListening()
    let port = try #require(await origin.boundPort())
    bookmarks.arm()
    let pending = Task {
      try await GatewayClientSession.connectHTTP(
        endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
        accessToken: "fixture-credential")
    }
    do {
      try await wait { bookmarks.entered }
      let stopping = Task { await origin.stop() }
      var events = stoppingEvents.makeAsyncIterator()
      _ = await events.next()
      #expect(!bookmarks.returned)
      bookmarks.release()
      await stopping.value
      if case .success(let client) = await pending.result {
        await client.disconnect()
        Issue.record("A stopped listener admitted an HTTP session")
      }
      await #expect(throws: (any Error).self) { try await source.makeSession("late-principal") }
      #expect(await fixture.service.controlSessions().isEmpty)
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      bookmarks.release()
      pending.cancel()
      await origin.stop()
      if case .success(let client) = await pending.result { await client.disconnect() }
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func managedHTTPStopJoinsPreparedPublicationAndRejectsObsoleteCandidates() async throws {
    let bookmarks = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmarks)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.cloudflareTunnel])
    let configuration = try await fixture.control.activeConfiguration()
    let source = try await fixture.service.makeHTTPSessions(
      profileID: .chatGPTOperate, trace: .init(transport: "http"))
    let origin = GatewayHTTPRuntime(
      configuration: configuration, source: .managed(source), host: "127.0.0.1", port: 0,
      publicBaseURL: nil, accessToken: "fixture-credential")
    try await origin.startListening()
    let port = try #require(await origin.boundPort())
    let client = try await GatewayClientSession.connectHTTP(
      endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
      accessToken: "fixture-credential")
    let before = try fixture.database.configurationState()
    bookmarks.arm()
    let publication = Task {
      try await fixture.service.changePlugins(
        .enabled(pluginID: "future-plugin", true), expectedRevision: 0)
    }
    do {
      try await wait { bookmarks.entered }
      let stopping = Task {
        await origin.stop()
        return bookmarks.returned
      }
      try await waitUntil { await fixture.service.controlSessions().isEmpty }
      try await wait { try fixture.pids().allSatisfy { !alive($0) } }
      #expect(try fixture.database.configurationState() == before)
      bookmarks.release()
      #expect(await stopping.value)
      await #expect(throws: GatewaySocketError.notConnected) { _ = try await publication.value }
      #expect(try fixture.database.configurationState() == before)
      #expect(try fixture.pids().allSatisfy { !alive($0) })
      await client.disconnect()
    } catch {
      bookmarks.release()
      publication.cancel()
      _ = await publication.result
      await origin.stop()
      await client.disconnect()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func localAdminStopJoinsPendingConstructionAndRestartsWithFreshAdmission() async throws {
    let bookmarks = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmarks)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let socket = fixture.root.appendingPathComponent("control.sock")
    let control = ControlSocketService(
      controlPlane: fixture.control, gatewayService: fixture.service, socketURL: socket)
    let client = AppControlPlaneServiceClient(socketURL: socket)
    try await control.start()
    bookmarks.arm()
    let pending = Task { try await adminCall(client, "project.list") }
    var stopping: Task<Void, Never>?
    do {
      try await wait { bookmarks.entered }
      stopping = Task { await control.stop() }
      try await waitUntil { await control.snapshot().state == .stopping }
      bookmarks.release()
      await stopping?.value
      #expect(await control.snapshot().state == .stopped)
      #expect(try fixture.pids().allSatisfy { !alive($0) })
      if case .success = await pending.result {
        Issue.record("A stopped admission returned success")
      }
      try await control.start()
      let metadata = try await adminCall(client, "project.list")
      #expect(
        metadata.objectValue?["result"]?.objectValue?["projects"]?.arrayValue?.contains {
          $0.objectValue?["id"] == .string("fixture")
        } == true)
      let refused = try await client.call(
        "tools.call",
        arguments: .object([
          "name": .string("mcp.tools.list"),
          "arguments": .object(["project_id": .string("fixture"), "server": .string("fixture")]),
        ]))
      #expect(refused.objectValue?["isError"] == .bool(true))
      #expect(try fixture.pids().isEmpty)
      await control.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      bookmarks.release()
      pending.cancel()
      await stopping?.value
      _ = await pending.result
      await control.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func bridgePluginUpdateRevokesOldOwnersAndRechecksRemovedProject() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    let archives = try ArchiveFixture()
    defer { archives.remove() }
    try await fixture.activate(version: 1)
    var configuration = try await fixture.control.activeConfiguration()
    configuration.mcp.servers = []
    configuration.profiles[0].grant.permissions.removeEntry(for: .mcpServer("fixture"))
    _ = try await fixture.service.changeManifest(
      configuration.exportedTOML(), expectedDigest: try await fixture.control.configurationDigest())
    var snapshot = try await fixture.installPlugin(version: 1, managed: true, archives: archives)
    snapshot = try await fixture.service.changePlugins(
      .settings(
        pluginID: "live-fixture",
        .init(
          enabled: true,
          mcp: [
            "native": .init(
              registrationID: "fixture", exposure: .reexport, prefix: "fixture", allowAnyTool: true,
              toolRisks: Dictionary(
                uniqueKeysWithValues: [
                  "start", "inspect", "finish", "identity", "generation_1", "generation_2",
                ].map { ($0, CapabilityRisk.readOnly) }),
              args: [fixture.root.path, "unused", "yes"])
          ])), expectedRevision: snapshot.state.revision)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    let arguments: [String: JSONValue] = ["handle": .string("retained")]
    do {
      let started = try await client.call(toolName: "fixture.start", arguments: .object(arguments))
      try #require(started.result.objectValue?["isError"] != .bool(true), "\(started.result)")
      let oldPID = try pid(started)
      let listed = try await client.call(
        toolName: "runtime.owners.list", arguments: .object(["project_id": .string("fixture")]))
      try #require(listed.result.objectValue?["isError"] != .bool(true), "\(listed.result)")
      let rows = try #require(value(listed, "result")?.objectValue?["owners"]?.arrayValue)
      let providerCalls = try fixture.calls()
      let owner = try #require(
        rows.first { $0.objectValue?["kind"] == .string("mcpResource") }?.objectValue?["owner"],
        "Start: \(started.result); owners: \(listed.result); PID: \(oldPID), alive: \(alive(oldPID)); provider calls: \(providerCalls)"
      )
      _ = try await fixture.installPlugin(version: 2, managed: true, archives: archives)
      #expect(try pid(await fixture.identity(client)) != oldPID)
      try await wait { !alive(oldPID) }
      let callsBefore = try fixture.calls()
      let retired = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: arguments)
      #expect(retired.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == callsBefore)
      let state = try fixture.database.configurationState()
      await #expect(throws: (any Error).self) {
        _ = try await fixture.installPlugin(version: 3, managed: true, archives: archives)
      }
      #expect(try fixture.database.configurationState() == state)
      #expect(!alive(oldPID))
      _ = try await fixture.service.changeProjects(.remove("fixture"))
      let before = try fixture.calls()
      let denied = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: arguments)
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == before)
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func managedHTTPCallsRetainNativeWorkAcrossConnections(listenerRunning: Bool) async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.localMCP, .cloudflareTunnel])
    let source = try await fixture.service.makeHTTPSessions(
      profileID: .chatGPTOperate, trace: .init(transport: "http"))
    let origin = GatewayHTTPRuntime(
      configuration: try await fixture.control.activeConfiguration(), source: .managed(source),
      host: "127.0.0.1", port: 0, publicBaseURL: nil, accessToken: "fixture-credential")
    try await origin.startListening()
    let port = try #require(await origin.boundPort())
    let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
    var phase = "start calls"
    func call(_ name: String) async throws -> JSONValue {
      phase = "connect for \(name)"
      let previous = Set(await origin.controlSessions().map(\.id))
      let client = try await GatewayClientSession.connectHTTP(
        endpoint: endpoint, accessToken: "fixture-credential")
      do {
        try Task.checkCancellation()
        phase = "consent for \(name)"
        let session = try #require(
          await origin.controlSessions().first { !previous.contains($0.id) })
        let consent = try await fixture.consent(session, lifetime: .alwaysAllowClient)
        try #require(consent.fullAccessConsent?.lifetime == .alwaysAllowClient)
        try Task.checkCancellation()
        if name == "fixture.start" || name == "fixture.identity" {
          phase = "discover for \(name)"
          try await fixture.discover(client)
          try Task.checkCancellation()
        }
        phase = "call \(name)"
        let report = try await client.call(
          toolName: name, arguments: .object(["handle": .string("owned")]))
        try Task.checkCancellation()
        try #require(report.result.objectValue?["isError"] != .bool(true), "\(report.result)")
        let result = try #require(report.result.objectValue?["structuredContent"])
        phase = "disconnect after \(name)"
        await client.disconnect()
        try Task.checkCancellation()
        return result
      } catch {
        await client.disconnect()
        throw error
      }
    }
    do {
      if listenerRunning { try await fixture.service.start(profile: .chatGPTOperate) }
      let first = try await call("fixture.start")
      let original = try #require(
        first.objectValue?["pid"]?.int64Value.flatMap(Int32.init(exactly:)))
      #expect(alive(original))
      let continued = try await call("fixture.inspect")
      #expect(continued.objectValue?["pid"] == .integer(Int64(original)))
      #expect(try fixture.pids().count == 2)
      #expect(try fixture.invocationPIDs() == [original])
      let firstRequest = try #require(
        first.objectValue?["gateway_execution"]?.objectValue?["request_id"]?.stringValue)
      let secondRequest = try #require(
        continued.objectValue?["gateway_execution"]?.objectValue?["request_id"]?.stringValue)
      func terminalAudit(requestID: String, capabilityID: String) throws -> AuditEvent {
        let events = try fixture.database.auditEvents(requestID: requestID)
        let admitted = events.filter {
          $0.capabilityID == capabilityID && $0.decision == .allowed
            && $0.errorCode == "permission.admitted"
        }
        let completed = events.filter {
          $0.capabilityID == capabilityID && $0.decision == .allowed && $0.errorCode == nil
        }
        try #require(admitted.count == 1 && completed.count == 1, "\(events)")
        let admission = try #require(admitted.first)
        let terminal = try #require(completed.first)
        #expect(
          admission.principalDigest != nil && admission.principalDigest == terminal.principalDigest)
        #expect(admission.profileID == terminal.profileID && admission.caller == terminal.caller)
        #expect(admission.transport == terminal.transport)
        #expect(admission.inputDigest == terminal.inputDigest)
        #expect(admission.outputDigest == nil && terminal.outputDigest != nil)
        let before = try #require(admission.errorDetails?.objectValue)
        let after = try #require(terminal.errorDetails?.objectValue)
        #expect(before["admission"] == .string("allowed"))
        #expect(after["admission"] == .string("completed"))
        #expect(
          before["authorization_id"] != nil
            && before["authorization_id"] == after["authorization_id"])
        return terminal
      }
      let firstAudit = try terminalAudit(requestID: firstRequest, capabilityID: "fixture.start")
      let secondAudit = try terminalAudit(requestID: secondRequest, capabilityID: "fixture.inspect")
      #expect(firstAudit.requestID != secondAudit.requestID)
      #expect(
        firstAudit.principalDigest != nil
          && firstAudit.principalDigest == secondAudit.principalDigest)
      #expect(firstAudit.profileID == .chatGPTOperate && secondAudit.profileID == .chatGPTOperate)
      #expect(firstAudit.transport == "http" && secondAudit.transport == "http")
      #expect(firstAudit.caller == .cloudflareTunnel && secondAudit.caller == .cloudflareTunnel)
      phase = "publish version 2"
      try await fixture.publishMetadata(version: 2)
      let current = try await call("fixture.identity")
      try #require(current.objectValue?["version"] == .integer(1), "\(current)")
      #expect(current.objectValue?["pid"] != first.objectValue?["pid"])
      #expect(try await call("fixture.inspect").objectValue?["pid"] == .integer(Int64(original)))
      phase = "stop local listener"
      await fixture.service.stop()
      try Task.checkCancellation()
      #expect(await fixture.service.snapshot().state == .stopped)
      #expect(try await call("fixture.inspect").objectValue?["pid"] == .integer(Int64(original)))
      phase = "publish external version 3"
      var metadata = try await fixture.control.activeConfiguration()
      metadata.server.name = "version-3"
      try fixture.writeManifest(try metadata.exportedTOML(), atomic: false)
      try await waitUntil {
        try await fixture.control.activeConfiguration().server.name == "version-3"
      }
      #expect(try await call("fixture.identity").objectValue?["version"] == .integer(1))
      phase = "start local listener"
      try await fixture.service.start(profile: .chatGPTOperate)
      phase = "restart local listener"
      try await fixture.service.restart(profile: .chatGPTOperate)
      #expect(try await call("fixture.inspect").objectValue?["pid"] == .integer(Int64(original)))
      _ = try await call("fixture.finish")
      phase = "stop HTTP origin"
      await origin.stop()
      try Task.checkCancellation()
      phase = "stop local listener after HTTP origin"
      await fixture.service.stop()
      try Task.checkCancellation()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      Issue.record(
        "HTTP reconnect failed during \(phase), listenerRunning=\(listenerRunning): \(error)")
      await origin.stop()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func originStopRetiresOnlyItsOwnersAndRestartRejectsOldAdmission() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, callers: [.localMCP, .cloudflareTunnel])
    let source = try await fixture.service.makeHTTPSessions(
      profileID: .chatGPTOperate, trace: .init(transport: "http"))
    let origin = GatewayHTTPRuntime(
      configuration: try await fixture.control.activeConfiguration(), source: .managed(source),
      host: "127.0.0.1", port: 0, publicBaseURL: nil, accessToken: "fixture-credential")
    try await origin.startListening()
    let port = try #require(await origin.boundPort())
    let local = try await GatewayClientSession.connectHTTP(
      endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
      accessToken: "fixture-credential")
    try await fixture.service.start(profile: .chatGPTOperate)
    let remote = try await fixture.connect()
    var restarted: GatewayHTTPManagedSessions?
    do {
      try await fixture.consentSessions()
      try await fixture.discover(local)
      let localPID = try pid(
        await local.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("local")])))
      let remotePID = try pid(
        await remote.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("remote")])))
      #expect(localPID != remotePID)
      await origin.stop()
      #expect(!alive(localPID) && alive(remotePID))
      #expect(
        try pid(
          await remote.call(
            toolName: "fixture.inspect", arguments: .object(["handle": .string("remote")])))
          == remotePID)
      await #expect(throws: GatewaySocketError.self) {
        _ = try await source.makeSession("obsolete-origin-client")
      }
      let fresh = try await fixture.service.makeHTTPSessions(
        profileID: .chatGPTOperate, trace: .init(transport: "http"))
      restarted = fresh
      let serving = try await fresh.makeSession("verified-fresh-origin-client")
      let metadata = try await serving.callToolAsync(
        name: "project.list", arguments: .object([:]), context: .empty)
      #expect(metadata.objectValue?["isError"] != .bool(true))
      await fresh.shutdown()
      restarted = nil
      await local.disconnect()
      await remote.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await restarted?.shutdown()
      await origin.stop()
      await local.disconnect()
      await remote.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func bridgeShellAndMCPReceiptsSurviveSeparateCallsAndManifestPublication() async throws {
    let fixture = try GenerationFixture(reportWork: false)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, shellEnabled: true)
    let skillRoot = fixture.root.appendingPathComponent("published-skills")
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    _ = try await fixture.service.changeManifest(
      fixture.externalManifest(version: 1, skillRoot: skillRoot),
      expectedDigest: try await fixture.control.configurationDigest())
    try await fixture.service.start(profile: .chatGPTOperate)
    func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
      let client = try await fixture.connect()
      do {
        let report = try await client.call(toolName: name, arguments: .object(arguments))
        try #require(report.result.objectValue?["isError"] != .bool(true), "\(report.result)")
        let result = try #require(report.result.objectValue?["structuredContent"])
        await client.disconnect()
        return result
      } catch {
        await client.disconnect()
        throw error
      }
    }
    var shellPID: Int32?
    do {
      let started = try await call(
        "shell.spawn", ["mode": .string("argv"), "executable": .string("/bin/cat")])
      let session = try #require(started.objectValue?["result"]?.objectValue?["session_id"])
      let read = try await call("shell.read", ["session_id": session])
      shellPID = try #require(
        read.objectValue?["result"]?.objectValue?["process_id"]?.int64Value.flatMap(
          Int32.init(exactly:)))
      _ = try await call(
        "mcp.tools.call",
        [
          "server": .string("fixture"), "tool": .string("wait"), "arguments": .object([:]),
          "request_id": .string("background"), "wait_for_result": .bool(false),
        ])
      try await fixture.publishMetadata(version: 2)
      let native = try await call("fixture.identity")
      #expect(native.objectValue?["version"] == .integer(1))
      let permissions = try fixture.database.permissionRuntime(platform: fixture.platform)
      let published = try #require(try await permissions.store.read().environment.paths)
      #expect(
        published.pathRules.contains {
          $0.kind == .skillLibrary && $0.root.string == skillRoot.path
        })
      _ = try await call(
        "shell.write", ["session_id": session, "text": .string("retained\n")])
      let repeated = try await call("shell.read", ["session_id": session])
      #expect(
        repeated.objectValue?["result"]?.objectValue?["process_id"]
          == .integer(Int64(try #require(shellPID))))
      let request = try await call(
        "mcp.requests.read",
        ["server": .string("fixture"), "request_id": .string("background")])
      #expect(request.objectValue?["result"]?.objectValue?["request_id"] == .string("background"))
      #expect(try await permissions.store.read().environment.paths == published)
      try Data().write(to: fixture.root.appendingPathComponent("release"))
      await fixture.service.stop()
      #expect(!alive(try #require(shellPID)))
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      try? Data().write(to: fixture.root.appendingPathComponent("release"))
      await fixture.service.stop()
      if let shellPID, alive(shellPID) { _ = kill(-shellPID, SIGKILL) }
      throw error
    }
  }

  private func adminCall(
    _ client: AppControlPlaneServiceClient, _ name: String, _ arguments: [String: JSONValue] = [:]
  ) async throws -> JSONValue {
    let result = try await client.call(
      "tools.call", arguments: .object(["name": .string(name), "arguments": .object(arguments)]))
    try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
    return try #require(result.objectValue?["structuredContent"])
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func externalProviderChangesRevokeOldWorkAndPreserveConnectionAndEditorBytes(atomic: Bool)
    async throws
  {
    let bookmarks = RepairFailureBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmarks)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let startedAt = await fixture.service.snapshot().startedAt
      let oldPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("old")])))
      let candidate = try await fixture.externalManifest(version: 2)
      try fixture.writeManifest(candidate, atomic: atomic)
      let file = fixture.control.directories.manifest
      let identity = try #require(
        FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
      try await waitUntil {
        try await fixture.control.activeConfiguration().server.name == "version-2"
      }
      #expect(
        try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
          == identity)
      let currentPID = try pid(await fixture.identity(client))
      #expect(currentPID != oldPID)
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_2" })
      try await wait { !alive(oldPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("old")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
      let history = try fixture.database.configurationRevisions()
      var rejected = try await fixture.control.activeConfiguration()
      rejected.server.name = "recoverable"
      bookmarks.arm(
        root: fixture.root, resolveNumber: 1, replace: false, underlyingError: POSIXError(.EIO))
      let rejectedText = try rejected.exportedTOML()
      try fixture.writeManifest(rejectedText, atomic: atomic)
      try await waitUntil { await fixture.service.snapshot().lastError != nil }
      let attempts = try fixture.pids()
      try await Task.sleep(for: .milliseconds(1500))
      let subsequent = try fixture.pids()
      #expect(subsequent == attempts)
      #expect(try fixture.database.configurationRevisions() == history)
      #expect(try Data(contentsOf: file) == Data(rejectedText.utf8))
      #expect(try pid(await fixture.identity(client)) == currentPID)
      try fixture.writeManifest(rejectedText, atomic: atomic)
      try await waitUntil {
        let published = try await fixture.control.activeConfiguration().server.name
        let status = await fixture.service.snapshot()
        // Persistence is observable before the external reload task finishes its status update.
        return published == "recoverable" && status.lastError == nil
      }
      #expect(await fixture.service.snapshot().lastError == nil)
      #expect(try fixture.database.configurationRevisions().count == history.count + 1)
      try fixture.writeManifest(try await fixture.externalManifest(version: 3), atomic: atomic)
      try await waitUntil {
        let published = try await fixture.control.activeConfiguration().server.name
        let status = await fixture.service.snapshot()
        return published == "version-3" && status.lastError == nil
      }
      #expect(await fixture.service.snapshot().lastError == nil)
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      #expect(await fixture.service.snapshot().connectionCount == 1)
      try await wait { !alive(oldPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.finish", arguments: .object(["handle": .string("old")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
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

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func externalReloadCoalescesAndRecoversFromConflictingPublication(managed: Bool) async throws {
    let bookmarks = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmarks)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    var mutation: Task<Void, any Error>?
    do {
      let oldPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("old")])))
      bookmarks.arm()
      if managed {
        mutation = Task {
          _ = try await fixture.service.changePlugins(
            .enabled(pluginID: "future", true), expectedRevision: 0)
        }
      } else {
        try fixture.writeManifest(try await fixture.externalManifest(version: 2), atomic: true)
      }
      try await wait { bookmarks.entered }
      for version in 3...8 {
        try fixture.writeManifest(
          try await fixture.externalManifest(version: version), atomic: true)
      }
      #expect(try pid(await fixture.identity(client)) == oldPID)
      bookmarks.release()
      if let mutation { await #expect(throws: (any Error).self) { try await mutation.value } }
      try await waitUntil {
        try await fixture.control.activeConfiguration().server.name == "version-8"
      }
      #expect(try fixture.database.pluginStoreSnapshot().revision == 0)
      #expect(try fixture.database.configurationRevisions().count == 2)
      #expect(try fixture.invocationPIDs().count <= 3)
      try await fixture.discover(client)
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_8" })
      try await wait { !alive(oldPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.finish", arguments: .object(["handle": .string("old")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      mutation?.cancel()
      bookmarks.release()
      _ = await mutation?.result
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func stopJoinsExternalPreparationAndRestartReconsidersLatestFile() async throws {
    let bookmarks = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmarks)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    var stopping: Task<Void, Never>?
    do {
      bookmarks.arm()
      try fixture.writeManifest(try await fixture.externalManifest(version: 2), atomic: true)
      try await wait { bookmarks.entered }
      stopping = Task { await fixture.service.stop() }
      try fixture.writeManifest(try await fixture.externalManifest(version: 3), atomic: true)
      bookmarks.release()
      await stopping?.value
      #expect(await fixture.service.snapshot().state == .stopped)
      #expect(try fixture.pids().allSatisfy { !alive($0) })
      await client.disconnect()
      try fixture.writeManifest(try await fixture.externalManifest(version: 4), atomic: false)
      try await fixture.service.start(profile: .chatGPTOperate)
      try await waitUntil {
        try await fixture.control.activeConfiguration().server.name == "version-4"
      }
      let reconnected = try await fixture.connect()
      #expect(try await reconnected.listTools().contains { $0.name == "fixture.generation_4" })
      await reconnected.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      bookmarks.release()
      await stopping?.value
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    let completed = try await condition()
    try #require(completed, "Timed out waiting for external manifest publication.")
  }

  @Test(.timeLimit(.minutes(1)))
  func managedProviderUpdateAndRollbackPreserveConnectionAndRetireOldWork() async throws {
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
      let currentPID = try pid(await fixture.identity(client))
      #expect(currentPID != oldPID)
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_2" })
      try await wait { !alive(oldPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("old")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
      let before = try fixture.database.configurationState()
      let history = try fixture.database.configurationRevisions()
      var rejected = proposed
      rejected.mcp.servers.append(rejected.mcp.servers[0])
      await #expect(throws: (any Error).self) {
        try await operations.activateManifest(
          rejected.exportedTOML(), expectedDigest: applied.digest)
      }
      #expect(try Data(contentsOf: fixture.control.directories.manifest) == Data(manifest.utf8))
      #expect(try fixture.database.configurationState() == before)
      #expect(try fixture.database.configurationRevisions() == history)
      #expect(try pid(await fixture.identity(client)) == currentPID)
      let rollback = try await operations.rollbackManifest(to: original.id)
      #expect(rollback.id != original.id && rollback.digest == original.digest)
      try await fixture.discover(client)
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_1" })
      #expect(await fixture.service.snapshot().connectionCount == 1)
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      try await wait { !alive(oldPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.finish", arguments: .object(["handle": .string("old")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
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

  @Test(.timeLimit(.minutes(1)), arguments: [1, 2, 3], [false, true])
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
      try await operations.repairProject(id: "fixture", at: destination)
    }
    #expect(bookmark.failureInjected)
    #expect(try fixture.database.configurationState() == before)
    #expect(await fixture.service.snapshot().state != .running)
    #expect(try fixture.pids().allSatisfy { !alive($0) })
    await fixture.service.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func connectedRepairRebindsIdentityAndIrrevocablyRetiresOldWork() async throws {
    let bookmarks = RepairFailureBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmarks)
    defer { fixture.removeFiles() }
    var metadata = try #require(try fixture.database.project(id: "fixture"))
    metadata.displayName = "  原有 Project  "
    try fixture.database.saveProject(metadata)
    let original = try #require(try fixture.database.project(id: "fixture"))
    var alias = original
    alias.id = "alias"
    alias.createdAt = original.createdAt.addingTimeInterval(1)
    try fixture.importHistoricalDuplicate(alias)
    _ = try fixture.database.applyProjectDeduplication(
      expectedPlanDigest: fixture.database.projectDeduplicationPlan().planDigest,
      allowMetadataConflicts: false)
    try await fixture.activate(version: 1)
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
      bookmarks.arm(root: destination, resolveNumber: 2, replace: false)
      await #expect(throws: (any Error).self) {
        try await operations.repairProject(id: alias.id, at: destination)
      }
      #expect(try fixture.database.configurationState() == before)
      #expect(
        try pid(await call(client, owner: owner, tool: "fixture.inspect", arguments: arguments))
          == oldPID)
      #expect(bookmarks.failureInjected)
      let repaired = try await operations.repairProject(id: alias.id, at: destination)
      #expect(repaired.id == original.id && repaired.createdAt == original.createdAt)
      #expect(repaired.displayName == original.displayName)
      #expect(
        repaired.rootPath == destination.resolvingSymlinksInPath().path
          && repaired.bookmarkData != nil)
      #expect(try fixture.database.project(id: alias.id) == repaired)
      #expect(
        try fixture.database.profiles().first?.permissions == before.profiles.first?.permissions)
      try await wait { !alive(oldPID) }
      try await fixture.consentSessions()
      let currentPID = try pid(await fixture.identity(client))
      #expect(currentPID != oldPID && alive(currentPID))
      let currentArguments = JSONValue.object(["handle": .string("repaired")])
      #expect(
        try pid(await client.call(toolName: "fixture.start", arguments: currentArguments))
          == currentPID)
      let currentOwner = try await observedResourceOwner(client, excluding: [owner])
      let beforePending = try fixture.calls()
      let pending = try await client.call(toolName: "fixture.finish", arguments: currentArguments)
      #expect(value(pending, "error")?.objectValue?["code"] == .string("mcp.continuation_pending"))
      #expect(try fixture.calls() == beforePending)
      #expect(
        try pid(
          await call(
            client, owner: currentOwner, tool: "fixture.finish",
            arguments: try #require(currentArguments.objectValue)))
          == currentPID)
      let calls = try fixture.calls()
      let denied = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: arguments)
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == calls)
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      #expect(await fixture.service.snapshot().connectionCount == 1)
      _ = try await operations.repairProject(
        id: original.id, at: fixture.root, displayName: "Restored")
      #expect(try fixture.database.project(id: original.id)?.displayName == "Restored")
      try await wait { !alive(currentPID) }
      try await fixture.consentSessions()
      let restoredPID = try pid(await fixture.identity(client))
      #expect(restoredPID != oldPID && restoredPID != currentPID)
      let restoredCalls = try fixture.calls()
      let retired = try await call(
        client, owner: owner, tool: "fixture.finish", arguments: arguments)
      #expect(retired.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == restoredCalls)
      #expect(!alive(oldPID))
      let restoredArguments = JSONValue.object(["handle": .string("restored")])
      #expect(
        try pid(await client.call(toolName: "fixture.start", arguments: restoredArguments))
          == restoredPID)
      let restoredOwner = try await observedResourceOwner(
        client, excluding: [owner, currentOwner])
      #expect(
        try pid(
          await call(
            client, owner: restoredOwner, tool: "fixture.finish",
            arguments: try #require(restoredArguments.objectValue)))
          == restoredPID)
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func projectChangesRetireWorkAndFreshContinuationsRequireExactOwners() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let originalArguments: [String: JSONValue] = [
        "project_id": .string("fixture"), "handle": .string("shared"),
      ]
      let oldPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(originalArguments)))
      let oldOwner = try #require(try await owners(client, kind: "mcpResource").first)
      let root = fixture.root.appendingPathComponent("added")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let operations = AppControlPlaneOperations(
        controlPlane: fixture.control, gatewayService: fixture.service)
      let added = try await operations.registerProject(at: root, displayName: "Added")
      var grant = try #require(
        try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      try grant.permissions.set(.granted(.write), for: .project(added.id))
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      try await wait { !alive(oldPID) }
      let beforeApproval = try fixture.calls()
      let retired = try await call(
        client, owner: oldOwner, tool: "fixture.inspect", arguments: originalArguments)
      #expect(retired.result.objectValue?["isError"] == .bool(true), "\(retired.result)")
      #expect(try fixture.calls() == beforeApproval)

      try await approveConnectedSession(fixture, profileID: .chatGPTOperate)
      try await fixture.discover(client)
      try await fixture.discover(client, projectID: added.id)
      let originalPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(originalArguments)))
      let originalOwner = try await observedResourceOwner(client, excluding: [oldOwner])
      let addedArguments: [String: JSONValue] = [
        "project_id": .string(added.id), "handle": .string("shared"),
      ]
      let addedPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(addedArguments)))
      let addedOwner = try await observedResourceOwner(client, projectID: added.id)
      #expect(originalPID != oldPID && addedPID != oldPID && originalPID != addedPID)
      let calls = try fixture.calls()
      let ambiguous = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("shared")]))
      #expect(ambiguous.result.objectValue?["isError"] == .bool(true))
      #expect(
        value(ambiguous, "error")?.objectValue?["code"] == .string("mcp.continuation_ambiguous"))
      #expect(try fixture.calls() == calls)
      #expect(
        try pid(
          await call(
            client, owner: originalOwner, tool: "fixture.inspect", arguments: originalArguments))
          == originalPID)
      #expect(
        try pid(
          await call(
            client, owner: addedOwner, tool: "fixture.inspect", arguments: addedArguments,
            projectID: added.id))
          == addedPID)
      #expect(!alive(oldPID))

      grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.permissions.removeEntry(for: .project(added.id))
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let beforeDenial = try fixture.calls()
      let denied = try await call(
        client, owner: addedOwner, tool: "fixture.finish", arguments: addedArguments,
        projectID: added.id)
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == beforeDenial)
      try await wait { !alive(originalPID) && !alive(addedPID) }
      try await approveConnectedSession(fixture, profileID: .chatGPTOperate)
      try await fixture.discover(client)
      let afterApproval = try fixture.calls()
      for owner in [oldOwner, originalOwner] {
        let retired = try await call(
          client, owner: owner, tool: "fixture.finish", arguments: originalArguments)
        #expect(retired.result.objectValue?["isError"] == .bool(true), "\(retired.result)")
      }
      #expect(try fixture.calls() == afterApproval)
      let freshArguments = JSONValue.object([
        "project_id": .string("fixture"), "handle": .string("fresh"),
      ])
      let freshPID = try pid(
        await client.call(toolName: "fixture.start", arguments: freshArguments))
      #expect(![oldPID, originalPID, addedPID].contains(freshPID))
      let freshOwner = try await observedResourceOwner(
        client, excluding: [oldOwner, originalOwner])
      #expect(
        try pid(
          await call(
            client, owner: freshOwner, tool: "fixture.finish",
            arguments: try #require(freshArguments.objectValue)))
          == freshPID)
      #expect(!alive(oldPID) && !alive(originalPID) && !alive(addedPID))
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func connectedDeduplicationPublishesAliasesAndGrantRevision() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let canonical = try #require(try fixture.database.project(id: "fixture"))
    var duplicate = canonical
    duplicate.id = "duplicate"
    duplicate.createdAt = canonical.createdAt.addingTimeInterval(1)
    let beforeDuplicate = try fixture.database.configurationState()
    let permissions = try fixture.database.permissionRuntime(platform: fixture.platform)
    let pathsBeforeDuplicate = try #require(try await permissions.store.read().environment.paths)
    #expect(throws: PermissionModelError.invalidProjectGraph) {
      try fixture.database.saveProject(duplicate)
    }
    #expect(try fixture.database.configurationState() == beforeDuplicate)
    #expect(try fixture.database.project(id: duplicate.id) == nil)
    #expect(try await permissions.store.read().environment.paths == pathsBeforeDuplicate)
    var grant = ProfileGrant.cloudflareOperate
    try grant.permissions.set(.granted(.write), for: .project(duplicate.id))
    try fixture.database.saveProfile(grant)
    let before = try #require(try fixture.database.profiles().first { $0.id == grant.id })
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let arguments = JSONValue.object([
        "project_id": .string("fixture"), "handle": .string("old"),
      ])
      let oldPID = try pid(await client.call(toolName: "fixture.start", arguments: arguments))
      try fixture.importHistoricalDuplicate(duplicate)
      let plan = try fixture.database.projectDeduplicationPlan()
      let operations = AppControlPlaneOperations(
        controlPlane: fixture.control, gatewayService: fixture.service)
      let receipt = try await operations.applyProjectDeduplication(
        expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
      #expect(receipt.aliasedProjectIDs == [duplicate.id])
      #expect(try fixture.database.project(id: duplicate.id)?.id == canonical.id)
      let after = try #require(try fixture.database.profiles().first { $0.id == grant.id })
      #expect(after.permissions.state(for: .project(canonical.id)) == .granted(.write))
      #expect(after.permissions.entries[.project(duplicate.id)] == nil)
      #expect(after.authorizationRevision == before.authorizationRevision + 1)
      #expect(await fixture.service.snapshot().connectionCount == 1)
      #expect(try pid(await fixture.identity(client)) != oldPID)
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

  @Test(.timeLimit(.minutes(1)))
  func connectedProjectPublicationRetiresWorkAndPreservesFailedCandidateAuthority() async throws {
    let bookmarks = RepairFailureBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmarks)
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
      let oldArguments: [String: JSONValue] = [
        "project_id": .string("fixture"), "handle": .string("old"),
      ]
      let oldPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(oldArguments)))
      let oldOwner = try #require(try await owners(client, kind: "mcpResource").first)
      let added = try await operations.registerProject(at: addedRoot, displayName: "Added")
      #expect(try fixture.database.project(id: added.id) != nil)
      try await wait { !alive(oldPID) }
      let retiredCalls = try fixture.calls()
      let retired = try await call(
        client, owner: oldOwner, tool: "fixture.inspect", arguments: oldArguments)
      #expect(retired.result.objectValue?["isError"] == .bool(true), "\(retired.result)")
      #expect(try fixture.calls() == retiredCalls)
      try await approveConnectedSession(fixture, profileID: .chatGPTOperate)
      let currentPID = try pid(await fixture.identity(client))
      #expect(currentPID != oldPID)
      let currentArguments: [String: JSONValue] = [
        "project_id": .string("fixture"), "handle": .string("registered"),
      ]
      #expect(
        try pid(await client.call(toolName: "fixture.start", arguments: .object(currentArguments)))
          == currentPID)
      let currentOwner = try await observedResourceOwner(client, excluding: [oldOwner])
      let beforeRepeat = try fixture.database.configurationState()
      let repeated = try await operations.registerProject(at: addedRoot, displayName: "Added")
      #expect(repeated.id == added.id)
      #expect(try fixture.database.projects().count == 2)
      #expect(try fixture.database.configurationState() == beforeRepeat)
      #expect(
        try pid(
          await call(
            client, owner: currentOwner, tool: "fixture.inspect", arguments: currentArguments))
          == currentPID)
      let before = try fixture.database.configurationState()
      await #expect(throws: AppControlPlaneServiceError.self) {
        try await operations.registerProject(at: addedRoot, displayName: "Conflicting")
      }
      #expect(try fixture.database.configurationState() == before)
      #expect(
        try pid(
          await call(
            client, owner: currentOwner, tool: "fixture.inspect", arguments: currentArguments))
          == currentPID)
      bookmarks.arm(
        root: fixture.root, resolveNumber: 1, replace: false, underlyingError: POSIXError(.EIO))
      await #expect(throws: POSIXError.self) { try await operations.removeProject(id: added.id) }
      #expect(try fixture.database.configurationState() == before)
      #expect(
        try pid(
          await call(
            client, owner: currentOwner, tool: "fixture.inspect", arguments: currentArguments))
          == currentPID)
      #expect(bookmarks.failureInjected)
      try await operations.removeProject(id: added.id)
      #expect(try fixture.database.project(id: added.id) == nil)
      #expect(await fixture.service.snapshot().connectionCount == 1)
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      try await wait { !alive(oldPID) && !alive(currentPID) }
      try await approveConnectedSession(fixture, profileID: .chatGPTOperate)
      let freshPID = try pid(await fixture.identity(client))
      #expect(freshPID != oldPID && freshPID != currentPID)
      let afterApproval = try fixture.calls()
      for (owner, arguments) in [(oldOwner, oldArguments), (currentOwner, currentArguments)] {
        let retired = try await call(
          client, owner: owner, tool: "fixture.finish", arguments: arguments)
        #expect(retired.result.objectValue?["isError"] == .bool(true), "\(retired.result)")
      }
      #expect(try fixture.calls() == afterApproval)
      #expect(!alive(oldPID) && !alive(currentPID))
      let freshArguments = JSONValue.object(["handle": .string("fresh")])
      #expect(
        try pid(await client.call(toolName: "fixture.start", arguments: freshArguments)) == freshPID
      )
      let freshOwner = try await observedResourceOwner(
        client, excluding: [oldOwner, currentOwner])
      #expect(
        try pid(
          await call(
            client, owner: freshOwner, tool: "fixture.finish",
            arguments: try #require(freshArguments.objectValue)))
          == freshPID)
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func connectedPluginInvalidationRetiresNativeWorkAndRejectsFailedCandidates(managed: Bool)
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
        .settings(pluginID: "live-fixture", settings),
        expectedRevision: try await fixture.control.pluginSnapshot().state.revision)
      var configuration = try await fixture.control.activeConfiguration()
      configuration.mcp.servers = []
      _ = try await fixture.control.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try? await fixture.control.configurationDigest())
      #expect(try await !client.listTools().contains { $0.name == "fixture.identity" })
      let changes = GatewayToolChangeBroadcaster()
      let events = changes.stream()
      await observer.onNotification(ToolListChangedNotification.self) { _ in changes.send() }
      snapshot = try await fixture.enableLivePlugin()
      try await fixture.discover(client)
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
        .enabled(pluginID: "live-fixture", false),
        expectedRevision: try await fixture.control.pluginSnapshot().state.revision)
      #expect(try await !client.listTools().contains { $0.name == "fixture.identity" })
      try await wait { !alive(oldPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("old-plugin")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
      snapshot = try await fixture.enableLivePlugin()
      snapshot = try await fixture.installPlugin(version: 2, managed: managed, archives: archives)
      let fresh = try await fixture.identity(client)
      let newPID = try pid(fresh)
      #expect(value(fresh, "version") == .integer(2))
      let requestID = try #require(
        value(fresh, "gateway_execution")?.objectValue?["request_id"]?.stringValue)
      let audit = try #require(try fixture.database.auditEvent(requestID: requestID))
      #expect(audit.mcpRequestID == fresh.requestID)
      #expect(audit.socketConnectionID != nil)
      #expect(oldPID != newPID && !alive(oldPID))
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_2" })
      try await wait { !alive(oldPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("old-plugin")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
      let beforeFailure = try fixture.database.configurationState()
      let directoriesBeforeFailure = try fixture.database.pluginOwnedDirectories()
      await #expect(throws: (any Error).self) {
        try await fixture.installPlugin(version: 3, managed: managed, archives: archives)
      }
      #expect(try fixture.database.configurationState() == beforeFailure)
      #expect(try fixture.database.pluginOwnedDirectories() == directoriesBeforeFailure)
      #expect(try pid(await fixture.identity(client)) == newPID)
      #expect(!alive(oldPID))
      snapshot = try await fixture.service.changePlugins(
        managed
          ? .uninstallArtifact(installationID: oldRecord.id)
          : .removeDevelopment(installationID: oldRecord.id),
        expectedRevision: try await fixture.control.pluginSnapshot().state.revision)
      if !managed { #expect(FileManager.default.fileExists(atPath: oldRecord.source.root.path)) }
      try await wait { !alive(oldPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("old-plugin")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
      _ = try await client.call(
        toolName: "fixture.finish", arguments: .object(["handle": .string("old-plugin")]))
      try await wait { !alive(oldPID) }
      snapshot = try await fixture.service.changePlugins(
        .recover, expectedRevision: try await fixture.control.pluginSnapshot().state.revision)
      // Uncertain retained work keeps its runtime's shared artifact lease until shutdown.
      #expect(FileManager.default.fileExists(atPath: oldRecord.source.root.path))
      try await fixture.discover(client)
      let retainedPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("removed-plugin")])))
      let selected = try #require(snapshot.state.selectedInstallations["live-fixture"])
      snapshot = try await fixture.service.changePlugins(
        managed
          ? .uninstallArtifact(installationID: selected)
          : .removeDevelopment(installationID: selected),
        expectedRevision: try await fixture.control.pluginSnapshot().state.revision)
      let removedCall = try await client.call(toolName: "fixture.identity")
      #expect(removedCall.result.objectValue?["isError"] == .bool(true))
      try await wait { !alive(retainedPID) }
      do {
        let before = try fixture.calls()
        let retired = try await client.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("removed-plugin")]))
        #expect(retired.result.objectValue?["isError"] == .bool(true))
        #expect(try fixture.calls() == before)
      }
      _ = try await client.call(
        toolName: "fixture.finish", arguments: .object(["handle": .string("removed-plugin")]))
      try await wait { !alive(retainedPID) }
      _ = try await fixture.service.changePlugins(
        .recover, expectedRevision: try await fixture.control.pluginSnapshot().state.revision)
      await observer.disconnect()
      await client.disconnect()
      await fixture.service.stop()
      _ = try await fixture.service.changePlugins(
        .recover, expectedRevision: try await fixture.control.pluginSnapshot().state.revision)
      #expect(FileManager.default.fileExists(atPath: oldRecord.source.root.path) == !managed)
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await observer.disconnect()
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: [false, true], ["plugin", "register", "repair", "manifest"])
  func listenerStopJoinsConfigurationPublication(cancel: Bool, change: String) async throws {
    let project = change != "plugin"
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
        _ = try await fixture.service.changeManifest(
          manifest, expectedDigest: try await fixture.control.configurationDigest())
      } else if change == "repair" {
        _ = try await fixture.service.changeProjects(
          .repair(id: "fixture", root: fixture.root, displayName: nil))
      } else if project {
        _ = try await fixture.service.changeProjects(.register(addedRoot, displayName: "Added"))
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
      #expect(try fixture.database.pluginStoreSnapshot().revision == (cancel || project ? 0 : 1))
      #expect(try fixture.database.projects().count == (change == "register" && !cancel ? 2 : 1))
      #expect(try fixture.pids().allSatisfy { !alive($0) })
      await client.disconnect()
      try await fixture.service.start(profile: .chatGPTOperate)
      let reconnected = try await fixture.connect()
      _ = try pid(await fixture.identity(reconnected))
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

  @Test(.timeLimit(.minutes(3)))
  func publicationCapacityIncludesEveryExistingAndPreparedRuntime() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    let profiles = try (0..<65).map { number in
      ProfileGrantConfig(
        id: try #require(GatewayProfileID(rawValue: "client-\(number)")),
        allowedCallers: [.localMCP])
    }
    let configuration = GatewayConfiguration(profiles: profiles, projectDirectory: fixture.root)
    _ = try await fixture.control.activateManifest(
      configuration.exportedTOML(), expectedDigest: try? await fixture.control.configurationDigest()
    )
    try fixture.database.bootstrapPermissionProfiles(
      Set(GatewayProfileID.builtIns + configuration.profiles.map(\.id)).map {
        configuration.profileGrant(for: $0)
      }, declarations: configuration.profiles.map(\.grant))
    try await fixture.service.start(profile: profiles[0].id)
    var clients: [GatewayClientSession] = []
    var checkedMetadata = 0
    defer { #expect(checkedMetadata == profiles.count) }
    var phase = "connect profiles"
    do {
      for profile in profiles {
        phase = "select \(profile.id.rawValue)"
        try await fixture.service.selectProfile(profile.id)
        phase = "connect \(profile.id.rawValue)"
        clients.append(try await fixture.connect())
      }
      phase = "publish at capacity"
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
      for (index, client) in clients.enumerated() {
        phase = "metadata for \(profiles[index].id.rawValue)"
        try #require(
          try await client.call(toolName: "project.list").result.objectValue?["isError"]
            != .bool(true))
        checkedMetadata += 1
        await client.disconnect()
      }
      await fixture.service.stop()
    } catch {
      let connected = await fixture.service.snapshot().connectionCount
      Issue.record(
        "Capacity fixture failed during \(phase); established=\(clients.count), connected=\(connected), error=\(error)"
      )
      for client in clients { await client.disconnect() }
      await fixture.service.stop()
      throw error
    }
  }

  enum PublicationOutcome: Sendable {
    case publish, cancel, profileConflict, staleManifest
  }

  enum PublicationChange: Sendable {
    case plugin, register, repair, manifest
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      (PublicationOutcome.publish, PublicationChange.plugin),
      (.publish, .register),
      (.publish, .repair),
      (.publish, .manifest),
      // Repair first pauses during selected-folder validation, before preparing runtimes.
      (.cancel, .repair),
      (.cancel, .plugin),
      (.profileConflict, .plugin),
      (.profileConflict, .register),
      (.profileConflict, .repair),
      (.profileConflict, .manifest),
      // Plugins and projects use withCurrentConfiguration. Manifest changes commit prepared bytes.
      (.staleManifest, .plugin),
      (.staleManifest, .manifest),
    ])
  func configurationPublicationCoordinatesAdmissionAndIrreversibleAuthorityChanges(
    outcome: PublicationOutcome, change: PublicationChange
  ) async throws {
    let bookmark = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmark)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, shellEnabled: true)
    let future = try #require(GatewayProfileID(rawValue: "future-client"))
    var configuration = try await fixture.control.activeConfiguration()
    let original = try #require(configuration.profiles.first)
    for id in [GatewayProfileID.cloudflareOperate, future] {
      var profile = original
      profile.grant.id = id
      configuration.profiles.append(profile)
      try fixture.database.saveProfile(profile.grant)
    }
    _ = try await fixture.control.activateManifest(
      configuration.exportedTOML(), expectedDigest: try? await fixture.control.configurationDigest()
    )
    configuration.server.name = "published"
    let manifestCandidate = try configuration.exportedTOML()
    let manifestURL = fixture.control.directories.manifest
    let admittedManifest = try Data(contentsOf: manifestURL)
    let unadmittedManifest = Data("schema_version = 999\n".utf8)
    try await fixture.service.start(profile: .chatGPTOperate)
    let first = try await fixture.connect()
    try await fixture.service.selectProfile(.cloudflareOperate)
    let second = try await fixture.connect()
    let liveArguments: [String: JSONValue] = ["handle": .string("live")]
    let started = try await first.call(toolName: "fixture.start", arguments: .object(liveArguments))
    try #require(started.result.objectValue?["isError"] != .bool(true), "\(started.result)")
    let previous = try pid(started)
    let previousOwner = try #require(try await owners(first, kind: "mcpResource").first)
    let secondPID = try pid(await second.call(toolName: "fixture.identity"))
    let before = try fixture.database.configurationState()
    let addedRoot = fixture.root.appendingPathComponent("added")
    try FileManager.default.createDirectory(at: addedRoot, withIntermediateDirectories: true)
    bookmark.arm()
    let mutation = Task {
      switch change {
      case .manifest:
        _ = try await fixture.service.changeManifest(
          manifestCandidate, expectedDigest: try await fixture.control.configurationDigest())
      case .repair:
        _ = try await fixture.service.changeProjects(
          .repair(id: "fixture", root: fixture.root, displayName: nil))
      case .register:
        _ = try await fixture.service.changeProjects(.register(addedRoot, displayName: "Added"))
      case .plugin:
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
      await #expect(throws: PluginHostError.changeInProgress) {
        _ = try await fixture.service.makeHTTPSessions(
          profileID: .cloudflareObserve, trace: .init(transport: "http"))
      }
      try await fixture.service.selectProfile(future)
      connecting = Task { try await fixture.connect(consent: outcome != .staleManifest) }
      let deadline = ContinuousClock.now + .seconds(5)
      while await fixture.service.snapshot().connectionCount < 3, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await fixture.service.snapshot().connectionCount == 3)
      if outcome == .cancel { mutation.cancel() }
      if outcome == .profileConflict {
        var grant = try #require(before.profiles.first { $0.id == .chatGPTOperate })
        grant.permissions.removeEntry(for: .mcpServer("fixture"))
        try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
        let denied = try await first.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("live")]))
        #expect(denied.result.objectValue?["isError"] == .bool(true))
      }
      if outcome == .staleManifest {
        try unadmittedManifest.write(to: manifestURL, options: .atomic)
      }
      bookmark.release()
      switch outcome {
      case .publish:
        try await mutation.value
        #expect(try fixture.database.pluginStoreSnapshot().revision == (change == .plugin ? 1 : 0))
        #expect(try fixture.database.projects().count == (change == .register ? 2 : 1))
      case .staleManifest:
        await #expect(throws: AtomicManifestStoreError.staleDigest) { try await mutation.value }
      case .cancel:
        await #expect(throws: CancellationError.self) { try await mutation.value }
      case .profileConflict:
        if change == .repair {
          await #expect(throws: AppControlPlaneServiceError.gatewayInputsChanged) {
            try await mutation.value
          }
        } else {
          await #expect(throws: GatewayDatabaseError.configurationChanged) {
            try await mutation.value
          }
        }
      }
      if outcome != .publish {
        #expect(try fixture.database.pluginStoreSnapshot() == before.plugins)
        #expect(try fixture.database.projects() == before.projects)
      }
      let third = try await #require(connecting).value
      if outcome == .staleManifest {
        let sessions = await fixture.service.controlSessions().filter { $0.profileID == future }
        try #require(sessions.count == 1)
        #expect(sessions.first?.fullAccessConsent == nil)
        let metadata = try await third.call(toolName: "project.list")
        try #require(metadata.result.objectValue?["isError"] != .bool(true), "\(metadata.result)")
        let invoked = try fixture.invocationPIDs()
        let calls = try fixture.calls()
        let discovered = try await third.call(
          toolName: "mcp.tools.list",
          arguments: .object(["project_id": .string("fixture"), "server": .string("fixture")]))
        #expect(discovered.result.objectValue?["isError"] == .bool(false), "\(discovered.result)")
        #expect(try fixture.invocationPIDs() == invoked)
        let pids = try fixture.pids()
        let marker = fixture.root.appendingPathComponent("unconsented-command")
        let refused = try await third.call(
          toolName: "shell.run",
          arguments: .object([
            "project_id": .string("fixture"), "mode": .string("argv"),
            "executable": .string("/usr/bin/touch"), "argv": .array([.string(marker.path)]),
          ]))
        #expect(refused.result.objectValue?["isError"] == .bool(true), "\(refused.result)")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try fixture.pids() == pids)
        #expect(try fixture.calls() == calls)
        // The provider uses its own approved mode; the client's native commands need its consent.
        let providerCall = try await third.call(
          toolName: "mcp.tools.call",
          arguments: .object([
            "project_id": .string("fixture"), "server": .string("fixture"),
            "tool": .string("identity"), "arguments": .object([:]),
          ]))
        #expect(
          providerCall.result.objectValue?["isError"] == .bool(false), "\(providerCall.result)")
        #expect(try fixture.invocationPIDs().count == invoked.count + 1)
        #expect(
          await fixture.service.controlSessions().first(where: { $0.profileID == future })?
            .fullAccessConsent == nil)
        #expect(try fixture.database.configurationState() == before)
        #expect(try Data(contentsOf: manifestURL) == unadmittedManifest)
        // A new consent waits for the owner to restore admitted manifest bytes.
        try admittedManifest.write(to: manifestURL, options: .atomic)
        try await approveConnectedSession(fixture, profileID: future)
        let admitted = try await third.call(
          toolName: "shell.run",
          arguments: .object([
            "project_id": .string("fixture"), "mode": .string("argv"),
            "executable": .string("/usr/bin/touch"), "argv": .array([.string(marker.path)]),
          ]))
        #expect(admitted.result.objectValue?["isError"] != .bool(true), "\(admitted.result)")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try await fixture.discover(third)
      }
      _ = try pid(
        await third.call(
          toolName: "fixture.identity", arguments: .object(["project_id": .string("fixture")])))
      await third.disconnect()
      connecting = nil
      if outcome == .publish, change == .register || change == .repair {
        try await wait { !alive(previous) && !alive(secondPID) }
        let beforeApproval = try fixture.calls()
        let denied = try await call(
          first, owner: previousOwner, tool: "fixture.inspect", arguments: liveArguments)
        #expect(denied.result.objectValue?["isError"] == .bool(true), "\(denied.result)")
        #expect(try fixture.calls() == beforeApproval)
        try await approveConnectedSession(fixture, profileID: .chatGPTOperate)
        try await approveConnectedSession(fixture, profileID: .cloudflareOperate)
        let freshPID = try pid(await fixture.identity(first))
        #expect(freshPID != previous)
        #expect(try pid(await fixture.identity(second)) != secondPID)
        let afterApproval = try fixture.calls()
        let retired = try await call(
          first, owner: previousOwner, tool: "fixture.finish", arguments: liveArguments)
        #expect(retired.result.objectValue?["isError"] == .bool(true), "\(retired.result)")
        #expect(try fixture.calls() == afterApproval)
        let freshArguments = JSONValue.object([
          "project_id": .string("fixture"), "handle": .string("fresh"),
        ])
        #expect(
          try pid(await first.call(toolName: "fixture.start", arguments: freshArguments))
            == freshPID)
        let freshOwner = try await observedResourceOwner(first, excluding: [previousOwner])
        #expect(
          try pid(
            await call(
              first, owner: freshOwner, tool: "fixture.finish",
              arguments: try #require(freshArguments.objectValue)))
            == freshPID)
        #expect(!alive(previous) && !alive(secondPID))
      } else if outcome == .publish {
        #expect(try pid(await fixture.identity(first)) != previous)
        #expect(try pid(await fixture.identity(second)) != secondPID)
        #expect(
          try pid(
            await first.call(
              toolName: "fixture.inspect", arguments: .object(liveArguments)))
            == previous)
        try await wait { !alive(secondPID) }
      } else {
        #expect(try pid(await second.call(toolName: "fixture.identity")) == secondPID)
        if outcome == .profileConflict {
          try await wait { !alive(previous) }
        } else {
          #expect(alive(previous))
        }
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

  @Test(.timeLimit(.minutes(1)))
  func connectedProviderUpdateRetiresOldWorkAndRegrantDoesNotReviveIt() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    var phase = "start original work"
    do {
      let started = try await client.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("old")]))
      let oldPID = try pid(started)
      phase = "activate provider version 2"
      try await fixture.activate(version: 2)
      phase = "invoke provider version 2"
      let fresh = try await fixture.identity(client)
      let currentPID = try pid(fresh)
      #expect(value(fresh, "version") == .integer(2))
      #expect(currentPID != oldPID)
      try await wait { !alive(oldPID) }
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_2" })
      let inspected = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("old")]))
      #expect(inspected.result.objectValue?["isError"] == .bool(true))

      let finished = try await client.call(
        toolName: "fixture.finish", arguments: .object(["handle": .string("old")]))
      #expect(finished.result.objectValue?["isError"] == .bool(true))
      try await wait { !alive(oldPID) }
      #expect(alive(currentPID))
      phase = "revoke caller permission"
      var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      let permissions = grant.permissions
      grant.permissions.removeEntry(for: .mcpServer("fixture"))
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let denied = try await client.call(toolName: "fixture.identity")
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      try await wait { !alive(currentPID) }
      phase = "regrant caller permission"
      grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.permissions = permissions
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      phase = "renew caller consent"
      try await fixture.consentSessions()
      let resumedPID = try pid(await fixture.identity(client))
      #expect(resumedPID != currentPID)

      var previous = resumedPID
      for version in 3...8 {
        phase = "activate provider version \(version)"
        try await fixture.activate(version: version)
        phase = "invoke provider version \(version)"
        let next = try await fixture.identity(client)
        #expect(value(next, "version") == .integer(Int64(version)))
        let obsolete = previous
        previous = try pid(next)
        #expect(previous != obsolete)
        try await wait { !alive(obsolete) }
      }
      let pids = try fixture.pids()
      #expect(pids.count >= 8)
      #expect(try fixture.invocationPIDs().filter(alive) == [previous])
      #expect(pids.filter(alive).count == 2)
      await client.disconnect()
      await fixture.service.stop()
      #expect(pids.allSatisfy { !alive($0) })
    } catch {
      Issue.record("Provider fixture failed during \(phase): \(error)")
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
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
      try await fixture.publishMetadata(version: 2)
      try await fixture.discover(client)
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

  @Test(.timeLimit(.minutes(1)))
  func providerWithoutWorkReportingIsRetainedUntilExplicitShutdown() async throws {
    let fixture = try GenerationFixture(reportWork: false)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let previous = try pid(await fixture.identity(client))
      try await fixture.publishMetadata(version: 2)
      let current = try pid(await fixture.identity(client))
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
      grant.permissions.removeEntry(for: .mcpServer("fixture"))
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      #expect(try await self.owners(client, kind: "mcpUnreportedWork").isEmpty)
      for owner in owners {
        #expect(
          try await call(client, owner: owner, tool: "fixture.identity")
            .result.objectValue?["isError"] == .bool(true))
      }
      #expect(try fixture.calls() == calls)
      #expect(try fixture.pids() == starts)
      try await wait { !alive(previous) && !alive(current) }
      await client.disconnect()
      #expect(!alive(previous) && !alive(current))
      await fixture.service.stop()
      #expect(!alive(previous) && !alive(current))
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
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
      _ = try await fixture.identity(client)
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

  @Test(.timeLimit(.minutes(1)))
  func selectedConnectionCloseUsesOneTimePermissionAndLeavesCurrentWorkAlive() async throws {
    let fixture = try GenerationFixture(reportWork: false)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
    try grant.permissions.set(.granted(.read), for: .mcpServer("fixture"))
    try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let originalPID = try pid(await fixture.identity(client))
      let owner = try #require(try await owners(client, kind: "mcpUnreportedWork").first)
      try await fixture.publishMetadata(version: 2)
      let currentPID = try pid(await fixture.identity(client))
      let arguments: [String: JSONValue] = ["server": .string("fixture")]
      let unbound = try await client.call(
        toolName: "mcp.connections.close", arguments: .object(arguments))
      #expect(String(describing: unbound.result).contains("mcp.connection_owner_required"))
      let pending = try await call(
        client, owner: owner, tool: "mcp.connections.close", arguments: arguments)
      let requests = try permissionRequestIDs(pending)
      #expect(alive(originalPID) && alive(currentPID))
      let unanswered = try await call(
        client, owner: owner, tool: "mcp.connections.close", arguments: arguments,
        retryIDs: requests)
      #expect(unanswered.result.objectValue?["isError"] == .bool(true))
      #expect(alive(originalPID) && alive(currentPID))
      try fixture.answer(requests, .onlyThisTime)
      let closed = try await call(
        client, owner: owner, tool: "mcp.connections.close", arguments: arguments,
        retryIDs: requests)
      let result = try #require(value(closed, "result")?.objectValue)
      #expect(result["transport_closed"] == .bool(true))
      #expect(result["managed_process_exit_confirmed"] == .bool(true))
      #expect(result["work_cleanup"] == .string("confirmed"))
      #expect(result["remaining_owners"] == .integer(0))
      #expect(!alive(originalPID) && alive(currentPID))
      let repeated = try await call(
        client, owner: owner, tool: "mcp.connections.close", arguments: arguments,
        retryIDs: requests)
      #expect(repeated.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.invocationPIDs() == [originalPID, currentPID])
      #expect(try await owners(client, kind: "mcpUnreportedWork").count == 1)
      let currentOwner = try #require(try await owners(client, kind: "mcpUnreportedWork").first)
      let currentPending = try await call(
        client, owner: currentOwner, tool: "mcp.connections.close", arguments: arguments)
      let currentRequests = try permissionRequestIDs(currentPending)
      try fixture.answer(currentRequests, .onlyThisTime)
      async let firstClose = call(
        client, owner: currentOwner, tool: "mcp.connections.close", arguments: arguments,
        retryIDs: currentRequests)
      async let secondClose = call(
        client, owner: currentOwner, tool: "mcp.connections.close", arguments: arguments,
        retryIDs: currentRequests)
      let results = try await [firstClose, secondClose]
      #expect(results.filter { $0.result.objectValue?["isError"] != .bool(true) }.count == 1)
      #expect(!alive(currentPID))
      #expect(try fixture.invocationPIDs() == [originalPID, currentPID])
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
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
      #expect(try fixture.invocationPIDs() == [originalPID])
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func physicalRootReplacementDeniesOldOwnerUntilRepairRetiresIt() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    let root = fixture.root.appendingPathComponent("project")
    let moved = fixture.root.appendingPathComponent("original")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var project = try #require(try fixture.database.project(id: "fixture"))
    project.rootPath = root.path
    try fixture.database.saveProject(project)
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

      _ = try await fixture.service.changeProjects(
        .repair(id: "fixture", root: root, displayName: nil))
      try await wait { !alive(originalPID) }
      try await fixture.activate(version: 2)
      let currentPID = try pid(await fixture.identity(client))
      #expect(currentPID != originalPID)
      #expect(!alive(originalPID))
      #expect(await fixture.service.snapshot().startedAt == startedAt)
      let stillDenied = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: arguments)
      #expect(stillDenied.result.objectValue?["isError"] == .bool(true))

      try FileManager.default.removeItem(at: root)
      try FileManager.default.moveItem(at: moved, to: root)
      let beforeRestoreCall = try fixture.calls()
      let restored = try await call(
        client, owner: owner, tool: "fixture.finish", arguments: arguments)
      #expect(restored.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == beforeRestoreCall)
      #expect(!alive(originalPID))
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["remove", "rebind", "reregister"])
  func metadataRenamePreservesWorkAndProjectAuthorityChangesRetireIt(change: String) async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let original = try #require(try fixture.database.project(id: "fixture"))
      let arguments: [String: JSONValue] = ["handle": .string("original")]
      let originalPID = try pid(
        await client.call(toolName: "fixture.start", arguments: .object(arguments)))
      let owner = try await observedResourceOwner(client)
      var renamed = original
      renamed.displayName = "Renamed"
      try fixture.database.saveProject(renamed)
      #expect(
        try pid(await client.call(toolName: "fixture.inspect", arguments: .object(arguments)))
          == originalPID)
      #expect(
        try pid(await call(client, owner: owner, tool: "fixture.inspect", arguments: arguments))
          == originalPID)
      switch change {
      case "remove": try fixture.database.deleteProject(id: original.id)
      case "rebind":
        let other = fixture.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var rebound = original
        rebound.rootPath = other.path
        try fixture.database.saveProject(rebound)
      default:
        try fixture.database.deleteProject(id: original.id)
        var replacement = original
        replacement.createdAt = original.createdAt.addingTimeInterval(1)
        try fixture.database.saveProject(replacement)
      }
      let before = try fixture.calls()
      let ordinary = try await client.call(
        toolName: "fixture.inspect", arguments: .object(arguments))
      let selected = try await call(
        client, owner: owner, tool: "fixture.inspect", arguments: arguments)
      let listed = try await client.call(
        toolName: "runtime.owners.list",
        arguments: .object(["project_id": .string("fixture")]))
      #expect(ordinary.result.objectValue?["isError"] == .bool(true), "\(ordinary.result)")
      #expect(selected.result.objectValue?["isError"] == .bool(true), "\(selected.result)")
      #expect(
        listed.result.objectValue?["isError"] == .bool(true)
          || value(listed, "result")?.objectValue?["owners"] == .array([]),
        "Scope mutation: \(change)")
      #expect(try fixture.calls() == before)
      try await wait { !alive(originalPID) }
      #expect(try fixture.invocationPIDs() == [originalPID])

      try fixture.database.saveProject(original)
      let restored = try await call(
        client, owner: owner, tool: "fixture.finish", arguments: arguments)
      #expect(restored.result.objectValue?["isError"] == .bool(true), "\(restored.result)")
      #expect(try fixture.calls() == before)
      #expect(!alive(originalPID))
      try await approveConnectedSession(fixture, profileID: .chatGPTOperate)
      let freshPID = try pid(await fixture.identity(client))
      #expect(freshPID != originalPID)
      let freshArguments: [String: JSONValue] = ["handle": .string("fresh")]
      #expect(
        try pid(await client.call(toolName: "fixture.start", arguments: .object(freshArguments)))
          == freshPID)
      let freshOwner = try await observedResourceOwner(client, excluding: [owner])
      let freshCalls = try fixture.calls()
      let stillRetired = try await call(
        client, owner: owner, tool: "fixture.finish", arguments: arguments)
      #expect(stillRetired.result.objectValue?["isError"] == .bool(true), "\(stillRetired.result)")
      #expect(try fixture.calls() == freshCalls)
      #expect(!alive(originalPID) && alive(freshPID))
      #expect(
        try pid(
          await call(
            client, owner: freshOwner, tool: "fixture.finish", arguments: freshArguments))
          == freshPID)
      #expect(try fixture.invocationPIDs() == [originalPID, freshPID])
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
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
      let originalPID = try #require(try fixture.invocationPIDs().first)
      let owner = try #require(try await owners(client, kind: "mcpRequest").first)
      try await fixture.publishMetadata(version: 2)
      let currentPID = try pid(await fixture.identity(client))
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
      #expect(try fixture.calls() == "1:wait\n1:identity\n")
      #expect(try fixture.invocationPIDs() == [originalPID, currentPID])
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
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
      foreign["project_id"] = .string("another")
      for invalid in [old, .object(forged), .object(foreign)] {
        let rejected = try await call(
          client, owner: invalid, tool: "fixture.inspect", arguments: arguments)
        #expect(rejected.result.objectValue?["isError"] == .bool(true))
      }
      #expect(try fixture.calls() == calls)
      #expect(
        try pid(await call(client, owner: fresh, tool: "fixture.inspect", arguments: arguments))
          == originalPID)
      #expect(try fixture.invocationPIDs() == [originalPID])
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

  @Test(.timeLimit(.minutes(1)))
  func oneTimePermissionBindsExactResourceOwnerWithinOneProvider() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    let sourceProbe = fixture.root.appendingPathComponent("retry-source-probe")
    try Data("original".utf8).write(to: sourceProbe)
    try await fixture.activate(version: 1, destructiveFinish: true)
    var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
    try grant.permissions.set(.granted(.read), for: .mcpServer("fixture"))
    try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let originalPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("one")])))
      let first = try await observedResourceOwner(client)
      #expect(
        try pid(
          await client.call(
            toolName: "fixture.start", arguments: .object(["handle": .string("two")])))
          == originalPID)
      let second = try await observedResourceOwner(client, excluding: [first])
      #expect(try await owners(client, kind: "mcpResource").count == 2)
      let firstPending = try await call(client, owner: first, tool: "fixture.change")
      let firstRequests = try permissionRequestIDs(firstPending)
      let secondPending = try await call(client, owner: second, tool: "fixture.change")
      let secondRequests = try permissionRequestIDs(secondPending)
      #expect(Set(firstRequests).isDisjoint(with: secondRequests))
      let view = try fixture.permissionView()
      let provider = try #require(view.providers.first { $0.identity == .localServer("fixture") })
      #expect(provider.fullAccessConsent != nil)
      let firstRequest = try #require(view.requests.first { firstRequests.contains($0.request.id) })
      let secondRequest = try #require(
        view.requests.first { secondRequests.contains($0.request.id) })
      #expect(
        firstRequest.request.invocation.argumentsDigest
          != secondRequest.request.invocation.argumentsDigest)
      let before = try fixture.calls()
      let unanswered = try await call(
        client, owner: first, tool: "fixture.change", retryIDs: firstRequests)
      #expect(unanswered.result.objectValue?["isError"] == .bool(true))
      #expect(
        value(unanswered, "error")?.objectValue?["code"]
          == .string("permission.invalid_authorization"))
      #expect(try fixture.calls() == before)
      try fixture.answer(firstRequests, .onlyThisTime)
      let wrongOwner = try await call(
        client, owner: second, tool: "fixture.change", retryIDs: firstRequests)
      #expect(wrongOwner.result.objectValue?["isError"] == .bool(true))
      #expect(
        value(wrongOwner, "error")?.objectValue?["code"] == .string("permission.retry_mismatch"))
      #expect(try fixture.calls() == before)
      let retried = try await call(
        client, owner: first, tool: "fixture.change", retryIDs: firstRequests)
      #expect(retried.result.objectValue?["isError"] != .bool(true), "\(retried.result)")
      #expect(value(retried, "arguments") == .object([:]))
      #expect(try pid(retried) == originalPID)
      #expect(value(retried, "source_write_blocked") == .bool(false))
      #expect(try Data(contentsOf: sourceProbe) == Data("changed".utf8))
      #expect(try fixture.calls() == before + "1:change\n")
      let replayed = try await call(
        client, owner: first, tool: "fixture.change", retryIDs: firstRequests)
      #expect(replayed.result.objectValue?["isError"] == .bool(true))
      #expect(
        value(replayed, "error")?.objectValue?["code"] == .string("permission.retry_consumed"))
      let sibling = try await call(
        client, owner: second, tool: "fixture.change", retryIDs: secondRequests)
      #expect(
        value(sibling, "error")?.objectValue?["code"] == .string("permission.invalid_authorization")
      )
      let fresh = try await client.call(toolName: "fixture.change", arguments: .object([:]))
      #expect(Set(try permissionRequestIDs(fresh)).isDisjoint(with: firstRequests + secondRequests))
      #expect(try fixture.calls() == before + "1:change\n")
      #expect(try fixture.invocationPIDs() == [originalPID])
      let saved = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      #expect(saved.permissions.state(for: .mcpServer("fixture")) == .granted(.read))
      #expect(saved.fullAccess)
      let providerAfter = try #require(
        try fixture.permissionView().providers.first { $0.identity == .localServer("fixture") })
      #expect(providerAfter.fullAccessConsent == provider.fullAccessConsent)
      let acquired = try await observedResourceOwner(client, excluding: [first, second])
      let foreignHandle = try await call(
        client, owner: acquired, tool: "fixture.inspect", arguments: ["handle": .string("one")])
      #expect(foreignHandle.result.objectValue?["isError"] == .bool(true))
      #expect(try fixture.calls() == before + "1:change\n")
      let retained = try await call(
        client, owner: acquired, tool: "fixture.inspect",
        arguments: ["handle": .string("acquired-on-retry")])
      #expect(try pid(retained) == originalPID)
      #expect(try fixture.calls() == before + "1:change\n1:inspect\n")
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func selectedRetryDoesNotGiveSandboxAWritableSourceProject() async throws {
    let fixture = try GenerationFixture(localProviderFullAccess: false)
    defer { fixture.removeFiles() }
    let sourceProbe = fixture.root.appendingPathComponent("retry-source-probe")
    try Data("original".utf8).write(to: sourceProbe)
    try await fixture.activate(version: 1, destructiveFinish: true)
    var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
    grant.fullAccess = false
    try grant.permissions.set(.granted(.read), for: .mcpServer("fixture"))
    try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect(consent: false)
    do {
      try await fixture.discover(client)
      let originalPID = try pid(
        await client.call(
          toolName: "fixture.start", arguments: .object(["handle": .string("one")])))
      let owner = try await observedResourceOwner(client)
      let pending = try await call(client, owner: owner, tool: "fixture.change")
      let requests = try permissionRequestIDs(pending)
      let before = try fixture.calls()
      try fixture.answer(requests, .onlyThisTime)
      let rejected = try await call(
        client, owner: owner, tool: "fixture.change", retryIDs: requests)
      let error = try #require(value(rejected, "error")?.objectValue)
      #expect(error["code"] == .string("execution.unavailable"))
      #expect(
        error["message"]
          == .string("Execution requires a verified worktree and private Git context"))
      #expect(try fixture.calls() == before)
      let inspected = try await call(
        client, owner: owner, tool: "fixture.inspect",
        arguments: ["handle": .string("one"), "probe_source_write": .bool(true)])
      #expect(try pid(inspected) == originalPID)
      #expect(value(inspected, "source_write_blocked") == .bool(true))
      #expect(try Data(contentsOf: sourceProbe) == Data("original".utf8))
      let provider = try #require(
        try fixture.permissionView().providers.first { $0.identity == .localServer("fixture") })
      #expect(provider.fullAccessConsent == nil)
      let session = try #require(await fixture.service.controlSessions().first)
      #expect(session.fullAccessConsent == nil)
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  private func permissionRequestIDs(_ report: GatewayCallReport) throws -> [UUID] {
    let error = try #require(value(report, "error")?.objectValue)
    try #require(error["code"] == .string("permission.required"), "\(report.result)")
    let values = try #require(error["request_ids"]?.arrayValue)
    let ids = try values.map { try #require($0.stringValue.flatMap(UUID.init(uuidString:))) }
    try #require(!ids.isEmpty)
    return ids
  }

  private func call(
    _ client: GatewayClientSession, owner: JSONValue, tool: String,
    arguments: [String: JSONValue] = [:], retryIDs: [UUID] = [], projectID: String = "fixture"
  ) async throws -> GatewayCallReport {
    var envelope: [String: JSONValue] = [
      "project_id": .string(projectID), "owner": owner, "tool": .string(tool),
      "arguments": .object(arguments),
    ]
    if !retryIDs.isEmpty {
      envelope["_permission_request_ids"] = .array(retryIDs.map { .string($0.uuidString) })
    }
    return try await client.call(toolName: "runtime.owners.call", arguments: .object(envelope))
  }

  private func owners(
    _ client: GatewayClientSession, kind: String, pageSize: Int = 50, projectID: String = "fixture"
  )
    async throws -> [JSONValue]
  {
    var result: [JSONValue] = []
    var after: JSONValue?
    var seen = Set<String>()
    repeat {
      var arguments: [String: JSONValue] = [
        "project_id": .string(projectID), "limit": .integer(Int64(pageSize)),
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

  private func observedResourceOwner(
    _ client: GatewayClientSession, projectID: String = "fixture", excluding: [JSONValue] = []
  ) async throws -> JSONValue {
    let deadline = ContinuousClock.now + .seconds(5)
    repeat {
      let candidates = try await owners(client, kind: "mcpResource", projectID: projectID).filter {
        !excluding.contains($0)
      }
      if !candidates.isEmpty {
        try #require(candidates.count == 1, "Expected one freshly observed resource owner.")
        let owner = try #require(candidates.first)
        #expect(owner.objectValue?["project_id"] == .string(projectID))
        return owner
      }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    throw GatewayToolError.executionFailed("A fresh resource owner was not observed.")
  }

  @Test(.timeLimit(.minutes(1)))
  func shellContinuationSurvivesReplacementAndListenerStopJoinsItsProcesses() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, shellEnabled: true)
    let skillRoot = fixture.root.appendingPathComponent("published-skills")
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    _ = try await fixture.control.activateManifest(
      fixture.externalManifest(version: 1, skillRoot: skillRoot),
      expectedDigest: try await fixture.control.configurationDigest())
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
      let previousProvider = try pid(await fixture.identity(client))
      _ = try await fixture.service.changeManifest(
        fixture.externalManifest(version: 2, skillRoot: skillRoot),
        expectedDigest: try await fixture.control.configurationDigest())
      #expect(value(try await fixture.identity(client), "version") == .integer(2))
      #expect(alive(first.pid))
      try await wait { !alive(previousProvider) }
      let permissions = try fixture.database.permissionRuntime(platform: fixture.platform)
      let published = try #require(try await permissions.store.read().environment.paths)
      #expect(
        published.pathRules.contains {
          $0.kind == .skillLibrary && $0.root.string == skillRoot.path
        })
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
      #expect(try await permissions.store.read().environment.paths == published)
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

  @Test(.timeLimit(.minutes(1)), arguments: ["profile", "project", "connection"])
  func retainedShellContinuationRechecksAuthorityAfterPublication(restriction: String) async throws
  {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1, shellEnabled: true)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    var child: Int32?
    defer { if let child, alive(child) { _ = kill(-child, SIGKILL) } }
    var phase = "start original work"
    do {
      let started = try await client.call(
        toolName: "shell.spawn",
        arguments: .object(["mode": .string("argv"), "executable": .string("/bin/cat")]))
      let sessionID = try #require(value(started, "result")?.objectValue?["session_id"])
      let before = try await client.call(
        toolName: "shell.read", arguments: .object(["session_id": sessionID]))
      let pid = try #require(value(before, "result")?.objectValue?["process_id"]?.int64Value)
      try #require((1...Int64(Int32.max)).contains(pid))
      child = Int32(pid)
      let owner = try #require(try await owners(client, kind: "shell").first)
      phase = "activate provider version 2"
      try await fixture.activate(version: 2, shellEnabled: true)
      phase = "invoke provider version 2"
      #expect(value(try await fixture.identity(client), "version") == .integer(2))
      let permissions = try fixture.database.permissionRuntime(platform: fixture.platform)
      phase = "apply \(restriction) restriction"
      switch restriction {
      case "profile":
        phase = "revoke caller permission"
        var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
        try grant.permissions.set(.denied, for: .project("fixture"))
        try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      case "project":
        let changed = fixture.root.appendingPathComponent("rebound")
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        var project = try #require(try fixture.database.project(id: "fixture"))
        project.rootPath = changed.path
        try fixture.database.saveProject(project)
      default:
        let session = try #require(await fixture.service.controlSessions().first)
        _ = try await fixture.service.limitControlSession(
          id: session.id,
          to: .init(permissionCeilings: fixturePermissions([.project("fixture"): .denied])),
          expectedRevision: session.revision)
      }
      let current = try #require(try await permissions.store.read().environment.paths)
      let processes = try fixture.pids()
      for tool in ["shell.read", "shell.write", "shell.cancel"] {
        var arguments: [String: JSONValue] = ["session_id": sessionID]
        if tool == "shell.write" { arguments["text"] = .string("forbidden") }
        let refused = try await call(client, owner: owner, tool: tool, arguments: arguments)
        #expect(
          refused.result.objectValue?["isError"] == .bool(true),
          "Restriction: \(restriction), tool: \(tool)")
      }
      #expect(try await permissions.store.read().environment.paths == current)
      #expect(try fixture.pids() == processes)
      try await wait { !alive(try #require(child)) }
      await client.disconnect()
      await fixture.service.stop()
      #expect(try fixture.pids().allSatisfy { !alive($0) })
    } catch {
      Issue.record("Provider fixture failed during \(phase): \(error)")
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  private func approveConnectedSession(
    _ fixture: GenerationFixture, profileID: GatewayProfileID
  ) async throws {
    let matching = await fixture.service.controlSessions().filter { $0.profileID == profileID }
    try #require(matching.count == 1)
    let session = try #require(matching.first)
    let trust = try fixture.database.clientTrust(
      principalID: session.principalID, profileID: profileID, caller: session.caller)
    let approved = try await fixture.service.approveControlSession(
      id: session.id, lifetime: .alwaysAllowClient, expectedRevision: session.revision,
      expectedTrustRevision: trust?.revision ?? 0)
    try #require(approved.fullAccessConsent?.lifetime == .alwaysAllowClient)
  }

  private func pid(_ report: GatewayCallReport) throws -> Int32 {
    let value = try #require(value(report, "pid")?.int64Value, "\(report.result)")
    return try #require(Int32(exactly: value), "\(report.result)")
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

private final class GatedBookmarkService: ProjectBookmarkServicing, @unchecked Sendable {
  private let condition = NSCondition()
  private var armed = false
  private var _entered = false
  private var _returned = false
  private var released = false
  private let base = ProjectBookmarkService()

  var entered: Bool { condition.withLock { _entered } }
  var returned: Bool { condition.withLock { _returned } }
  func arm() { condition.withLock { armed = true } }
  func release() {
    condition.withLock {
      released = true
      condition.broadcast()
    }
  }

  func registerFolder(at url: URL, displayName: String?) throws -> ComputerMCPCore.RegisteredProject
  {
    try base.registerFolder(at: url, displayName: displayName)
  }

  func resolve(_ project: ComputerMCPCore.RegisteredProject) throws -> ResolvedProjectAccess {
    condition.lock()
    if armed && !_entered {
      _entered = true
      condition.broadcast()
      while !released { condition.wait() }
      _returned = true
    }
    condition.unlock()
    return try base.resolve(project)
  }
}

private struct GenerationFixture: Sendable {
  let root: URL
  let database: GatewayDatabase
  let control: AppControlPlaneService
  let service: AppGatewayService
  let reportWork: Bool
  let platform: PlatformServices
  private let localProviderFullAccess: Bool

  func publishMetadata(version: Int) async throws {
    var configuration = try await control.activeConfiguration()
    configuration.server.name = "catalog-\(version)"
    _ = try await control.activateManifest(
      configuration.exportedTOML(), expectedDigest: try await control.configurationDigest())
  }

  func externalManifest(version: Int, skillRoot: URL? = nil) async throws -> String {
    var configuration = try await control.activeConfiguration()
    if let skillRoot {
      configuration.skills.roots = [.init(id: "published-skills", path: skillRoot.path)]
    }
    configuration.server.name = "version-\(version)"
    configuration.mcp.servers[0].args[2] = String(version)
    configuration.mcp.servers[0].toolRisks["generation_\(version)"] = .readOnly
    return try configuration.exportedTOML()
  }

  func writeManifest(_ text: String, atomic: Bool) throws {
    let file = control.directories.manifest
    if atomic {
      try Data(text.utf8).write(to: file, options: .atomic)
    } else {
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: Data(text.utf8))
      try handle.synchronize()
    }
  }

  /// Seeds legacy duplicate metadata for owner recovery without publishing path authority.
  func importHistoricalDuplicate(_ project: ComputerMCPCore.RegisteredProject) throws {
    try database.connection.writer.write { try ProjectRecord(project).insert($0) }
  }

  init(
    reportWork: Bool = true,
    bookmarkService: any ProjectBookmarkServicing = ProjectBookmarkService(),
    executionLauncher: ExecutionLauncher? = nil, localProviderFullAccess: Bool = true
  ) throws {
    self.reportWork = reportWork
    self.localProviderFullAccess = localProviderFullAccess
    root = URL(fileURLWithPath: "/private/tmp/cm-gen-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathExtension("host"),
      logs: root.appendingPathExtension("host").appendingPathComponent("logs"))
    try directories.prepare()
    database = try fixturePermissionDatabase(path: directories.database.path)
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let launcher = executionLauncher ?? testExecutionLauncher()
    let native = MacOSPlatform.services(launcher: launcher)
    platform = PlatformServices(
      launcher: launcher, projectGrants: bookmarkService,
      pluginDirectories: native.pluginDirectories, applications: native.applications,
      toolProviders: native.toolProviders, managementToolNames: native.managementToolNames,
      executableSearchDirectories: native.executableSearchDirectories,
      gitExecutable: native.gitExecutable, fileChanges: native.fileChanges,
      permissionPolicyReader: TestManagedPolicyReader(), executionProxy: native.executionProxy)
    try database.bootstrapPermissionProfiles([])
    let permissions = try database.permissionRuntime(platform: platform)
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin,
        trustedPrincipalID: "generation-fixture-owner"), validate: {})
    let permissionControl = PermissionControlService(service: permissions.service, owner: { owner })
    control = AppControlPlaneService(
      directories: directories, database: database, permissionControl: permissionControl,
      manifestStore: try AtomicManifestStore(
        manifestURL: directories.manifest, database: database,
        loader: GatewayManifestConfigurationLoader(
          database: database,
          applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications)),
      defaultManifest: DefaultGatewayConfiguration.manifest,
      secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: testExecutionLauncher(),
        secretStore: secrets,
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()
      ),
      gatewayExecutablePath: try nativeGatewayTestExecutable().path,
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(),
      platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
    try database.saveProject(.init(id: "fixture", displayName: "Fixture", rootPath: root.path))
    try writePythonTestExecutable(Self.provider, to: root.appendingPathExtension("py"))
  }

  func activate(
    version: Int, shellEnabled: Bool = false, destructiveFinish: Bool = false,
    callers: [GatewayCallerKind] = [.localMCP]
  ) async throws {
    let names = [
      "start", "inspect", "finish", "identity", "change", "wait", "generation_\(version)",
    ]
    let existing = try database.profiles().first { $0.id == .chatGPTOperate }
    let profile = ProfileGrantConfig(
      grant: existing
        ?? ProfileGrant(
          id: .chatGPTOperate,
          permissions: fixturePermissions([
            .project("fixture"): .granted(.write),
            .mcpServer("fixture"): .granted(.all),
            .plugin("live-fixture"): .granted(.use),
          ]),
          fullAccess: true, allowedCallers: Set(callers)))
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
      policy: .init(shellEnabled: shellEnabled), profiles: [profile],
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: try providerInterpreter(),
          args: [
            root.appendingPathExtension("py").path, root.path, String(version),
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
      ]), projectDirectory: root)
    if existing == nil { try database.saveProfile(profile.grant) }
    if FileManager.default.fileExists(atPath: control.directories.manifest.path) {
      _ = try await service.changeManifest(
        configuration.exportedTOML(), expectedDigest: try await control.configurationDigest())
    } else {
      _ = try await control.activateManifest(configuration.exportedTOML())
    }
    try database.bootstrapPermissionProfiles(
      Set(GatewayProfileID.builtIns + configuration.profiles.map(\.id)).map {
        configuration.profileGrant(for: $0)
      }, declarations: configuration.profiles.map(\.grant))
    try await approveProviders()
  }

  func installPlugin(version: Int, managed: Bool, archives: ArchiveFixture) async throws
    -> PluginHostSnapshot
  {
    let manifest = """
      id = 'live-fixture'
      name = 'Live Fixture'
      version = '\(version).0.0'
      plugin_api = \(version == 3 ? 999 : 1)
      [sandbox]
      full_access = true
      purpose = 'Run the fixture native provider'
      [[permissions]]
      id = 'project'
      access = 'write'
      purpose = 'Operate the fixture project'
      [compatibility]
      minimum_host = '0.1.0'
      architectures = ['arm64', 'x86_64']
      [[mcp]]
      id = 'native'
      transport = 'stdio'
      executable = { path = 'provider' }
      """
    let provider = try pluginProvider(version: version)
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
      _ = try await service.changePlugins(
        .installArchive(
          archive: archive, sha256: digest, pluginID: "live-fixture",
          version: PluginVersion("\(version).0.0")),
        expectedRevision: revision)
      try await approveProviders()
      return try await control.pluginSnapshot()
    }
    let package = root.appendingPathComponent("plugin-\(version)")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try manifest.write(
      to: package.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8
    )
    let executable = package.appendingPathComponent("provider")
    try provider.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    _ = try await service.changePlugins(
      .registerDevelopment(package), expectedRevision: revision)
    try await approveProviders()
    return try await control.pluginSnapshot()
  }

  func connect(consent: Bool = true) async throws -> GatewayClientSession {
    let previous = Set(await service.controlSessions().map(\.id))
    let client = try await GatewayClientSession.connectSocket(
      socketURL: service.socketConfiguration.socketURL)
    do {
      if consent {
        for session in await service.controlSessions() where !previous.contains(session.id) {
          if session.profile?.grant.fullAccess == true {
            _ = try await self.consent(session)
            try await discover(client)
          }
        }
      }
      return client
    } catch {
      await client.disconnect()
      throw error
    }
  }

  @discardableResult
  func consent(
    _ session: GatewayControlSessionSnapshot,
    lifetime: GatewayFullAccessLifetime = .alwaysAllowClient
  ) async throws -> GatewayControlSessionSnapshot {
    try await approveProviders()
    if session.fullAccessConsent != nil { return session }
    let trust = try database.clientTrust(
      principalID: session.principalID, profileID: session.profileID, caller: session.caller)
    return try await service.approveControlSession(
      id: session.id, lifetime: lifetime, expectedRevision: session.revision,
      expectedTrustRevision: trust?.revision ?? 0)
  }

  func consentSessions() async throws {
    for session in await service.controlSessions() where session.profile?.grant.fullAccess == true {
      _ = try await consent(session)
    }
  }

  func discover(_ client: GatewayClientSession, projectID: String = "fixture") async throws {
    let projects = try await client.call(toolName: "project.list")
    try #require(projects.result.objectValue?["isError"] != .bool(true), "\(projects.result)")
    try await approveProviders()
    let discovered = try await client.call(
      toolName: "mcp.tools.list",
      arguments: .object(["project_id": .string(projectID), "server": .string("fixture")]))
    try #require(discovered.result.objectValue?["isError"] != .bool(true), "\(discovered.result)")
    _ = try await client.listTools()
  }

  func identity(_ client: GatewayClientSession) async throws -> GatewayCallReport {
    try await discover(client)
    return try await client.call(
      toolName: "fixture.identity", arguments: .object(["project_id": .string("fixture")]))
  }

  func permissionView() throws -> GatewayPermissionView {
    try database.permissionRuntime(platform: platform).service.view(owner: permissionOwner())
  }

  func answer(_ ids: [UUID], _ answer: PermissionAnswer) throws {
    let service = try database.permissionRuntime(platform: platform).service
    let owner = try permissionOwner()
    for id in ids {
      _ = try service.answerRequest(
        id, answer: answer, owner: owner, expectedRevision: service.view(owner: owner).revision)
    }
  }

  private func permissionOwner() throws -> GatewayPermissionOwner {
    try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin,
        trustedPrincipalID: "verified-generation-owner"), validate: {})
  }

  func enableLivePlugin() async throws -> PluginHostSnapshot {
    let change = PluginHostChange.enabled(pluginID: "live-fixture", true)
    let revision = try database.pluginStoreSnapshot().revision
    let review = try #require(
      try await control.reviewPluginEnablement(change, expectedRevision: revision))
    return try await service.changePlugins(
      change, expectedRevision: revision,
      approval: .init(
        review: review, selection: .init(permissions: try providerProjectGrants(), fullAccess: true)
      ))
  }

  private func providerProjectGrants() throws -> Permissions {
    fixturePermissions(
      Dictionary(
        uniqueKeysWithValues:
          try database.projects().filter { try database.derivedSourceID(for: $0.id) == nil }
          .map { (Permission.project($0.id), PermissionState.granted(.write)) }))
  }

  func approveProviders() async throws {
    let configuration = try await control.activeConfiguration()
    let runtime = try database.permissionRuntime(platform: platform)
    let grants = try providerProjectGrants()
    for server in configuration.mcp.servers where server.transport == .stdio {
      try fixtureApproveLocalProvider(
        server, database: database, runtime: runtime, permissions: grants,
        fullAccess: localProviderFullAccess)
    }
    let snapshot = try database.pluginStoreSnapshot()
    if let id = snapshot.selectedInstallations["live-fixture"],
      let installation = snapshot.installations.first(where: { $0.id == id })
    {
      let package = try PluginPackage.load(at: installation.source.root)
      let owner = try permissionOwner()
      let view = try runtime.service.view(owner: owner)
      let previous = view.providers.first { $0.identity == .package("live-fixture") }
      let current = try runtime.store.readWithDatabase { _, ledger in
        previous?.fullAccessConsent.map {
          ledger.isConsentValid($0, for: .plugin(.package("live-fixture")))
        } ?? false
      }
      if previous?.enabled != true || previous?.sourceDigest != installation.manifestDigest
        || !current
      {
        try fixtureApprovePlugin(
          package, database: database, runtime: runtime, permissions: grants, fullAccess: true)
      }
    }
  }

  private func providerHomes() throws -> [URL] {
    try [PluginIdentity.localServer("fixture"), .package("live-fixture")].map {
      URL(fileURLWithPath: try database.prepareProviderContainer($0).sandbox.home.value)
    }
  }

  func pids() throws -> [Int32] {
    try providerHomes().flatMap { home -> [Int32] in
      let path = home.appendingPathComponent("pids")
      guard FileManager.default.fileExists(atPath: path.path) else { return [] }
      return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap {
        Int32($0)
      }
    }
  }

  func invocationPIDs() throws -> [Int32] {
    try providerHomes().flatMap { home -> [Int32] in
      let path = home.appendingPathComponent("invocation-pids")
      guard FileManager.default.fileExists(atPath: path.path) else { return [] }
      return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap {
        Int32($0)
      }
    }
  }

  func calls() throws -> String {
    try providerHomes().map { home in
      let path = home.appendingPathComponent("calls")
      return FileManager.default.fileExists(atPath: path.path)
        ? try String(contentsOf: path, encoding: .utf8) : ""
    }.joined()
  }

  func removeFiles() {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: root.appendingPathExtension("py"))
    try? FileManager.default.removeItem(at: root.appendingPathExtension("host"))
  }

  private func providerInterpreter() throws -> String {
    let script = try String(contentsOf: root.appendingPathExtension("py"), encoding: .utf8)
    return String(try #require(script.split(separator: "\n").first).dropFirst(2))
  }

  private func pluginProvider(version: Int) throws -> String {
    "#!\(try providerInterpreter())\n"
      + Self.provider.replacingOccurrences(of: "int(sys.argv[2])", with: String(version))
  }

  private static let provider = #"""
    import json, os, sys, time, uuid
    from pathlib import Path
    root, version, reporting = Path(os.environ["HOME"]), int(sys.argv[2]), sys.argv[3] == "yes"
    with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\n")
    uri, instance, revision, resources = "computer-mcp://runtime/work/v1", str(uuid.uuid4()), 0, []
    invoked = False
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
            if not invoked:
                with (root / "invocation-pids").open("a") as f: f.write(str(os.getpid()) + "\n")
                invoked = True
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
                while not (Path(sys.argv[1]) / "release").exists(): time.sleep(0.01)
            result = {"content": [], "structuredContent": {"pid": os.getpid(), "version": version, "arguments": arguments}}
            if name == "change" or (name == "inspect" and arguments.get("probe_source_write")):
                probe = Path(sys.argv[1]) / "retry-source-probe"
                if probe.is_file():
                    try:
                        probe.write_text("changed")
                        result["structuredContent"]["source_write_blocked"] = False
                    except PermissionError:
                        result["structuredContent"]["source_write_blocked"] = True
                    if name == "change":
                        acquisition = params["_meta"]["io.github.computer-mcp/work-invocation"]
                        resources.append({"kind": "session", "id": "acquired-on-retry", "acquired_by": acquisition, "state": "active"})
                        revision += 1
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
    """#
}

/// Each supplied script must be a fixed protocol fixture that never creates descendants.
/// Native identity tracking can then own the complete execution through its one root.
func fixtureProtocolExecutionLauncher(
  root: URL, scripts: [String], arguments: [[String]], allowCat: Bool = false
) -> ExecutionLauncher {
  ExecutionLauncher(
    platform: GenerationExecutionPlatform(
      root: root, scripts: scripts, allowedArguments: arguments, allowCat: allowCat))
}

private struct GenerationExecutionPlatform: ExecutionPlatform {
  let root: URL
  let scripts: [String]
  let allowedArguments: [[String]]
  let allowCat: Bool
  private let base = DarwinExecutionPlatform(
    bootstrapExecutable: (try? nativeGatewayTestExecutable())?
      .deletingLastPathComponent().appendingPathComponent("computer-mcp-execution-bootstrap"))

  var supportsRecovery: Bool { true }
  var bootSessionID: String? { base.bootSessionID }
  var hostSystemReadPaths: [SandboxPath] { base.hostSystemReadPaths }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool { true }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    // Owner administration retains its ordinary backend and ownership contract.
    if try PreparedExecutionContext.current() == nil || sandbox != nil {
      return try await base.start(
        command, sandbox: sandbox, method: method, input: input, output: output, error: error,
        bindOwnership: bindOwnership)
    }
    let executable: SandboxPath
    let arguments: [String]
    if allowCat, command.executable.value == "/bin/cat", command.arguments.isEmpty {
      executable = command.executable
      arguments = []
    } else {
      let script: String
      let original: [String]
      if command.executable.value == "/usr/bin/python3", let first = command.arguments.first {
        script = first
        original = Array(command.arguments.dropFirst())
      } else {
        script = command.executable.value
        original = command.arguments
      }
      let path = URL(fileURLWithPath: script).resolvingSymlinksInPath().path
      guard path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
        let contents = try? String(contentsOfFile: path, encoding: .utf8),
        scripts.contains(contents),
        allowedArguments.contains(original)
      else {
        throw ExecutionEnvironmentError.unavailable(
          "The generation backend accepts fixed fixture programs only")
      }
      executable = try SandboxPath("/usr/bin/python3")
      arguments = ["-I", path] + original
    }
    let controlled = ExecutionCommand(
      executable: executable, arguments: arguments, directory: command.directory,
      environment: command.environment.filter {
        !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("PYTHON")
      },
      directoryDescriptor: command.directoryDescriptor,
      inheritedDescriptors: command.inheritedDescriptors)
    let owner = try await base.start(
      controlled, sandbox: nil, method: method, input: input, output: output, error: error,
      bindOwnership: { bindOwnership(GenerationProcessOwnership(base: $0)) })
    return GenerationProcessOwnership(base: owner)
  }

  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    if state.sandboxed { return try await base.recover(state) }
    guard state.backend == GenerationProcessOwnership.backend,
      state.root.processID > 0, state.root.identity > 0
    else { throw ExecutionEnvironmentError.unavailable("Invalid generation fixture recovery") }
    try await base.interrupt([state.root])
    return GenerationCompletedOwnership(state: state)
  }

  func interrupt(_ members: [ExecutionMember]) async throws { try await base.interrupt(members) }

  func releaseRecovery(_ state: ExecutionRecoveryState) throws {
    if state.sandboxed {
      try base.releaseRecovery(state)
    } else if state.backend != GenerationProcessOwnership.backend {
      throw ExecutionEnvironmentError.unavailable("Invalid generation fixture recovery")
    }
  }
}

private struct GenerationProcessOwnership: ExecutionOwnership {
  static let backend = "generation-fixture"
  let base: any ExecutionOwnership

  func recoveryState() throws -> ExecutionRecoveryState {
    let state = try base.recoveryState()
    return ExecutionRecoveryState(root: state.root, sandboxed: false, backend: Self.backend)
  }

  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
    base.beforeStart(handler)
  }
  func members() async throws -> [ExecutionMember] { try await base.members() }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) { base.onCancellation(handler) }
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    try await base.cancel(until: deadline)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    try await base.wait(until: deadline)
  }
}

private struct GenerationCompletedOwnership: ExecutionOwnership {
  let state: ExecutionRecoveryState
  func recoveryState() throws -> ExecutionRecoveryState { state }
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {}
  func members() async throws -> [ExecutionMember] { [] }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    ExecutionExit(status: 128 + SIGTERM, signal: SIGTERM)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    ExecutionExit(status: 128 + SIGTERM, signal: SIGTERM)
  }
}

private final class RepairFailureBookmarkService: ProjectBookmarkServicing, @unchecked Sendable {
  private let base = ProjectBookmarkService()
  private let lock = NSLock()
  private var root: URL?
  private var resolveNumber = 0
  private var calls = 0
  private var replace = false
  private var underlyingError: POSIXError?
  var failureInjected: Bool { lock.withLock { calls >= resolveNumber && resolveNumber > 0 } }

  func arm(
    root: URL, resolveNumber: Int, replace: Bool, underlyingError: POSIXError? = nil
  ) {
    lock.withLock {
      self.root = root
      self.resolveNumber = resolveNumber
      self.replace = replace
      self.underlyingError = underlyingError
    }
  }

  func registerFolder(at url: URL, displayName: String?) throws -> ComputerMCPCore.RegisteredProject
  {
    try base.registerFolder(at: url, displayName: displayName)
  }

  func resolve(_ project: ComputerMCPCore.RegisteredProject) throws -> ResolvedProjectAccess {
    let failure = lock.withLock { () -> (URL, Bool, POSIXError?)? in
      guard let root,
        URL(fileURLWithPath: project.rootPath).resolvingSymlinksInPath().path
          == root.resolvingSymlinksInPath().path
      else { return nil }
      calls += 1
      return calls == resolveNumber ? (root, replace, underlyingError) : nil
    }
    if let (root, replace, underlyingError) = failure {
      if let underlyingError { throw underlyingError }
      if replace {
        try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("original"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      } else {
        throw ProjectBookmarkError.securityScopeAccessDenied(projectID: project.id)
      }
    }
    return try base.resolve(project)
  }
}

private final class GenerationFailureProviders: GatewayToolProviderFactory, @unchecked Sendable {
  enum Failure: Error { case unavailable }
  private let lock = NSLock()
  private var failing = false
  let base: any GatewayToolProviderFactory
  init(base: any GatewayToolProviderFactory) { self.base = base }
  func fail(_ value: Bool) { lock.withLock { failing = value } }
  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    let registry = base.makeProviders(
      configuration: configuration, commandRunner: commandRunner,
      processManager: processManager, shellManager: shellManager, mcpClient: mcpClient,
      hostContext: hostContext)
    return GatewayToolRegistry(
      providers: { [self] in
        if lock.withLock({ failing }) { throw Failure.unavailable }
        return try registry.providers()
      }, downstreamPolicy: registry.downstreamPolicy, shutdown: { await registry.shutdown() })
  }
}
