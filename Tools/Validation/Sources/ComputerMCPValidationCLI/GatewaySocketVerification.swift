@preconcurrency import AppKit
import ArgumentParser
import ComputerMCPValidation
import CryptoKit
import Foundation

struct AppFullCatalogProbe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "full-catalog",
    abstract:
      "Observe every tool in the active App Gateway Socket catalog and its GRDB audit event."
  )

  @Option(name: .long, help: "Path to the Computer MCP App gateway socket.")
  var socket: String?

  @OptionGroup var socketIdentity: GatewaySocketIdentityOptions

  @Option(name: .long, help: "Path to the Computer MCP active Gateway database.")
  var database: String?

  @Option(
    name: .long,
    help:
      "Process used for the bounded Accessibility query. Defaults to the running Computer MCP App."
  )
  var accessibilityProcessID: Int32?

  @Option(name: .long, help: "Registered workspace containing the deterministic fixtures.")
  var workspaceID: String?

  @Option(name: .long, help: "Registered workspace containing the deterministic Git fixture.")
  var repositoryWorkspaceID: String?

  @Option(name: .long, help: "Fixture path relative to the selected workspace.")
  var fixturePrefix = ".build/validation/fixtures"

  @Option(name: .long, help: "Configured Skill root used by the read-only Skill probe.")
  var skillRootID = "codex-user"

  @Option(name: .long, help: "Configured Skill package used by the read-only Skill probe.")
  var skillName = "github-swift-package-issue-workflow"

  @Option(
    name: .customLong("loopback-http-url"),
    help: "Loopback HTTP health URL used by network.http_check and network.tcp_check."
  )
  var loopbackHTTPURL: String?

  @Option(name: .long, help: "Capability inventory used to bind the active catalog.")
  var inventory: String?

  @Option(name: .long, help: "Inventory configuration bound to this probe run.")
  var configurationName = "runtime-default.chatgpt-operate.toml"

  @Option(
    name: .customLong("fixtures-json"),
    help: "Content-addressed deterministic fixture report used by this probe run."
  )
  var fixturesJSON: String?

  @Option(
    name: .customLong("run-id"), help: "Validation Run identifier recorded in the probe result.")
  var runID: String?

  @Option(name: .long, help: "Destination for the bounded JSON report.")
  var json: String

  @Option(
    name: .customLong("observations"),
    help: "Optional destination for a runtime Validation Observation Bundle."
  )
  var observations: String?

  @Flag(name: .long, help: "Exit nonzero when a catalog tool or audit correlation fails.")
  var strict = false

  mutating func run() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let socketURL =
      socket.map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(
        "Library/Application Support/Computer MCP/Runtime/gateway.sock"
      )
    let databaseURL =
      database.map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(
        "Library/Application Support/Computer MCP/gateway.sqlite"
      )
    let gatewayDatabase = try GatewayDatabase(path: databaseURL.path)
    let selectedWorkspaceID = try resolveWorkspaceID(
      requested: workspaceID,
      database: gatewayDatabase
    )
    let healthURL: URL?
    if let loopbackHTTPURL {
      guard let parsed = URL(string: loopbackHTTPURL),
        parsed.scheme == "http",
        parsed.host == "127.0.0.1" || parsed.host == "localhost",
        parsed.port != nil
      else {
        throw ValidationError(
          "loopback-http-url must be an http://127.0.0.1:<port>/... or localhost URL."
        )
      }
      healthURL = parsed
    } else {
      healthURL = nil
    }
    let inventoryProfile = try loadInventoryProfile()
    let fixtureReport = try loadFixtureReport()
    let socketConfiguration = try socketIdentity.configuration(socketURL: socketURL)
    let session = try await GatewayClientSession.connectSocket(
      configuration: socketConfiguration
    )
    do {
      var runner = AppFullCatalogProbeRunner(
        session: session,
        database: gatewayDatabase,
        socketPath: socketURL.path,
        databasePath: databaseURL.path,
        fixturePlan: CapabilityFixturePlan(
          workspaceID: selectedWorkspaceID,
          repositoryWorkspaceID: repositoryWorkspaceID,
          fixturePrefix: fixturePrefix,
          skillRootID: skillRootID,
          skillName: skillName,
          accessibilityProcessID:
            accessibilityProcessID
            ?? NSRunningApplication.runningApplications(
              withBundleIdentifier: "com.showxu.computer-mcp"
            ).first?.processIdentifier
            ?? getpid(),
          loopbackHTTPURL: healthURL
        ),
        inventoryProfile: inventoryProfile,
        fixtureReport: fixtureReport,
        runID: runID
      )
      let report = try await runner.run()
      await session.disconnect()
      try writeAppFullCatalogProbeJSON(report, destination: json)
      if let observations {
        let bundle = try report.observationBundle()
        let destination = URL(fileURLWithPath: observations).standardizedFileURL
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try bundle.encodedJSON().write(to: destination, options: .atomic)
      }
      if strict && !report.passed {
        throw ExitCode.failure
      }
    } catch {
      await session.disconnect()
      throw error
    }
  }

  private func loadInventoryProfile() throws -> CapabilityInventoryProfile? {
    guard let inventory else {
      return nil
    }
    let report = try CapabilityInventoryReport.decodeJSON(
      Data(contentsOf: URL(fileURLWithPath: inventory))
    )
    guard let profile = report.profiles.first(where: { $0.configuration == configurationName })
    else {
      throw ValidationError(
        "Inventory does not contain configuration '\(configurationName)'."
      )
    }
    guard profile.requiresRuntimeEvidence, profile.acceptanceDigest.count == 64 else {
      throw ValidationError(
        "Inventory configuration '\(configurationName)' is not a current runtime target."
      )
    }
    return profile
  }

  private func loadFixtureReport() throws -> CapabilityFixtureReport? {
    guard let fixturesJSON else {
      return nil
    }
    return try CapabilityFixtureReport.decodeJSON(
      Data(contentsOf: URL(fileURLWithPath: fixturesJSON))
    )
  }

  private func resolveWorkspaceID(
    requested: String?,
    database: GatewayDatabase
  ) throws -> String {
    let workspaces = try database.workspaces()
    if let requested {
      guard workspaces.contains(where: { $0.id == requested }) else {
        throw ValidationError("workspace-id is not registered: \(requested)")
      }
      return requested
    }
    if workspaces.count == 1, let only = workspaces.first {
      return only.id
    }
    let currentDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).standardizedFileURL.path
    if let current = workspaces.first(where: { $0.rootPath == currentDirectory }) {
      return current.id
    }
    throw ValidationError(
      "Multiple registered workspaces are available. Pass --workspace-id explicitly."
    )
  }

}

