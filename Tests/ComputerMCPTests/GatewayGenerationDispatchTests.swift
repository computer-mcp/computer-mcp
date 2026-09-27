import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayGenerationDispatchTests {
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
