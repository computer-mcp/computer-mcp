import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite
struct MCPWorkspaceTests {
  @Test(arguments: [false, true])
  func connectionValidationUsesTheConfigurationDirectoryAndCleansUp(_ fail: Bool) async throws {
    let fixture = try MCPWorkspaceFixture()
    defer { fixture.remove() }
    let marker = fixture.root.appendingPathComponent("started.jsonl")
    var configuration = fixture.configuration()
    configuration.mcp.servers[0].cwd = "first"
    configuration.mcp.servers[0].env = ["START_MARKER": marker.path]
    if fail {
      configuration.mcp.servers.append(
        .init(
          id: "missing", transport: .stdio,
          command: fixture.root.appendingPathComponent("not-installed").path))
      await expectThrowsAsync(
        try await ComputerMCPProductContracts.validateMCPConnections(configuration: configuration)
      ) { error in
        #expect(error.localizedDescription.contains("missing"))
      }
    } else {
      let report = try await ComputerMCPProductContracts.validateMCPConnections(
        configuration: configuration)
      let row = try #require(report.arrayValue?.first?.objectValue)
      #expect(row["id"] == .string("shared"))
      #expect(row["ok"] == .bool(true))
      #expect(
        row["tools"]?.arrayValue?.first?.objectValue?["description"] == .string(fixture.first.path))
    }
    let records = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map {
      line in
      try #require(JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue)
    }
    #expect(records.count == 1)
    #expect(records.first?["cwd"] == .string(fixture.first.path))
    try await fixture.expectExited(records)
  }

  @Test(arguments: [false, true])
  func registriesOwnSessionsAndStoppingOnePreservesItsPeer(_ authorized: Bool) async throws {
    let fixture = try MCPWorkspaceFixture()
    defer { fixture.remove() }
    let configuration = fixture.configuration()
    let parent = MCPProxyClient()
    let client: any DownstreamMCPClient =
      authorized
      ? AuthorizedMCPClient(
        base: parent,
        policy: .init(
          configuration: configuration, grant: configuration.profileGrant(for: .localAdmin),
          derivesObserveGrant: false))
      : parent
    var firstConfiguration = configuration
    firstConfiguration.workspaceDirectory = fixture.first
    var secondConfiguration = configuration
    secondConfiguration.workspaceDirectory = fixture.second
    let first = GatewayToolRegistry(configuration: firstConfiguration, mcpClient: client)
    let second = GatewayToolRegistry(configuration: secondConfiguration, mcpClient: client)
    let executor = BlockingOperationExecutor(label: "test.mcp-workspace")
    do {
      let firstValue = try await executor.perform { try fixture.read(first) }
      let secondValue = try await executor.perform { try fixture.read(second) }
      #expect(firstValue["cwd"] == .string(fixture.first.path))
      #expect(secondValue["cwd"] == .string(fixture.second.path))
      #expect(firstValue["pid"] != secondValue["pid"])
      await first.shutdown()
      let repeated = try await executor.perform { try fixture.read(second) }
      #expect(repeated["pid"] == secondValue["pid"])
      #expect(repeated["cwd"] == secondValue["cwd"])
      await second.shutdown()
      await parent.shutdown()
      try await fixture.expectExited([firstValue, secondValue])
    } catch {
      await first.shutdown()
      await second.shutdown()
      await parent.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func runtimeRoutesConcurrentCallsToTheirWorkspaceSessions(_ readOnly: Bool) async throws {
    let fixture = try MCPWorkspaceFixture()
    defer { fixture.remove() }
    var configuration = fixture.configuration()
    configuration.mcp.servers[0].env[MCPHostContext.environmentKey] = "forged registration"
    let context = ExecutionContext(
      caller: readOnly ? .secureTunnel : .localMCP,
      profileID: readOnly ? .chatGPTObserve : .localAdmin,
      transportTrace: .init(
        transport: "fixture", socketConnectionID: "socket-owner", tunnelInstanceID: "tunnel-owner",
        tunnelProfileID: "tunnel-profile"), trustedPrincipalID: "workspace-session-owner")
    let gateway = try await GatewayRuntime.make(
      configuration: configuration, context: context,
      registeredWorkspaces: [
        .init(id: "first", displayName: "First", rootPath: fixture.first.path),
        .init(id: "second", displayName: "Second", rootPath: fixture.second.path),
      ], mcpClient: MCPProxyClient(), plugins: [])
    do {
      async let first = gateway.callToolAsync(
        name: "fixture.context",
        arguments: .object([
          "workspace_id": .string("first"), "caller": .string("local-admin"),
          "hostContext": .object(["readOnly": .bool(false)]),
        ]))
      async let second = gateway.callToolAsync(
        name: "fixture.context", arguments: .object(["workspace_id": .string("second")]))
      let values = try await [first, second].map { result in
        #expect(result.objectValue?["isError"] != .bool(true))
        return try #require(result.objectValue?["structuredContent"]?.objectValue)
      }
      #expect(values[0]["cwd"] == .string(fixture.first.path))
      #expect(values[1]["cwd"] == .string(fixture.second.path))
      #expect(values[0]["pid"] != values[1]["pid"])
      var runtimeIDs: Set<String> = []
      for (index, workspaceID) in ["first", "second"].enumerated() {
        let host = try #require(values[index]["hostContext"]?.objectValue)
        #expect(host["formatVersion"] == .number(1))
        #expect(host["caller"] == .string(context.caller.rawValue))
        #expect(host["profileID"] == .string(context.profileID.rawValue))
        #expect(host["readOnly"] == .bool(readOnly))
        #expect(host["workspace"]?.objectValue?["id"] == .string(workspaceID))
        let declaredRoot = URL(
          fileURLWithPath: try #require(host["workspace"]?.objectValue?["rootPath"]?.stringValue))
        let actualRoot = URL(fileURLWithPath: try #require(values[index]["cwd"]?.stringValue))
        #expect(
          try WorkspacePathResolver.canonicalWorkspace(declaredRoot)
            == WorkspacePathResolver.canonicalWorkspace(actualRoot))
        #expect(
          host["transportTrace"]?.objectValue?["socketConnectionID"] == .string("socket-owner"))
        #expect(
          host["transportTrace"]?.objectValue?["tunnelInstanceID"] == .string("tunnel-owner"))
        #expect(
          host["transportTrace"]?.objectValue?["tunnelProfileID"] == .string("tunnel-profile"))
        runtimeIDs.insert(try #require(host["runtimeID"]?.stringValue))
        #expect(host["fullShellEnabled"] == nil)
      }
      #expect(runtimeIDs.count == 1)
      #expect(runtimeIDs.first.flatMap(UUID.init(uuidString:)) != nil)
      var reconnected = context
      reconnected.transportTrace?.socketConnectionID = "new-connection"
      let retained = try await gateway.callToolAsync(
        name: "fixture.context", arguments: .object(["workspace_id": .string("first")]),
        context: reconnected)
      #expect(retained.objectValue?["structuredContent"]?.objectValue?["pid"] == values[0]["pid"])
      for changedPrincipal in [false, true] {
        var changedContext = context
        if changedPrincipal {
          changedContext.trustedPrincipalID = "different-owner"
        } else {
          changedContext.caller = .localCLI
        }
        await expectThrowsAsync(
          try await gateway.callToolAsync(
            name: "fixture.context", arguments: .object(["workspace_id": .string("first")]),
            context: changedContext)
        ) { error in
          #expect(error.localizedDescription.contains("policy.caller_denied"))
        }
      }
      await gateway.shutdown()
      try await fixture.expectExited(values)
    } catch {
      await gateway.shutdown()
      throw error
    }
  }

  @Test(arguments: [nil, "", "workspace", "nested"] as [String?])
  func launchResolvesDirectoryExecutableAndInterpreterTogether(_ cwd: String?) async throws {
    let fixture = try MCPWorkspaceFixture()
    defer { fixture.remove() }
    let directory = cwd == "nested" ? fixture.first.appendingPathComponent("nested") : fixture.first
    let bin = directory.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let link = directory.appendingPathComponent("probe")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.script)
    let interpreter = bin.appendingPathComponent("fixture-runtime")
    try Data("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".utf8).write(to: interpreter)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
    var configuration = fixture.configuration()
    configuration.workspaceDirectory = fixture.first
    configuration.mcp.servers[0].command = "./probe"
    configuration.mcp.servers[0].args = []
    configuration.mcp.servers[0].cwd = cwd
    configuration.mcp.servers[0].env = ["PATH": "bin", "SCOPE_VALUE": "child", "EMPTY": ""]
    configuration.mcp.servers[0].env[MCPHostContext.environmentKey] = "forged registration"
    let registry = GatewayToolRegistry(
      configuration: configuration,
      environment: [
        "PATH": "/unrelated", "SCOPE_VALUE": "parent", "EMPTY": "parent",
        MCPHostContext.environmentKey: "forged ancestor",
      ])
    do {
      let value = try await BlockingOperationExecutor(label: "test.mcp-launch").perform {
        try fixture.read(registry)
      }
      #expect(value["cwd"] == .string(directory.path))
      #expect(value["script"] == .string(link.standardizedFileURL.path))
      #expect(value["scope"] == .string("child"))
      #expect(value["empty"] == .string(""))
      #expect(value["hostContext"] == .null)
      await registry.shutdown()
      try await fixture.expectExited([value])
    } catch {
      await registry.shutdown()
      throw error
    }
  }
}

