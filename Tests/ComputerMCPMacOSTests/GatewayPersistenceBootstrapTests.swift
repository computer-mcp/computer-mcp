import ComputerMCPPermissions
import ComputerMCPTestSupport
import ComputerMCPTransport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPProcess
@testable import computer_mcp

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(2)))
struct GatewayPersistenceBootstrapTests {
  enum Composition: String, CaseIterable, Sendable {
    case appHTTP, appSocket, administration, standaloneHTTP, stdio
  }

  @Test(arguments: Composition.allCases, [false, true])
  func persistedExecutionReopensInterruptedWithoutReplay(
    composition: Composition, fullAccess: Bool
  ) async throws {
    let f = try FixedHostFixture(
      fullAccess: fullAccess, lifecycle: true, caller: .cloudflareTunnel,
      allowedCallers: [.cloudflareTunnel, .localMCP, .localCLI])
    try await f.run { f in
      try await f.initializeRepository()
      let (path, saved, bytes) = try await seed(f, fullAccess: fullAccess)
      let sessionID = saved.snapshot.sessionID

      let reopened = f.database
      let manifest = f.root.appendingPathComponent("standalone.toml").path
      let destination = journalDirectory(composition, root: f.root, manifest: manifest)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let restoredFile = destination.appendingPathComponent(sessionID + ".json")
      try bytes.write(to: restoredFile)

      func check() throws {
        let record = try JSONDecoder().decode(
          TerminalSessionJournal.Record.self, from: Data(contentsOf: restoredFile))
        #expect(record.snapshot.executionID == saved.snapshot.executionID)
        #expect(!record.snapshot.isRunning && record.snapshot.endReason == .interrupted)
        #expect(record.members.isEmpty)
        #expect(try String(contentsOfFile: path + "/launches", encoding: .utf8) == "once")
      }

      switch composition {
      case .appHTTP, .appSocket, .administration:
        let app = try await GatewayManagedHostFixture(f, database: reopened)
        switch composition {
        case .appHTTP:
          let sessions = try await app.service.makeHTTPSessions(
            profileID: .chatGPTOperate,
            trace: .init(transport: "http", tunnelInstanceID: "bootstrap"))
          do {
            try check()
            let other = try await sessions.makeSession("unrelated-client")
            #expect(!(try await other.listToolsAsync(context: .empty)).isEmpty)
            other.session.end()
            await sessions.shutdown()
          } catch {
            await sessions.shutdown()
            throw error
          }
        case .appSocket:
          try await app.service.start(profile: .chatGPTOperate)
          do {
            try check()
            let other = try await GatewayClientSession.connectSocket(
              socketURL: f.root.appendingPathComponent("gateway.sock"))
            #expect(!(try await other.listToolNames()).isEmpty)
            await other.disconnect()
            await app.service.stop()
          } catch {
            await app.service.stop()
            throw error
          }
        case .administration:
          let epoch = try await app.service.startLocalAdministration()
          do {
            try check()
            let other = GatewaySocketConnectionIdentity(
              trustedPrincipalID: "unrelated-owner", origin: .localCLI)
            #expect(!(try await app.service.localAdminTools(identity: other, epoch: epoch)).isEmpty)
            await app.service.stopLocalAdministration(epoch: epoch)
          } catch {
            await app.service.stopLocalAdministration(epoch: epoch)
            throw error
          }
        default: preconditionFailure()
        }
      case .standaloneHTTP, .stdio:
        let sessions: GatewayTerminalSessions
        if composition == .standaloneHTTP {
          let command = try ServeHTTP.parse(["--config", manifest, "--port", "0"])
          sessions = try await command.makeTerminalSessions(
            database: reopened, platform: f.platform, configuration: f.configuration)
        } else {
          let command = try ServeStdio.parse(["--config", manifest])
          sessions = try await command.makeTerminalSessions(
            database: reopened, platform: f.platform)
        }
        try check()
        let runtime = try await GatewayRuntime.make(
          configuration: f.configuration,
          context: .init(
            caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "unrelated-client"),
          database: reopened, platform: f.platform,
          bundledPlugins: .init(packages: [], issues: []), terminalSessions: sessions)
        do {
          let other = try runtime.makeControlSession()
          #expect(other.principalID == "unrelated-client")
          other.end()
          await runtime.shutdown()
          try sessions.discardResults()
        } catch {
          await runtime.shutdown()
          throw error
        }
      }
    }
  }