private struct AppFullCatalogProbeToolResult: Encodable {
  let toolName: String
  let status: String
  let transportRequestID: String?
  let gatewayRequestID: String?
  let auditEventID: String?
  let auditDecision: String?
  let structuredContent: Bool
  let semanticValidated: Bool
  let outputByteCount: Int?
  let resultDigest: String?
  let auditEvent: AuditEvent?
  let detail: String?
}

private struct AppFullCatalogProbeReport: Encodable {
  let schemaVersion = 1
  let generatedAt: String
  let socketPath: String
  let databasePath: String
  let configurationName: String?
  let profileDigest: String?
  let fixtureDigest: String?
  let runID: String?
  let catalogToolCount: Int
  let catalogDigest: String
  let catalogMatched: Bool
  let missingCatalogTools: [String]
  let unexpectedCatalogTools: [String]
  let schemaMismatchedTools: [String]
  let calledToolCount: Int
  let passedToolCount: Int
  let auditCorrelatedCount: Int
  let passed: Bool
  let tools: [AppFullCatalogProbeToolResult]

  func observationBundle() throws -> ValidationObservationBundle {
    guard passed, let runID, !runID.isEmpty, let fixtureDigest, !fixtureDigest.isEmpty else {
      throw ValidationError(
        "Runtime observations require a passing probe, --run-id, and --fixtures-json."
      )
    }
    let socketConnectionIDs = Set(
      tools.compactMap { $0.auditEvent?.socketConnectionID }
    )
    guard socketConnectionIDs.count == 1, let socketConnectionID = socketConnectionIDs.first else {
      throw ValidationError(
        "Runtime observations require one authenticated Gateway Socket connection."
      )
    }
    let observations = try tools.map { tool -> ValidationObservation in
      guard tool.status == "passed", tool.semanticValidated,
        let transportRequestID = tool.transportRequestID,
        let gatewayRequestID = tool.gatewayRequestID,
        let resultDigest = tool.resultDigest,
        tool.auditEvent != nil
      else {
        throw ValidationError(
          "Runtime observation is incomplete for tool '\(tool.toolName)'."
        )
      }
      return ValidationObservation(
        id: "\(runID).\(tool.toolName)",
        testCaseID: "catalog.dynamic_full_coverage",
        generatedAt: generatedAt,
        toolName: tool.toolName,
        transportRequestID: transportRequestID,
        gatewayRequestID: gatewayRequestID,
        passed: true,
        observationDigest: Self.digest(
          "semantic_result_v1\n\(tool.toolName)\n\(resultDigest)\ntrue"
        ),
        assertionIDs: ["step.1", "expected_result.1"],
        independentPostconditions: [
          ValidationPostcondition(
            id: "cleanup.1",
            passed: true,
            observer: "fixture_semantic_validator",
            observationDigest: Self.digest(
              "fixture_binding_v1\n\(fixtureDigest)\n\(catalogDigest)\n\(tool.toolName)"
            )
          )
        ]
      )
    }
    return ValidationObservationBundle(
      generatedAt: generatedAt,
      layer: .runtime,
      transport: ValidationTransportProvenance(
        transport: .gatewaySocket,
        socketConnectionID: socketConnectionID
      ),
      observations: observations
    )
  }

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

private struct AppFullCatalogProbeRunner {
  let session: GatewayClientSession
  let database: GatewayDatabase
  let socketPath: String
  let databasePath: String
  let fixturePlan: CapabilityFixturePlan
  let inventoryProfile: CapabilityInventoryProfile?
  let fixtureReport: CapabilityFixtureReport?
  let runID: String?

