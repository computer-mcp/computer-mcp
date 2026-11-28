import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPGateway
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import Foundation

/// A fresh connection observation, not proof of tool execution or a caller profile's permissions.
package struct MCPRegistrationDoctorReport: Codable, Equatable, Sendable {
  package enum Status: String, Codable, Sendable { case passed, failed, disabled }
  package let registrationID: String
  package let projectID: String
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
  package func doctorMCPRegistration(id: String, projectID: String) async throws
    -> MCPRegistrationDoctorReport
  {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    let snapshot = try mcpRegistrations()
    guard let entry = snapshot.registrations.first(where: { $0.id == id }) else {
      throw GatewayToolError.unknownMCPServer(id)
    }
    guard let project = try database.project(id: projectID) else {
      throw GatewayToolError.invalidArguments("Unknown registered project.")
    }
    var report = MCPRegistrationDoctorReport(
      registrationID: id, projectID: projectID, currentDigest: snapshot.currentDigest,
      checkedAt: Date(), status: .disabled, stage: "configuration",
      message: "The registration is disabled; no connection was started.")
    let ownershipRoot =
      database.mcpProcessOwnershipRoot
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "computer-mcp-mcp-processes", isDirectory: true)
    func inspectCleanup() throws {
      guard entry.server.transport == .stdio else { return }
      let access = try platform.projectGrants.resolve(project)
      defer { access.close() }
      report.processReceipts = try MCPProcessOwnership.inspect(
        root: ownershipRoot, project: access.rootURL, registration: id)
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
      let access = try platform.projectGrants.resolve(project)
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

    report.status = .failed
    report.stage = "execution"
    report.errorCode = "execution.unavailable"
    report.message = "Connection checks are unavailable in this build."
    return report
  }

  package func recoverMCPProcessReceipt(
    id: String, projectID: String, receiptID: String, expectedReceiptDigest: String,
    expectedCurrentDigest: String
  ) throws {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    let snapshot = try mcpRegistrations()
    guard snapshot.currentDigest == expectedCurrentDigest else {
      throw GatewayToolError.invalidArguments(
        "MCP configuration changed. Check the registration again.")
    }
    guard let entry = snapshot.registrations.first(where: { $0.id == id }),
      entry.server.transport == .stdio,
      let project = try database.project(id: projectID)
    else {
      throw GatewayToolError.invalidArguments("Select a stdio MCP and a registered project.")
    }
    let access = try platform.projectGrants.resolve(project)
    defer { access.close() }
    try MCPProcessOwnership.recover(
      root: database.mcpProcessOwnershipRoot
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "computer-mcp-mcp-processes", isDirectory: true),
      project: access.rootURL, registration: id, id: receiptID,
      expectedDigest: expectedReceiptDigest)
  }
}
