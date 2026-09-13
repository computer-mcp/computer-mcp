import CryptoKit
import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct CombinedPluginWorkflowTests {
  @Test(arguments: [PluginSourceKind.bundled, .artifact, .development])
  func allContributionsRunAndRetireTogetherWithoutRemovingIndependentRegistrations(
    source: PluginSourceKind
  ) async throws {
    let files = try ArchiveFixture()
    defer { files.remove() }
    let tree = try String(
      contentsOf: Self.repository.appendingPathComponent("Examples/printf-cli-tree.json"),
      encoding: .utf8)
    let entries: [ArchiveFixture.Entry] = [
      .init(name: PluginManifest.filename, content: Self.manifest),
      .init(name: "bin/server", content: Self.server, mode: 0o700),
      .init(name: "tree.json", content: tree),
      .init(name: "skills/combined-guide/SKILL.md", content: Self.guide),
      .init(
        name: "skills/combined-guide/scripts/never-run.sh",
        content: "#!/bin/sh\ntouch skill-script-ran\n", mode: 0o700),
    ]
    let archive = try files.archive(entries, format: "zip")
    let packages = files.root.appendingPathComponent("Packages")
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: false)
    let sourceRoot = packages.appendingPathComponent("combined")
    _ = try PluginArchiveExtractor().extract(archive, toNewDirectory: sourceRoot)
    let digest = Self.digest(try Data(contentsOf: archive))
    let fixture = try PluginControlFixture(
      worker: Self.repository.appendingPathComponent(".build/debug/computer-mcp").path,
      bundled: source == .bundled ? .load(directory: packages) : .load(directory: nil))
    defer { fixture.remove() }
    let manualSkills = fixture.root.appendingPathComponent("manual-skills/manual-guide")
    try FileManager.default.createDirectory(at: manualSkills, withIntermediateDirectories: true)
    try Data(Self.guide.replacingOccurrences(of: "combined-guide", with: "manual-guide").utf8)
      .write(to: manualSkills.appendingPathComponent("SKILL.md"))
    let vendor = fixture.root.appendingPathComponent("external-server")
    try Data(Self.server.utf8).write(to: vendor)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vendor.path)
    let manualTree = fixture.root.appendingPathComponent("manual-tree.json")
    try Data(tree.utf8).write(to: manualTree)
    let starts = fixture.root.appendingPathComponent("plugin-pids")
    var configuration = GatewayConfiguration(workspaceDirectory: fixture.root)
    configuration.profiles = [
      .init(
        id: .chatGPTOperate, capabilities: ["*"],
        workspaces: ["fixture"], allowedCallers: [.localCLI])
    ]
    configuration.mcp.servers = [
      .init(
        id: "manual", transport: .stdio, command: vendor.path,
        exposure: .reexport, prefix: "manual", allowAnyTool: true, toolRisks: ["inspect": .readOnly]
      )
    ]
    configuration.cli.commands = [
      .init(
        id: "manual-cli", executable: "/usr/bin/printf", allowAnyArgs: false,
        tree: .init(kind: .file, path: manualTree.path))
    ]
    configuration.skills = .init(
      enabled: true,
      roots: [
        .init(id: "manual-skills", path: manualSkills.deletingLastPathComponent().path)
      ])
    _ = try await fixture.host.activateManifest(configuration.exportedTOML())
    try fixture.database.saveWorkspace(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    let grant = ProfileGrant(
      id: .chatGPTOperate, capabilityIDs: ["*"], workspaceIDs: ["fixture"],
      allowedCallers: [.localCLI], fullShellEnabled: true)
    try fixture.database.saveProfile(grant)
    let initialManifest = try Data(contentsOf: fixture.directories.manifest)
    let initialVendor = try Data(contentsOf: vendor)
    try await fixture.socket.start()
    var client: Client?
    do {
      var snapshot = try await fixture.host.pluginSnapshot()
      if source == .artifact {
        snapshot = try await Self.run(
          fixture,
          ["install", archive.path, "--id", "combined", "--version", "1.0.0", "--sha256", digest],
          revision: snapshot.state.revision)
      } else if source == .development {
        snapshot = try await Self.run(
          fixture, ["register", sourceRoot.path], revision: snapshot.state.revision)
      }
      #expect(snapshot.contributions.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: starts.path))
      let installation = snapshot.state.installations.first
      let settings = PluginSettings(
        enabled: true,
        mcp: [
          "native": .init(
            registrationID: "combined-mcp", exposure: .reexport, prefix: "combined",
            allowAnyTool: true, toolRisks: ["inspect": .readOnly], args: [starts.path])
        ],
        cli: ["print": .init(registrationID: "combined-cli")],
        skills: ["guidance": .init(registrationID: "combined-skills")],
        dependencyExecutables: ["printf": "/usr/bin/printf"])
      let settingsURL = fixture.root.appendingPathComponent("settings.json")
      try JSONEncoder().encode(settings).write(to: settingsURL)
      snapshot = try await Self.run(
        fixture, ["configure", "combined", "--settings-file", settingsURL.path],
        revision: snapshot.state.revision)
      #expect(snapshot.contributions.count == 3)
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let active = try await Self.connect(fixture)
      client = active
      let projectedName = try await Self.checkActive(active)
      let busy = try await fixture.cli([
        "disable", "combined", "--expected-revision", String(snapshot.state.revision),
      ])
      #expect(busy.exitCode != 0)
      #expect(try fixture.database.pluginStoreSnapshot().revision == snapshot.state.revision)
      #expect(try await active.callTool(name: "combined.inspect", arguments: [:]).isError != true)
      await active.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts)
      var rejectedEntries = entries
      rejectedEntries[0].content =
        Self.manifest
        .replacingOccurrences(of: "version = '1.0.0'", with: "version = '1.0.1'")
        + "\n[compatibility]\nminimum_host = '9999.0.0'\n"
      let rejectedArchive = try files.archive(rejectedEntries, format: "zip")
      let rejected = try await fixture.cli([
        "install", rejectedArchive.path, "--id", "combined", "--version", "1.0.1",
        "--sha256", Self.digest(try Data(contentsOf: rejectedArchive)),
        "--expected-revision", String(snapshot.state.revision),
      ])
      #expect(rejected.exitCode != 0)
      #expect(try fixture.database.pluginStoreSnapshot() == snapshot.state)
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let retained = try await Self.connect(fixture)
      client = retained
      #expect(try await Self.checkActive(retained) == projectedName)
      await retained.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts, count: 2)

      var updatedEntries = entries
      updatedEntries[0].content = Self.manifest
        .replacingOccurrences(of: "version = '1.0.0'", with: "version = '1.1.0'")
      updatedEntries[1].content = Self.server
        .replacingOccurrences(of: "combined MCP reply", with: "updated MCP reply")
      let updateArchive = try files.archive(updatedEntries, format: "zip")
      snapshot = try await Self.run(
        fixture,
        [
          "install", updateArchive.path, "--id", "combined", "--version", "1.1.0",
          "--sha256", Self.digest(try Data(contentsOf: updateArchive)),
        ], revision: snapshot.state.revision)
      #expect(snapshot.state.settings["combined"] == settings)
      #expect(snapshot.contributions.count == 3)
      let updateID = try #require(snapshot.state.selectedInstallations["combined"])
      let updateRoot = try #require(snapshot.state.installations.first { $0.id == updateID }).source
        .root
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let updated = try await Self.connect(fixture)
      client = updated
      #expect(try await Self.checkActive(updated, reply: "updated MCP reply") == projectedName)
      await updated.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts, count: 3)

      let selection = installation.map { ["--installation-id", $0.id] } ?? ["--bundled"]
      snapshot = try await Self.run(
        fixture, ["select", "combined"] + selection, revision: snapshot.state.revision)
      #expect(snapshot.state.settings["combined"] == settings)
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let restored = try await Self.connect(fixture)
      client = restored
      #expect(try await Self.checkActive(restored) == projectedName)
      await restored.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts, count: 4)
      snapshot = try await Self.run(
        fixture, ["uninstall", updateID], revision: snapshot.state.revision)
      #expect(!FileManager.default.fileExists(atPath: updateRoot.path))
      #expect(snapshot.contributions.count == 3)
      snapshot = try await Self.run(
        fixture, ["disable", "combined"], revision: snapshot.state.revision)
      #expect(snapshot.contributions.isEmpty)
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let disabled = try await Self.connect(fixture)
      client = disabled
      try await Self.checkIndependent(disabled, removedCLI: projectedName)
      await disabled.disconnect()
      client = nil
      await fixture.gateway.stop()
      if let installation {
        snapshot = try await Self.run(
          fixture,
          [source == .artifact ? "uninstall" : "remove", installation.id],
          revision: snapshot.state.revision)
        #expect(snapshot.state.installations.isEmpty)
        #expect(
          FileManager.default.fileExists(atPath: installation.source.root.path)
            == (source == .development))
      } else {
        #expect(snapshot.bundled.contains { $0.manifest.id == "combined" })
      }
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let removed = try await Self.connect(fixture)
      client = removed
      try await Self.checkIndependent(removed, removedCLI: projectedName)
      await removed.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts, count: 4)
      #expect(try Data(contentsOf: fixture.directories.manifest) == initialManifest)
      #expect(try Data(contentsOf: vendor) == initialVendor)
      #expect(try Self.digest(Data(contentsOf: archive)) == digest)
      #expect(try fixture.database.profiles().first { $0.id == .chatGPTOperate } == grant)
      #expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/printf"))
      #expect(
        FileManager.default.fileExists(atPath: manualSkills.appendingPathComponent("SKILL.md").path)
      )
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("skill-script-ran").path))
      #expect(
        !FileManager.default.fileExists(
          atPath: sourceRoot.appendingPathComponent("skill-script-ran").path))
      await fixture.socket.stop()
    } catch {
      await client?.disconnect()
      await fixture.gateway.stop()
      await fixture.socket.stop()
      throw error
    }
  }

  private static func checkActive(_ client: Client, reply: String = "combined MCP reply")
    async throws -> String
  {
    let tools = try await allTools(client)
    #expect(tools.contains { $0.name == "combined.inspect" })
    let projected = try #require(
      tools.first { $0.title == "combined-cli" }, "Catalog: \(tools.map(\.name))")
    let mcp = try await call(client, "combined.inspect")
    #expect(mcp.isError != true)
    #expect(
      try JSONValue.encoded(mcp.content).arrayValue?.first?.objectValue?["text"] == .string(reply))
    let cli = try await call(
      client, projected.name, ["values": .array([.string("含 空格"), .string("-1"), .string("")])])
    #expect(cli.isError != true)
    #expect(
      cli.structuredContent?.objectValue?["result"]?.objectValue?["stdout"]?.objectValue?["data"]
        == .string("含 空格\n-1\n\n"))
    let skill = try await call(
      client, "skills.read",
      ["root_id": .string("combined-skills"), "name": .string("combined-guide")])
    #expect(skill.isError != true)
    #expect(
      skill.structuredContent?.objectValue?["result"]?.objectValue?["content"]?.stringValue?
        .contains("Read the combined fixture guidance.") == true)
    return projected.name
  }

  private static func checkIndependent(_ client: Client, removedCLI: String) async throws {
    let tools = try await allTools(client)
    #expect(!tools.contains { $0.name == "combined.inspect" || $0.name == removedCLI })
    #expect(try await client.callTool(name: "combined.inspect", arguments: [:]).isError == true)
    #expect(
      try await client.callTool(
        name: removedCLI, arguments: ["values": .array([.string("denied")])]
      ).isError == true)
    #expect(try await client.callTool(name: "manual.inspect", arguments: [:]).isError != true)
    let manualCLI = try #require(tools.first { $0.title == "manual-cli" })
    #expect(
      try await client.callTool(
        name: manualCLI.name, arguments: ["values": .array([.string("retained")])]
      ).isError != true)
    #expect(
      try await client.callTool(
        name: "skills.read",
        arguments: ["root_id": .string("combined-skills"), "name": .string("combined-guide")]
      ).isError == true)
    #expect(
      try await client.callTool(
        name: "skills.read",
        arguments: ["root_id": .string("manual-skills"), "name": .string("manual-guide")]
      ).isError != true)
  }

  private static func call(_ client: Client, _ name: String, _ arguments: [String: MCP.Value] = [:])
    async throws -> MCP.CallTool.Result
  {
    let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
      name: name, arguments: arguments)
    return try await request.value
  }

  private static func allTools(_ client: Client) async throws -> [MCP.Tool] {
    var cursor: String?
    var seen = Set<String>()
    var tools: [MCP.Tool] = []
    repeat {
      let page = try await client.listTools(cursor: cursor)
      tools += page.tools
      cursor = page.nextCursor
      if let cursor { try #require(seen.insert(cursor).inserted && seen.count < 100) }
    } while cursor != nil
    return tools
  }

  private static func checkExited(_ receipt: URL, count: Int = 1) throws {
    let pids = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").compactMap {
      Int32($0)
    }
    #expect(pids.count == count)
    #expect(pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
  }

  private static func connect(_ fixture: PluginControlFixture) async throws -> Client {
    let client = Client(name: "combined-workflow", version: "1")
    _ = try await client.connect(
      transport: GatewaySocketTransport(
        configuration: .init(
          socketURL: fixture.directories.gatewaySocket, clientIdentity: .localCLI)))
    return client
  }

  private static func run(_ fixture: PluginControlFixture, _ arguments: [String], revision: Int64)
    async throws -> PluginHostSnapshot
  {
    let result = try await fixture.cli(arguments + ["--expected-revision", String(revision)])
    try #require(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
    return try CanonicalJSONCoding.decoder().decode(
      PluginHostSnapshot.self, from: Data(result.stdout.utf8))
  }

  private static var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static let guide =
    "---\nname: combined-guide\ndescription: Combined package fixture.\n---\nRead the combined fixture guidance.\n"
  private static let manifest = """
    id = 'combined'
    name = 'Combined integration fixture'
    version = '1.0.0'
    [[dependencies]]
    id = 'printf'
    commands = ['printf']
    instructions = 'Use the system printf.'
    [[mcp]]
    id = 'native'
    transport = 'stdio'
    executable = { path = 'bin/server' }
    [[cli]]
    id = 'print'
    executable = { dependency = 'printf' }
    tree = { kind = 'file', path = 'tree.json' }
    [[skills]]
    id = 'guidance'
    path = 'skills'
    """
  private static let server = #"""
    #!/usr/bin/python3
    import json, os, sys
    if len(sys.argv) > 1:
        with open(sys.argv[1], "a") as f: f.write(str(os.getpid()) + "\n")
    for line in sys.stdin:
        req = json.loads(line)
        if "id" not in req: continue
        if req["method"] == "initialize":
            result = {"protocolVersion": req["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "combined", "version": "1"}}
        elif req["method"] == "tools/list":
            result = {"tools": [{"name": "inspect", "inputSchema": {"type": "object"}}]}
        else:
            result = {"content": [{"type": "text", "text": "combined MCP reply"}], "isError": False}
        print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}), flush=True)
    """#
}