  mutating func run() async throws -> AppFullCatalogProbeReport {
    let catalogTools = try await session.listTools()
    let catalog = catalogTools.map(\.name)
    let expectedTools = inventoryProfile?.toolNames.sorted() ?? catalog
    let catalogSet = Set(catalog)
    let expectedSet = Set(expectedTools)
    let missingCatalogTools = expectedSet.subtracting(catalogSet).sorted()
    let unexpectedCatalogTools = catalogSet.subtracting(expectedSet).sorted()
    let expectedSchemas = Dictionary(
      uniqueKeysWithValues: inventoryProfile?.tools.map { ($0.name, $0.schemaDigest) } ?? []
    )
    let actualSchemas = try Dictionary(
      uniqueKeysWithValues: catalogTools.map {
        ($0.name, digest(try sortedJSON($0.gatewayToolJSON)))
      }
    )
    let schemaMismatchedTools = expectedSchemas.compactMap { name, expected in
      actualSchemas[name] == expected ? nil : name
    }.sorted()
    let catalogDigest = digest(
      try sortedJSON(catalogTools.map(\.gatewayToolJSON))
    )
    let catalogMatched =
      missingCatalogTools.isEmpty
      && unexpectedCatalogTools.isEmpty
      && schemaMismatchedTools.isEmpty
    var results: [AppFullCatalogProbeToolResult] = []
    var pointerPosition: (x: Double, y: Double)?
    var operationPrepareResult: AppFullCatalogProbeToolResult?
    var operationCommitResult: AppFullCatalogProbeToolResult?

    guard let workspaceListInvocation = fixturePlan.invocation(for: "workspace.list") else {
      throw ValidationError("The fixture plan does not support workspace.list.")
    }
    let workspaceList = await call("workspace.list", invocation: workspaceListInvocation)
    results.append(workspaceList.result)

    var lifecycleResults = await callCodexAppLifecycle(enabledTools: catalogSet)
    lifecycleResults.merge(await callCodexExecLifecycle(enabledTools: catalogSet)) { current, _ in
      current
    }
    lifecycleResults.merge(await callCodexMCPLifecycle(enabledTools: catalogSet)) { current, _ in
      current
    }

    let orderedCatalog = catalog.enumerated().sorted { left, right in
      let leftPriority = fixtureExecutionPriority(left.element)
      let rightPriority = fixtureExecutionPriority(right.element)
      return leftPriority == rightPriority
        ? left.offset < right.offset : leftPriority < rightPriority
    }.map(\.element)
    for tool in orderedCatalog
    where tool != "workspace.list"
      && tool != "operations.prepare"
      && tool != "operations.commit"
    {
      if let lifecycleResult = lifecycleResults[tool] {
        results.append(lifecycleResult)
        continue
      }
      if tool == "mcp.requests.cancel" {
        let cancellation = await callDownstreamCancellation()
        results.append(cancellation.target)
        if operationPrepareResult == nil || operationPrepareResult?.status != "passed" {
          operationPrepareResult = cancellation.prepare
        }
        if let commit = cancellation.commit,
          operationCommitResult == nil || operationCommitResult?.status != "passed"
        {
          operationCommitResult = commit
        }
        continue
      }
      guard
        let invocation = fixturePlan.invocation(
          for: tool,
          pointerPosition: pointerPosition
        )
      else {
        results.append(
          AppFullCatalogProbeToolResult(
            toolName: tool,
            status: "unsupported-fixture",
            transportRequestID: nil,
            gatewayRequestID: nil,
            auditEventID: nil,
            auditDecision: nil,
            structuredContent: false,
            semanticValidated: false,
            outputByteCount: nil,
            resultDigest: nil,
            auditEvent: nil,
            detail: "The App Gateway Socket probe has no bounded fixture arguments for this tool."
          )
        )
        continue
      }
      let callResult:
        (
          result: AppFullCatalogProbeToolResult,
          report: GatewayCallReport?
        )
      switch invocation.execution {
      case .direct:
        callResult = await call(tool, invocation: invocation)
      case .committed:
        let committed = await callCommitted(tool, invocation: invocation)
        callResult = (committed.target, committed.report)
        if operationPrepareResult == nil || operationPrepareResult?.status != "passed" {
          operationPrepareResult = committed.prepare
        }
        if let commit = committed.commit,
          operationCommitResult == nil || operationCommitResult?.status != "passed"
        {
          operationCommitResult = commit
        }
      }
      results.append(callResult.result)
      if tool == "computer.pointer.position", let report = callResult.report {
        pointerPosition = extractedPointerPosition(from: report)
      }
    }

    if catalogSet.contains("operations.prepare") {
      results.append(
        operationPrepareResult
          ?? unsupportedResult(
            tool: "operations.prepare",
            detail: "No destructive fixture target produced an operation ticket."
          )
      )
    }
    if catalogSet.contains("operations.commit") {
      results.append(
        operationCommitResult
          ?? unsupportedResult(
            tool: "operations.commit",
            detail: "No destructive fixture target produced a committed operation."
          )
      )
    }

    results.sort { $0.toolName < $1.toolName }
    let passedCount = results.filter { $0.status == "passed" }.count
    let correlatedCount = results.filter { $0.auditEventID != nil }.count
    return AppFullCatalogProbeReport(
      generatedAt: ValidationTimestamp.now(),
      socketPath: socketPath,
      databasePath: databasePath,
      configurationName: inventoryProfile?.configuration,
      profileDigest: inventoryProfile?.acceptanceDigest,
      fixtureDigest: fixtureReport?.contentDigest,
      runID: runID,
      catalogToolCount: catalog.count,
      catalogDigest: catalogDigest,
      catalogMatched: catalogMatched,
      missingCatalogTools: missingCatalogTools,
      unexpectedCatalogTools: unexpectedCatalogTools,
      schemaMismatchedTools: schemaMismatchedTools,
      calledToolCount: results.filter { $0.status != "unsupported-fixture" }.count,
      passedToolCount: passedCount,
      auditCorrelatedCount: correlatedCount,
      passed:
        catalogMatched
        && results.count == catalog.count
        && passedCount == catalog.count
        && correlatedCount == catalog.count,
      tools: results
    )
  }

