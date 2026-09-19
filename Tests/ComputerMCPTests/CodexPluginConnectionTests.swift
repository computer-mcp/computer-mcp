import CryptoKit
import Darwin
import Foundation
import GRDB
import MCP
import Testing

@testable import ComputerMCP

/// Real gateway transports and packaged adapter; only the vendor protocol is a disposable process.
@Suite(
  .serialized, .timeLimit(.minutes(2)),
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_CODEX_PLUGIN"] != nil))
struct CodexPluginConnectionTests {
  @Test
  func workspacesOwnIndependentProcessesAndReleasePreservesTheSibling() async throws {
    let fixture = try ConnectionFixture(workspaceCount: 2)
    defer { fixture.remove() }
    let gateway = try await fixture.gateway(
      trace: .init(transport: "fixture", socketConnectionID: "multi"))
    do {
      let first = fixture.workspaces[0]
      let second = fixture.workspaces[1]
      async let startFirst = fixture.start(gateway, workspace: first)
      async let startSecond = fixture.start(gateway, workspace: second)
      let (firstThread, secondThread) = try await (startFirst, startSecond)
      #expect(firstThread != secondThread)
      let a = try await fixture.evidence(gateway, workspace: first)
      let b = try await fixture.evidence(gateway, workspace: second)
      #expect(a.runtimeID != b.runtimeID)
      #expect(a.processes.isDisjoint(with: b.processes))
      #expect(a.owner["workspace_id"] == .string(first.id))
      #expect(b.owner["workspace_id"] == .string(second.id))
      #expect(a.processes.union(b.processes).allSatisfy(ConnectionFixture.exists))
      _ = try await fixture.base.call(
        gateway, "codex.app.thread.release", ["thread_id": .string(firstThread)],
        workspaceID: first.id)
      try await fixture.requireStopped(a, thread: firstThread, adapterExited: false)
      let sibling = try await fixture.base.call(
        gateway, "codex.app.thread.loaded.list", workspaceID: second.id)
      #expect(sibling.objectValue?["data"]?.arrayValue == [.string(secondThread)])
      #expect(b.processes.allSatisfy(ConnectionFixture.exists))
      await gateway.shutdown()
      try await fixture.requireStopped(a, thread: firstThread)
      try await fixture.requireStopped(b, thread: secondThread)
    } catch {
      await gateway.shutdown()
      throw error
    }
  }

  @Test(arguments: ["disconnect", "abrupt", "tunnel-reconnect"])
  func reconnectRetainsOwnedExecutionUntilTheListenerStops(mode: String) async throws {
    let fixture = try ConnectionFixture()
    defer { fixture.remove() }
    let socketRoot = URL(fileURLWithPath: "/tmp/cm-plugin-" + UUID().uuidString.prefix(8))
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let credential = fixture.base.root.appendingPathComponent("tunnel-auth")
    try GatewaySocketCredentialStore.create(at: credential)
    var socketConfiguration = GatewaySocketConfiguration(
      socketURL: socketRoot.appendingPathComponent("gateway.sock"))
    socketConfiguration.tunnelCredentialFile = credential
    let owner = ConnectionRuntimeOwner(fixture: fixture)
    let server = GatewaySocketServer(
      configuration: socketConfiguration,
      sessionFactory: { identity in
        let gateway = try await owner.admit(identity)
        let server = await MCPRuntimeAdapter.makeGatewayServer(
          configuration: fixture.configuration, registry: gateway)
        return GatewaySocketServerSession(server: server)
      })
    try await server.start()
    var original: ConnectionEvidence?
    var originalThread: String?
    do {
      for generation in 1...2 {
        var clientConfiguration = socketConfiguration
        if mode == "tunnel-reconnect" {
          clientConfiguration.clientIdentity = .secureTunnel(
            credentialFile: credential, tunnelInstanceID: "tunnel-\(generation)",
            tunnelProfileID: "fixture")
        }
        let transport = GatewaySocketTransport(configuration: clientConfiguration)
        let client = MCP.Client(name: "plugin-connection", version: "1")
        do {
          _ = try await client.connect(transport: transport)
          let workspace = fixture.workspaces[0]
          if originalThread == nil {
            let started = try await fixture.call(
              client, "codex.app.thread.start", workspace: workspace)
            originalThread = try #require(
              started.objectValue?["thread"]?.objectValue?["id"]?.stringValue)
          } else {
            let loaded = try await fixture.call(
              client, "codex.app.thread.loaded.list", workspace: workspace)
            #expect(
              loaded.objectValue?["data"]?.arrayValue == [.string(try #require(originalThread))])
          }
          let status = try await fixture.call(client, "codex.app.status", workspace: workspace)
          let evidence = try ConnectionEvidence(status)
          if let original {
            #expect(evidence.runtimeID == original.runtimeID)
            #expect(evidence.processes == original.processes)
            #expect(evidence.owner["principal_id"] == original.owner["principal_id"])
          } else {
            original = evidence
          }
          #expect(evidence.owner["workspace_id"] == .string(workspace.id))
          #expect(
            evidence.owner["caller"]
              == .string(mode == "tunnel-reconnect" ? "secure-tunnel" : "local-mcp"))
          if mode == "tunnel-reconnect" {
            #expect(evidence.owner["tunnel_instance_id"] == .string("tunnel-1"))
          }
          #expect(evidence.processes.allSatisfy(ConnectionFixture.exists))
          if mode == "abrupt" { await transport.disconnect() } else { await client.disconnect() }
          let cleanupDeadline = ContinuousClock.now + .seconds(2)
          var remainingConnections = await server.connectionCount()
          while remainingConnections != 0, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(20))
            remainingConnections = await server.connectionCount()
          }
          #expect(remainingConnections == 0)
          #expect(evidence.processes.allSatisfy(ConnectionFixture.exists))
          await client.disconnect()
        } catch {
          await client.disconnect()
          await transport.disconnect()
          throw error
        }
      }
      let admissions = await owner.identities
      #expect(Set(admissions.map(\.connectionID)).count == 2)
      #expect(Set(admissions.map(\.trustedPrincipalID)).count == 1)
      await server.stop()
      await owner.shutdown()
      try await fixture.requireStopped(try #require(original), thread: try #require(originalThread))
    } catch {
      await server.stop()
      await owner.shutdown()
      throw error
    }
  }

  @Test
  func httpOriginStopReleasesThePluginAndItsVendorWriter() async throws {
    let fixture = try ConnectionFixture()
    defer { fixture.remove() }
    let gateway = try await fixture.gateway(
      caller: .cloudflareTunnel,
      trace: .init(transport: "http"))
    let runtime = GatewayHTTPRuntime(
      configuration: fixture.configuration, registry: gateway, host: "127.0.0.1", port: 0,
      publicBaseURL: nil)
    try await runtime.startListening()
    do {
      let port = try #require(await runtime.boundPort())
      let session = try await GatewayClientSession.connectHTTP(
        endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")), streaming: false)
      let workspace = fixture.workspaces[0]
      let started = try await session.call(
        toolName: "codex.app.thread.start",
        arguments: .object([
          "workspace_id": .string(workspace.id)
        ]))
      let thread = try #require(
        started.result.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["thread"]?.objectValue?["id"]?.stringValue)
      let status = try await session.call(
        toolName: "codex.app.status",
        arguments: .object([
          "workspace_id": .string(workspace.id)
        ]))
      let evidence = try ConnectionEvidence(
        try #require(status.result.objectValue?["structuredContent"]?.objectValue?["result"]))
      #expect(evidence.owner["caller"] == .string("cloudflare-tunnel"))
      #expect(evidence.owner["transport"] == .string("http"))
      #expect(evidence.owner["tunnel_instance_id"] == nil)
      #expect(evidence.owner["principal_id"]?.stringValue?.isEmpty == false)
      await runtime.stop()
      await session.disconnect()
      try await fixture.requireStopped(evidence, thread: thread)
    } catch {
      await runtime.stop()
      throw error
    }
  }
}

/// The listener, not an individual protocol session, owns admitted executions.
private actor ConnectionRuntimeOwner {
  let fixture: ConnectionFixture
  var identities: [GatewaySocketConnectionIdentity] = []
  private var runtimes: [String: GatewayRuntime] = [:]
  init(fixture: ConnectionFixture) { self.fixture = fixture }
  func admit(_ identity: GatewaySocketConnectionIdentity) async throws -> GatewayRuntime {
    identities.append(identity)
    let key = identity.trustedPrincipalID + ":" + identity.caller.rawValue
    if let runtime = runtimes[key] { return runtime }
    let runtime = try await fixture.gateway(
      caller: identity.caller, trace: identity.transportTrace,
      principalID: identity.trustedPrincipalID)
    runtimes[key] = runtime
    return runtime
  }
  func shutdown() async {
    for runtime in runtimes.values { await runtime.shutdown() }
    runtimes.removeAll()
  }
}

private struct ConnectionEvidence: Sendable {
  let runtimeID: String
  let owner: [String: JSONValue]
  let vendor: Int32
  let supervisor: Int32
  let adapter: Int32
  var processes: Set<Int32> { [vendor, supervisor, adapter] }
  init(_ status: JSONValue) throws {
    let object = try #require(status.objectValue)
    runtimeID = try #require(object["runtime_id"]?.stringValue)
    owner = try #require(object["owner"]?.objectValue)
    let process = try #require(object["process"]?.objectValue)
    vendor = try #require(process["process_id"]?.intValue).asPID()
    supervisor = try #require(process["supervisor_process_id"]?.intValue).asPID()
    adapter = try #require(process["parent_process_id"]?.intValue).asPID()
  }
}

extension Int {
  fileprivate func asPID() throws -> Int32 {
    try #require(self > 1 && self <= Int(Int32.max))
    return Int32(self)
  }
}

private final class ConnectionFixture: Sendable {
  let base: BoundServicesFixture
  let workspaces: [RegisteredWorkspace]
  let configuration: GatewayConfiguration
  init(workspaceCount: Int = 1) throws {
    base = try BoundServicesFixture(prefix: "")
    try Data().write(to: base.root.appendingPathComponent("workspace-thread-ids"))
    var registered = [base.workspace]
    if workspaceCount == 2 {
      let directory = base.root.appendingPathComponent("sibling")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let workspace = RegisteredWorkspace(
        id: UUID().uuidString, displayName: "Sibling", rootPath: directory.path)
      try base.database.saveWorkspace(workspace)
      registered.append(workspace)
    }
    workspaces = registered
    let callers: [GatewayCallerKind] = [.secureTunnel, .localMCP, .cloudflareTunnel]
    var configured = base.configuration(workspaces: registered)
    configured.profiles[0].allowedCallers = callers
    configuration = configured
    try base.database.saveProfile(
      .init(
        id: .chatGPTOperate, capabilityIDs: Set(configured.profiles[0].capabilities),
        workspaceIDs: Set(registered.map(\.id)), allowedCallers: Set(callers),
        mode: .workspaceOperations))
  }
  func gateway(
    caller: GatewayCallerKind = .secureTunnel, trace: GatewayTransportTrace,
    principalID: String = "connection-fixture"
  ) async throws
    -> GatewayRuntime
  {
    try await GatewayRuntime.make(
      configuration: configuration,
      context: .init(
        caller: caller, profileID: .chatGPTOperate, transportTrace: trace,
        trustedPrincipalID: principalID),
      database: base.database, registeredWorkspaces: workspaces)
  }
  func start(_ gateway: GatewayRuntime, workspace: RegisteredWorkspace) async throws -> String {
    let result = try await base.call(gateway, "codex.app.thread.start", workspaceID: workspace.id)
    return try #require(result.objectValue?["thread"]?.objectValue?["id"]?.stringValue)
  }
  func evidence(_ gateway: GatewayRuntime, workspace: RegisteredWorkspace) async throws
    -> ConnectionEvidence
  {
    try await ConnectionEvidence(base.call(gateway, "codex.app.status", workspaceID: workspace.id))
  }
  func call(_ client: MCP.Client, _ name: String, workspace: RegisteredWorkspace) async throws
    -> JSONValue
  {
    let request = try await client.send(
      MCP.CallTool.request(
        .init(
          name: name, arguments: ["workspace_id": .string(workspace.id)])))
    let response = try await request.value
    try #require(response.isError != true, "\(name): \(response.content)")
    return try JSONDecoder().decode(
      JSONValue.self,
      from: JSONEncoder().encode(
        try #require(response.structuredContent?.objectValue?["result"])))
  }
  func requireStopped(_ evidence: ConnectionEvidence, thread: String, adapterExited: Bool = true)
    async throws
  {
    let processes: Set<Int32> =
      adapterExited ? evidence.processes : [evidence.vendor, evidence.supervisor]
    let deadline = ContinuousClock.now + .seconds(10)
    while processes.contains(where: Self.exists), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!processes.contains(where: Self.exists), "Owned processes still alive: \(processes)")
    let identity = try JSONEncoder().encode([
      try #require(evidence.owner["principal_id"]?.stringValue),
      try #require(evidence.owner["profile_id"]?.stringValue),
      try #require(evidence.owner["workspace_id"]?.stringValue),
    ])
    let scope = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    let database = base.root.appendingPathComponent("adapter-state/subjects/\(scope)/codex.sqlite")
    var configuration = Configuration()
    configuration.readonly = true
    let inspection = try DatabaseQueue(path: database.path, configuration: configuration)
    let (text, threadState) = try await inspection.read { db in
      (
        try String.fetchOne(
          db, sql: "SELECT payloadJSON FROM codexRuntimeLeases WHERE id = ?",
          arguments: [evidence.runtimeID]),
        try String.fetchOne(
          db, sql: "SELECT state FROM codexThreadOwnership WHERE threadID = ?", arguments: [thread])
      )
    }
    try inspection.close()
    let record = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(text).utf8))
    #expect(record.objectValue?["state"] == .string("stopped"))
    #expect(record.objectValue?["owner"] == .object(evidence.owner))
    #expect(threadState == "released")
  }
  static func exists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
  func remove() { base.remove() }
}
