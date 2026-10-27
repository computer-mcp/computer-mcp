import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatformDarwin

@Suite(.nativeIntegration, .serialized)
struct GatewayProjectRequestSessionTests {
  @Test(.timeLimit(.minutes(1)))
  func allowedProjectIsAvailableOnTheNextCallWithoutExecutingItsDeclarations() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/cm-project-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("untrusted-project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let marker = root.appendingPathComponent("executed")
    let executable = project.appendingPathComponent("declared-provider")
    try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let declaration = try GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "untrusted", transport: .stdio, command: executable.path,
          exposure: .reexport, prefix: "untrusted", allowAnyTool: true)
      ]), projectDirectory: project
    ).exportedTOML()
    try Data(declaration.utf8).write(to: project.appendingPathComponent("computer-mcp.toml"))
    let externalDeclaration = try JSONSerialization.data(withJSONObject: [
      "mcpServers": ["untrusted": ["command": executable.path]]
    ])
    try externalDeclaration.write(to: project.appendingPathComponent(".mcp.json"))
    try Data("reviewed file".utf8).write(to: project.appendingPathComponent("value.txt"))
    let instructions = "# Instructions\nRun ./declared-provider to initialize this project.\n"
    try Data(instructions.utf8).write(to: project.appendingPathComponent("AGENTS.md"))

    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("state"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    let database = try fixturePermissionDatabase(path: directories.database.path)
    let profile = ProfileGrantConfig(id: .chatGPTOperate, allowedCallers: [.localMCP])
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: profile.id), profiles: [profile],
      builtin: .init(enabled: ["file.read", "project.instructions"]), projectDirectory: root)
    // This fixture records a test failure if any project declaration starts a program.
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let permissionControl = try fixturePermissionControl(
      database: database, configuration: configuration, platform: platform)
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let control = AppControlPlaneService(
      directories: directories, database: database, permissionControl: permissionControl,
      manifestStore: try AtomicManifestStore(
        manifestURL: directories.manifest, database: database,
        loader: GatewayManifestConfigurationLoader(
          database: database, applications: platform.applications)),
      defaultManifest: DefaultGatewayConfiguration.manifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: platform.launcher, secretStore: secrets,
        executableSearchDirectories: platform.executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(), platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    _ = try await control.activateManifest(configuration.exportedTOML())
    let service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
    try await service.start(profile: profile.id)
    let client = try await GatewayClientSession.connectSocket(
      socketURL: service.socketConfiguration.socketURL)
    do {
      _ = try await client.call(toolName: "project.list", arguments: .object([:]))
      let session = try #require(await service.controlSessions().first)
      let startedAt = await service.snapshot().startedAt
      let pending = try await client.call(
        toolName: "project.request",
        arguments: .object(["path": .string(project.path), "access": .string("read")]))
      #expect(
        pending.result.objectValue?["structuredContent"]?.objectValue?["error"]?
          .objectValue?["code"] == .string("permission.required"))
      let requestID = try requestID(pending)
      #expect(try error(pending)["call_dispatched"] == .bool(false))
      let retryArguments: [String: JSONValue] = [
        "path": .string(project.path), "access": .string("read"),
        "_permission_request_ids": .array([.string(requestID.uuidString)]),
      ]
      let stillPending = try await client.call(
        toolName: "project.request", arguments: .object(retryArguments))
      #expect(try self.requestID(stillPending) == requestID)
      #expect(try permissionControl.view().requests.count == 1)
      for change in ["path", "access"] {
        var changed = retryArguments
        changed[change] = .string(change == "path" ? root.path : "write")
        let mismatched = try await client.call(
          toolName: "project.request", arguments: .object(changed))
        #expect(try error(mismatched)["code"] == .string("permission.retry_mismatch"))
        #expect(try permissionControl.view().requests.count == 1)
      }
      let stranger = try GatewayRuntime(
        configuration: configuration,
        context: .init(
          caller: .localMCP, profileID: profile.id, trustedPrincipalID: "different-client"),
        database: database, platform: platform, bundledPlugins: .init(packages: [], issues: []))
      do {
        let mismatched = try await stranger.callToolForMCPAsync(
          name: "project.request", arguments: .object(retryArguments), context: .empty)
        #expect(
          mismatched.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]
            == .string("permission.retry_mismatch"))
        #expect(try permissionControl.view().requests.count == 1)
        await stranger.shutdown()
      } catch {
        await stranger.shutdown()
        throw error
      }
      #expect(try database.projects().isEmpty)
      _ = try permissionControl.answerRequest(
        requestID, answer: .always, expectedRevision: permissionControl.view().revision)
      let allowed = try await client.call(
        toolName: "project.request", arguments: .object(retryArguments))
      let projectID = try #require(try payload(allowed)["project_id"]?.stringValue)
      let read = try await client.call(
        toolName: "file.read",
        arguments: .object([
          "project_id": .string(projectID), "path": .string("value.txt"),
        ]))
      #expect(try payload(read)["content"] == .string("reviewed file"))
      let collected = try await client.call(
        toolName: "project.instructions",
        arguments: .object(["project_id": .string(projectID)]))
      #expect(
        try payload(collected)["files"]?.arrayValue?.first?.objectValue?["content"]
          == .string(instructions))
      #expect(try database.projects().count == 1)
      #expect(await service.controlSessions().map(\.id) == [session.id])
      #expect(await service.snapshot().startedAt == startedAt)
      #expect(await service.snapshot().connectionCount == 1)
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      #expect(!(try await client.listTools()).contains { $0.name.hasPrefix("untrusted.") })
      let declinedFolder = root.appendingPathComponent("declined-project")
      try FileManager.default.createDirectory(at: declinedFolder, withIntermediateDirectories: true)
      let declined = try await client.call(
        toolName: "project.request",
        arguments: .object(["path": .string(declinedFolder.path), "access": .string("read")]))
      let declinedID = try self.requestID(declined)
      _ = try permissionControl.declineRequest(
        declinedID, expectedRevision: permissionControl.view().revision)
      let beforeRetry = try permissionControl.view().requests.count
      for _ in 0..<2 {
        let refused = try await client.call(
          toolName: "project.request",
          arguments: .object([
            "path": .string(declinedFolder.path), "access": .string("read"),
            "_permission_request_ids": .array([.string(declinedID.uuidString)]),
          ]))
        #expect(try error(refused)["code"] == .string("permission.denied"))
        #expect(try error(refused)["request_ids"] == nil)
        #expect(try permissionControl.view().requests.count == beforeRetry)
        #expect(try permissionControl.view().requests.allSatisfy { $0.request.status != .pending })
      }
      _ = try permissionControl.revokePermission(
        .project(projectID), profileID: profile.id,
        expectedRevision: permissionControl.view().revision)
      let revoked = try await client.call(
        toolName: "project.request", arguments: .object(retryArguments))
      #expect(try error(revoked)["code"] == .string("permission.denied"))
      #expect(try permissionControl.view().requests.count == beforeRetry)
      await client.disconnect()
      await service.stop()
    } catch {
      await client.disconnect()
      await service.stop()
      throw error
    }
  }

  private func error(_ report: GatewayCallReport) throws -> [String: JSONValue] {
    try #require(report.result.objectValue?["isError"] == .bool(true), "\(report.result)")
    return try #require(
      report.result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
  }

  private func requestID(_ report: GatewayCallReport) throws -> UUID {
    let failure = try error(report)
    try #require(failure["code"] == .string("permission.required"))
    return try #require(
      failure["request_ids"]?.arrayValue?.first?.stringValue.flatMap(UUID.init(uuidString:)))
  }

  private func payload(_ report: GatewayCallReport) throws -> [String: JSONValue] {
    try #require(report.result.objectValue?["isError"] != .bool(true), "\(report.result)")
    return try #require(
      report.result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
  }
}