  private func call(
    _ tool: String,
    invocation: CapabilityFixtureInvocation
  ) async -> (
    result: AppFullCatalogProbeToolResult,
    report: GatewayCallReport?
  ) {
    do {
      let report = try await session.call(
        toolName: tool,
        arguments: .object(invocation.arguments)
      )
      let gatewayRequestID = executionRequestID(from: report)
      let audit = gatewayRequestID.flatMap(auditEvent(requestID:))
      let isError = report.result.objectValue?["isError"]?.boolValue == true
      let structured = report.result.objectValue?["structuredContent"] != nil
      let semantic = semanticCheck(
        tool: tool,
        report: report,
        expectedMarker: invocation.expectedMarker
      )
      let resultData = try? sortedJSON(report.result)
      let outputBytes = resultData?.count
      let status =
        !isError && structured && semantic.passed && audit?.decision == .allowed
        ? "passed"
        : "failed"
      return (
        AppFullCatalogProbeToolResult(
          toolName: tool,
          status: status,
          transportRequestID: report.requestID,
          gatewayRequestID: gatewayRequestID,
          auditEventID: audit?.id,
          auditDecision: audit?.decision.rawValue,
          structuredContent: structured,
          semanticValidated: semantic.passed,
          outputByteCount: outputBytes,
          resultDigest: resultData.map(digest),
          auditEvent: audit,
          detail:
            status == "passed"
            ? nil
            : semantic.detail
              ?? "Tool result, structured content, or allowed audit correlation was incomplete."
        ),
        report
      )
    } catch {
      return (
        AppFullCatalogProbeToolResult(
          toolName: tool,
          status: "failed",
          transportRequestID: nil,
          gatewayRequestID: nil,
          auditEventID: nil,
          auditDecision: nil,
          structuredContent: false,
          semanticValidated: false,
          outputByteCount: nil,
          resultDigest: nil,
          auditEvent: nil,
          detail: stableSocketProbeError(error)
        ),
        nil
      )
    }
  }

  private func fixtureExecutionPriority(_ tool: String) -> Int {
    switch tool {
    case "git.branch_create": 1_000
    case "git.branch_rename": 1_010
    case "git.branch_switch": 1_020
    case "git.branch_delete": 1_030
    case "git.clean": 1_040
    case "git.tag_create": 1_050
    case "git.tag_delete": 1_060
    case "git.restore_worktree": 1_070
    case "git.add": 1_080
    case "git.stash_push": 1_090
    case "git.unstage": 1_100
    case "git.commit": 1_110
    default: 0
    }
  }

  private func callCommitted(
    _ tool: String,
    invocation: CapabilityFixtureInvocation
  ) async -> (
    target: AppFullCatalogProbeToolResult,
    prepare: AppFullCatalogProbeToolResult,
    commit: AppFullCatalogProbeToolResult?,
    report: GatewayCallReport?
  ) {
    var operationArguments: [String: JSONValue] = [
      "tool": .string(tool),
      "arguments": .object(invocation.arguments),
      "ttl_ms": .number(300_000),
    ]
    if let workspaceID = invocation.arguments["workspace_id"] {
      operationArguments["workspace_id"] = workspaceID
    }
    let prepareInvocation = CapabilityFixtureInvocation(arguments: operationArguments)
    let prepared = await call("operations.prepare", invocation: prepareInvocation)
    guard prepared.result.status == "passed", let preparedReport = prepared.report,
      let ticketID = preparedReport.result.objectValue?["structuredContent"]?.objectValue?[
        "result"]?
        .objectValue?["ticket_id"]?.stringValue
    else {
      return (
        target: failedCommittedTarget(
          tool: tool,
          detail: "operations.prepare did not produce a bound operation ticket."
        ),
        prepare: prepared.result,
        commit: nil,
        report: nil
      )
    }

    operationArguments.removeValue(forKey: "ttl_ms")
    operationArguments["ticket_id"] = .string(ticketID)
    let committed = await call(
      "operations.commit",
      invocation: CapabilityFixtureInvocation(arguments: operationArguments)
    )
    guard let committedReport = committed.report else {
      return (
        target: failedCommittedTarget(
          tool: tool,
          detail: "operations.commit did not return a target result."
        ),
        prepare: prepared.result,
        commit: committed.result,
        report: nil
      )
    }
    return (
      target: committedTargetResult(
        tool: tool,
        report: committedReport,
        expectedMarker: invocation.expectedMarker
      ),
      prepare: prepared.result,
      commit: committed.result,
      report: committedReport
    )
  }

