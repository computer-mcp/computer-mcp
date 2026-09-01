import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class CodexAppServerRuntimeTests {
  @Test
  func testShutdownReapsProtocolProcessAndReleasesWriterLease() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }

    let firstRuntime = fixture.makeRuntime()
    let firstResponse = try await firstRuntime.call(
      method: "thread/loaded/list",
      params: .object([:])
    )
    #expect(firstResponse.objectValue?["data"] == .array([.string("thread_fixture")]))
    let firstPID = try await fixture.waitForLatestPID(count: 1)
    #expect(processExists(firstPID))
    #expect(FileManager.default.fileExists(atPath: fixture.leaseDirectory.path))

    await firstRuntime.shutdown()

    #expect(await waitForProcessExit(firstPID))
    #expect(await waitForFileRemoval(fixture.leaseDirectory))

    let secondRuntime = fixture.makeRuntime()
    let secondResponse = try await secondRuntime.call(
      method: "thread/loaded/list",
      params: .object([:])
    )
    #expect(secondResponse.objectValue?["data"] == .array([.string("thread_fixture")]))
    let secondPID = try await fixture.waitForLatestPID(count: 2)
    #expect(firstPID != secondPID)
    #expect(processExists(secondPID))

    await secondRuntime.shutdown()

    #expect(await waitForProcessExit(secondPID))
    #expect(await waitForFileRemoval(fixture.leaseDirectory))
  }

  @Test
  func testConcurrentFirstRequestsShareOneRuntimeGeneration() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let runtime = fixture.makeRuntime()

    async let first = runtime.call(method: "thread/loaded/list", params: .object([:]))
    async let second = runtime.call(method: "thread/loaded/list", params: .object([:]))
    _ = try await (first, second)

    _ = try await fixture.waitForLatestPID(count: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try fixture.processIDs().count == 1)

    await runtime.shutdown()
  }

  @Test
  func testMultipleRegisteredWorkspacesOwnAndReapIndependentAppServers() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let firstWorkspaceURL = fixture.directory.appendingPathComponent(
      "workspace-one",
      isDirectory: true
    )
    let secondWorkspaceURL = fixture.directory.appendingPathComponent(
      "workspace-two",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: firstWorkspaceURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: secondWorkspaceURL,
      withIntermediateDirectories: true
    )
    let firstWorkspace = RegisteredWorkspace(
      id: "workspace-one",
      displayName: "Workspace One",
      rootPath: firstWorkspaceURL.path
    )
    let secondWorkspace = RegisteredWorkspace(
      id: "workspace-two",
      displayName: "Workspace Two",
      rootPath: secondWorkspaceURL.path
    )
    let configuration = GatewayConfiguration(
      schemaVersion: 1,
      runtime: RuntimeBindingConfig(caller: .localMCP, profileID: .localAdmin),
      profiles: [
        ProfileGrantConfig(
          id: .localAdmin,
          capabilities: ["codex.app.thread.loaded.list"],
          workspaces: [firstWorkspace.id, secondWorkspace.id],
          allowedCallers: [.localMCP]
        )
      ],
      codex: CodexConfig(
        enabled: true,
        executable: fixture.executable.path,
        execEnabled: false,
        mcpEnabled: false,
        appServerRequestTimeoutSeconds: 2,
        appServerTerminationGraceMilliseconds: 200,
        appServerKillGraceMilliseconds: 1_000,
        approvalPolicy: .onRequest
      )
    )
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try GatewayRuntime(
      configuration: configuration,
      database: database,
      registeredWorkspaces: [firstWorkspace, secondWorkspace]
    )

    for workspaceID in [firstWorkspace.id, secondWorkspace.id] {
      let response = try await gateway.callToolAsync(
        name: "codex.app.thread.loaded.list",
        arguments: .object(["workspace_id": .string(workspaceID)])
      )
      #expect(response.objectValue?["isError"] != .bool(true))
    }

    _ = try await fixture.waitForLatestPID(count: 2)
    let processIDs = try fixture.processIDs()
    #expect(Set(processIDs).count == 2)
    #expect(processIDs.allSatisfy(processExists))
    #expect(
      FileManager.default.fileExists(
        atPath: firstWorkspaceURL.appendingPathComponent("writer.lease").path
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: secondWorkspaceURL.appendingPathComponent("writer.lease").path
      )
    )
    let firstStatuses = await CodexRuntimeDirectory.shared.statuses(
      workspaceID: firstWorkspace.id
    )
    let secondStatuses = await CodexRuntimeDirectory.shared.statuses(
      workspaceID: secondWorkspace.id
    )
    #expect(firstStatuses.objectValue?["runtimes"]?.arrayValue?.count == 1)
    #expect(secondStatuses.objectValue?["runtimes"]?.arrayValue?.count == 1)

    await gateway.shutdown()

    #expect(await processIDs.asyncAllSatisfy(waitForProcessExit))
    #expect(
      await waitForFileRemoval(firstWorkspaceURL.appendingPathComponent("writer.lease"))
    )
    #expect(
      await waitForFileRemoval(secondWorkspaceURL.appendingPathComponent("writer.lease"))
    )
    let stoppedReceipts = try database.codexRuntimeLeases(limit: 20).filter {
      $0.state == "stopped"
    }
    #expect(
      Set(stoppedReceipts.compactMap { $0.owner?.workspaceID }) == [
        firstWorkspace.id, secondWorkspace.id,
      ])
  }

  @Test
  func testOfficialGoalLifecycleUsesStableAppServerProtocol() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let runtime = fixture.makeRuntime()
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

    let set = try await runtime.call(
      method: "thread/goal/set",
      params: .object([
        "threadId": .string("thread_fixture"),
        "objective": .string("Pass every acceptance criterion."),
        "status": .string("active"),
        "tokenBudget": .number(50_000),
      ])
    )
    #expect(set.objectValue?["goal"]?.objectValue?["threadId"] == .string("thread_fixture"))
    #expect(set.objectValue?["goal"]?.objectValue?["status"] == .string("active"))
    #expect(set.objectValue?["goal"]?.objectValue?["tokenBudget"] == .number(50_000))

    let get = try await runtime.call(
      method: "thread/goal/get",
      params: .object(["threadId": .string("thread_fixture")])
    )
    #expect(
      get.objectValue?["goal"]?.objectValue?["objective"]
        == .string("Pass every acceptance criterion.")
    )
    #expect(get.objectValue?["goal"]?.objectValue?["tokensUsed"] == .number(1_250))

    let clear = try await runtime.call(
      method: "thread/goal/clear",
      params: .object(["threadId": .string("thread_fixture")])
    )
    #expect(clear.objectValue?["cleared"] == .bool(true))

    await runtime.shutdown()
  }

  @Test
  func testAbruptGatewaySocketLossReapsOwnedAppServerAndRecordsConnectionOwner()
    async throws
  {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let socketRoot = URL(fileURLWithPath: "/tmp/cm-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let socketConfiguration = GatewaySocketConfiguration(
      socketURL: socketRoot.appendingPathComponent("gateway.sock")
    )
    let server = try makeCodexSocketServer(
      fixture: fixture,
      database: database,
      socketConfiguration: socketConfiguration
    )
    try await server.start()
    defer { Task { await server.stop() } }

    let transport = GatewaySocketTransport(configuration: socketConfiguration)
    let client = Client(name: "codex-socket-loss", version: "1")
    try await client.connect(transport: transport)
    let result = try await client.callTool(
      name: "codex.app.thread.loaded.list",
      arguments: ["workspace_id": .string("fixture-workspace")]
    )
    #expect(result.isError != true)
    let processID = try await fixture.waitForLatestPID(count: 1)
    let live = await CodexRuntimeDirectory.shared.statuses(workspaceID: "fixture-workspace")
    let socketConnectionID = live.objectValue?["runtimes"]?.arrayValue?.first?
      .objectValue?["owner"]?.objectValue?["socket_connection_id"]?.stringValue
    #expect(socketConnectionID?.isEmpty == false)

    await transport.disconnect()
    try await waitUntilSocketCondition { await server.connectionCount() == 0 }
    #expect(await waitForProcessExit(processID))
    #expect(await waitForFileRemoval(fixture.leaseDirectory))
    let receipt = try await waitForRuntimeReceipt(
      database: database,
      processID: processID,
      state: "stopped"
    )
    #expect(receipt.state == "stopped")
    #expect(receipt.owner?.socketConnectionID == socketConnectionID)

    await client.disconnect()
    await server.stop()
  }

  @Test
  func testSecureTunnelReconnectCreatesNewOwnedGenerationAndReapsPreviousOne()
    async throws
  {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let credential = fixture.directory.appendingPathComponent("tunnel-auth")
    try GatewaySocketCredentialStore.create(at: credential)
    let socketRoot = URL(fileURLWithPath: "/tmp/cm-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    var serverConfiguration = GatewaySocketConfiguration(
      socketURL: socketRoot.appendingPathComponent("gateway.sock")
    )
    serverConfiguration.tunnelCredentialFile = credential
    let server = try makeCodexSocketServer(
      fixture: fixture,
      database: database,
      socketConfiguration: serverConfiguration
    )
    try await server.start()
    defer { Task { await server.stop() } }

    for generation in 1...2 {
      var clientConfiguration = serverConfiguration
      clientConfiguration.clientIdentity = .secureTunnel(
        credentialFile: credential,
        tunnelInstanceID: "tunnel-generation-\(generation)",
        tunnelProfileID: "fixture-profile"
      )
      let client = Client(name: "codex-tunnel-\(generation)", version: "1")
      try await client.connect(
        transport: GatewaySocketTransport(configuration: clientConfiguration)
      )
      let result = try await client.callTool(
        name: "codex.app.thread.loaded.list",
        arguments: ["workspace_id": .string("fixture-workspace")]
      )
      #expect(result.isError != true)
      let processID = try await fixture.waitForLatestPID(count: generation)
      await client.disconnect()
      try await waitUntilSocketCondition { await server.connectionCount() == 0 }
      #expect(await waitForProcessExit(processID))
      _ = try await waitForRuntimeReceipt(
        database: database,
        processID: processID,
        state: "stopped"
      )
      #expect(await waitForFileRemoval(fixture.leaseDirectory))
    }

    let receipts = try database.codexRuntimeLeases(limit: 20).filter {
      $0.owner?.workspaceID == "fixture-workspace" && $0.state == "stopped"
    }
    #expect(receipts.count == 2)
    #expect(
      Set(receipts.compactMap { $0.owner?.tunnelInstanceID })
        == ["tunnel-generation-1", "tunnel-generation-2"]
    )

    await server.stop()
  }

  @Test
  func testHTTPOriginStopReapsCloudflareOwnedAppServer() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let profileID = GatewayProfileID(rawValue: "fixture-profile")!
    let workspace = RegisteredWorkspace(
      id: "fixture-workspace",
      displayName: "Fixture",
      rootPath: fixture.directory.path
    )
    try database.saveWorkspace(workspace)
    let configuration = GatewayConfiguration(
      schemaVersion: 1,
      server: ServerConfig(name: "computer-mcp-http-lifecycle-fixture"),
      runtime: RuntimeBindingConfig(caller: .cloudflareTunnel, profileID: profileID),
      profiles: [
        ProfileGrantConfig(
          id: profileID,
          capabilities: ["codex.app.thread.loaded.list"],
          workspaces: [workspace.id],
          allowedCallers: [.cloudflareTunnel]
        )
      ],
      codex: CodexConfig(
        enabled: true,
        executable: fixture.executable.path,
        execEnabled: false,
        mcpEnabled: false,
        appServerRequestTimeoutSeconds: 2,
        appServerTerminationGraceMilliseconds: 200,
        appServerKillGraceMilliseconds: 1_000,
        approvalPolicy: .onRequest
      ),
      workspaceDirectory: fixture.directory
    )
    let gateway = try GatewayRuntime(
      configuration: configuration,
      context: configuration.executionContext(
        caller: .cloudflareTunnel,
        profileID: profileID,
        transportTrace: GatewayTransportTrace(
          transport: "streamable_http",
          socketConnectionID: nil,
          tunnelInstanceID: "cloudflare-origin-generation-1",
          tunnelProfileID: "fixture-profile"
        )
      ),
      database: database,
      registeredWorkspaces: [workspace]
    )
    let port = try availableCodexHTTPPort()
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: gateway,
      host: "127.0.0.1",
      port: port,
      publicBaseURL: nil
    )
    try await runtime.startListening()
    let session = try await GatewayClientSession.connectHTTP(
      endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
      streaming: false
    )
    let call = try await session.call(
      toolName: "codex.app.thread.loaded.list",
      arguments: .object(["workspace_id": .string("fixture-workspace")])
    )
    #expect(call.result.objectValue?["isError"] != .bool(true))
    let processID = try await fixture.waitForLatestPID(count: 1)

    await runtime.stop()
    #expect(await waitForProcessExit(processID))
    #expect(await waitForFileRemoval(fixture.leaseDirectory))
    let receipt = try await waitForRuntimeReceipt(
      database: database,
      processID: processID,
      state: "stopped"
    )
    #expect(receipt.owner?.transport == "streamable_http")
    #expect(receipt.owner?.tunnelInstanceID == "cloudflare-origin-generation-1")

    await session.disconnect()
  }

  @Test
  func testTimeoutRetirementReapsBeforeReadOnlyRetryStarts() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try Data().write(to: fixture.hangRequestsFile)
    let runtime = fixture.makeRuntime(requestTimeoutSeconds: 1)

    await assertThrowsErrorAsync(
      try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    )

    let secondPID = try await fixture.waitForLatestPID(count: 2)
    let processIDs = try fixture.processIDs()
    #expect(processIDs.count == 2)
    #expect(await processIDs.asyncAllSatisfy(waitForProcessExit))
    #expect(!processExists(secondPID))
    #expect(!FileManager.default.fileExists(atPath: fixture.leaseDirectory.path))
  }

  @Test
  func testApprovalBrokerPersistsRedactsAndApprovesOnce() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(
      grantRoot: fixture.directory.path,
      reason: "token=fixture-secret"
    )
    let database = try GatewayDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

    let pending = try await waitForPendingApproval(runtime)
    #expect(pending.kind == .fileChange)
    #expect(
      pending.details.objectValue?["reason"] == .string("token=[REDACTED]")
    )
    let response = try await runtime.respondToApproval(
      id: pending.id,
      decision: CodexApprovalDecision.approveOnce.rawValue
    )
    #expect(
      response.objectValue?["approval"]?.objectValue?["state"] == .string("approved")
    )
    #expect(try await fixture.waitForApprovalResponse().contains("accept"))
    #expect(try database.codexApproval(id: pending.id)?.state == .approved)

    await runtime.shutdown()
  }

  @Test
  func testApprovalBrokerDeniesMalformedDecisionAndTimesOut() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: fixture.directory.path)
    let database = try GatewayDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(
      requestTimeoutSeconds: 3,
      approvalTimeoutSeconds: 1,
      database: database
    )
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    let pending = try await waitForPendingApproval(runtime)

    await assertThrowsErrorAsync(
      try await runtime.respondToApproval(id: pending.id, decision: "allow_forever")
    )

    let timedOut = try await waitForApprovalState(
      runtime,
      approvalID: pending.id,
      state: .timedOut
    )
    #expect(timedOut.resolutionReason == "Approval deadline expired.")
    #expect(try await fixture.waitForApprovalResponse().contains("cancel"))
    #expect(try database.codexApproval(id: pending.id)?.state == .timedOut)

    await runtime.shutdown()
  }

  @Test
  func testApprovalTimeoutResponseFailureBecomesTerminal() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: fixture.directory.path)
    try Data().write(to: fixture.closeInputAfterApprovalRequestFile)
    let database = try GatewayDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(
      requestTimeoutSeconds: 3,
      approvalTimeoutSeconds: 1,
      database: database
    )
    let requestTask = Task {
      try? await runtime.call(method: "thread/loaded/list", params: .object([:]))
    }
    let pending = try await waitForPendingApproval(runtime)

    let failed = try await waitForApprovalState(
      runtime,
      approvalID: pending.id,
      state: .failed
    )
    #expect(failed.decision == .deny)
    #expect(failed.resolutionReason?.contains("could not be delivered") == true)
    #expect(try database.codexApproval(id: pending.id)?.state == .failed)
    #expect(
      try await runtime.approvals(state: CodexApprovalState.pending.rawValue, limit: 10)
        .objectValue?["approvals"] == .array([])
    )
    _ = await requestTask.value

    await runtime.shutdown()
  }

  @Test
  func testApprovalBrokerRejectsOutOfScopeAndCanAutoApproveBoundedWrite() async throws {
    let deniedFixture = try AppServerProcessFixture()
    defer { deniedFixture.remove() }
    try deniedFixture.configureFileApproval(grantRoot: "/tmp/outside-computer-mcp")
    let database = try GatewayDatabase(inMemory: ())
    let deniedRuntime = deniedFixture.makeRuntime(database: database)
    _ = try await deniedRuntime.call(method: "thread/loaded/list", params: .object([:]))
    let denied = try await waitForLatestApproval(deniedRuntime)
    #expect(denied.state == .denied)
    #expect(denied.resolutionReason?.contains("exceeds the registered workspace") == true)
    #expect(try await deniedFixture.waitForApprovalResponse().contains("error"))
    await deniedRuntime.shutdown()

    let approvedFixture = try AppServerProcessFixture()
    defer { approvedFixture.remove() }
    try approvedFixture.configureFileApproval(grantRoot: approvedFixture.directory.path)
    let approvedRuntime = approvedFixture.makeRuntime(
      database: database,
      autoApproveWorkspaceWrites: true
    )
    _ = try await approvedRuntime.call(method: "thread/loaded/list", params: .object([:]))
    let approved = try await waitForApprovalState(
      approvedRuntime,
      state: .approved
    )
    #expect(approved.decision == .approveOnce)
    #expect(try await approvedFixture.waitForApprovalResponse().contains("accept"))
    await approvedRuntime.shutdown()
  }

  @Test
  func testApprovalBrokerIsolatesWorkspacesAndRoutesToOwningRuntime() async throws {
    let owningFixture = try AppServerProcessFixture()
    defer { owningFixture.remove() }
    try owningFixture.configureFileApproval(grantRoot: owningFixture.directory.path)
    let database = try GatewayDatabase(inMemory: ())
    let owningRuntime = owningFixture.makeRuntime(
      database: database,
      workspaceID: "workspace-a"
    )
    _ = try await owningRuntime.call(method: "thread/loaded/list", params: .object([:]))
    let pending = try await waitForPendingApproval(owningRuntime)

    let isolatedFixture = try AppServerProcessFixture()
    defer { isolatedFixture.remove() }
    let isolatedRuntime = isolatedFixture.makeRuntime(
      database: database,
      workspaceID: "workspace-b"
    )
    let isolatedList = try await isolatedRuntime.approvals(state: nil, limit: 10)
    #expect(isolatedList.objectValue?["approvals"] == .array([]))
    await assertThrowsErrorAsync(try await isolatedRuntime.approval(id: pending.id))
    await assertThrowsErrorAsync(
      try await isolatedRuntime.respondToApproval(id: pending.id, decision: "approve_once")
    )

    let routingFixture = try AppServerProcessFixture()
    defer { routingFixture.remove() }
    let routingRuntime = routingFixture.makeRuntime(
      database: database,
      workspaceID: "workspace-a"
    )
    let routed = try await routingRuntime.respondToApproval(
      id: pending.id,
      decision: "approve_once"
    )
    #expect(routed.objectValue?["approval"]?.objectValue?["state"] == .string("approved"))
    #expect(try await owningFixture.waitForApprovalResponse().contains("accept"))

    await routingRuntime.shutdown()
    await isolatedRuntime.shutdown()
    await owningRuntime.shutdown()
  }

  @Test
  func testApprovalBrokerHandlesEverySupportedNativeApprovalKind() async throws {
    let cases: [(CodexApprovalKind, String, JSONValue, CodexApprovalDecision)] = [
      (
        .commandExecution,
        "item/commandExecution/requestApproval",
        .object([
          "command": .string("git status"),
          "cwd": .string("__WORKSPACE__"),
          "itemId": .string("item-command"),
          "reason": .string("Inspect repository status."),
          "startedAtMs": .number(1),
          "threadId": .string("thread_fixture"),
          "turnId": .string("turn-command"),
        ]),
        .approveOnce
      ),
      (
        .fileChange,
        "item/fileChange/requestApproval",
        .object([
          "grantRoot": .string("__WORKSPACE__"),
          "itemId": .string("item-file"),
          "reason": .string("Write a fixture file."),
          "startedAtMs": .number(1),
          "threadId": .string("thread_fixture"),
          "turnId": .string("turn-file"),
        ]),
        .approveSession
      ),
      (
        .permissions,
        "item/permissions/requestApproval",
        .object([
          "cwd": .string("__WORKSPACE__"),
          "itemId": .string("item-permissions"),
          "permissions": .object([
            "fileSystem": .object([
              "read": .array([.string("__WORKSPACE__")]),
              "write": .array([.string("__WORKSPACE__")]),
            ])
          ]),
          "reason": .string("Use the registered workspace."),
          "startedAtMs": .number(1),
          "threadId": .string("thread_fixture"),
          "turnId": .string("turn-permissions"),
        ]),
        .approveSession
      ),
      (
        .applyPatch,
        "applyPatchApproval",
        .object([
          "callId": .string("call-patch"),
          "conversationId": .string("thread_fixture"),
          "fileChanges": .object([
            "__WORKSPACE__/approved.txt": .object([
              "content": .string("approved\n"),
              "type": .string("add"),
            ])
          ]),
          "grantRoot": .string("__WORKSPACE__"),
          "reason": .string("Apply a reviewed patch."),
        ]),
        .approveOnce
      ),
      (
        .execCommand,
        "execCommandApproval",
        .object([
          "callId": .string("call-exec"),
          "command": .array([.string("/usr/bin/git"), .string("status")]),
          "conversationId": .string("thread_fixture"),
          "cwd": .string("__WORKSPACE__"),
          "parsedCmd": .array([
            .object([
              "cmd": .string("git status"),
              "type": .string("unknown"),
            ])
          ]),
          "reason": .string("Inspect repository status."),
        ]),
        .approveOnce
      ),
    ]

    for (kind, method, template, decision) in cases {
      let fixture = try AppServerProcessFixture()
      do {
        let params = replaceWorkspacePlaceholder(template, with: fixture.directory.path)
        try fixture.configureApproval(method: method, params: params)
        let database = try GatewayDatabase(inMemory: ())
        let runtime = fixture.makeRuntime(database: database)
        _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

        let pending = try await waitForPendingApproval(runtime)
        #expect(pending.kind == kind)
        let response = try await runtime.respondToApproval(
          id: pending.id,
          decision: decision.rawValue
        )
        let approval = response.objectValue?["approval"]?.objectValue
        #expect(approval?["state"] == .string("approved"))
        #expect(
          approval?["scope"]
            == .string(decision == .approveSession ? "session" : "once")
        )
        let upstream = try await fixture.waitForApprovalResponse()
        #expect(upstream.contains("\"id\":900"))
        await runtime.shutdown()
      } catch {
        fixture.remove()
        throw error
      }
      fixture.remove()
    }
  }

  @Test
  func testPendingApprovalBecomesInterruptedAndCannotBeReplayedAfterRestart() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: fixture.directory.path)
    let database = try GatewayDatabase(inMemory: ())
    let first = fixture.makeRuntime(database: database)
    _ = try await first.call(method: "thread/loaded/list", params: .object([:]))
    let pending = try await waitForPendingApproval(first)

    await first.shutdown()

    let interrupted = try #require(try database.codexApproval(id: pending.id))
    #expect(interrupted.state == .interrupted)
    #expect(interrupted.resolvedAt != nil)
    try? FileManager.default.removeItem(at: fixture.approvalRequestFile)
    let replacement = fixture.makeRuntime(database: database)
    let record = try await replacement.approval(id: pending.id)
      .objectValue?["approval"]?.objectValue
    #expect(record?["state"] == .string("interrupted"))
    await assertThrowsErrorAsync(
      try await replacement.respondToApproval(
        id: pending.id,
        decision: CodexApprovalDecision.approveOnce.rawValue
      )
    )
    await replacement.shutdown()
  }

  @Test
  func testMalformedApprovalRequestFailsClosedWithoutCreatingConsentRecord() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureApproval(
      method: "item/fileChange/requestApproval",
      params: .object([
        "grantRoot": .string(fixture.directory.path),
        "reason": .string("token=malformed-secret"),
      ])
    )
    let database = try GatewayDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try? await runtime.call(method: "thread/loaded/list", params: .object([:]))

    var eventKinds: Set<String> = []
    for _ in 0..<500 {
      let events = await runtime.events(afterCursor: 0, maxResults: 100)
      eventKinds = Set(
        (events.objectValue?["events"]?.arrayValue ?? []).compactMap {
          $0.objectValue?["kind"]?.stringValue
        }
      )
      if eventKinds.contains("server_request_stream_failed") { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(eventKinds.contains("server_request_stream_failed"))
    #expect(try database.codexApprovals(workspaceID: "fixture-workspace").isEmpty)
    let encodedEvents = try String(
      decoding: JSONEncoder().encode(await runtime.events(afterCursor: 0, maxResults: 100)),
      as: UTF8.self
    )
    #expect(!encodedEvents.contains("malformed-secret"))
    await runtime.shutdown()
  }

  @Test
  func testMCPElicitationIsSurfacedRedactedAndResolvedByCaller() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureElicitation(message: "Use token=fixture-secret to continue")
    let runtime = fixture.makeRuntime()
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

    let request = try await waitForInteractiveRequest(runtime, kind: "mcp_elicitation")
    #expect(
      request.payload.objectValue?["params"]?.objectValue?["message"]
        == .string("Use token=[REDACTED] to continue")
    )
    _ = try await runtime.respond(
      requestID: request.id,
      response: .object(["action": .string("decline")])
    )
    #expect(try await fixture.waitForApprovalResponse().contains("decline"))

    await runtime.shutdown()
  }

  @Test
  func testUserInputRequestAndEventAreRedactedBeforeExposure() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureUserInput(question: "Confirm token=fixture-secret before continuing")
    let runtime = fixture.makeRuntime()
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

    let request = try await waitForInteractiveRequest(runtime, kind: "user_input")
    let encodedRequest = String(
      decoding: try JSONEncoder().encode(request.payload),
      as: UTF8.self
    )
    #expect(encodedRequest.contains("token=[REDACTED]"))
    #expect(!encodedRequest.contains("fixture-secret"))
    let encodedEvents = String(
      decoding: try JSONEncoder().encode(await runtime.events(afterCursor: 0, maxResults: 100)),
      as: UTF8.self
    )
    #expect(!encodedEvents.contains("fixture-secret"))

    await runtime.shutdown()
  }

  @Test
  func testRegisteredReadOnlyToolRunsThroughGatewayPolicyAndAudit() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureDynamicTool(name: "system.time", arguments: .object([:]))
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeDynamicToolGateway(
      fixture: fixture,
      database: database,
      targetCapabilities: ["system.time"]
    )

    _ = try await gateway.callToolAsync(
      name: "codex.app.thread.loaded.list",
      arguments: .object(["workspace_id": .string("fixture-workspace")])
    )
    let response = try await fixture.waitForApprovalResponse()
    #expect(response.contains("success"))
    #expect(response.contains("true"))
    #expect(try database.auditEvent(requestID: "codex-call-fixture")?.capabilityID == "system.time")

    await gateway.shutdown()
  }

  @Test
  func testRegisteredWriteToolWaitsForApprovalThenUsesGatewayPolicyAndAudit() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureDynamicTool(
      name: "file.append",
      arguments: .object([
        "path": .string("generated.txt"),
        "content": .string("from-codex"),
      ])
    )
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeDynamicToolGateway(
      fixture: fixture,
      database: database,
      targetCapabilities: ["file.append"]
    )

    _ = try await gateway.callToolAsync(
      name: "codex.app.thread.loaded.list",
      arguments: .object(["workspace_id": .string("fixture-workspace")])
    )
    let pending = try await waitForGatewayApproval(gateway)
    #expect(pending.kind == .registeredTool)
    #expect(pending.correlationID == "codex-call-fixture")
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent("generated.txt").path))

    _ = try await gateway.callToolAsync(
      name: "codex.app.approvals.respond",
      arguments: .object([
        "workspace_id": .string("fixture-workspace"),
        "approval_id": .string(pending.id),
        "decision": .string("approve_once"),
      ])
    )
    #expect(
      try String(
        contentsOf: fixture.directory.appendingPathComponent("generated.txt"), encoding: .utf8)
        == "from-codex")
    #expect(try await fixture.waitForApprovalResponse().contains("true"))
    #expect(try database.auditEvent(requestID: "codex-call-fixture")?.capabilityID == "file.append")

    await gateway.shutdown()
  }

  @Test
  func testCodexGovernedGitPathCreatesHookedCommitAndCleanWorktree() async throws {
    let repository = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repository) }
    try runGit(["init"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    let hook = repository.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\n/usr/bin/touch .git/hook-ran\n".utf8).write(to: hook)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: hook.path
    )

    let database = try GatewayDatabase(inMemory: ())
    let capabilities = ["file.write", "git.add", "git.commit", "git.status"]
    let cli = CLISectionConfig(commands: [
      CLICommandConfig(id: "git", executable: "/usr/bin/git")
    ])

    try await runApprovedDynamicTool(
      name: "file.write",
      arguments: .object([
        "path": .string("product.txt"),
        "content": .string("production-ready\n"),
      ]),
      callID: "codex-write",
      repository: repository,
      database: database,
      capabilities: capabilities,
      builtins: capabilities,
      cli: cli
    )
    try await runApprovedDynamicTool(
      name: "git.add",
      arguments: .object(["paths": .array([.string("product.txt")])]),
      callID: "codex-stage",
      repository: repository,
      database: database,
      capabilities: capabilities,
      builtins: capabilities,
      cli: cli
    )
    try await runApprovedDynamicTool(
      name: "git.commit",
      arguments: .object(["message": .string("feat: verify governed Codex Git")]),
      callID: "codex-commit",
      repository: repository,
      database: database,
      capabilities: capabilities,
      builtins: capabilities,
      cli: cli
    )

    #expect(
      FileManager.default.fileExists(
        atPath: repository.appendingPathComponent(".git/hook-ran").path))
    #expect(try runGit(["status", "--porcelain"], in: repository).isEmpty)
    #expect(
      try runGit(["log", "-1", "--pretty=%s"], in: repository).trimmingCharacters(
        in: .whitespacesAndNewlines) == "feat: verify governed Codex Git")
    #expect(try database.auditEvent(requestID: "codex-write")?.capabilityID == "operations.commit")
    #expect(try database.auditEvent(requestID: "codex-stage")?.capabilityID == "operations.commit")
    #expect(try database.auditEvent(requestID: "codex-commit")?.capabilityID == "git.commit")
  }

  @Test
  func testBoundedRequestClosesTimedOutOperation() async {
    let probe = CodexAppServerTimeoutProbe()

    do {
      _ = try await LiveCodexAppServerRuntime.boundedRequest(
        timeoutSeconds: 1,
        onTimeout: {
          await probe.recordTimeout()
        },
        operation: {
          try await Task.sleep(for: .seconds(60))
          return "late"
        }
      )
      Issue.record("Expected the App Server request to time out.")
    } catch {
      #expect(error.localizedDescription.contains("1-second deadline"))
    }
    #expect(await probe.didTimeOut)
  }

  @Test
  func testBoundedRequestDoesNotWaitForNonCooperativeOperation() async {
    let probe = CodexAppServerNonCooperativeProbe()
    let safetyRelease = Task {
      try? await Task.sleep(for: .seconds(5))
      await probe.release()
    }
    let clock = ContinuousClock()
    let started = clock.now

    do {
      _ = try await LiveCodexAppServerRuntime.boundedRequest(
        timeoutSeconds: 1,
        onTimeout: {},
        operation: {
          await probe.wait()
        }
      )
      Issue.record("Expected the non-cooperative request to time out.")
    } catch {
      #expect(error.localizedDescription.contains("1-second deadline"))
    }

    let elapsed = started.duration(to: clock.now)
    #expect(elapsed < .seconds(3))
    await probe.release()
    safetyRelease.cancel()
  }

  @Test
  func testOnlyTimedOutReadOnlyRequestsReceiveOneRetry() {
    let timeout = LiveCodexAppServerRuntime.RequestTimeoutError(seconds: 30)

    #expect(
      LiveCodexAppServerRuntime.shouldRetryRequest(
        timeout,
        risk: .readOnly,
        attempt: 0,
        maximumAttempts: 2
      ))
    #expect(
      !LiveCodexAppServerRuntime.shouldRetryRequest(
        timeout,
        risk: .readOnly,
        attempt: 1,
        maximumAttempts: 2
      ))
    #expect(
      !LiveCodexAppServerRuntime.shouldRetryRequest(
        timeout,
        risk: .workspaceWrite,
        attempt: 0,
        maximumAttempts: 2
      ))
    #expect(
      !LiveCodexAppServerRuntime.shouldRetryRequest(
        CocoaError(.fileNoSuchFile),
        risk: .readOnly,
        attempt: 0,
        maximumAttempts: 2
      ))
  }

  @Test
  func testNormalizePinsThreadListAndSkillsToBoundWorkspace() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")
    let runtime = LiveCodexAppServerRuntime(
      configuration: CodexConfig(enabled: true),
      workspaceURL: workspace
    )

    let threadList = try await runtime.normalize(
      params: .object([
        "cwd": .string(workspace.path),
        "searchTerm": .string("gateway"),
      ]),
      for: try method("thread/list")
    )
    #expect((threadList?.objectValue?["cwd"]) == (.string(workspace.path)))
    #expect((threadList?.objectValue?["searchTerm"]) == (.string("gateway")))

    let skillsList = try await runtime.normalize(
      params: .object([
        "perCwdExtraUserRoots": .object([workspace.path: .array([.string("/tmp/escape")])])
      ]),
      for: try method("skills/list")
    )
    #expect((skillsList?.objectValue?["cwds"]) == (.array([.string(workspace.path)])))
    #expect((skillsList?.objectValue?["perCwdExtraUserRoots"]) == nil)
  }

  @Test
  func testNormalizePinsSandboxAndRejectsAuthorityOverrides() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")
    let runtime = LiveCodexAppServerRuntime(
      configuration: CodexConfig(
        enabled: true,
        sandbox: .workspaceWrite,
        approvalPolicy: .never
      ),
      workspaceURL: workspace
    )

    let normalized = try await runtime.normalize(
      params: .object([
        "threadId": .string("thread-1"),
        "input": .array([]),
      ]),
      for: try method("turn/start")
    )
    #expect((normalized?.objectValue?["cwd"]) == (.string(workspace.path)))
    #expect((normalized?.objectValue?["approvalPolicy"]) == (.string("never")))
    #expect(
      (normalized?.objectValue?["sandboxPolicy"]?.objectValue?["type"])
        == (.string("workspaceWrite")))

    await assertThrowsErrorAsync(
      try await runtime.normalize(
        params: .object(["config": .object([:])]),
        for: try method("thread/start")
      ),
      expectedCode: "codex.app.override_denied"
    )
    await assertThrowsErrorAsync(
      try await runtime.normalize(
        params: .object(["sandbox": .string("danger-full-access")]),
        for: try method("thread/start")
      ),
      expectedCode: "codex.app.danger_full_access_denied"
    )
  }

  @Test
  func testTimedOutReadOnlyRequestRunsExactlyOneFreshAttempt() async throws {
    let probe = CodexAppServerRetryProbe()

    let result = try await LiveCodexAppServerRuntime.withRequestRetry(risk: .readOnly) {
      attempt in
      await probe.record(attempt: attempt)
      if attempt == 0 {
        throw LiveCodexAppServerRuntime.RequestTimeoutError(seconds: 30)
      }
      return "recovered"
    }

    #expect(result == "recovered")
    #expect(await probe.attempts == [0, 1])
  }

  @Test
  func testWorkspaceScopedThreadIDRequiresThreadForScopedMethods() throws {
    #expect(
      (try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "thread/list",
        params: .object([:])
      )) == nil)
    #expect(
      (try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "turn/start",
        params: .object(["threadId": .string("thread-1")])
      )) == ("thread-1"))
    expectThrows(
      try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "thread/read",
        params: .object([:])
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.validatedThreadID(String(repeating: "x", count: 1_025)))
    expectThrows(try LiveCodexAppServerRuntime.validatedThreadID("thread\nforged"))
  }

  @Test
  func testThreadWorkspaceValidationAllowsDescendantsAndRejectsOtherRoots() throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")

    expectNoThrow(
      try LiveCodexAppServerRuntime.validateThreadWorkspace(
        threadID: "thread-1",
        response: threadResponse(cwd: workspace.appendingPathComponent("nested").path),
        workspaceURL: workspace
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.validateThreadWorkspace(
        threadID: "thread-2",
        response: threadResponse(cwd: "/tmp/other-workspace"),
        workspaceURL: workspace
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.validateThreadWorkspace(
        threadID: "thread-3",
        response: .object(["thread": .object([:])]),
        workspaceURL: workspace
      )
    )
    expectNoThrow(
      try LiveCodexAppServerRuntime.validatePersistedThreadWorkspace(
        threadID: "thread-4",
        threadCWD: workspace.appendingPathComponent("nested").path,
        workspaceURL: workspace
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.validatePersistedThreadWorkspace(
        threadID: "thread-5",
        threadCWD: "/tmp/other-workspace",
        workspaceURL: workspace
      )
    )
  }

  @Test
  func testCreatedThreadWorkspaceValidationAcceptsBoundThreadAndRejectsEscapes() throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")

    #expect(
      (try LiveCodexAppServerRuntime.createdWorkspaceScopedThreadID(
        response: createdThreadResponse(id: "thread-created", cwd: workspace.path),
        workspaceURL: workspace
      )) == ("thread-created"))
    expectThrows(
      try LiveCodexAppServerRuntime.createdWorkspaceScopedThreadID(
        response: createdThreadResponse(
          id: "thread-created-outside",
          cwd: "/tmp/outside-workspace"
        ),
        workspaceURL: workspace
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.createdWorkspaceScopedThreadID(
        response: threadResponse(cwd: workspace.path),
        workspaceURL: workspace
      )
    )
  }

  private func method(_ name: String) throws -> CodexAppServerMethod {
    try #require(CodexAppServerMethodCatalog.method(named: name))
  }

  private func threadResponse(cwd: String) -> JSONValue {
    .object([
      "thread": .object([
        "cwd": .string(cwd)
      ])
    ])
  }

  private func createdThreadResponse(id: String, cwd: String) -> JSONValue {
    .object([
      "thread": .object([
        "id": .string(id),
        "cwd": .string(cwd),
      ])
    ])
  }
}

