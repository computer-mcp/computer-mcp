import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct StandaloneToolCommandTests {
  @Test(arguments: ["list", "inspect", "missing", "call", "error"])
  func commandsCloseTheirOwnedSessionBeforeExit(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("server.py")
    let pidFile = root.appendingPathComponent("pid")
    let closed = root.appendingPathComponent("closed")
    try Data(
      #"""
      import json, os, pathlib, sys
      pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
      for line in sys.stdin:
          request = json.loads(line)
          if "id" not in request:
              continue
          if request["method"] == "initialize":
              result = {"protocolVersion": request["params"]["protocolVersion"],
                        "capabilities": {"tools": {}}, "serverInfo": {"name": "owned-cli", "version": "1"}}
          elif request["method"] == "tools/list":
              result = {"tools": [{"name": "inspect", "inputSchema": {"type": "object"}}]}
          else:
              result = {"content": [{"type": "text", "text": "fixture reply"}],
                        "isError": request.get("params", {}).get("arguments", {}).get("fail", False)}
          print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
      pathlib.Path(sys.argv[2]).write_text("eof")
      """#.utf8
    ).write(to: script)
    let config = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin),
      workspaces: [.init(id: "fixture", path: root.path)],
      mcp: .init(servers: [
        .init(
          id: "owned", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, pidFile.path, closed.path], exposure: .reexport, prefix: "owned",
          allowedTools: ["inspect"], requestTimeoutMs: 2000, toolRisks: ["inspect": .readOnly])
      ]), workspaceDirectory: root)
    let manifest = root.appendingPathComponent("config.toml")
    try Data(config.exportedTOML().utf8).write(to: manifest)
    var arguments = ["tools"]
    switch mode {
    case "list": arguments += ["list"]
    case "inspect": arguments += ["inspect", "owned.inspect"]
    case "missing": arguments += ["inspect", "owned.missing"]
    default:
      arguments += [
        "call", "owned.inspect", "--arguments-json", mode == "error" ? #"{"fail":true}"# : "{}",
      ]
    }
    arguments += ["--config", manifest.path]
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/computer-mcp")
    let invocationArguments = arguments
    let result = try await BlockingOperationExecutor(label: "standalone-tool-test").perform {
      try ProcessCommandRunner().run(
        executable: executable.path, arguments: invocationArguments, workingDirectory: root,
        environment: [:], timeoutMilliseconds: 8000, maxOutputBytes: 1_048_576)
    }
    #expect(
      result.exitCode == (mode == "missing" ? 64 : mode == "error" ? 1 : 0), "\(result.stderr)")
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(try String(contentsOf: closed, encoding: .utf8) == "eof")
    if mode == "call" || mode == "error" {
      let reply = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
      #expect(reply.objectValue?["isError"] == .bool(mode == "error"))
    }
  }
}
