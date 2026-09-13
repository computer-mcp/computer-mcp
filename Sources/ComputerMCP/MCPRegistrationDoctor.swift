import Foundation

/// A fresh connection observation, not proof of tool execution or a caller profile's permissions.
package struct MCPRegistrationDoctorReport: Codable, Equatable, Sendable {
  package enum Status: String, Codable, Sendable { case passed, failed, disabled }
  package let registrationID: String
  package let workspaceID: String
  package let currentDigest: String
  package let checkedAt: Date
  package var status: Status
  package var stage: String
  package var catalogReceived = false
  package var protocolVersion: String?
  package var serverVersion: String?
  package var executableInspection: ExecutableInspection?
  package var processReceipts: [MCPProcessReceiptStatus]?
  package var errorCode: String?
  package var message: String
  package var scope = "connection_and_catalog"
  package var notChecked = [
    "tool_execution", "remote_profile_access", "system_permissions", "host_persistence",
  ]
}

extension AppControlPlaneService {
  package func doctorMCPRegistration(id: String, workspaceID: String) async throws
    -> MCPRegistrationDoctorReport
  {
    guard !pluginMutationInProgress else { throw PluginHostError.changeInProgress }
    let snapshot = try mcpRegistrations()
    guard let entry = snapshot.registrations.first(where: { $0.id == id }) else {
      throw GatewayToolError.unknownMCPServer(id)
    }
    guard let workspace = try database.workspace(id: workspaceID) else {
      throw GatewayToolError.invalidArguments("Unknown registered workspace.")
    }
    var report = MCPRegistrationDoctorReport(
      registrationID: id, workspaceID: workspaceID, currentDigest: snapshot.currentDigest,
      checkedAt: Date(), status: .disabled, stage: "configuration",
      message: "The registration is disabled; no connection was started.")
    let ownershipRoot =
      database.mcpProcessOwnershipRoot
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "computer-mcp-mcp-processes", isDirectory: true)
    func inspectCleanup() throws {
      guard entry.server.transport == .stdio else { return }
      let access = try bookmarkService.resolve(workspace)
      defer { access.close() }
      report.processReceipts = try MCPProcessOwnership.inspect(
        root: ownershipRoot, workspace: access.rootURL, registration: id)
      if report.processReceipts?.contains(where: \.blocksLaunch) == true {
        report.status = .failed
        report.stage = "cleanup"
        report.errorCode = "mcp.cleanup_unconfirmed"
        report.message =
          "Previous MCP cleanup is unconfirmed. Review the process records before starting another connection."
      }
    }
    do { try inspectCleanup() } catch {
      report.status = .failed
      report.stage = "cleanup"
      report.errorCode = "mcp.ownership_storage"
      report.message = error.localizedDescription
    }
    guard entry.server.enabled, report.status != .failed else { return report }
    if let authentication = entry.server.authentication {
      do {
        try authentication.validate(endpoint: entry.server.url, transport: entry.server.transport)
        _ = try await authentication.bearerToken(from: secretStore)
      } catch {
        report.status = .failed
        report.stage = "authentication"
        report.errorCode = "mcp.authentication"
        report.message = error.localizedDescription
        return report
      }
    }
    if entry.server.transport == .stdio {
      let access = try bookmarkService.resolve(workspace)
      defer { access.close() }
      let inspection = ExecutableInspection.inspect(
        entry.server.command ?? "",
        workingDirectory: entry.server.resolvedWorkingDirectory(base: access.rootURL),
        environment: ProcessInfo.processInfo.environment.merging(entry.server.env) { _, value in
          value
        })
      report.executableInspection = inspection
      if inspection.hasKnownFailure {
        report.status = .failed
        report.stage = "executable"
        report.message = inspection.message
        return report
      }
    }

    // Discovery is explicitly invoked after the real runtime has attached its host context.
    // Package resolution has already selected the executable and launch settings.
    var server = entry.server
    server.exposure = .gateway
    server.prefix = nil
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .chatGPTObserve),
      profiles: [
        .init(
          id: .chatGPTObserve, capabilities: ["mcp.tools.list", "mcp.servers.status"],
          workspaces: [workspaceID], allowedCallers: [.localCLI], mcpServers: [id])
      ],
      mcp: .init(servers: [server]))
    // This ephemeral read-only scope has no persistence authority or unrelated providers.
    let runtime = try await GatewayRuntime.make(
      configuration: configuration, registeredWorkspaces: [workspace],
      bookmarkService: bookmarkService,
      mcpClient: MCPProxyClient(secretStore: secretStore, processOwnershipRoot: ownershipRoot),
      plugins: [], bundledPlugins: .load(directory: nil))
    let arguments: JSONValue = .object([
      "server": .string(id), "workspace_id": .string(workspaceID),
    ])
    do {
      let catalog = try await runtime.callToolForMCPAsync(
        name: "mcp.tools.list", arguments: arguments)
      let status = try await runtime.callToolForMCPAsync(
        name: "mcp.servers.status", arguments: arguments)
      let statusResult = status.objectValue?["structuredContent"]?.objectValue?["result"]
      let payload = statusResult?.objectValue?["servers"]?.arrayValue?.first?.objectValue
      let connection = payload?["connection"]?.objectValue
      report.stage = "connection_and_catalog"
      let tools = catalog.objectValue?["structuredContent"]?.objectValue?["result"]?.arrayValue
      let connected = connection?["state"] == .string("connected")
      report.status =
        connected && tools != nil && catalog.objectValue?["isError"] != .bool(true)
        ? .passed : .failed
      report.catalogReceived = tools != nil && catalog.objectValue?["isError"] != .bool(true)
      let initialization = connection?["initialize"]?.objectValue
      report.protocolVersion = initialization?["protocolVersion"]?.stringValue
      report.serverVersion = initialization?["serverInfo"]?.objectValue?["version"]?.stringValue.map
      { String($0.prefix(128)) }
      report.errorCode =
        catalog.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]?
        .stringValue
      report.message =
        report.status == .passed
        ? "The selected MCP initialized and returned its tool catalog. Tool execution and production permissions were not checked."
        : "The selected MCP did not complete connection and catalog discovery. Check the launch configuration, endpoint authentication and system permissions."
      await runtime.shutdown()
      try inspectCleanup()
      return report
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  package func recoverMCPProcessReceipt(
    id: String, workspaceID: String, receiptID: String, expectedReceiptDigest: String,
    expectedCurrentDigest: String
  ) throws {
    guard !pluginMutationInProgress else { throw PluginHostError.changeInProgress }
    let snapshot = try mcpRegistrations()
    guard snapshot.currentDigest == expectedCurrentDigest else {
      throw GatewayToolError.invalidArguments(
        "MCP configuration changed. Check the registration again.")
    }
    guard let entry = snapshot.registrations.first(where: { $0.id == id }),
      entry.server.transport == .stdio,
      let workspace = try database.workspace(id: workspaceID)
    else {
      throw GatewayToolError.invalidArguments("Select a stdio MCP and a registered workspace.")
    }
    let access = try bookmarkService.resolve(workspace)
    defer { access.close() }
    try MCPProcessOwnership.recover(
      root: database.mcpProcessOwnershipRoot
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "computer-mcp-mcp-processes", isDirectory: true),
      workspace: access.rootURL, registration: id, id: receiptID,
      expectedDigest: expectedReceiptDigest)
  }
}
