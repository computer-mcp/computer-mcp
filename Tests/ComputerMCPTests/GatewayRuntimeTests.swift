import CryptoKit
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class GatewayRuntimeTests {
  @Test
  func testRoutesExplicitWorkspaceAndRejectsCrossWorkspaceAccess() throws {
    let first = try temporaryDirectory()
    let second = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    try "first".write(
      to: first.appendingPathComponent("value.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "second".write(
      to: second.appendingPathComponent("value.txt"),
      atomically: true,
      encoding: .utf8
    )
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["workspace.list", "workspace.describe", "file.read"],
      workspaceIDs: ["first"],
      builtin: ["file.read"],
      database: database,
      workspaces: [
        workspace(id: "first", root: first),
        workspace(id: "second", root: second),
      ]
    )

    let listedNames = try gateway.listTools().map(\.name)
    #expect((Set(listedNames)) == (["workspace.list", "workspace.describe", "file.read"]))
    let fileRead = try #require(
      gateway.listTools().first(where: { $0.name == "file.read" })
    )
    #expect(
      (fileRead.inputSchema.objectValue?["properties"]?.objectValue?["workspace_id"]?
        .objectValue?["type"]) == (.string("string")))

    expectThrows(
      try gateway.callTool(
        name: "file.read",
        arguments: .object(["path": .string("value.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("workspace_id"))
    }

    let result = try gateway.callTool(
      name: "file.read",
      arguments: .object([
        "workspace_id": .string("first"),
        "path": .string("value.txt"),
      ])
    )
    #expect((try payload(result).objectValue?["content"]) == (.string("first")))

    expectThrows(
      try gateway.callTool(
        name: "file.read",
        arguments: .object([
          "workspace_id": .string("second"),
          "path": .string("value.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains(PolicyDenialCode.workspaceDenied.rawValue))
    }

    let workspaceList = try gateway.callTool(name: "workspace.list", arguments: .object([:]))
    let rows = try #require(payload(workspaceList).objectValue?["workspaces"]?.arrayValue)
    #expect((rows.count) == (1))
    #expect((rows.first?.objectValue?["id"]) == (.string("first")))
  }

  @Test
  func testFullShellRequiresBothManifestAndProfileEnablement() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = workspace(id: "root", root: root)
    let database = try GatewayDatabase(inMemory: ())
    let disabled = try makeGateway(
      capabilities: ["shell.run"],
      workspaceIDs: ["root"],
      builtin: [],
      database: database,
      workspaces: [workspace],
      shellEnabled: true,
      fullShellEnabled: false,
      caller: .localMCP,
      profileID: .localAdmin
    )
    #expect(!(try disabled.listTools().contains(where: { $0.name == "shell.run" })))

    let enabled = try makeGateway(
      capabilities: ["shell.run"],
      workspaceIDs: ["root"],
      builtin: [],
      database: database,
      workspaces: [workspace],
      shellEnabled: true,
      fullShellEnabled: true,
      caller: .localMCP,
      profileID: .localAdmin
    )
    #expect(try enabled.listTools().contains(where: { $0.name == "shell.run" }))
    let result = try enabled.callTool(
      name: "shell.run",
      arguments: .object([
        "workspace_id": .string("root"),
        "command": .string("printf gateway-shell"),
      ])
    )
    #expect(
      (try payload(result).objectValue?["stdout"]?.objectValue?["text"])
        == (.string("gateway-shell")))
  }

  @Test
  func testChatGPTOperateCanUseExplicitlyEnabledFullShell() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try makeGateway(
      capabilities: ["shell.run"],
      workspaceIDs: ["root"],
      builtin: [],
      database: GatewayDatabase(inMemory: ()),
      workspaces: [workspace(id: "root", root: root)],
      shellEnabled: true,
      fullShellEnabled: true,
      caller: .secureTunnel,
      profileID: .chatGPTOperate
    )

    #expect(try gateway.listTools().contains { $0.name == "shell.run" })
    let result = try gateway.callTool(
      name: "shell.run",
      arguments: .object([
        "workspace_id": .string("root"),
        "command": .string("printf chatgpt-shell"),
      ])
    )
    #expect(
      try payload(result).objectValue?["stdout"]?.objectValue?["text"]
        == .string("chatgpt-shell")
    )
  }

  @Test
  func testDestructiveToolRequiresSingleUseBoundOperationTicket() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("obsolete.txt")
    try "obsolete".write(to: file, atomically: true, encoding: .utf8)
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["operations.prepare", "operations.commit", "file.trash"],
      workspaceIDs: ["root"],
      builtin: ["file.trash"],
      database: database,
      workspaces: [workspace(id: "root", root: root)],
      allowedCallers: [.secureTunnel, .localApp]
    )
    let targetArguments: JSONValue = .object(["path": .string("obsolete.txt")])
    let prepareContext = ExecutionContext(
      requestID: "prepare-request",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      workspaceID: "root"
    )
    let commitContext = ExecutionContext(
      requestID: "commit-request",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      workspaceID: "root"
    )

    expectThrows(
      try gateway.callTool(
        name: "file.trash",
        arguments: .object([
          "workspace_id": .string("root"),
          "path": .string("obsolete.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("operations.ticket_required"))
    }

    let prepared = try gateway.callTool(
      name: "operations.prepare",
      arguments: .object([
        "workspace_id": .string("root"),
        "tool": .string("file.trash"),
        "arguments": targetArguments,
      ]),
      context: prepareContext
    )
    let ticketID = try #require(payload(prepared).objectValue?["ticket_id"]?.stringValue)
    #expect((try payload(prepared).objectValue?["state_digest"]?.stringValue) != nil)

    expectThrows(
      try gateway.callTool(
        name: "operations.commit",
        arguments: .object([
          "workspace_id": .string("root"),
          "ticket_id": .string(ticketID),
          "tool": .string("file.trash"),
          "arguments": targetArguments,
        ]),
        context: ExecutionContext(
          requestID: "wrong-principal-request",
          caller: .localApp,
          profileID: .chatGPTOperate,
          workspaceID: "root"
        )
      )
    ) { error in
      #expect(error.localizedDescription.contains("operations.ticket_context_mismatch"))
    }
    #expect((try database.operationTicket(id: ticketID)?.state) == (.prepared))

    expectThrows(
      try gateway.callTool(
        name: "operations.commit",
        arguments: .object([
          "workspace_id": .string("root"),
          "ticket_id": .string(ticketID),
          "tool": .string("file.trash"),
          "arguments": .object(["path": .string("different.txt")]),
        ]),
        context: commitContext
      )
    ) { error in
      #expect(error.localizedDescription.contains("ticket_arguments_mismatch"))
    }

    let committed = try gateway.callTool(
      name: "operations.commit",
      arguments: .object([
        "workspace_id": .string("root"),
        "ticket_id": .string(ticketID),
        "tool": .string("file.trash"),
        "arguments": targetArguments,
      ]),
      context: commitContext
    )
    let trashedPath = try #require(payload(committed).objectValue?["trashed_path"]?.stringValue)
    defer { try? FileManager.default.removeItem(atPath: trashedPath) }
    #expect(!(FileManager.default.fileExists(atPath: file.path)))

    expectThrows(
      try gateway.callTool(
        name: "operations.commit",
        arguments: .object([
          "workspace_id": .string("root"),
          "ticket_id": .string(ticketID),
          "tool": .string("file.trash"),
          "arguments": targetArguments,
        ]),
        context: ExecutionContext(
          requestID: "second-commit-request",
          caller: .secureTunnel,
          profileID: .chatGPTOperate,
          workspaceID: "root"
        )
      )
    ) { error in
      #expect(error.localizedDescription.contains("operations.ticket_expired_or_used"))
    }
    let ticket = try #require(try database.operationTicket(id: ticketID))
    #expect((ticket.state) == (.succeeded))
    let invocationID = try #require(ticket.invocationID)
    #expect((ticket.parentRequestID) == (commitContext.requestID))

    let executions = try #require(
      committed.objectValue?["structuredContent"]?.objectValue
    )
    #expect(
      (executions["gateway_execution"]?.objectValue?["request_id"])
        == (.string(commitContext.requestID)))
    #expect((executions["target_execution"]?.objectValue?["request_id"]) == (.string(invocationID)))
    #expect(
      (executions["target_execution"]?.objectValue?["parent_request_id"])
        == (.string(commitContext.requestID)))

    let events = try database.auditEvents()
    let prepareAudit = try #require(
      events.first { $0.capabilityID == "operations.prepare" }
    )
    let commitAudit = try #require(
      events.first {
        $0.capabilityID == "operations.commit" && $0.requestID == commitContext.requestID
      }
    )
    let targetAudit = try #require(events.first { $0.capabilityID == "file.trash" })
    #expect((prepareAudit.ticketID) == (ticketID))
    #expect((commitAudit.ticketID) == (ticketID))
    #expect((commitAudit.invocationID) == (invocationID))
    #expect((commitAudit.parentRequestID) == nil)
    #expect((targetAudit.requestID) == (invocationID))
    #expect((targetAudit.invocationID) == (invocationID))
    #expect((targetAudit.parentRequestID) == (commitContext.requestID))
    #expect((targetAudit.ticketID) == (ticketID))
    #expect((events.count) >= (5))
    #expect(
      events.allSatisfy {
        $0.inputDigest != nil && $0.outputByteCount == nil || $0.outputByteCount! >= 0
      })
  }

  @Test
  func testOperationPreparationRejectsEscapingSymlinkTarget() throws {
    let container = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: container) }
    let root = container.appendingPathComponent("workspace", isDirectory: true)
    let outside = container.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"),
      withDestinationURL: outside
    )
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["operations.prepare", "operations.commit", "file.write"],
      workspaceIDs: ["root"],
      builtin: ["file.write"],
      database: database,
      workspaces: [workspace(id: "root", root: root)],
      caller: .secureTunnel,
      profileID: .chatGPTOperate
    )

    expectThrows(
      try gateway.callTool(
        name: "operations.prepare",
        arguments: .object([
          "workspace_id": .string("root"),
          "tool": .string("file.write"),
          "arguments": .object([
            "path": .string("escape/written.txt"),
            "content": .string("must not escape"),
          ]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("operations.state_path_escape"))
    }
    #expect(
      !FileManager.default.fileExists(atPath: outside.appendingPathComponent("written.txt").path))
    let audit = try #require(
      try database.auditEvents().first { $0.capabilityID == "operations.prepare" }
    )
    #expect(audit.decision == .denied)
    #expect(audit.errorCode == "operations.state_path_escape")
  }

  @Test
  func testOperationTicketFailsClosedWhenTargetStateDrifts() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("drift.txt")
    try "before".write(to: file, atomically: true, encoding: .utf8)
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["operations.prepare", "operations.commit", "file.trash"],
      workspaceIDs: ["root"],
      builtin: ["file.trash"],
      database: database,
      workspaces: [workspace(id: "root", root: root)]
    )
    let targetArguments: JSONValue = .object(["path": .string("drift.txt")])
    let prepared = try gateway.callTool(
      name: "operations.prepare",
      arguments: .object([
        "workspace_id": .string("root"),
        "tool": .string("file.trash"),
        "arguments": targetArguments,
      ])
    )
    let ticketID = try #require(payload(prepared).objectValue?["ticket_id"]?.stringValue)

    try "after".write(to: file, atomically: true, encoding: .utf8)
    expectThrows(
      try gateway.callTool(
        name: "operations.commit",
        arguments: .object([
          "workspace_id": .string("root"),
          "ticket_id": .string(ticketID),
          "tool": .string("file.trash"),
          "arguments": targetArguments,
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("operations.ticket_state_changed"))
    }

    #expect(FileManager.default.fileExists(atPath: file.path))
    let ticket = try #require(try database.operationTicket(id: ticketID))
    #expect((ticket.state) == (.failed))
    #expect((ticket.failureCode) == ("operations.ticket_state_changed"))
    #expect((ticket.invocationID) == nil)
    #expect(!(try database.auditEvents().contains { $0.capabilityID == "file.trash" }))
  }

  @Test
  func testOperationTicketRecordsFailedTargetAndParentAuditAttribution() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("plain.txt")
    try "plain".write(to: file, atomically: true, encoding: .utf8)
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["operations.prepare", "operations.commit", "file.remove_xattr"],
      workspaceIDs: ["root"],
      builtin: ["file.remove_xattr"],
      database: database,
      workspaces: [workspace(id: "root", root: root)]
    )
    let targetArguments: JSONValue = .object([
      "path": .string("plain.txt"),
      "name": .string("com.showxu.missing"),
    ])
    let prepared = try gateway.callTool(
      name: "operations.prepare",
      arguments: .object([
        "workspace_id": .string("root"),
        "tool": .string("file.remove_xattr"),
        "arguments": targetArguments,
      ]),
      context: ExecutionContext(
        requestID: "failure-prepare",
        caller: .secureTunnel,
        profileID: .chatGPTOperate,
        workspaceID: "root"
      )
    )
    let ticketID = try #require(payload(prepared).objectValue?["ticket_id"]?.stringValue)
    let commitContext = ExecutionContext(
      requestID: "failure-commit",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      workspaceID: "root"
    )

    expectThrows(
      try gateway.callTool(
        name: "operations.commit",
        arguments: .object([
          "workspace_id": .string("root"),
          "ticket_id": .string(ticketID),
          "tool": .string("file.remove_xattr"),
          "arguments": targetArguments,
        ]),
        context: commitContext
      )
    ) { error in
      #expect(error.localizedDescription.contains("Extended attribute does not exist"))
    }

    let ticket = try #require(try database.operationTicket(id: ticketID))
    #expect((ticket.state) == (.failed))
    #expect((ticket.failureCode) == ("operations.target_failed"))
    let invocationID = try #require(ticket.invocationID)
    let targetAudit = try #require(
      try database.auditEvents().first { $0.capabilityID == "file.remove_xattr" }
    )
    let commitAudit = try #require(
      try database.auditEvents().first {
        $0.capabilityID == "operations.commit" && $0.requestID == commitContext.requestID
      }
    )
    #expect((targetAudit.requestID) == (invocationID))
    #expect((targetAudit.parentRequestID) == (commitContext.requestID))
    #expect((targetAudit.ticketID) == (ticketID))
    #expect((targetAudit.decision) == (.failed))
    #expect((commitAudit.invocationID) == (invocationID))
    #expect((commitAudit.ticketID) == (ticketID))
    #expect((commitAudit.decision) == (.failed))
  }

  @Test
  func testSingleWorkspaceMayBeSelectedImplicitly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try "single".write(
      to: root.appendingPathComponent("value.txt"),
      atomically: true,
      encoding: .utf8
    )
    let gateway = try makeGateway(
      capabilities: ["file.read"],
      workspaceIDs: ["only"],
      builtin: ["file.read"],
      database: try GatewayDatabase(inMemory: ()),
      workspaces: [workspace(id: "only", root: root)]
    )

    let result = try gateway.callTool(
      name: "file.read",
      arguments: .object(["path": .string("value.txt")])
    )
    #expect((try payload(result).objectValue?["content"]) == (.string("single")))
  }

  @Test
  func testGenericExecutionIsRestrictedRemotelyAndAvailableToLocalAdmin() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let command = CLICommandConfig(
      id: "echo",
      executable: "/bin/echo",
      allowAnyArgs: true
    )
    let restricted = try makeGateway(
      capabilities: [
        "cli.help", "cli.exec", "policy.probe", "process.list", "process.spawn",
      ],
      workspaceIDs: ["root"],
      builtin: [],
      database: database,
      workspaces: [workspace(id: "root", root: root)],
      cli: CLISectionConfig(commands: [command])
    )

    #expect(
      (Set(try restricted.listTools().map(\.name)))
        == (["cli.help", "policy.probe", "process.list"]))
    let processList = try restricted.callTool(
      name: "process.list",
      arguments: .object(["workspace_id": .string("root")])
    )
    #expect((try payload(processList).objectValue?["processes"]) == (.array([])))
    expectThrows(
      try restricted.callTool(
        name: "policy.probe",
        arguments: .object([
          "capability_id": .string("process.spawn"),
          "workspace_id": .string("root"),
          "arguments": .object([
            "id": .string("echo"),
            "argv": .array([.string("blocked")]),
          ]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains(PolicyDenialCode.fullShellDisabled.rawValue))
    }
    let events = try database.auditEvents()
    #expect((Set(events.map(\.capabilityID))) == (["policy.probe", "process.list"]))
    let policyProbeEvent = try #require(
      events.first { $0.capabilityID == "policy.probe" }
    )
    #expect((policyProbeEvent.decision) == (.denied))
    #expect((policyProbeEvent.errorCode) == (PolicyDenialCode.fullShellDisabled.rawValue))
    let processListEvent = try #require(
      events.first { $0.capabilityID == "process.list" }
    )
    #expect((processListEvent.decision) == (.allowed))

    let enabled = try makeGateway(
      capabilities: ["cli.exec", "process.spawn"],
      workspaceIDs: ["root"],
      builtin: [],
      database: try GatewayDatabase(inMemory: ()),
      workspaces: [workspace(id: "root", root: root)],
      fullShellEnabled: true,
      cli: CLISectionConfig(commands: [command]),
      caller: .localMCP,
      profileID: .localAdmin
    )
    #expect((Set(try enabled.listTools().map(\.name))) == (["cli.exec", "process.spawn"]))
  }

  @Test
  func testComputerUseToolsFollowProfileCapabilities() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = workspace(id: "root", root: root)

    let observe = try makeGateway(
      capabilities: ["computer.permissions", "computer.displays", "computer.pointer.click"],
      workspaceIDs: ["root"],
      builtin: [],
      database: try GatewayDatabase(inMemory: ()),
      workspaces: [workspace]
    )
    #expect(
      (Set(try observe.listTools().map(\.name)))
        == (["computer.permissions", "computer.displays", "computer.pointer.click"]))

    let permissions = try observe.callTool(name: "computer.permissions", arguments: .object([:]))
    #expect((try payload(permissions).objectValue?["accessibility"]) != nil)
  }

  @Test
  func testEachGatewayCallReceivesAUniqueAuditRequestID() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["computer.permissions"],
      workspaceIDs: ["root"],
      builtin: [],
      database: database,
      workspaces: [workspace(id: "root", root: root)]
    )

    _ = try gateway.callTool(name: "computer.permissions", arguments: .object([:]))
    _ = try gateway.callTool(name: "computer.permissions", arguments: .object([:]))

    let events = try database.auditEvents()
    #expect((events.count) == (2))
    #expect((Set(events.map(\.requestID)).count) == (2))
  }

  @Test
  func testSuccessfulCallReturnsThePersistedAuditCorrelation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["workspace.list"],
      workspaceIDs: ["root"],
      builtin: [],
      database: database,
      workspaces: [workspace(id: "root", root: root)]
    )

    let result = try gateway.callTool(name: "workspace.list", arguments: .object([:]))
    let structuredContent = try #require(
      result.objectValue?["structuredContent"]?.objectValue
    )
    let execution = try #require(
      structuredContent["gateway_execution"]?.objectValue
    )
    let requestID = try #require(execution["request_id"]?.stringValue)
    let event = try #require(try database.auditEvents().first)

    #expect((requestID) == (event.requestID))
    #expect((execution["caller"]) == (.string("secure-tunnel")))
    #expect((execution["profile_id"]) == (.string("chatgpt-operate")))
    #expect((execution["capability_id"]) == (.string("workspace.list")))
    #expect(
      (result.objectValue?["_meta"]?.objectValue?["computer_mcp"]?.objectValue?[
        "request_id"
      ]) == (.string(requestID)))
  }

  @Test
  func testUnknownToolAndRouteFailuresAreAudited() throws {
    let first = try temporaryDirectory()
    let second = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["file.read"],
      workspaceIDs: ["first"],
      builtin: ["file.read"],
      database: database,
      workspaces: [
        workspace(id: "first", root: first),
        workspace(id: "second", root: second),
      ]
    )

    expectThrows(
      try gateway.callTool(name: "unknown.tool", arguments: .object([:]))
    )
    expectThrows(
      try gateway.callTool(
        name: "file.read",
        arguments: .object([
          "workspace_id": .string("second"),
          "path": .string("value.txt"),
        ])
      )
    )

    let events = try database.auditEvents()
    #expect((events.count) == (2))
    #expect((Set(events.map(\.capabilityID))) == (["unknown.tool", "file.read"]))
    let unknownTool = try #require(events.first { $0.capabilityID == "unknown.tool" })
    let crossWorkspace = try #require(events.first { $0.capabilityID == "file.read" })
    #expect((unknownTool.decision) == (.failed))
    #expect((unknownTool.errorCode) == ("gateway.tool_unknown"))
    #expect((crossWorkspace.decision) == (.denied))
    #expect((crossWorkspace.errorCode) == (PolicyDenialCode.workspaceDenied.rawValue))
    #expect(
      events.allSatisfy {
        $0.inputDigest != nil && $0.outputDigest != nil && $0.outputByteCount != nil
      })
  }

  @Test
  func testComputerUsePermissionFailureHasStableDeniedAuditClassification() {
    let error = ComputerUseGatewayProviderError.service(
      .permissionRequired(.accessibility)
    )

    #expect((GatewayRuntime.auditDecision(for: error)) == (.denied))
    #expect((GatewayRuntime.auditErrorCode(for: error)) == ("computer_use.permission_required"))
  }

  @Test
  func testSecurityValidationFailuresHaveStableDeniedAuditClassification() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["file.read"],
      workspaceIDs: ["root"],
      builtin: ["file.read"],
      database: database,
      workspaces: [workspace(id: "root", root: root)]
    )

    expectThrows(
      try gateway.callTool(
        name: "file.read",
        arguments: .object([
          "workspace_id": .string("root"),
          "path": .string("../outside.txt"),
        ])
      )
    )
    let event = try #require(try database.auditEvents().first)
    #expect((event.decision) == (.denied))
    #expect((event.errorCode) == (PolicyDenialCode.workspaceDenied.rawValue))

    let ticketReuse = GatewayToolError.invalidArguments(
      "[operations.ticket_expired_or_used] The operation ticket has expired or was used."
    )
    let authorityOverride = GatewayToolError.invalidArguments(
      "[codex.app.override_denied] 'config' is controlled by the local gateway."
    )
    let dangerFullAccess = GatewayToolError.invalidArguments(
      "[codex.app.danger_full_access_denied] Caller-supplied danger-full-access is denied; request a scoped grant for local approval."
    )
    let workspaceOverride = GatewayToolError.invalidArguments(
      "[codex.app.workspace_override_denied] cwd must match the bound workspace."
    )
    let unapprovedDownstreamTool = GatewayToolError.invalidArguments(
      "[mcp.tool_not_approved] The downstream tool is not approved."
    )
    #expect((GatewayRuntime.auditDecision(for: ticketReuse)) == (.denied))
    #expect((GatewayRuntime.auditDecision(for: authorityOverride)) == (.denied))
    #expect((GatewayRuntime.auditDecision(for: dangerFullAccess)) == (.denied))
    #expect((GatewayRuntime.auditDecision(for: workspaceOverride)) == (.denied))
    #expect((GatewayRuntime.auditDecision(for: unapprovedDownstreamTool)) == (.denied))
    #expect(
      (GatewayRuntime.auditErrorCode(for: ticketReuse)) == ("operations.ticket_expired_or_used"))
    #expect(
      (GatewayRuntime.auditErrorCode(for: authorityOverride)) == ("codex.app.override_denied"))
    #expect(
      (GatewayRuntime.auditErrorCode(for: dangerFullAccess))
        == ("codex.app.danger_full_access_denied"))
    #expect(
      (GatewayRuntime.auditErrorCode(for: workspaceOverride))
        == ("codex.app.workspace_override_denied"))
    #expect(
      (GatewayRuntime.auditErrorCode(for: unapprovedDownstreamTool)) == ("mcp.tool_not_approved")
    )
  }

  @Test
  func testMCPFailureReturnsExactlyAuditedErrorEnvelope() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let gateway = try makeGateway(
      capabilities: ["workspace.list"],
      workspaceIDs: ["root"],
      builtin: [],
      database: database,
      workspaces: [workspace(id: "root", root: root)]
    )

    let result = try await gateway.callToolForMCPAsync(
      name: "unknown.tool",
      arguments: .object([:])
    )
    let event = try #require(try database.auditEvents().first)
    let data = try canonicalEncoder().encode(result)

    #expect((result.objectValue?["isError"]) == (.bool(true)))
    #expect((event.decision) == (.failed))
    #expect((event.errorCode) == ("gateway.tool_unknown"))
    #expect((event.outputByteCount) == (data.count))
    #expect((event.outputDigest) == (digest(data)))
  }

  @Test
  func testShellSessionsAreIsolatedByWorkspaceRuntime() throws {
    let first = try temporaryDirectory()
    let second = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let gateway = try makeGateway(
      capabilities: ["shell.spawn", "shell.read", "shell.cancel"],
      workspaceIDs: ["first", "second"],
      builtin: [],
      database: try GatewayDatabase(inMemory: ()),
      workspaces: [
        workspace(id: "first", root: first),
        workspace(id: "second", root: second),
      ],
      shellEnabled: true,
      fullShellEnabled: true,
      caller: .localMCP,
      profileID: .localAdmin
    )
    let spawned = try gateway.callTool(
      name: "shell.spawn",
      arguments: .object([
        "workspace_id": .string("first"),
        "mode": .string("argv"),
        "executable": .string("/bin/sh"),
        "argv": .array([.string("-c"), .string("sleep 30")]),
      ])
    )
    let sessionID = try #require(payload(spawned).objectValue?["session_id"]?.stringValue)
    defer {
      _ = try? gateway.callTool(
        name: "shell.cancel",
        arguments: .object([
          "workspace_id": .string("first"),
          "session_id": .string(sessionID),
        ])
      )
    }

    expectThrows(
      try gateway.callTool(
        name: "shell.read",
        arguments: .object([
          "workspace_id": .string("second"),
          "session_id": .string(sessionID),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown shell session"))
    }
  }

  private func makeGateway(
    capabilities: [String],
    workspaceIDs: [String],
    builtin: [String],
    database: GatewayDatabase,
    workspaces: [RegisteredWorkspace],
    shellEnabled: Bool = false,
    fullShellEnabled: Bool = false,
    cli: CLISectionConfig = CLISectionConfig(),
    caller: GatewayCallerKind = .secureTunnel,
    profileID: GatewayProfileID = .chatGPTOperate,
    allowedCallers: [GatewayCallerKind]? = nil
  ) throws -> GatewayRuntime {
    let configuration = GatewayConfiguration(
      schemaVersion: 1,
      runtime: RuntimeBindingConfig(
        caller: caller,
        profileID: profileID
      ),
      policy: PolicyConfig(shellEnabled: shellEnabled),
      profiles: [
        ProfileGrantConfig(
          id: profileID,
          capabilities: capabilities,
          workspaces: workspaceIDs,
          allowedCallers: allowedCallers ?? [caller],
          fullShellEnabled: fullShellEnabled
        )
      ],
      cli: cli,
      builtin: BuiltinConfig(enabled: builtin)
    )
    return try GatewayRuntime(
      configuration: configuration,
      database: database,
      registeredWorkspaces: workspaces
    )
  }

  private func workspace(id: String, root: URL) -> RegisteredWorkspace {
    RegisteredWorkspace(id: id, displayName: id, rootPath: root.path)
  }

  private func payload(_ result: JSONValue) throws -> JSONValue {
    try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