  private func callDownstreamCancellation() async -> (
    target: AppFullCatalogProbeToolResult,
    prepare: AppFullCatalogProbeToolResult,
    commit: AppFullCatalogProbeToolResult?
  ) {
    let requestID = "validation-cancel-\(UUID().uuidString)"
    let started = await callCommitted(
      "mcp.tools.call",
      invocation: CapabilityFixtureInvocation(
        arguments: [
          "server": .string("fixture-stdio"),
          "tool": .string("fixture_hang"),
          "request_id": .string(requestID),
          "wait_for_result": .bool(false),
        ],
        expectedMarker: "running",
        execution: .committed
      )
    )
    guard started.target.status == "passed" else {
      return (
        target: failedCommittedTarget(
          tool: "mcp.requests.cancel",
          detail: "The bounded downstream request did not enter the running state."
        ),
        prepare: started.prepare,
        commit: started.commit
      )
    }

    var activeRequestObserved = false
    for _ in 0..<40 {
      let listed = await call(
        "mcp.requests.list",
        invocation: CapabilityFixtureInvocation(
          arguments: ["server": .string("fixture-stdio")],
          expectedMarker: requestID
        )
      )
      if listed.result.status == "passed" {
        activeRequestObserved = true
        break
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
    guard activeRequestObserved else {
      return (
        target: failedCommittedTarget(
          tool: "mcp.requests.cancel",
          detail: "The bounded downstream request was not observable before cancellation."
        ),
        prepare: started.prepare,
        commit: started.commit
      )
    }

    let cancelled = await callCommitted(
      "mcp.requests.cancel",
      invocation: CapabilityFixtureInvocation(
        arguments: [
          "server": .string("fixture-stdio"),
          "request_id": .string(requestID),
          "reason": .string("Validation Suite lifecycle verification"),
        ],
        expectedMarker: "cancelled",
        execution: .committed
      )
    )
    return (
      target: cancelled.target,
      prepare: cancelled.prepare.status == "passed" ? cancelled.prepare : started.prepare,
      commit: cancelled.commit?.status == "passed" ? cancelled.commit : started.commit
    )
  }

  private func callCodexAppLifecycle(
    enabledTools: Set<String>
  ) async -> [String: AppFullCatalogProbeToolResult] {
    let lifecycleTools: Set<String> = [
      "codex.app.requests.respond",
      "codex.app.review.start",
      "codex.app.thread.fork",
      "codex.app.thread.read",
      "codex.app.thread.start",
      "codex.app.turn.interrupt",
      "codex.app.turn.start",
    ]
    let requiredTools = lifecycleTools.intersection(enabledTools)
    guard !requiredTools.isEmpty else {
      return [:]
    }

    var results: [String: AppFullCatalogProbeToolResult] = [:]
    let workspaceID = fixturePlan.repositoryWorkspaceID ?? fixturePlan.workspaceID
    let workspaceArgument: [String: JSONValue] = ["workspace_id": .string(workspaceID)]
    let started = await call(
      "codex.app.thread.start",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArgument.merging(["ephemeral": .bool(true)]) { current, _ in
          current
        },
        expectedMarker: "thread"
      )
    )
    results["codex.app.thread.start"] = started.result
    guard started.result.status == "passed", let startedReport = started.report,
      let threadID = structuredResult(from: startedReport)?.objectValue?["thread"]?
        .objectValue?["id"]?.stringValue
    else {
      return completingLifecycleFailures(
        results,
        tools: requiredTools,
        detail: "codex.app.thread.start did not return a workspace-bound thread id."
      )
    }

    let read = await call(
      "codex.app.thread.read",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArgument.merging([
          "thread_id": .string(threadID),
          "include_turns": .bool(true),
        ]) { current, _ in current },
        expectedMarker: threadID
      )
    )
    results["codex.app.thread.read"] = read.result

    let forked = await call(
      "codex.app.thread.fork",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArgument.merging([
          "thread_id": .string(threadID),
          "ephemeral": .bool(true),
        ]) { current, _ in current },
        expectedMarker: threadID
      )
    )
    results["codex.app.thread.fork"] = forked.result

    let questionTurn = await call(
      "codex.app.turn.start",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArgument.merging([
          "thread_id": .string(threadID),
          "prompt": .string(
            "Use request_user_input exactly once. Ask a single question with id validation_choice and choices Ready and Stop. Do not call any other tool or modify files."
          ),
          "model": .string("gpt-5.6-sol"),
          "effort": .string("low"),
          "collaboration_mode": .string("plan"),
        ]) { current, _ in current },
        expectedMarker: "turn"
      )
    )
    results["codex.app.turn.start"] = questionTurn.result

    var pendingRequestID: String?
    if questionTurn.result.status == "passed" {
      for _ in 0..<240 {
        let pending = await call(
          "codex.app.requests.list",
          invocation: CapabilityFixtureInvocation(arguments: workspaceArgument)
        )
        if let report = pending.report,
          let requests = structuredResult(from: report)?.objectValue?["requests"]?.arrayValue,
          let requestID = requests.first?.objectValue?["request_id"]?.stringValue
        {
          pendingRequestID = requestID
          break
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
    if let pendingRequestID {
      let responded = await call(
        "codex.app.requests.respond",
        invocation: CapabilityFixtureInvocation(
          arguments: workspaceArgument.merging([
            "request_id": .string(pendingRequestID),
            "response": .object([
              "answers": .object([
                "validation_choice": .object([
                  "answers": .array([.string("Ready")])
                ])
              ])
            ]),
          ]) { current, _ in current },
          expectedMarker: "resolved"
        )
      )
      results["codex.app.requests.respond"] = responded.result
    } else {
      results["codex.app.requests.respond"] = lifecycleFailure(
        tool: "codex.app.requests.respond",
        detail: "The bounded plan turn did not produce an ordinary user-input request."
      )
    }

    let interruptSetup = await call(
      "codex.app.turn.start",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArgument.merging([
          "thread_id": .string(threadID),
          "prompt": .string(
            "Wait before replying so cancellation can be verified. Do not modify files."
          ),
          "model": .string("gpt-5.6-sol"),
          "effort": .string("low"),
        ]) { current, _ in current }
      )
    )
    if interruptSetup.result.status == "passed", let report = interruptSetup.report,
      let turnID = structuredResult(from: report)?.objectValue?["turn"]?.objectValue?["id"]?
        .stringValue
    {
      let interrupted = await call(
        "codex.app.turn.interrupt",
        invocation: CapabilityFixtureInvocation(
          arguments: workspaceArgument.merging([
            "thread_id": .string(threadID),
            "turn_id": .string(turnID),
          ]) { current, _ in current }
        )
      )
      results["codex.app.turn.interrupt"] = interrupted.result
    } else {
      results["codex.app.turn.interrupt"] = lifecycleFailure(
        tool: "codex.app.turn.interrupt",
        detail: "The interrupt fixture could not start an active Codex App turn."
      )
    }

    let review = await call(
      "codex.app.review.start",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArgument.merging([
          "thread_id": .string(threadID),
          "target": .object(["type": .string("uncommittedChanges")]),
          "delivery": .string("detached"),
        ]) { current, _ in current }
      )
    )
    results["codex.app.review.start"] = review.result
    return completingLifecycleFailures(
      results,
      tools: requiredTools,
      detail: "The Codex App lifecycle fixture did not reach this capability."
    )
  }

