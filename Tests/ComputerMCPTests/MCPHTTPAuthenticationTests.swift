import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct MCPHTTPAuthenticationTests {
  @Test(arguments: ["source", "endpoint", "ambiguous"])
  func inactivePluginCredentialsRequireUnambiguousCurrentSourceAndEndpoint(change: String)
    async throws
  {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    let store = PluginStore(database: fixture.database)
    let endpoint = "https://example.test/mcp"
    func register(_ id: String) async throws -> URL {
      let root = fixture.root.appendingPathComponent(id)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try
        "id='\(id)'\nname='HTTP fixture'\nversion='1.0.0'\n[[mcp]]\nid='remote'\ntransport='http'\nurl='\(endpoint)'\n"
        .write(
          to: root.appendingPathComponent(PluginManifest.filename), atomically: true,
          encoding: .utf8)
      let registered = try await store.registerDevelopment(
        at: root, expectedRevision: fixture.database.pluginStoreSnapshot().revision)
      _ = try await store.setSettings(
        .init(
          enabled: false,
          mcp: [
            "remote": .init(
              registrationID: "remote",
              authentication: .init(
                endpoint: endpoint, keychainAccount: "mcp.inactive"))
          ]), for: id, expectedRevision: registered.revision)
      return root
    }
    let root = try await register("first")
    let original = try await fixture.host.mcpCredentialStatus(id: "remote")
    #expect(!original.present)
    #expect(try await fixture.host.mcpRegistrations().registrations.isEmpty)
    switch change {
    case "source":
      let manifest = root.appendingPathComponent(PluginManifest.filename)
      try String(contentsOf: manifest, encoding: .utf8)
        .replacingOccurrences(of: "1.0.0", with: "2.0.0")
        .write(to: manifest, atomically: true, encoding: .utf8)
    case "endpoint":
      let state = try fixture.database.pluginStoreSnapshot()
      var settings = try #require(state.settings["first"])
      settings.mcp["remote"]?.authentication = .init(
        endpoint: "https://other.test/mcp", keychainAccount: "mcp.inactive")
      _ = try await store.setSettings(settings, for: "first", expectedRevision: state.revision)
    default:
      _ = try await register("second")
    }
    let before = try fixture.database.configurationState()
    await #expect(throws: (any Error).self) {
      try await fixture.host.mcpCredentialStatus(id: "remote")
    }
    await #expect(throws: (any Error).self) {
      try await fixture.host.changeMCPCredential(
        id: "remote", expectedBindingDigest: original.bindingDigest, token: "fixture-token")
    }
    #expect(try fixture.database.configurationState() == before)
    let secrets = await fixture.host.secretStore
    #expect(
      try await !secrets.containsAsynchronously(
        SecretReference(account: "mcp.inactive"), authenticationUI: .fail))
  }

  @Test(arguments: [
    "http://example.com/mcp", "https://user:pass@example.com/mcp",
    "https://example.com/mcp#fragment", "file:///mcp",
  ])
  func unsafeCredentialDestinationsAreRejected(endpoint: String) throws {
    let binding = MCPHTTPAuthentication(endpoint: endpoint, keychainAccount: "mcp.test")
    #expect(throws: (any Error).self) {
      try binding.validate(endpoint: endpoint, transport: .streamableHTTP)
    }
  }

  @Test
  func bindingsAreStrictAndConfigurationContainsOnlyReferences() throws {
    let binding = MCPHTTPAuthentication(
      endpoint: "https://example.test/mcp", keychainAccount: "mcp.test")
    #expect(throws: (any Error).self) {
      try binding.validate(endpoint: "https://other.test/mcp", transport: .http)
    }
    #expect(throws: (any Error).self) {
      try binding.validate(endpoint: binding.endpoint, transport: .stdio)
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        MCPHTTPAuthentication.self,
        from: Data(
          #"{"endpoint":"https://example.test/mcp","keychain_account":"mcp.test","token":"untrusted"}"#
            .utf8))
    }
    var configuration = GatewayConfiguration()
    configuration.mcp.servers = [
      .init(id: "remote", transport: .http, url: binding.endpoint, authentication: binding)
    ]
    let exported = try configuration.exportedTOML()
    #expect(exported.contains("keychain_account"))
    #expect(try GatewayConfiguration.load(text: exported).mcp.servers == configuration.mcp.servers)
    #expect(throws: (any Error).self) {
      try PluginManifest.parse(
        "id='untrusted'\nname='Untrusted'\nversion='1.0.0'\n[[mcp]]\nid='remote'\ntransport='http'\nurl='https://example.test/mcp'\n[mcp.authentication]\nendpoint='https://example.test/mcp'\nkeychain_account='mcp.test'\n"
      )
    }
  }

  @Test(arguments: ["unavailable", "missing", "invalid"])
  func credentialsFailBeforeAnyNetworkRequest(state: String) async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let store = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
      let binding = MCPHTTPAuthentication(
        endpoint: fixture.endpoint.absoluteString, keychainAccount: "mcp.fixture")
      if state == "invalid" {
        try store.set("invalid\nheader", for: SecretReference(account: binding.keychainAccount))
      }
      let client = MCPProxyClient(secretStore: state == "unavailable" ? nil : store)
      let server = MCPServerConfig(
        id: "remote", transport: .http, url: binding.endpoint, authentication: binding)
      await #expect(throws: (any Error).self) {
        try await BlockingOperationExecutor(label: "missing-mcp-credential").perform {
          try client.listTools(server: server)
        }
      }
      await client.shutdown()
      #expect(try fixture.requests().isEmpty)
    }
  }

  @Test
  func redirectsDoNotReplayAuthenticatedRequests() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = MCPHTTPClientTransport(
        endpoint: fixture.endpoint.deletingLastPathComponent().appendingPathComponent("redirect"),
        streaming: false, bearerToken: { "fixture-token" })
      try await transport.connect()
      await #expect(throws: MCPHTTPTransportError.httpStatus(307)) {
        try await transport.send(
          Data(#"{"jsonrpc":"2.0","id":"redirect","method":"initialize","params":{}}"#.utf8))
      }
      await transport.disconnect()
      #expect(try fixture.requests().count == 1)
    }
  }

  @Test(arguments: [false, true])
  func ownerCredentialWorkflowReachesDoctorAndLiveDirectOrPluginRequests(plugin: Bool) async throws
  {
    try await HTTPStreamProcessFixture.withFixture { http in
      let fixture = try MCPRegistrationControlFixture()
      defer { fixture.remove() }
      let binding = MCPHTTPAuthentication(
        endpoint: http.endpoint.absoluteString, keychainAccount: "mcp.fixture")
      var configuration = GatewayConfiguration(workspaceDirectory: fixture.root)
      configuration.profiles = [
        .init(
          id: .chatGPTOperate, capabilities: ["*"], workspaces: ["fixture"],
          allowedCallers: [.localCLI])
      ]
      if !plugin {
        configuration.mcp.servers = [
          .init(
            id: "remote", transport: .http, url: binding.endpoint,
            exposure: .reexport, prefix: "remote", allowAnyTool: true,
            toolRisks: ["inspect": .readOnly], authentication: binding)
        ]
      }
      _ = try await fixture.host.activateManifest(configuration.exportedTOML())
      try fixture.database.saveWorkspace(
        .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
      try fixture.database.saveProfile(
        .init(
          id: .chatGPTOperate, capabilityIDs: ["*"], workspaceIDs: ["fixture"],
          allowedCallers: [.localCLI]))
      if plugin {
        let root = fixture.root.appendingPathComponent("http-plugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(
          "id='http-fixture'\nname='HTTP fixture'\nversion='1.0.0'\n[[mcp]]\nid='remote'\ntransport='http'\nurl='\(binding.endpoint)'\n"
            .utf8
        ).write(to: root.appendingPathComponent(PluginManifest.filename))
        let registered = try await fixture.gateway.changePlugins(
          .registerDevelopment(root), expectedRevision: 0)
        _ = try await fixture.gateway.changePlugins(
          .settings(
            pluginID: "http-fixture",
            .init(
              enabled: false,
              mcp: [
                "remote": .init(
                  registrationID: "remote", exposure: .reexport, prefix: "remote",
                  allowAnyTool: true,
                  toolRisks: ["inspect": .readOnly], authentication: binding)
              ])), expectedRevision: registered.state.revision)
      }
      let manifestBefore = try Data(contentsOf: fixture.directories.manifest)
      var pluginBefore = try fixture.database.pluginStoreSnapshot()
      try await fixture.socket.start()
      let client = Client(name: "credential-workflow", version: "1")
      do {
        if plugin {
          await #expect(throws: MCPHTTPAuthenticationError.missing) {
            try await fixture.gateway.changePlugins(
              .enabled(pluginID: "http-fixture", true), expectedRevision: pluginBefore.revision)
          }
          #expect(try fixture.database.pluginStoreSnapshot() == pluginBefore)
        } else {
          let missing = try await fixture.host.doctorMCPRegistration(
            id: "remote", workspaceID: "fixture")
          #expect(missing.status == .failed)
          #expect(missing.stage == "authentication" && missing.errorCode == "mcp.authentication")
        }
        #expect(try http.requests().isEmpty)
        let status = try await fixture.json(["credential", "status", "remote"])
        let digest = try #require(status.objectValue?["binding_digest"]?.stringValue)
        #expect(status.objectValue?["present"] == .bool(false))
        let stale = try await fixture.cli([
          "credential", "remove", "remote", "--expected-binding-digest", "stale",
        ])
        #expect(stale.exitCode != 0)
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
          .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            ".build/debug/computer-mcp")
        let execution = CLIProcessExecution()
        let saved = try await execution.runAsync(
          executable: executable.path,
          invocation: .init(
            arguments: [
              "mcp", "credential", "set", "remote", "--expected-binding-digest", digest, "--stdin",
              "--control-socket", fixture.directories.controlSocket.path,
            ], standardInput: Data("fixture-token\n".utf8)),
          cwd: fixture.root, environment: [:], timeoutMilliseconds: 5000, maxOutputBytes: 1_048_576)
        await execution.shutdown()
        #expect(saved.exitCode == 0)
        #expect(!String(describing: saved).contains("fixture-token"))
        #expect(try fixture.database.pluginStoreSnapshot() == pluginBefore)
        if plugin {
          _ = try await fixture.gateway.changePlugins(
            .enabled(pluginID: "http-fixture", true), expectedRevision: pluginBefore.revision)
          pluginBefore = try fixture.database.pluginStoreSnapshot()
          #expect(try await fixture.host.mcpCredentialStatus(id: "remote").bindingDigest == digest)
        }
        let ready = try await fixture.host.doctorMCPRegistration(
          id: "remote", workspaceID: "fixture")
        #expect(ready.status == .passed && ready.catalogReceived)
        try await fixture.gateway.start(profile: .chatGPTOperate)
        _ = try await client.connect(transport: fixture.transport())
        #expect(try await client.callTool(name: "remote.inspect", arguments: [:]).isError != true)
        let beforeRemoval = try http.requests().filter { $0["rpc"] == .string("tools/call") }.count
        _ = try await fixture.json([
          "credential", "remove", "remote", "--expected-binding-digest", digest,
        ])
        #expect(try await client.callTool(name: "remote.inspect", arguments: [:]).isError == true)
        #expect(
          try http.requests().filter { $0["rpc"] == .string("tools/call") }.count == beforeRemoval)
        #expect(try http.requests().allSatisfy { $0["authorized"] == .bool(true) })
        #expect(try Data(contentsOf: fixture.directories.manifest) == manifestBefore)
        #expect(try fixture.database.pluginStoreSnapshot() == pluginBefore)
        let audit = try JSONEncoder().encode(fixture.database.auditEvents(limit: 100))
        #expect(!String(decoding: audit, as: UTF8.self).contains("fixture-token"))
        await client.disconnect()
        await fixture.gateway.stop()
        await fixture.socket.stop()
      } catch {
        await client.disconnect()
        await fixture.gateway.stop()
        await fixture.socket.stop()
        throw error
      }
    }
  }
}
