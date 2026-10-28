import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPGateway

extension WorktreeHTTPAcceptanceTests {
  @Test func differentHTTPPrincipalCannotReadAStandingExecution() async throws {
    let f = try FixedHostFixture(
      fullAccess: false, lifecycle: true, caller: .cloudflareTunnel, gitExecutable: gitExecutable)
    try await f.run { f in
      try await f.initializeRepository()
      let owner = GatewayHTTPRuntime(
        configuration: f.configuration, registry: f.runtime, host: "127.0.0.1", port: 0,
        publicBaseURL: nil, accessToken: "standing-owner")
      let foreign = GatewayHTTPRuntime(
        configuration: f.configuration, registry: f.runtime, host: "127.0.0.1", port: 0,
        publicBaseURL: nil, accessToken: "standing-foreign")
      try await owner.startListening()
      try await foreign.startListening()
      let client = try await GatewayClientSession.connectHTTP(
        endpoint: URL(string: "http://127.0.0.1:\(try #require(await owner.boundPort()))/mcp")!,
        accessToken: "standing-owner")
      let other = try await GatewayClientSession.connectHTTP(
        endpoint: URL(string: "http://127.0.0.1:\(try #require(await foreign.boundPort()))/mcp")!,
        accessToken: "standing-foreign")
      do {
        let made = try await call(
          client, "git.worktree_add", "fixture", ["name": .string("principal")])
        let id = try #require(made["project_id"]?.stringValue)
        let started = try await call(
          client, "shell.spawn", id, ["command": .string("sleep 60"), "shell": .string("/bin/sh")])
        let session = try #require(started["session_id"]?.stringValue)
        let denied = try await other.call(
          toolName: "shell.read",
          arguments: .object([
            "project_id": .string(id), "session_id": .string(session),
          ]))
        #expect(denied.result.objectValue?["isError"] == .bool(true))
        let running = try await call(client, "shell.read", id, ["session_id": .string(session)])
        #expect(running["is_running"] == .bool(true))
        _ = try await call(client, "shell.cancel", id, ["session_id": .string(session)])
        _ = try await call(client, "git.worktree_remove", id)
        print("WORKTREE_HTTP foreign_principal=denied owner_execution=unaffected")
        await other.disconnect()
        await client.disconnect()
        await foreign.stop()
        await owner.stop()
      } catch {
        await other.disconnect()
        await client.disconnect()
        await foreign.stop()
        await owner.stop()
        throw error
      }
    }
  }

  @Test func endedConnectionConsentCannotReadThroughANewHTTPConnection() async throws {
    let f = try FixedHostFixture(
      fullAccess: true, lifecycle: true, caller: .cloudflareTunnel, gitExecutable: gitExecutable)
    try await f.run { f in
      try await f.initializeRepository()
      let http = GatewayHTTPRuntime(
        configuration: f.configuration, registry: f.runtime, host: "127.0.0.1", port: 0,
        publicBaseURL: nil, accessToken: "connection-consent")
      try await http.startListening()
      let endpoint = URL(string: "http://127.0.0.1:\(try #require(await http.boundPort()))/mcp")!
      var client = try await GatewayClientSession.connectHTTP(
        endpoint: endpoint, accessToken: "connection-consent")
      do {
        let first = try #require(await http.controlSessions().first)
        _ = try await http.approveControlSession(
          id: first.id, lifetime: .thisSession, expectedRevision: first.revision,
          expectedTrustRevision: 0)
        let made = try await call(
          client, "git.worktree_add", "fixture", ["name": .string("connection")])
        let id = try #require(made["project_id"]?.stringValue)
        let started = try await call(
          client, "shell.spawn", id, ["command": .string("sleep 60"), "shell": .string("/bin/sh")])
        let session = try #require(started["session_id"]?.stringValue)
        await client.disconnect()
        client = try await GatewayClientSession.connectHTTP(
          endpoint: endpoint, accessToken: "connection-consent")
        let second = try #require(await http.controlSessions().first)
        #expect(second.id != first.id && second.principalID == first.principalID)
        _ = try await http.approveControlSession(
          id: second.id, lifetime: .thisSession, expectedRevision: second.revision,
          expectedTrustRevision: 0)
        let denied = try await client.call(
          toolName: "shell.read",
          arguments: .object([
            "project_id": .string(id), "session_id": .string(session),
          ]))
        #expect(denied.result.objectValue?["isError"] == .bool(true))
        _ = try await call(client, "git.worktree_remove", id)
        print("WORKTREE_HTTP ended_connection_consent=denied_after_fresh_consent")
        await client.disconnect()
        await http.stop()
      } catch {
        await client.disconnect()
        await http.stop()
        throw error
      }
    }
  }
}