private struct MCPWorkspaceFixture: Sendable {
  let root: URL
  let first: URL
  let second: URL
  let script: URL

  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    root = try WorkspacePathResolver.canonicalWorkspace(directory)
    first = root.appendingPathComponent("first", isDirectory: true)
    second = root.appendingPathComponent("second", isDirectory: true)
    for url in [first, second] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    script = root.appendingPathComponent("probe.py")
    try Data(Self.server.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  }

  func configuration() -> GatewayConfiguration {
    GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      mcp: .init(servers: [
        .init(
          id: "shared", transport: .stdio, command: "/usr/bin/python3", args: [script.path],
          exposure: .reexport, prefix: "fixture", allowAnyTool: true,
          requestTimeoutMs: 5_000, toolRisks: ["context": .readOnly])
      ]), workspaceDirectory: root)
  }

  func read(_ registry: GatewayToolRegistry) throws -> [String: JSONValue] {
    _ = try registry.listTools()
    return try #require(
      registry.callTool(name: "fixture.context", arguments: .object([:]))
        .objectValue?["structuredContent"]?.objectValue)
  }

  func expectExited(_ values: [[String: JSONValue]]) async throws {
    for value in values {
      let pid = Int32(try #require(value["pid"]?.intValue))
      let deadline = ContinuousClock.now + .seconds(2)
      while kill(pid, 0) == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  private static let server = """
    #!/usr/bin/env fixture-runtime
    import json, os, sys
    marker = os.environ.get("START_MARKER")
    if marker:
        with open(marker, "a") as output:
            output.write(json.dumps({"pid": os.getpid(), "cwd": os.getcwd()}) + "\\n")
    for line in sys.stdin:
        message = json.loads(line)
        if "id" not in message:
            continue
        method = message.get("method")
        response = {"jsonrpc": "2.0", "id": message["id"]}
        if method == "initialize":
            response["result"] = {
                "protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                "serverInfo": {"name": "workspace-fixture", "version": "1"}}
        elif method == "tools/list":
            response["result"] = {"tools": [{
                "name": "context", "description": os.getcwd(),
                "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            response["result"] = {"content": [], "structuredContent": {
                "cwd": os.getcwd(), "pid": os.getpid(), "script": sys.argv[0],
                "scope": os.environ.get("SCOPE_VALUE"), "empty": os.environ.get("EMPTY"),
                "hostContext": json.loads(os.environ.get("COMPUTER_MCP_HOST_CONTEXT", "null"))}}
        else:
            response["error"] = {"code": -32601, "message": "not found"}
        print(json.dumps(response), flush=True)
    """
}
