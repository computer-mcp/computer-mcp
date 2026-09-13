import Foundation
import GRDB
import Testing

@testable import ComputerMCP

struct CodexElevationToolsTests {
  @Test(arguments: [CodexSandboxMode.readOnly, .workspaceWrite])
  func gatewayOwnsApprovalAndConnectionCleanupWithExecutionDisabled(
    importedSandbox: CodexSandboxMode
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let databasePath = root.appendingPathComponent("gateway.sqlite").path
    let database = try GatewayDatabase(path: databasePath)
    let workspace = RegisteredWorkspace(
      id: "host-approval", displayName: "Host approval", rootPath: root.path)
    try database.saveWorkspace(workspace)
    let runtime = try GatewayRuntime(
      configuration: .init(
        profiles: [
          .init(
            id: .chatGPTOperate,
            capabilities: [
              "codex.app.elevation.request", "codex.app.elevation.read",
              "codex.app.elevation.approve", "codex.app.elevation.deny",
            ],
            workspaces: [workspace.id], allowedCallers: [.secureTunnel])
        ],
        codex: .init(enabled: false, executable: "/missing/codex", sandbox: importedSandbox)),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate,
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "host-connection")),
      database: database, registeredWorkspaces: [workspace])
    do {
      let names = Set(try runtime.listTools().map(\.name))
      #expect(names.contains("codex.app.elevation.request"))
      #expect(!names.contains("codex.app.elevation.approve"))
      #expect(!names.contains("codex.app.elevation.deny"))
      #expect(!names.contains("codex.app.thread.start"))
      let response = try await runtime.callToolAsync(
        name: "codex.app.elevation.request",
        arguments: .object([
          "workspace_id": .string(workspace.id), "mode": .string("bounded-time"),
          "reason": .string("Exercise host-only approval lifetime"),
        ]))
      let result = try providerResult(response)
      #expect(result["effective_sandbox"] == .null)
      #expect(result["effective"]?.objectValue?["effective_next_turn"] == .bool(false))
      let grantID = try #require(result["grant"]?.objectValue?["id"]?.stringValue)
      #expect(try database.codexElevationGrant(id: grantID)?.state == .pending)
      await #expect(throws: (any Error).self) {
        try await runtime.callToolAsync(
          name: "codex.app.elevation.approve",
          arguments: .object([
            "workspace_id": .string(workspace.id), "grant_id": .string(grantID),
          ]))
      }
      let inspection = try DatabaseQueue(path: databasePath)
      let leaseCount = try await inspection.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM codexRuntimeLeases")
      }
      try inspection.close()
      #expect(leaseCount == 0)
      await runtime.shutdown()
      #expect(try database.codexElevationGrant(id: grantID)?.state == .invalidated)
      await #expect(throws: (any Error).self) {
        try await runtime.callToolAsync(
          name: "codex.app.elevation.request",
          arguments: .object([
            "workspace_id": .string(workspace.id), "mode": .string("bounded-time"),
            "reason": .string("Closed connection"),
          ]))
      }
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func toolsRetainTheirHostApprovalContract() throws {
    let provider = CodexElevationTools(owner: nil, database: nil)
    let tools = try provider.listTools()
    let readNames: Set<String> = [
      "codex.app.elevation.list", "codex.app.elevation.read", "codex.app.elevation.effective",
    ]
    let writeNames: Set<String> = [
      "codex.app.elevation.request", "codex.app.elevation.approve",
      "codex.app.elevation.deny", "codex.app.elevation.revoke",
    ]
    #expect(Set(tools.map(\.name)) == readNames.union(writeNames))
    for tool in tools {
      let descriptor = provider.capability(for: tool)
      #expect(descriptor.risk == (readNames.contains(tool.name) ? .readOnly : .workspaceWrite))
      #expect(descriptor.workspaceRequirement == .required)
      #expect(
        descriptor.localOnly
          == (tool.name == "codex.app.elevation.approve" || tool.name == "codex.app.elevation.deny")
      )
      #expect(tool.outputSchema == MCPTool.resultEnvelopeSchema)
      #expect(tool.annotations?.readOnlyHint == readNames.contains(tool.name))
    }
  }

  @Test
  func testElevationMutationResultsReflectRemainingGrants() async throws {
    let database = try GatewayDatabase(inMemory: ())
    let workspace = RegisteredWorkspace(
      id: "workspace-elevation",
      displayName: "Elevation Fixture",
      rootPath: "/tmp/workspace-elevation"
    )
    try database.saveWorkspace(workspace)
    let requester = CodexRuntimeOwner(
      workspaceID: workspace.id,
      profileID: GatewayProfileID.chatGPTOperate.rawValue,
      caller: GatewayCallerKind.secureTunnel.rawValue,
      transport: "gateway_socket",
      socketConnectionID: "connection-1",
      tunnelInstanceID: "tunnel-1",
      tunnelProfileID: "computer-mcp"
    )
    let requesterProvider = CodexElevationTools(
      owner: requester,
      database: database
    )
    let localAdministratorProvider = CodexElevationTools(
      owner: CodexRuntimeOwner(
        workspaceID: workspace.id,
        profileID: GatewayProfileID.localAdmin.rawValue,
        caller: GatewayCallerKind.localCLI.rawValue,
        transport: "control_socket",
        socketConnectionID: "local-control",
        tunnelInstanceID: nil,
        tunnelProfileID: nil
      ),
      database: database
    )

    await #expect(throws: (any Error).self) {
      try await requesterProvider.callToolAsync(
        name: "codex.app.elevation.request",
        arguments: .object([
          "mode": .string("bounded-time"),
          "reason": .string("Reject a malformed optional turn limit."),
          "maximum_turn_count": .string("many"),
        ])
      )
    }

    func requestGrant(expectedEffectiveSandbox: JSONValue) async throws -> String {
      let result = try providerResult(
        await requesterProvider.callToolAsync(
          name: "codex.app.elevation.request",
          arguments: .object([
            "mode": .string("thread-scoped-ttl"),
            "thread_id": .string("thread-1"),
            "reason": .string("Exercise exact effective-state reporting."),
          ])
        )
      )
      #expect(result["effective_sandbox"] == expectedEffectiveSandbox)
      return try #require(result["grant"]?.objectValue?["id"]?.stringValue)
    }

    let firstID = try await requestGrant(expectedEffectiveSandbox: .null)
    let firstApproval = try providerResult(
      await localAdministratorProvider.callToolAsync(
        name: "codex.app.elevation.approve",
        arguments: .object(["grant_id": .string(firstID)])
      )
    )
    #expect(firstApproval["effective_next_eligible_start"] == .bool(true))
    let approvalReview = try #require(
      firstApproval["grant"]?.objectValue?["local_approval_review"]?.objectValue
    )
    #expect(
      approvalReview["workspace"]?.objectValue?["display_name"]
        == .string("Elevation Fixture")
    )
    #expect(approvalReview["impact"]?.objectValue?["network_access"] == .bool(true))
    #expect(
      approvalReview["impact"]?.objectValue?["git_metadata_direct_write"] == .bool(true)
    )
    #expect(
      approvalReview["impact"]?.objectValue?[
        "sandbox_restriction_to_registered_workspace_removed"
      ] == .bool(true)
    )
    #expect(
      approvalReview["revoke"]?.objectValue?["cli_argv"]?.arrayValue
        == [
          .string("computer-mcp"), .string("codex"), .string("elevation"),
          .string("revoke"), .string(firstID), .string("--workspace-id"),
          .string(workspace.id),
        ]
    )
    #expect(
      firstApproval["effective"]?.objectValue?["effective_sandbox"]
        == .string("danger-full-access")
    )

    let secondID = try await requestGrant(expectedEffectiveSandbox: .string("danger-full-access"))
    _ = try await localAdministratorProvider.callToolAsync(
      name: "codex.app.elevation.approve",
      arguments: .object(["grant_id": .string(secondID)])
    )
    let firstRevocation = try providerResult(
      await requesterProvider.callToolAsync(
        name: "codex.app.elevation.revoke",
        arguments: .object(["grant_id": .string(firstID)])
      )
    )
    #expect(firstRevocation["effective_next_turn"] == .string("danger-full-access"))

    let secondRevocation = try providerResult(
      await requesterProvider.callToolAsync(
        name: "codex.app.elevation.revoke",
        arguments: .object(["grant_id": .string(secondID)])
      )
    )
    #expect(secondRevocation["effective_next_turn"] == .null)
  }

}
private func providerResult(_ response: JSONValue) throws -> [String: JSONValue] {
  try #require(response.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
}