  private func seed(
    _ f: FixedHostFixture, fullAccess: Bool
  ) async throws -> (String, TerminalSessionJournal.Record, Data) {
    let app = try await GatewayManagedHostFixture(f)
    let sessions = try await app.service.makeHTTPSessions(
      profileID: .chatGPTOperate, trace: .init(transport: "http", tunnelInstanceID: "seed"))
    let http = GatewayHTTPRuntime(
      configuration: f.configuration, source: .managed(sessions), host: "127.0.0.1", port: 0,
      publicBaseURL: nil, accessToken: "bootstrap-owner")
    try await http.startListening()
    let endpoint = URL(string: "http://127.0.0.1:\(try #require(await http.boundPort()))/mcp")!
    let client = try await GatewayClientSession.connectHTTP(
      endpoint: endpoint, accessToken: "bootstrap-owner")
    do {
      if fullAccess {
        let session = try #require(await http.controlSessions().first)
        _ = try await http.approveControlSession(
          id: session.id, lifetime: .alwaysAllowClient, expectedRevision: session.revision,
          expectedTrustRevision: 0)
      }
      func call(_ name: String, _ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        try payload(await client.call(toolName: name, arguments: .object(args)).result)
      }
      let project: String
      let path: String
      if fullAccess {
        project = "fixture"
        path = f.project.path
      } else {
        let made = try await call(
          "git.worktree_add", ["project_id": .string("fixture"), "name": .string("bootstrap")])
        project = try #require(made["project_id"]?.stringValue)
        path = try #require(made["path"]?.stringValue)
      }
      let launched = try await call(
        "shell.spawn",
        [
          "project_id": .string(project), "shell": .string("/bin/sh"),
          "command": .string("printf once >> launches; sleep 60"),
        ])
      let sessionID = try #require(launched["session_id"]?.stringValue)
      let read = try await call(
        "shell.read", ["project_id": .string(project), "session_id": .string(sessionID)])
      let executionID = try #require(read["execution_id"]?.stringValue)
      let encoded = Data("http:seed".utf8).base64EncodedString()
      let file = f.root.appendingPathComponent(
        "app/Executions/HTTP/" + encoded + "/" + sessionID + ".json")
      let bytes = try Data(contentsOf: file)
      let saved = try JSONDecoder().decode(TerminalSessionJournal.Record.self, from: bytes)
      try #require(
        saved.snapshot.isRunning && saved.snapshot.executionID?.uuidString == executionID)
      let deadline = ContinuousClock.now + .seconds(5)
      while !FileManager.default.fileExists(atPath: path + "/launches")
        && ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      await client.disconnect()
      await http.stop()
      return (path, saved, bytes)
    } catch {
      await client.disconnect()
      await http.stop()
      throw error
    }
  }

  private func payload(_ value: JSONValue) throws -> [String: JSONValue] {
    try #require(value.objectValue?["isError"] != .bool(true), "\(value)")
    return try #require(
      value.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
  }

  private func journalDirectory(_ composition: Composition, root: URL, manifest: String) -> URL {
    switch composition {
    case .appSocket: return root.appendingPathComponent("app/Executions/Socket")
    case .administration: return root.appendingPathComponent("app/Executions/Administration")
    default:
      let directory: URL
      let owner: String
      if composition == .appHTTP {
        directory = root.appendingPathComponent("app/Executions/HTTP")
        owner = "http:bootstrap"
      } else {
        directory = root.appendingPathComponent("Executions")
        owner =
          root.appendingPathComponent("state.sqlite").standardizedFileURL.path
          + (composition == .stdio ? ":stdio:" : ":http:")
          + URL(fileURLWithPath: manifest).standardizedFileURL.path
          + (composition == .stdio ? "" : ":0")
      }
      let encoded = Array(
        Data(owner.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: "+", with: "-"))
      return stride(from: 0, to: encoded.count, by: 120).reduce(directory) { path, offset in
        path.appendingPathComponent(String(encoded[offset..<min(offset + 120, encoded.count)]))
      }
    }
  }
}