private struct AppServerProcessFixture {
  let directory: URL
  let executable: URL
  let processLog: URL
  let leaseDirectory: URL
  let hangRequestsFile: URL
  let approvalRequestFile: URL
  let approvalResponseLog: URL
  let closeInputAfterApprovalRequestFile: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    executable = directory.appendingPathComponent("codex-fixture")
    processLog = directory.appendingPathComponent("processes.log")
    leaseDirectory = directory.appendingPathComponent("writer.lease", isDirectory: true)
    hangRequestsFile = directory.appendingPathComponent("hang-requests")
    approvalRequestFile = directory.appendingPathComponent("approval-request.json")
    approvalResponseLog = directory.appendingPathComponent("approval-response.log")
    closeInputAfterApprovalRequestFile = directory.appendingPathComponent(
      "close-input-after-approval-request"
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(
      """
      #!/bin/sh
      fixture_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      workspace_dir=$(pwd -P)
      lease_dir="$workspace_dir/writer.lease"
      process_log="$fixture_dir/processes.log"

      if ! /bin/mkdir "$lease_dir"; then
        printf '%s\n' 'writer lease is already owned' >&2
        exit 73
      fi

      cleanup() {
        /bin/rmdir "$lease_dir" 2>/dev/null || true
      }
      trap cleanup EXIT
      trap 'exit 0' HUP INT TERM
      printf '%s\n' "$$" >> "$process_log"

      IFS= read -r line || exit 74
      id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/')
      printf '{"id":%s,"result":{"codexHome":"%s","platformFamily":"unix","platformOs":"macos","userAgent":"Codex/computer-mcp-fixture"}}\n' "$id" "$fixture_dir"
      IFS= read -r line || exit 75
      if [ -f "$fixture_dir/approval-request.json" ]; then
        /bin/cat "$fixture_dir/approval-request.json"
        printf '\n'
        if [ -f "$fixture_dir/close-input-after-approval-request" ]; then
          exec 0<&-
          /bin/sleep 10
          exit 0
        fi
      fi

      while IFS= read -r line; do
        case "$line" in
          *'"id":900'*|*'"id":"900"'*)
            printf '%s\n' "$line" >> "$fixture_dir/approval-response.log"
            continue
            ;;
        esac
        id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/')
        case "$line" in
          *thread*loaded*list*)
            if [ -f "$fixture_dir/hang-requests" ]; then
              continue
            fi
            printf '{"id":%s,"result":{"data":["thread_fixture"],"nextCursor":null}}\n' "$id"
            ;;
          *thread*unsubscribe*)
            printf '{"id":%s,"result":{"status":"unsubscribed"}}\n' "$id"
            ;;
          *thread*goal*set*)
            printf '{"id":%s,"result":{"goal":{"createdAt":1,"objective":"Pass every acceptance criterion.","status":"active","threadId":"thread_fixture","timeUsedSeconds":30,"tokenBudget":50000,"tokensUsed":1250,"updatedAt":2}}}\n' "$id"
            ;;
          *thread*goal*get*)
            printf '{"id":%s,"result":{"goal":{"createdAt":1,"objective":"Pass every acceptance criterion.","status":"active","threadId":"thread_fixture","timeUsedSeconds":30,"tokenBudget":50000,"tokensUsed":1250,"updatedAt":2}}}\n' "$id"
            ;;
          *thread*goal*clear*)
            printf '{"id":%s,"result":{"cleared":true}}\n' "$id"
            ;;
          *)
            printf '{"id":%s,"error":{"code":-32601,"message":"fixture method unavailable"}}\n' "$id"
            ;;
        esac
      done
      """.utf8
    ).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: executable.path
    )
  }

  func makeRuntime(
    requestTimeoutSeconds: Int = 2,
    approvalTimeoutSeconds: Int = 300,
    database: GatewayDatabase? = nil,
    autoApproveWorkspaceWrites: Bool = false,
    workspaceID: String? = "fixture-workspace"
  ) -> LiveCodexAppServerRuntime {
    LiveCodexAppServerRuntime(
      configuration: CodexConfig(
        enabled: true,
        executable: executable.path,
        execEnabled: false,
        mcpEnabled: false,
        appServerRequestTimeoutSeconds: requestTimeoutSeconds,
        appServerTerminationGraceMilliseconds: 200,
        appServerKillGraceMilliseconds: 1_000,
        appServerApprovalTimeoutSeconds: approvalTimeoutSeconds,
        appServerAutoApproveWorkspaceWrites: autoApproveWorkspaceWrites,
        approvalPolicy: .onRequest
      ),
      workspaceURL: directory,
      owner: CodexRuntimeOwner(
        workspaceID: workspaceID,
        profileID: "fixture-profile",
        caller: "local-mcp",
        transport: "fixture",
        socketConnectionID: "socket-fixture",
        tunnelInstanceID: nil,
        tunnelProfileID: nil
      ),
      database: database
    )
  }

  func configureFileApproval(grantRoot: String, reason: String? = nil) throws {
    var params: [String: JSONValue] = [
      "grantRoot": .string(grantRoot),
      "itemId": .string("item-fixture"),
      "startedAtMs": .number(1),
      "threadId": .string("thread_fixture"),
      "turnId": .string("turn-fixture"),
    ]
    if let reason {
      params["reason"] = .string(reason)
    }
    try configureApproval(
      method: "item/fileChange/requestApproval",
      params: .object(params)
    )
  }

  func configureApproval(method: String, params: JSONValue) throws {
    let request: JSONValue = .object([
      "id": .number(900),
      "method": .string(method),
      "params": params,
    ])
    try? FileManager.default.removeItem(at: approvalResponseLog)
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(request)
      .write(to: approvalRequestFile)
  }

  func configureElicitation(message: String) throws {
    let request: JSONValue = .object([
      "id": .number(900),
      "method": .string("mcpServer/elicitation/request"),
      "params": .object([
        "elicitationId": .string("elicitation-fixture"),
        "message": .string(message),
        "mode": .string("url"),
        "url": .string("https://example.invalid/authorize"),
      ]),
    ])
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(request)
      .write(to: approvalRequestFile)
  }

  func configureUserInput(question: String) throws {
    let request: JSONValue = .object([
      "id": .number(900),
      "method": .string("item/tool/requestUserInput"),
      "params": .object([
        "isBlocking": .bool(true),
        "itemId": .string("item-input-fixture"),
        "questions": .array([
          .object([
            "header": .string("Confirm"),
            "id": .string("confirmation"),
            "question": .string(question),
          ])
        ]),
        "threadId": .string("thread_fixture"),
        "turnId": .string("turn-fixture"),
      ]),
    ])
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(request)
      .write(to: approvalRequestFile)
  }

  func configureDynamicTool(
    name: String,
    arguments: JSONValue,
    callID: String = "codex-call-fixture"
  ) throws {
    let request: JSONValue = .object([
      "id": .number(900),
      "method": .string("item/tool/call"),
      "params": .object([
        "arguments": arguments,
        "callId": .string(callID),
        "namespace": .string("computer-mcp"),
        "threadId": .string("thread_fixture"),
        "tool": .string(name),
        "turnId": .string("turn-fixture"),
      ]),
    ])
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(request)
      .write(to: approvalRequestFile)
  }

  func waitForApprovalResponse() async throws -> String {
    for _ in 0..<500 {
      if let response = try? String(contentsOf: approvalResponseLog, encoding: .utf8),
        response.last?.isNewline == true
      {
        return response
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexAppServerProcessTransportError.launchFailed(
      "Timed out waiting for fixture approval response."
    )
  }

  func waitForLatestPID(count: Int) async throws -> Int32 {
    for _ in 0..<500 {
      let ids = try processIDs()
      if ids.count >= count, let processID = ids.last {
        return processID
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexAppServerProcessTransportError.launchFailed(
      "Timed out waiting for fixture process generation \(count)."
    )
  }

  func processIDs() throws -> [Int32] {
    guard let contents = try? String(contentsOf: processLog, encoding: .utf8) else {
      return []
    }
    return contents.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private func makeCodexSocketServer(
  fixture: AppServerProcessFixture,
  database: GatewayDatabase,
  socketConfiguration: GatewaySocketConfiguration
) throws -> GatewaySocketServer {
  let profileID = GatewayProfileID(rawValue: "fixture-profile")!
  let workspace = RegisteredWorkspace(
    id: "fixture-workspace",
    displayName: "Fixture",
    rootPath: fixture.directory.path
  )
  try database.saveWorkspace(workspace)
  let configuration = GatewayConfiguration(
    schemaVersion: 1,
    server: ServerConfig(name: "computer-mcp-codex-lifecycle-fixture"),
    runtime: RuntimeBindingConfig(caller: .localMCP, profileID: profileID),
    profiles: [
      ProfileGrantConfig(
        id: profileID,
        capabilities: ["codex.app.thread.loaded.list"],
        workspaces: [workspace.id],
        allowedCallers: [.localMCP, .secureTunnel]
      )
    ],
    codex: CodexConfig(
      enabled: true,
      executable: fixture.executable.path,
      execEnabled: false,
      mcpEnabled: false,
      appServerRequestTimeoutSeconds: 2,
      appServerTerminationGraceMilliseconds: 200,
      appServerKillGraceMilliseconds: 1_000,
      approvalPolicy: .onRequest
    ),
    workspaceDirectory: fixture.directory
  )
  return GatewaySocketServer(
    configuration: socketConfiguration,
    sessionFactory: { identity in
      let gateway = try GatewayRuntime(
        configuration: configuration,
        context: configuration.executionContext(
          caller: identity.caller,
          profileID: profileID,
          transportTrace: identity.transportTrace
        ),
        database: database,
        registeredWorkspaces: [workspace]
      )
      let server = await MCPRuntimeAdapter.makeGatewayServer(
        configuration: configuration,
        registry: gateway
      )
      return GatewaySocketServerSession(server: server) {
        await gateway.shutdown()
      }
    }
  )
}

private func waitUntilSocketCondition(
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<500 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexAppServerProcessTransportError.launchFailed(
    "Timed out waiting for gateway socket lifecycle condition."
  )
}

private func waitForRuntimeReceipt(
  database: GatewayDatabase,
  processID: Int32,
  state: String
) async throws -> CodexRuntimeLeaseRecord {
  for _ in 0..<500 {
    if let receipt = try database.codexRuntimeLeases(limit: 100).first(where: {
      $0.process?.processID == processID && $0.state == state
    }) {
      return receipt
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexAppServerProcessTransportError.launchFailed(
    "Timed out waiting for runtime receipt state '\(state)'."
  )
}

private func availableCodexHTTPPort() throws -> Int {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw POSIXError(.EIO) }
  defer { close(descriptor) }

  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bindResult == 0 else { throw POSIXError(.EADDRINUSE) }

  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      getsockname(descriptor, $0, &length)
    }
  }
  guard nameResult == 0 else { throw POSIXError(.EIO) }
  return Int(UInt16(bigEndian: address.sin_port))
}

private func waitForPendingApproval(
  _ runtime: LiveCodexAppServerRuntime
) async throws -> CodexApprovalRecord {
  try await waitForApprovalState(runtime, state: .pending)
}

private func replaceWorkspacePlaceholder(_ value: JSONValue, with workspace: String) -> JSONValue {
  switch value {
  case .string(let string):
    return .string(string.replacingOccurrences(of: "__WORKSPACE__", with: workspace))
  case .array(let values):
    return .array(values.map { replaceWorkspacePlaceholder($0, with: workspace) })
  case .object(let object):
    return .object(
      Dictionary(
        uniqueKeysWithValues: object.map { key, value in
          (
            key.replacingOccurrences(of: "__WORKSPACE__", with: workspace),
            replaceWorkspacePlaceholder(value, with: workspace)
          )
        }
      )
    )
  case .number, .bool, .null:
    return value
  }
}

private func makeDynamicToolGateway(
  fixture: AppServerProcessFixture,
  database: GatewayDatabase,
  targetCapabilities: [String],
  workspaceURL: URL? = nil,
  builtins: [String]? = nil,
  cli: CLISectionConfig = CLISectionConfig()
) throws -> GatewayRuntime {
  let workspaceURL = workspaceURL ?? fixture.directory
  let capabilities =
    [
      "codex.app.thread.loaded.list",
      "codex.app.approvals.list",
      "codex.app.approvals.respond",
      "operations.prepare",
      "operations.commit",
    ] + targetCapabilities
  let configuration = GatewayConfiguration(
    schemaVersion: 1,
    runtime: RuntimeBindingConfig(caller: .localMCP, profileID: .localAdmin),
    profiles: [
      ProfileGrantConfig(
        id: .localAdmin,
        capabilities: capabilities,
        workspaces: ["fixture-workspace"],
        allowedCallers: [.localMCP]
      )
    ],
    cli: cli,
    builtin: BuiltinConfig(enabled: builtins ?? targetCapabilities),
    codex: CodexConfig(
      enabled: true,
      executable: fixture.executable.path,
      execEnabled: false,
      mcpEnabled: false,
      appServerTerminationGraceMilliseconds: 200,
      appServerKillGraceMilliseconds: 1_000,
      approvalPolicy: .onRequest
    )
  )
  return try GatewayRuntime(
    configuration: configuration,
    database: database,
    registeredWorkspaces: [
      RegisteredWorkspace(
        id: "fixture-workspace",
        displayName: "Fixture",
        rootPath: workspaceURL.path
      )
    ]
  )
}

private func waitForGatewayApproval(_ gateway: GatewayRuntime) async throws -> CodexApprovalRecord {
  for _ in 0..<500 {
    let response = try await gateway.callToolAsync(
      name: "codex.app.approvals.list",
      arguments: .object(["workspace_id": .string("fixture-workspace")])
    )
    let result = response.objectValue?["structuredContent"]?.objectValue?["result"]
    for value in result?.objectValue?["approvals"]?.arrayValue ?? [] {
      let data = try JSONEncoder().encode(value)
      let record = try JSONDecoder().decode(CodexApprovalRecord.self, from: data)
      if record.state == .pending {
        return record
      }
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexApprovalBrokerError.unknown("registered_tool")
}

private func runApprovedDynamicTool(
  name: String,
  arguments: JSONValue,
  callID: String,
  repository: URL,
  database: GatewayDatabase,
  capabilities: [String],
  builtins: [String],
  cli: CLISectionConfig
) async throws {
  let fixture = try AppServerProcessFixture()
  defer { fixture.remove() }
  try fixture.configureDynamicTool(name: name, arguments: arguments, callID: callID)
  let gateway = try makeDynamicToolGateway(
    fixture: fixture,
    database: database,
    targetCapabilities: capabilities,
    workspaceURL: repository,
    builtins: builtins,
    cli: cli
  )
  _ = try await gateway.callToolAsync(
    name: "codex.app.thread.loaded.list",
    arguments: .object(["workspace_id": .string("fixture-workspace")])
  )
  let pending = try await waitForGatewayApproval(gateway)
  #expect(pending.correlationID == callID)
  _ = try await gateway.callToolAsync(
    name: "codex.app.approvals.respond",
    arguments: .object([
      "workspace_id": .string("fixture-workspace"),
      "approval_id": .string(pending.id),
      "decision": .string("approve_once"),
    ])
  )
  let response = try await fixture.waitForApprovalResponse()
  #expect(response.contains("true"), "\(response)")
  await gateway.shutdown()
}

@discardableResult
private func runGit(_ arguments: [String], in repository: URL) throws -> String {
  let result = try ProcessCommandRunner().run(
    executable: "/usr/bin/git",
    arguments: arguments,
    workingDirectory: repository,
    environment: [:],
    timeoutMilliseconds: 10_000,
    maxOutputBytes: 1_048_576
  )
  guard result.exitCode == 0, !result.timedOut else {
    throw CodexAppServerProcessTransportError.launchFailed(
      "git \(arguments.joined(separator: " ")) failed: \(result.stderr)"
    )
  }
  return result.stdout
}

private struct InteractiveRequestFixture {
  let id: String
  let payload: JSONValue
}

private func waitForInteractiveRequest(
  _ runtime: LiveCodexAppServerRuntime,
  kind: String
) async throws -> InteractiveRequestFixture {
  for _ in 0..<500 {
    let response = await runtime.pendingRequests()
    for value in response.objectValue?["requests"]?.arrayValue ?? []
    where value.objectValue?["kind"] == .string(kind) {
      if let id = value.objectValue?["request_id"]?.stringValue,
        let payload = value.objectValue?["request"]
      {
        return InteractiveRequestFixture(id: id, payload: payload)
      }
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexApprovalBrokerError.unknown(kind)
}

private func waitForLatestApproval(
  _ runtime: LiveCodexAppServerRuntime
) async throws -> CodexApprovalRecord {
  for _ in 0..<500 {
    let response = try await runtime.approvals(state: nil, limit: 10)
    if let value = response.objectValue?["approvals"]?.arrayValue?.first {
      let data = try JSONEncoder().encode(value)
      return try JSONDecoder().decode(CodexApprovalRecord.self, from: data)
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexApprovalBrokerError.unknown("fixture")
}

private func waitForApprovalState(
  _ runtime: LiveCodexAppServerRuntime,
  approvalID: String? = nil,
  state: CodexApprovalState
) async throws -> CodexApprovalRecord {
  for _ in 0..<500 {
    let response = try await runtime.approvals(state: state.rawValue, limit: 10)
    let values = response.objectValue?["approvals"]?.arrayValue ?? []
    for value in values {
      let data = try JSONEncoder().encode(value)
      let record = try JSONDecoder().decode(CodexApprovalRecord.self, from: data)
      if approvalID == nil || record.id == approvalID {
        return record
      }
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexApprovalBrokerError.unknown(approvalID ?? "fixture")
}

extension Array where Element == Int32 {
  fileprivate func asyncAllSatisfy(
    _ predicate: (Int32) async -> Bool
  ) async -> Bool {
    for element in self where !(await predicate(element)) {
      return false
    }
    return true
  }
}

private func waitForProcessExit(_ processID: Int32) async -> Bool {
  for _ in 0..<500 {
    if !processExists(processID) {
      return true
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

private func waitForFileRemoval(_ url: URL) async -> Bool {
  for _ in 0..<500 {
    if !FileManager.default.fileExists(atPath: url.path) {
      return true
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

private func processExists(_ processID: Int32) -> Bool {
  errno = 0
  if kill(processID, 0) == 0 {
    return true
  }
  return errno != ESRCH
}

private actor CodexAppServerTimeoutProbe {
  private(set) var didTimeOut = false

  func recordTimeout() {
    didTimeOut = true
  }
}

private actor CodexAppServerRetryProbe {
  private(set) var attempts: [Int] = []

  func record(attempt: Int) {
    attempts.append(attempt)
  }
}

private actor CodexAppServerNonCooperativeProbe {
  private var continuation: CheckedContinuation<String, Never>?
  private var released = false

  func wait() async -> String {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if released {
          continuation.resume(returning: "released")
        } else {
          self.continuation = continuation
        }
      }
    } onCancel: {
      // This fixture deliberately ignores cancellation to model an RPC that is
      // still blocked while its transport is being retired.
    }
  }

  func release() {
    released = true
    continuation?.resume(returning: "released")
    continuation = nil
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  expectedCode: String? = nil,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    Issue.record("Expected expression to throw.")
  } catch {
    if let expectedCode {
      #expect(String(describing: error).contains("[\(expectedCode)]"))
    }
  }
}