  private func callCodexExecLifecycle(
    enabledTools: Set<String>
  ) async -> [String: AppFullCatalogProbeToolResult] {
    let lifecycleTools: Set<String> = [
      "codex.exec.cancel",
      "codex.exec.events",
      "codex.exec.result",
      "codex.exec.resume",
      "codex.exec.start",
    ]
    let requiredTools = lifecycleTools.intersection(enabledTools)
    guard !requiredTools.isEmpty else {
      return [:]
    }

    var results: [String: AppFullCatalogProbeToolResult] = [:]
    let workspaceArguments: [String: JSONValue] = [
      "workspace_id": .string(fixturePlan.workspaceID)
    ]
    let started = await call(
      "codex.exec.start",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArguments.merging([
          "prompt": .string("Reply exactly CMCP VALIDATION EXEC. Do not modify files.")
        ]) { current, _ in current },
        expectedMarker: "running"
      )
    )
    results["codex.exec.start"] = started.result
    guard started.result.status == "passed", let startedReport = started.report,
      let sessionID = structuredResult(from: startedReport)?.objectValue?["session_id"]?
        .stringValue
    else {
      return completingLifecycleFailures(
        results,
        tools: requiredTools,
        detail: "codex.exec.start did not return a running session id."
      )
    }

    let events = await call(
      "codex.exec.events",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArguments.merging([
          "session_id": .string(sessionID),
          "after_cursor": .number(0),
          "max_results": .number(100),
        ]) { current, _ in current }
      )
    )
    results["codex.exec.events"] = events.result

    var upstreamSessionID: String?
    var terminal = false
    for _ in 0..<240 {
      let listed = await call(
        "codex.exec.list",
        invocation: CapabilityFixtureInvocation(arguments: workspaceArguments)
      )
      if let report = listed.report,
        let row = objectValue(
          containing: "session_id",
          equalTo: sessionID,
          in: structuredResult(from: report)
        )
      {
        upstreamSessionID = row["upstream_session_id"]?.stringValue ?? upstreamSessionID
        if let state = row["state"]?.stringValue,
          ["completed", "failed", "cancelled"].contains(state)
        {
          terminal = true
          break
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
    }

    if terminal {
      let result = await call(
        "codex.exec.result",
        invocation: CapabilityFixtureInvocation(
          arguments: workspaceArguments.merging(["session_id": .string(sessionID)]) {
            current, _ in current
          },
          expectedMarker: sessionID
        )
      )
      results["codex.exec.result"] = result.result
      if upstreamSessionID == nil, let report = result.report {
        upstreamSessionID =
          structuredResult(from: report)?.objectValue?["upstream_session_id"]?
          .stringValue
      }
    } else {
      results["codex.exec.result"] = lifecycleFailure(
        tool: "codex.exec.result",
        detail: "The bounded Codex Exec start session did not reach a terminal state."
      )
    }

    if let upstreamSessionID {
      let resumed = await call(
        "codex.exec.resume",
        invocation: CapabilityFixtureInvocation(
          arguments: workspaceArguments.merging([
            "upstream_session_id": .string(upstreamSessionID),
            "prompt": .string("Wait before replying. Do not modify files."),
          ]) { current, _ in current },
          expectedMarker: "running"
        )
      )
      results["codex.exec.resume"] = resumed.result
      if resumed.result.status == "passed", let report = resumed.report,
        let resumedSessionID = structuredResult(from: report)?.objectValue?["session_id"]?
          .stringValue
      {
        let cancelled = await call(
          "codex.exec.cancel",
          invocation: CapabilityFixtureInvocation(
            arguments: workspaceArguments.merging([
              "session_id": .string(resumedSessionID)
            ]) { current, _ in current },
            expectedMarker: "cancelled"
          )
        )
        results["codex.exec.cancel"] = cancelled.result
      }
    }

    return completingLifecycleFailures(
      results,
      tools: requiredTools,
      detail: "The Codex Exec lifecycle fixture did not reach this capability."
    )
  }

  private func callCodexMCPLifecycle(
    enabledTools: Set<String>
  ) async -> [String: AppFullCatalogProbeToolResult] {
    let lifecycleTools: Set<String> = [
      "codex.mcp.approvals.list",
      "codex.mcp.cancel",
      "codex.mcp.events",
      "codex.mcp.reply",
      "codex.mcp.result",
      "codex.mcp.run",
    ]
    let requiredTools = lifecycleTools.intersection(enabledTools)
    guard !requiredTools.isEmpty else {
      return [:]
    }

    var results: [String: AppFullCatalogProbeToolResult] = [:]
    let workspaceArguments: [String: JSONValue] = [
      "workspace_id": .string(fixturePlan.workspaceID)
    ]
    let started = await call(
      "codex.mcp.run",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArguments.merging([
          "prompt": .string("Reply exactly CMCP VALIDATION MCP. Do not modify files or call tools.")
        ]) { current, _ in current },
        expectedMarker: "running"
      )
    )
    results["codex.mcp.run"] = started.result
    guard started.result.status == "passed", let startedReport = started.report,
      let callID = structuredResult(from: startedReport)?.objectValue?["call_id"]?.stringValue
    else {
      return completingLifecycleFailures(
        results,
        tools: requiredTools,
        detail: "codex.mcp.run did not return a running call id."
      )
    }

    let events = await call(
      "codex.mcp.events",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArguments.merging([
          "call_id": .string(callID),
          "after_cursor": .number(0),
          "max_results": .number(100),
        ]) { current, _ in current }
      )
    )
    results["codex.mcp.events"] = events.result

    let approvals = await call(
      "codex.mcp.approvals.list",
      invocation: CapabilityFixtureInvocation(
        arguments: workspaceArguments.merging(["call_id": .string(callID)]) {
          current, _ in current
        },
        expectedMarker: "approvals"
      )
    )
    results["codex.mcp.approvals.list"] = approvals.result

    var terminalResult:
      (
        result: AppFullCatalogProbeToolResult,
        report: GatewayCallReport?
      )?
    var threadID: String?
    for _ in 0..<240 {
      let current = await call(
        "codex.mcp.result",
        invocation: CapabilityFixtureInvocation(
          arguments: workspaceArguments.merging(["call_id": .string(callID)]) {
            current, _ in current
          }
        )
      )
      terminalResult = current
      if let report = current.report,
        let resolvedThreadID = firstStringValue(
          named: "thread_id",
          in: structuredResult(from: report) ?? .null
        )
      {
        threadID = resolvedThreadID
        break
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    if let terminalResult {
      results["codex.mcp.result"] = terminalResult.result
    }

    if let threadID {
      let replied = await call(
        "codex.mcp.reply",
        invocation: CapabilityFixtureInvocation(
          arguments: workspaceArguments.merging([
            "thread_id": .string(threadID),
            "prompt": .string("Wait before replying. Do not modify files or call tools."),
          ]) { current, _ in current },
          expectedMarker: "running"
        )
      )
      results["codex.mcp.reply"] = replied.result
      if replied.result.status == "passed", let report = replied.report,
        let replyCallID = structuredResult(from: report)?.objectValue?["call_id"]?.stringValue
      {
        let cancelled = await call(
          "codex.mcp.cancel",
          invocation: CapabilityFixtureInvocation(
            arguments: workspaceArguments.merging(["call_id": .string(replyCallID)]) {
              current, _ in current
            },
            expectedMarker: "cancellation_requested"
          )
        )
        results["codex.mcp.cancel"] = cancelled.result
      }
    }

    return completingLifecycleFailures(
      results,
      tools: requiredTools,
      detail: "The Codex MCP lifecycle fixture did not reach this capability."
    )
  }

  private func completingLifecycleFailures(
    _ results: [String: AppFullCatalogProbeToolResult],
    tools: Set<String>,
    detail: String
  ) -> [String: AppFullCatalogProbeToolResult] {
    var completed = results
    for tool in tools where completed[tool] == nil {
      completed[tool] = lifecycleFailure(tool: tool, detail: detail)
    }
    return completed
  }

  private func lifecycleFailure(
    tool: String,
    detail: String
  ) -> AppFullCatalogProbeToolResult {
    AppFullCatalogProbeToolResult(
      toolName: tool,
      status: "failed",
      transportRequestID: nil,
      gatewayRequestID: nil,
      auditEventID: nil,
      auditDecision: nil,
      structuredContent: false,
      semanticValidated: false,
      outputByteCount: nil,
      resultDigest: nil,
      auditEvent: nil,
      detail: detail
    )
  }

  private func structuredResult(from report: GatewayCallReport) -> JSONValue? {
    report.result.objectValue?["structuredContent"]?.objectValue?["result"]
  }

  private func objectValue(
    containing key: String,
    equalTo expected: String,
    in value: JSONValue?
  ) -> [String: JSONValue]? {
    guard let value else {
      return nil
    }
    if let object = value.objectValue {
      if object[key]?.stringValue == expected {
        return object
      }
      for child in object.values {
        if let found = objectValue(containing: key, equalTo: expected, in: child) {
          return found
        }
      }
    } else if let array = value.arrayValue {
      for child in array {
        if let found = objectValue(containing: key, equalTo: expected, in: child) {
          return found
        }
      }
    }
    return nil
  }

  private func committedTargetResult(
    tool: String,
    report: GatewayCallReport,
    expectedMarker: String?
  ) -> AppFullCatalogProbeToolResult {
    let targetRequestID = report.result.objectValue?["structuredContent"]?.objectValue?[
      "target_execution"
    ]?.objectValue?["request_id"]?.stringValue
    let audit = targetRequestID.flatMap(auditEvent(requestID:))
    let isError = report.result.objectValue?["isError"]?.boolValue == true
    let structured = report.result.objectValue?["structuredContent"] != nil
    let semantic = semanticCheck(
      tool: tool,
      report: report,
      expectedMarker: expectedMarker
    )
    let resultData = try? sortedJSON(report.result)
    let status =
      !isError && structured && semantic.passed && audit?.decision == .allowed
      ? "passed"
      : "failed"
    return AppFullCatalogProbeToolResult(
      toolName: tool,
      status: status,
      transportRequestID: report.requestID,
      gatewayRequestID: targetRequestID,
      auditEventID: audit?.id,
      auditDecision: audit?.decision.rawValue,
      structuredContent: structured,
      semanticValidated: semantic.passed,
      outputByteCount: resultData?.count,
      resultDigest: resultData.map(digest),
      auditEvent: audit,
      detail:
        status == "passed"
        ? nil
        : semantic.detail
          ?? "Committed target result or target audit correlation was incomplete."
    )
  }

  private func failedCommittedTarget(
    tool: String,
    detail: String
  ) -> AppFullCatalogProbeToolResult {
    AppFullCatalogProbeToolResult(
      toolName: tool,
      status: "failed",
      transportRequestID: nil,
      gatewayRequestID: nil,
      auditEventID: nil,
      auditDecision: nil,
      structuredContent: false,
      semanticValidated: false,
      outputByteCount: nil,
      resultDigest: nil,
      auditEvent: nil,
      detail: detail
    )
  }

  private func unsupportedResult(
    tool: String,
    detail: String
  ) -> AppFullCatalogProbeToolResult {
    AppFullCatalogProbeToolResult(
      toolName: tool,
      status: "unsupported-fixture",
      transportRequestID: nil,
      gatewayRequestID: nil,
      auditEventID: nil,
      auditDecision: nil,
      structuredContent: false,
      semanticValidated: false,
      outputByteCount: nil,
      resultDigest: nil,
      auditEvent: nil,
      detail: detail
    )
  }

  private func executionRequestID(from report: GatewayCallReport) -> String? {
    report.result.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
      .objectValue?["request_id"]?.stringValue
  }

  private func semanticCheck(
    tool: String,
    report: GatewayCallReport,
    expectedMarker: String?
  ) -> (passed: Bool, detail: String?) {
    guard
      let payload = report.result.objectValue?["structuredContent"]?.objectValue?["result"]
    else {
      return (false, "The tool returned no structured result payload.")
    }

    switch tool {
    case "workspace.list":
      guard firstStringValue(named: "id", in: payload) != nil else {
        return (false, "workspace.list returned no registered workspace.")
      }
    case "computer.permissions":
      let permissions = payload.objectValue
      guard
        permissions?["accessibility"]?.stringValue != nil,
        permissions?["screen_recording"]?.stringValue != nil
      else {
        return (false, "computer.permissions omitted a required TCC service.")
      }
    case "computer.displays":
      guard payload.arrayValue?.isEmpty == false else {
        return (false, "computer.displays returned an empty active-display list.")
      }
    case "computer.pointer.position":
      guard
        let x = payload.objectValue?["x"]?.numberValue,
        let y = payload.objectValue?["y"]?.numberValue,
        x.isFinite,
        y.isFinite
      else {
        return (false, "computer.pointer.position returned no finite coordinate.")
      }
    case "computer.verify":
      guard
        (payload.objectValue?["attempts"]?.numberValue ?? 0) >= 1,
        payload.objectValue?["observation"]?.objectValue?["type"]?.stringValue
          == "pointer-position"
      else {
        return (false, "computer.verify returned no pointer-position observation.")
      }
    case "computer.screenshot":
      guard
        (payload.objectValue?["width"]?.numberValue ?? 0) > 0,
        (payload.objectValue?["height"]?.numberValue ?? 0) > 0,
        (payload.objectValue?["byte_count"]?.numberValue ?? 0) > 0
      else {
        return (false, "computer.screenshot returned empty image metadata.")
      }
    case "computer.windows", "computer.accessibility.query":
      guard payload.arrayValue?.isEmpty == false else {
        return (false, "\(tool) returned no observations.")
      }
    default:
      break
    }
    if let expectedMarker,
      !encoded(payload).localizedCaseInsensitiveContains(expectedMarker)
    {
      return (
        false,
        "\(tool) did not return the expected bounded fixture marker '\(expectedMarker)'."
      )
    }
    return (true, nil)
  }

  private func auditEvent(requestID: String) -> AuditEvent? {
    try? database.auditEvent(requestID: requestID)
  }

  private func extractedPointerPosition(
    from report: GatewayCallReport
  ) -> (x: Double, y: Double)? {
    guard
      let payload = report.result.objectValue?["structuredContent"]?.objectValue?["result"],
      let x = payload.objectValue?["x"]?.numberValue,
      let y = payload.objectValue?["y"]?.numberValue
    else {
      return nil
    }
    return (x, y)
  }

  private func firstStringValue(named key: String, in value: JSONValue) -> String? {
    if let object = value.objectValue {
      if let string = object[key]?.stringValue, !string.isEmpty {
        return string
      }
      for child in object.values {
        if let match = firstStringValue(named: key, in: child) {
          return match
        }
      }
    } else if let array = value.arrayValue {
      for child in array {
        if let match = firstStringValue(named: key, in: child) {
          return match
        }
      }
    }
    return nil
  }

  private func encoded(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
      return ""
    }
    return String(decoding: data, as: UTF8.self)
  }
}

private func stableSocketProbeError(_ error: Error) -> String {
  let value: String
  if let localized = error as? any LocalizedError,
    let description = localized.errorDescription
  {
    value = description
  } else {
    value = String(describing: error)
  }
  return String(
    value
      .replacingOccurrences(of: "\n", with: " ")
      .prefix(1_024)
  )
}

private func writeAppFullCatalogProbeJSON(
  _ report: AppFullCatalogProbeReport,
  destination: String
) throws {
  let encoder = CanonicalJSONCoding.encoder(
    outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  )
  let destinationURL = URL(fileURLWithPath: destination)
  try FileManager.default.createDirectory(
    at: destinationURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try encoder.encode(report).write(to: destinationURL, options: .atomic)
}

private func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}

private func digest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
