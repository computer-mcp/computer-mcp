import Darwin
import Foundation
import Testing

@testable import ComputerMCP

private enum RealCodexAcceptanceFixtureError: Error, LocalizedError {
  case commandFailed(String, String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let command, let stderr):
      return "Real acceptance fixture command failed (\(command)): \(stderr)"
    }
  }
}

@Suite(.serialized)
final class RealCodexAppServerAcceptanceTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_ACCEPTANCE"] == "1"
    )
  )
  func testSkillsListCompletesWithinTheOfficialRequestDeadline() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let executable =
      ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_EXECUTABLE"] ?? "codex"
    let runtime = LiveCodexAppServerRuntime(
      configuration: CodexConfig(
        enabled: true,
        executable: executable,
        execEnabled: false,
        mcpEnabled: false,
        appServerRequestTimeoutSeconds: 30,
        appServerTerminationGraceMilliseconds: 1_000,
        appServerKillGraceMilliseconds: 2_000,
        approvalPolicy: .never
      ),
      workspaceURL: workspace
    )
    let clock = ContinuousClock()
    let started = clock.now

    do {
      let response = try await runtime.call(
        method: "skills/list",
        params: .object(["forceReload": .bool(false)])
      )

      #expect(started.duration(to: clock.now) < .seconds(30))
      let entries = try #require(response.objectValue?["data"]?.arrayValue)
      #expect(entries.count == 1)
      #expect(entries.first?.objectValue?["cwd"] == .string(workspace.path))
      let ownedProcessID = await processID(runtime)
      await runtime.shutdown()
      if let ownedProcessID {
        #expect(await waitForExit(ownedProcessID))
      }
    } catch {
      let ownedProcessID = await processID(runtime)
      await runtime.shutdown()
      if let ownedProcessID {
        #expect(await waitForExit(ownedProcessID))
      }
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_ACCEPTANCE"] == "1"
    )
  )
  func testBoundedAppListCompletesAgainstOfficialAppServer() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let executable =
      ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_EXECUTABLE"] ?? "codex"
    let runtime = LiveCodexAppServerRuntime(
      configuration: CodexConfig(
        enabled: true,
        executable: executable,
        execEnabled: false,
        mcpEnabled: false,
        appServerRequestTimeoutSeconds: 30,
        appServerAppListTimeoutSeconds: 120,
        appServerTerminationGraceMilliseconds: 1_000,
        appServerKillGraceMilliseconds: 2_000,
        approvalPolicy: .never
      ),
      workspaceURL: workspace
    )
    let clock = ContinuousClock()
    let started = clock.now

    do {
      let response = try await runtime.call(
        method: "app/list",
        params: .object([
          "forceRefetch": .bool(false),
          "limit": .number(1),
        ])
      )
      let entries = try #require(response.objectValue?["data"]?.arrayValue)
      #expect(entries.count <= 1)
      #expect(started.duration(to: clock.now) < .seconds(120))
      let ownedProcessID = await processID(runtime)
      await runtime.shutdown()
      if let ownedProcessID {
        #expect(await waitForExit(ownedProcessID))
      }
    } catch {
      let ownedProcessID = await processID(runtime)
      await runtime.shutdown()
      if let ownedProcessID {
        #expect(await waitForExit(ownedProcessID))
      }
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_ACCEPTANCE"] == "1"
    )
  )
  func testScopedElevationPerformsGitAndLocalNetworkThenRevokes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cm-real-elevation-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
    let serverRoot = root.appendingPathComponent("Server", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try initializeRepository(at: workspace)

    let networkToken = "computer-mcp-elevation-\(UUID().uuidString)"
    try Data(networkToken.utf8).write(to: serverRoot.appendingPathComponent("probe.txt"))
    let serverPort = try reserveLoopbackPort()
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = [
      "-m", "http.server", String(serverPort), "--bind", "127.0.0.1", "--directory",
      serverRoot.path,
    ]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    try #require(await waitForHTTPServer(port: serverPort, token: networkToken))

    let database = try GatewayDatabase(inMemory: ())
    let workspaceID = "real-elevation-\(UUID().uuidString)"
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: workspaceID,
        displayName: "Real elevation acceptance",
        rootPath: workspace.path
      )
    )
    let executable =
      ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_EXECUTABLE"] ?? "codex"
    let model = realAcceptanceModel()
    let configuration = CodexConfig(
      enabled: true,
      executable: executable,
      execEnabled: false,
      mcpEnabled: false,
      appServerRequestTimeoutSeconds: 30,
      appServerTerminationGraceMilliseconds: 1_000,
      appServerKillGraceMilliseconds: 2_000,
      approvalPolicy: .never
    )
    let requester = CodexRuntimeOwner(
      workspaceID: workspaceID,
      profileID: GatewayProfileID.chatGPTOperate.rawValue,
      caller: GatewayCallerKind.secureTunnel.rawValue,
      transport: "openai-secure-mcp-tunnel",
      socketConnectionID: "real-elevation-remote",
      tunnelInstanceID: "real-elevation-tunnel",
      tunnelProfileID: GatewayProfileID.chatGPTOperate.rawValue
    )
    let localAdministrator = CodexRuntimeOwner(
      workspaceID: workspaceID,
      profileID: GatewayProfileID.localAdmin.rawValue,
      caller: GatewayCallerKind.localCLI.rawValue,
      transport: "control-socket",
      socketConnectionID: "real-elevation-local",
      tunnelInstanceID: nil,
      tunnelProfileID: nil
    )
    let runtime = LiveCodexAppServerRuntime(
      configuration: configuration,
      workspaceURL: workspace,
      owner: requester,
      database: database
    )
    var threadID: String?
    var currentTurnID: String?
    do {
      let started = try await runtime.call(
        method: "thread/start",
        params: .object([
          "ephemeral": .bool(false),
          "model": .string(model),
        ])
      )
      let createdThreadID = try #require(
        started.objectValue?["thread"]?.objectValue?["id"]?.stringValue
      )
      threadID = createdThreadID
      #expect(
        started.objectValue?["sandbox"]?.objectValue?["type"]
          != .string("dangerFullAccess")
      )

      let safeTurn = try await runtime.call(
        method: "turn/start",
        params: .object([
          "threadId": .string(createdThreadID),
          "effort": .string("low"),
          "model": .string(model),
          "input": .array([
            .object([
              "type": .string("text"),
              "text": .string(
                """
                This is a disposable automated sandbox check. Use exec_command once to run exactly:
                /bin/sleep 2; /usr/bin/touch .git/computer-mcp-safe-probe; /usr/bin/curl --silent --show-error --max-time 3 http://127.0.0.1:\(serverPort)/probe.txt > safe-network.txt
                Do not retry, ask for approval, or change any other file. Then finish the turn.
                """
              ),
            ])
          ]),
        ])
      )
      let safeTurnID = try #require(
        safeTurn.objectValue?["turn"]?.objectValue?["id"]?.stringValue
      )
      currentTurnID = safeTurnID

      let pending = try CodexElevationGrantService.request(
        owner: requester,
        database: database,
        threadID: createdThreadID,
        mode: .threadScopedTTL,
        reason: "Disposable Git and loopback-network acceptance.",
        maximumDurationSeconds: 300,
        maximumTurnCount: 5
      )
      _ = try CodexElevationGrantService.approve(
        id: pending.id,
        owner: localAdministrator,
        database: database
      )
      #expect(try database.codexElevationGrant(id: pending.id)?.state == .approved)
      try #require(await waitForIdle(runtime, threadID: createdThreadID, turnID: safeTurnID))
      currentTurnID = nil
      let safeTurnRecord = try await completedTurn(
        runtime,
        threadID: createdThreadID,
        turnID: safeTurnID
      )
      #expect(
        safeTurnRecord.objectValue?["status"] == .string("completed"),
        "Safe turn record: \(safeTurnRecord)"
      )
      #expect(
        !FileManager.default.fileExists(
          atPath: workspace.appendingPathComponent(".git/computer-mcp-safe-probe").path
        )
      )
      #expect(
        (try? String(contentsOf: workspace.appendingPathComponent("safe-network.txt")))
          != networkToken
      )

      let elevatedTurn = try await runtime.call(
        method: "turn/start",
        params: .object([
          "threadId": .string(createdThreadID),
          "effort": .string("low"),
          "model": .string(model),
          "input": .array([
            .object([
              "type": .string("text"),
              "text": .string(
                """
                This is a disposable automated full-access check. Use exec_command to run exactly:
                /usr/bin/printf 'elevated\n' > elevated.txt && /usr/bin/git add elevated.txt && /usr/bin/git -c user.name='Computer MCP Acceptance' -c user.email='acceptance@invalid.example' commit -m 'test: scoped elevation acceptance' && /usr/bin/curl --silent --show-error --max-time 3 http://127.0.0.1:\(serverPort)/probe.txt > elevated-network.txt
                Do not retry, ask for approval, push, or change any other file. Then finish the turn.
                """
              ),
            ])
          ]),
        ])
      )
      let elevatedTurnID = try #require(
        elevatedTurn.objectValue?["turn"]?.objectValue?["id"]?.stringValue
      )
      currentTurnID = elevatedTurnID
      try #require(
        await waitForIdle(runtime, threadID: createdThreadID, turnID: elevatedTurnID)
      )
      currentTurnID = nil
      let elevatedTurnRecord = try await completedTurn(
        runtime,
        threadID: createdThreadID,
        turnID: elevatedTurnID
      )
      #expect(
        elevatedTurnRecord.objectValue?["status"] == .string("completed"),
        "Elevated turn record: \(elevatedTurnRecord)"
      )
      #expect(
        try gitOutput(["log", "-1", "--pretty=%s"], at: workspace)
          == "test: scoped elevation acceptance"
      )
      #expect(
        try String(
          contentsOf: workspace.appendingPathComponent("elevated-network.txt"),
          encoding: .utf8
        ) == networkToken
      )
      let activated = try #require(try database.codexElevationGrant(id: pending.id))
      #expect(activated.state == .active)
      #expect(activated.consumedTurnIDs.contains(elevatedTurnID))

      _ = try CodexElevationGrantService.revoke(
        id: pending.id,
        owner: localAdministrator,
        database: database
      )
      let restoredTurn = try await runtime.call(
        method: "turn/start",
        params: .object([
          "threadId": .string(createdThreadID),
          "effort": .string("low"),
          "model": .string(model),
          "input": .array([
            .object([
              "type": .string("text"),
              "text": .string(
                """
                This is the disposable post-revocation check. Use exec_command once to run exactly:
                /usr/bin/touch .git/computer-mcp-restored-probe; /usr/bin/curl --silent --show-error --max-time 3 http://127.0.0.1:\(serverPort)/probe.txt > restored-network.txt
                Do not retry, ask for approval, or change any other file. Then finish the turn.
                """
              ),
            ])
          ]),
        ])
      )
      let restoredTurnID = try #require(
        restoredTurn.objectValue?["turn"]?.objectValue?["id"]?.stringValue
      )
      currentTurnID = restoredTurnID
      try #require(
        await waitForIdle(runtime, threadID: createdThreadID, turnID: restoredTurnID)
      )
      currentTurnID = nil
      #expect(
        !FileManager.default.fileExists(
          atPath: workspace.appendingPathComponent(".git/computer-mcp-restored-probe").path
        )
      )
      #expect(
        (try? String(contentsOf: workspace.appendingPathComponent("restored-network.txt")))
          != networkToken
      )

      let runtimePID = try #require(await processID(runtime))
      let released = try await CodexThreadHandoffService.release(
        threadID: createdThreadID,
        workspaceID: workspaceID,
        mode: .graceful,
        interruptActiveTurn: false,
        database: database
      )
      #expect(released.objectValue?["final_classification"] == .string("released_persisted"))
      #expect(await waitForExit(runtimePID))
      #expect(try database.codexElevationGrant(id: pending.id)?.state == .revoked)
      #expect(
        await archiveTemporaryThread(
          createdThreadID,
          configuration: configuration,
          workspaceURL: workspace
        )
      )
      threadID = nil
      #expect(await stopProcess(server))
    } catch {
      if let threadID, let currentTurnID {
        _ = try? await runtime.call(
          method: "turn/interrupt",
          params: .object([
            "threadId": .string(threadID),
            "turnId": .string(currentTurnID),
          ])
        )
      }
      #expect(await shutdownAndWaitForExit(runtime))
      if let threadID {
        #expect(
          await archiveTemporaryThread(
            threadID,
            configuration: configuration,
            workspaceURL: workspace
          )
        )
      }
      #expect(await stopProcess(server))
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_ACCEPTANCE"] == "1"
    )
  )
  func testApprovedGrantAppliesAtNewThreadStartAndFirstTurn() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("cm-real-startup-elevation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try initializeRepository(at: workspace)

    let database = try GatewayDatabase(inMemory: ())
    let workspaceID = "real-startup-elevation-\(UUID().uuidString)"
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: workspaceID,
        displayName: "Real startup elevation acceptance",
        rootPath: workspace.path
      )
    )
    let executable =
      ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_EXECUTABLE"] ?? "codex"
    let model = realAcceptanceModel()
    let configuration = CodexConfig(
      enabled: true,
      executable: executable,
      execEnabled: false,
      mcpEnabled: false,
      appServerRequestTimeoutSeconds: 30,
      appServerTerminationGraceMilliseconds: 1_000,
      appServerKillGraceMilliseconds: 2_000,
      approvalPolicy: .never
    )
    let requester = CodexRuntimeOwner(
      workspaceID: workspaceID,
      profileID: GatewayProfileID.chatGPTOperate.rawValue,
      caller: GatewayCallerKind.secureTunnel.rawValue,
      transport: "openai-secure-mcp-tunnel",
      socketConnectionID: "real-startup-elevation-remote",
      tunnelInstanceID: "real-startup-elevation-tunnel",
      tunnelProfileID: GatewayProfileID.chatGPTOperate.rawValue
    )
    let localAdministrator = CodexRuntimeOwner(
      workspaceID: workspaceID,
      profileID: GatewayProfileID.localAdmin.rawValue,
      caller: GatewayCallerKind.localCLI.rawValue,
      transport: "control-socket",
      socketConnectionID: "real-startup-elevation-local",
      tunnelInstanceID: nil,
      tunnelProfileID: nil
    )
    let pending = try CodexElevationGrantService.request(
      owner: requester,
      database: database,
      threadID: nil,
      mode: .boundedTime,
      reason: "Prove approved Full Access applies during cold thread startup.",
      maximumDurationSeconds: 300,
      maximumTurnCount: 3
    )
    _ = try CodexElevationGrantService.approve(
      id: pending.id,
      owner: localAdministrator,
      database: database
    )
    let runtime = LiveCodexAppServerRuntime(
      configuration: configuration,
      workspaceURL: workspace,
      owner: requester,
      database: database
    )
    var threadID: String?
    var turnID: String?
    do {
      let started = try await runtime.call(
        method: "thread/start",
        params: .object([
          "ephemeral": .bool(false),
          "model": .string(model),
        ])
      )
      let createdThreadID = try #require(
        started.objectValue?["thread"]?.objectValue?["id"]?.stringValue
      )
      threadID = createdThreadID
      #expect(
        started.objectValue?["sandbox"]?.objectValue?["type"]
          == .string("dangerFullAccess")
      )
      let activated = try #require(try database.codexElevationGrant(id: pending.id))
      #expect(activated.state == .active)
      #expect(activated.threadID == createdThreadID)

      let firstTurn = try await runtime.call(
        method: "turn/start",
        params: .object([
          "threadId": .string(createdThreadID),
          "effort": .string("low"),
          "model": .string(model),
          "input": .array([
            .object([
              "type": .string("text"),
              "text": .string(
                "Reply with exactly STARTUP_FULL_ACCESS_OK. Do not inspect or modify files, run commands, or call tools."
              ),
            ])
          ]),
        ])
      )
      let createdTurnID = try #require(
        firstTurn.objectValue?["turn"]?.objectValue?["id"]?.stringValue
      )
      turnID = createdTurnID
      try #require(
        await waitForIdle(runtime, threadID: createdThreadID, turnID: createdTurnID)
      )
      turnID = nil
      let firstTurnRecord = try await completedTurn(
        runtime,
        threadID: createdThreadID,
        turnID: createdTurnID
      )
      #expect(
        firstTurnRecord.objectValue?["status"] == .string("completed"),
        "Startup turn record: \(firstTurnRecord)"
      )
      let afterFirstTurn = try #require(
        try database.codexElevationGrant(id: pending.id)
      )
      #expect(afterFirstTurn.consumedTurnIDs.contains(createdTurnID))
      #expect(afterFirstTurn.consumedRuntimeIDs.contains(runtime.runtimeID))

      _ = try CodexElevationGrantService.revoke(
        id: pending.id,
        owner: localAdministrator,
        database: database
      )
      let runtimePID = try #require(await processID(runtime))
      _ = try await CodexThreadHandoffService.release(
        threadID: createdThreadID,
        workspaceID: workspaceID,
        mode: .graceful,
        interruptActiveTurn: false,
        database: database
      )
      #expect(await waitForExit(runtimePID))
      #expect(
        await archiveTemporaryThread(
          createdThreadID,
          configuration: configuration,
          workspaceURL: workspace
        )
      )
      threadID = nil
    } catch {
      if let threadID, let turnID {
        _ = try? await runtime.call(
          method: "turn/interrupt",
          params: .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
          ])
        )
      }
      #expect(await shutdownAndWaitForExit(runtime))
      if let threadID {
        #expect(
          await archiveTemporaryThread(
            threadID,
            configuration: configuration,
            workspaceURL: workspace
          )
        )
      }
      throw error
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_ACCEPTANCE"] == "1"
    )
  )
  func testDeterministicHandoffAllowsBidirectionalOfficialClaimWithoutOrphan() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let git = try ProcessCommandRunner().run(
      executable: "/usr/bin/git",
      arguments: ["init", "-q"],
      workingDirectory: workspace,
      environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
      timeoutMilliseconds: 10_000,
      maxOutputBytes: 1_048_576
    )
    #expect(git.exitCode == 0)

    let database = try GatewayDatabase(inMemory: ())
    let workspaceID = "real-codex-acceptance"
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: workspaceID,
        displayName: "Real Codex acceptance",
        rootPath: workspace.path
      )
    )
    let executable =
      ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_EXECUTABLE"] ?? "codex"
    let model = realAcceptanceModel()
    let configuration = CodexConfig(
      enabled: true,
      executable: executable,
      execEnabled: false,
      mcpEnabled: false,
      appServerRequestTimeoutSeconds: 30,
      appServerTerminationGraceMilliseconds: 1_000,
      appServerKillGraceMilliseconds: 2_000,
      approvalPolicy: .never
    )
    let owner = CodexRuntimeOwner(
      workspaceID: workspaceID,
      profileID: GatewayProfileID.localAdmin.rawValue,
      caller: GatewayCallerKind.localMCP.rawValue,
      transport: "real_acceptance",
      socketConnectionID: "real-acceptance-generation-1",
      tunnelInstanceID: nil,
      tunnelProfileID: nil
    )
    let first = LiveCodexAppServerRuntime(
      configuration: configuration,
      workspaceURL: workspace,
      owner: owner,
      database: database
    )
    var second: LiveCodexAppServerRuntime?
    var third: LiveCodexAppServerRuntime?
    var threadID: String?
    var turnID: String?
    do {
      let started = try await first.call(
        method: "thread/start",
        params: .object([
          "ephemeral": .bool(false),
          "model": .string(model),
        ])
      )
      let createdThreadID = try #require(
        started.objectValue?["thread"]?.objectValue?["id"]?.stringValue
      )
      threadID = createdThreadID
      _ = try await first.call(
        method: "thread/goal/set",
        params: .object([
          "threadId": .string(createdThreadID),
          "objective": .string("Prove deterministic bidirectional handoff."),
        ])
      )
      let turn = try await first.call(
        method: "turn/start",
        params: .object([
          "threadId": .string(createdThreadID),
          "effort": .string("low"),
          "model": .string(model),
          "input": .array([
            .object([
              "type": .string("text"),
              "text": .string(
                "Reply with exactly OK. Do not inspect or modify files, run commands, or call tools."
              ),
            ])
          ]),
        ])
      )
      let createdTurnID = try #require(
        turn.objectValue?["turn"]?.objectValue?["id"]?.stringValue
      )
      turnID = createdTurnID
      try #require(
        await waitForIdle(first, threadID: createdThreadID, turnID: createdTurnID)
      )
      let firstPID = try #require(await processID(first))

      let firstRelease = try await CodexThreadHandoffService.release(
        threadID: createdThreadID,
        workspaceID: workspaceID,
        mode: .graceful,
        interruptActiveTurn: false,
        database: database
      )
      #expect(firstRelease.objectValue?["final_classification"] == .string("released_persisted"))
      #expect(firstRelease.objectValue?["externally_claimable"] == .bool(true))
      #expect(
        firstRelease.objectValue?["computer_mcp_writer_ownership_remaining"] == .bool(false)
      )
      #expect(await waitForExit(firstPID))
      #expect(
        await CodexRuntimeDirectory.shared.runtimeIDs(
          owning: createdThreadID,
          workspaceID: workspaceID
        ).isEmpty
      )

      let nextOwner = CodexRuntimeOwner(
        workspaceID: workspaceID,
        profileID: GatewayProfileID.localAdmin.rawValue,
        caller: GatewayCallerKind.localMCP.rawValue,
        transport: "real_acceptance",
        socketConnectionID: "real-acceptance-generation-2",
        tunnelInstanceID: nil,
        tunnelProfileID: nil
      )
      let next = LiveCodexAppServerRuntime(
        configuration: configuration,
        workspaceURL: workspace,
        owner: nextOwner,
        database: database
      )
      second = next
      let resumed = try await next.call(
        method: "thread/resume",
        params: .object(["threadId": .string(createdThreadID)])
      )
      #expect(
        resumed.objectValue?["thread"]?.objectValue?["id"] == .string(createdThreadID)
      )
      let secondPID = try #require(await processID(next))
      #expect(secondPID != firstPID)

      let secondRelease = try await CodexThreadHandoffService.release(
        threadID: createdThreadID,
        workspaceID: workspaceID,
        mode: .graceful,
        interruptActiveTurn: false,
        database: database
      )
      #expect(
        secondRelease.objectValue?["final_classification"] == .string("released_persisted")
      )
      #expect(await waitForExit(secondPID))
      second = nil

      let finalOwner = CodexRuntimeOwner(
        workspaceID: workspaceID,
        profileID: GatewayProfileID.localAdmin.rawValue,
        caller: GatewayCallerKind.localMCP.rawValue,
        transport: "real_acceptance",
        socketConnectionID: "real-acceptance-generation-3",
        tunnelInstanceID: nil,
        tunnelProfileID: nil
      )
      let finalRuntime = LiveCodexAppServerRuntime(
        configuration: configuration,
        workspaceURL: workspace,
        owner: finalOwner,
        database: database
      )
      third = finalRuntime
      let resumedBack = try await finalRuntime.call(
        method: "thread/resume",
        params: .object(["threadId": .string(createdThreadID)])
      )
      #expect(
        resumedBack.objectValue?["thread"]?.objectValue?["id"] == .string(createdThreadID)
      )
      let goal = try await finalRuntime.call(
        method: "thread/goal/get",
        params: .object(["threadId": .string(createdThreadID)])
      )
      #expect(
        goal.objectValue?["goal"]?.objectValue?["objective"]
          == .string("Prove deterministic bidirectional handoff.")
      )
      let thirdPID = try #require(await processID(finalRuntime))
      let finalRelease = try await CodexThreadHandoffService.release(
        threadID: createdThreadID,
        workspaceID: workspaceID,
        mode: .graceful,
        interruptActiveTurn: false,
        database: database
      )
      #expect(finalRelease.objectValue?["goal_preservation"] == .string("persisted-and-unchanged"))
      #expect(await waitForExit(thirdPID))
      third = nil

      #expect(
        await archiveTemporaryThread(
          createdThreadID,
          configuration: configuration,
          workspaceURL: workspace
        )
      )
      threadID = nil

      let stopped = try database.codexRuntimeLeases(limit: 20).filter {
        $0.owner?.workspaceID == workspaceID && $0.state == "stopped"
      }
      #expect(stopped.count == 3)
      #expect(
        Set(stopped.compactMap { $0.process?.processID }) == [firstPID, secondPID, thirdPID]
      )
    } catch {
      if let threadID, let turnID {
        _ = try? await first.call(
          method: "turn/interrupt",
          params: .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
          ])
        )
      }
      #expect(await shutdownAndWaitForExit(first))
      if let second {
        #expect(await shutdownAndWaitForExit(second))
      }
      if let third {
        #expect(await shutdownAndWaitForExit(third))
      }
      if let threadID {
        #expect(
          await archiveTemporaryThread(
            threadID,
            configuration: configuration,
            workspaceURL: workspace
          )
        )
      }
      throw error
    }
  }

  private func initializeRepository(at workspace: URL) throws {
    try Data("initial\n".utf8).write(to: workspace.appendingPathComponent("README.md"))
    for arguments in [
      ["init", "-q"],
      ["add", "README.md"],
      [
        "-c", "user.name=Computer MCP Acceptance", "-c",
        "user.email=acceptance@invalid.example", "commit", "-q", "-m", "initial",
      ],
    ] {
      let result = try ProcessCommandRunner().run(
        executable: "/usr/bin/git",
        arguments: arguments,
        workingDirectory: workspace,
        environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
        timeoutMilliseconds: 10_000,
        maxOutputBytes: 1_048_576
      )
      guard result.exitCode == 0 else {
        throw RealCodexAcceptanceFixtureError.commandFailed(
          "git \(arguments.joined(separator: " "))",
          result.stderr
        )
      }
    }
  }

  private func realAcceptanceModel() -> String {
    ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_MODEL"] ?? "gpt-5.4"
  }

  private func gitOutput(_ arguments: [String], at workspace: URL) throws -> String {
    let result = try ProcessCommandRunner().run(
      executable: "/usr/bin/git",
      arguments: arguments,
      workingDirectory: workspace,
      environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
      timeoutMilliseconds: 10_000,
      maxOutputBytes: 1_048_576
    )
    guard result.exitCode == 0 else {
      throw RealCodexAcceptanceFixtureError.commandFailed(
        "git \(arguments.joined(separator: " "))",
        result.stderr
      )
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func reserveLoopbackPort() throws -> Int {
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

  private func waitForHTTPServer(port: Int, token: String) async -> Bool {
    for _ in 0..<40 {
      if let result = try? ProcessCommandRunner().run(
        executable: "/usr/bin/curl",
        arguments: [
          "--silent", "--show-error", "--max-time", "1",
          "http://127.0.0.1:\(port)/probe.txt",
        ],
        workingDirectory: nil,
        environment: ["NO_PROXY": "127.0.0.1,localhost"],
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 8_192
      ), result.exitCode == 0,
        result.stdout == token
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  private func stopProcess(_ process: Process) async -> Bool {
    let processID = process.processIdentifier
    if process.isRunning {
      process.terminate()
    }
    if await waitForExit(processID) {
      return true
    }
    Darwin.kill(processID, SIGKILL)
    return await waitForExit(processID)
  }

  private func shutdownAndWaitForExit(_ runtime: LiveCodexAppServerRuntime) async -> Bool {
    let ownedProcessID = await processID(runtime)
    await runtime.shutdown()
    guard let ownedProcessID else {
      return true
    }
    return await waitForExit(ownedProcessID)
  }

  private func archiveTemporaryThread(
    _ threadID: String,
    configuration: CodexConfig,
    workspaceURL: URL
  ) async -> Bool {
    let cleanup = LiveCodexAppServerRuntime(
      configuration: configuration,
      workspaceURL: workspaceURL
    )
    do {
      _ = try await cleanup.call(
        method: "thread/archive",
        params: .object(["threadId": .string(threadID)])
      )
      return await shutdownAndWaitForExit(cleanup)
    } catch {
      let exited = await shutdownAndWaitForExit(cleanup)
      if !exited {
        Issue.record("Temporary real-client cleanup App Server did not exit")
      }
      Issue.record("Failed to archive temporary real-client thread \(threadID): \(error)")
      return false
    }
  }

  private func processID(_ runtime: LiveCodexAppServerRuntime) async -> Int32? {
    await runtime.status().objectValue?["process"]?.objectValue?["process_id"]?.intValue
      .flatMap(Int32.init)
  }

  private func waitForExit(_ processID: Int32) async -> Bool {
    for _ in 0..<500 {
      errno = 0
      if kill(processID, 0) != 0, errno == ESRCH {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  private func waitForIdle(
    _ runtime: LiveCodexAppServerRuntime,
    threadID: String,
    turnID: String
  ) async -> Bool {
    for _ in 0..<1_200 {
      let thread = await runtime.status().objectValue?["threads"]?.arrayValue?.first {
        $0.objectValue?["thread_id"] == .string(threadID)
      }
      let state = thread?.objectValue?["state"]
      let isIdle = state == .string("idle") || state?.objectValue?["type"] == .string("idle")
      let activeTurnID = thread?.objectValue?["active_turn_id"]?.stringValue
      if isIdle, activeTurnID != turnID {
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func completedTurn(
    _ runtime: LiveCodexAppServerRuntime,
    threadID: String,
    turnID: String
  ) async throws -> JSONValue {
    let response = try await runtime.call(
      method: "thread/read",
      params: .object([
        "threadId": .string(threadID),
        "includeTurns": .bool(true),
      ])
    )
    return try #require(
      response.objectValue?["thread"]?.objectValue?["turns"]?.arrayValue?.first {
        $0.objectValue?["id"] == .string(turnID)
      }
    )
  }
}
