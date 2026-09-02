import Darwin
import Foundation
import Testing

@testable import ComputerMCP

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
  func testSecondOfficialAppServerResumesAfterOwnedRuntimeReleasesThread() async throws {
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
    var threadID: String?
    var turnID: String?
    var firstReleased = false
    do {
      let started = try await first.call(
        method: "thread/start",
        params: .object(["ephemeral": .bool(false)])
      )
      let createdThreadID = try #require(
        started.objectValue?["thread"]?.objectValue?["id"]?.stringValue
      )
      threadID = createdThreadID
      let turn = try await first.call(
        method: "turn/start",
        params: .object([
          "threadId": .string(createdThreadID),
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

      await first.shutdown()
      firstReleased = true
      #expect(await waitForExit(firstPID))

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

      _ = try await next.call(
        method: "thread/archive",
        params: .object(["threadId": .string(createdThreadID)])
      )
      await next.shutdown()
      #expect(await waitForExit(secondPID))
      second = nil

      let stopped = try database.codexRuntimeLeases(limit: 20).filter {
        $0.owner?.workspaceID == workspaceID && $0.state == "stopped"
      }
      #expect(stopped.count == 2)
      #expect(Set(stopped.compactMap { $0.process?.processID }) == [firstPID, secondPID])
    } catch {
      if !firstReleased, let threadID, let turnID {
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
}
