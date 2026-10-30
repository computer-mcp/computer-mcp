import ComputerMCPPermissions
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPTransport
import CryptoKit
import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
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
    let resolvedServer = files.root.appendingPathComponent("resolved-server")
    try writePythonTestExecutable(Self.server, to: resolvedServer)
    let serverProgram = try String(contentsOf: resolvedServer, encoding: .utf8)
    let entries: [ArchiveFixture.Entry] = [
      .init(name: PluginManifest.filename, content: Self.manifest),
      .init(name: "bin/server", content: serverProgram, mode: 0o700),
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
    let worker = try nativeGatewayTestExecutable()
    let serverPrograms = [
      serverProgram,
      serverProgram.replacingOccurrences(of: "combined MCP reply", with: "updated MCP reply"),
    ]
    let fixture = try PluginControlFixture(
      worker: worker.path,
      bundled: source == .bundled ? .load(directory: packages) : .load(directory: nil),
      executionLauncher: { root in
        ExecutionLauncher(
          platform: CombinedWorkflowExecutionPlatform(
            root: root, sourceRoot: sourceRoot, scripts: serverPrograms, worker: worker))
      })
    defer { fixture.remove() }
    let manualSkills = fixture.root.appendingPathComponent("manual-skills/manual-guide")
    try FileManager.default.createDirectory(at: manualSkills, withIntermediateDirectories: true)
    try Data(Self.guide.replacingOccurrences(of: "combined-guide", with: "manual-guide").utf8)
      .write(to: manualSkills.appendingPathComponent("SKILL.md"))
    let vendor = fixture.root.appendingPathComponent("external-server")
    try Data(serverProgram.utf8).write(to: vendor)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vendor.path)
    let manualTree = fixture.root.appendingPathComponent("manual-tree.json")
    try Data(tree.utf8).write(to: manualTree)
    let project = fixture.root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    let providerHome = URL(
      fileURLWithPath: try fixture.database.prepareProviderContainer(.package("combined")).sandbox
        .home.value)
    _ = try fixture.database.prepareProviderContainer(.localServer("manual"))
    let starts = providerHome.appendingPathComponent("plugin-pids")
    var configuration = GatewayConfiguration(projectDirectory: project)
    configuration.policy.shellEnabled = true
    configuration.profiles = [
      .init(
        id: .chatGPTOperate,
        permissions: fixturePermissions([
          .machineInformation: .granted(.access), .skills: .granted(.access),
          .screen: .granted(.access), .desktopControl: .granted(.access),
          .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
          .project("fixture"): .granted(.write), .mcpServer("*"): .granted(.all),
          .plugin("*"): .granted(.use),
        ]), fullAccess: true, allowedCallers: [.localCLI])
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
    _ = try await fixture.host.activateManifest(
      configuration.exportedTOML(), expectedDigest: try? await fixture.host.configurationDigest())
    try fixture.database.saveProject(
      .init(id: "fixture", displayName: "Fixture", rootPath: project.path))
    let grant = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
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
      try await Self.approve(fixture, identity: .package("combined"))
      snapshot = try await fixture.host.pluginSnapshot()
      snapshot = try await Self.run(
        fixture, ["configure", "combined", "--settings-file", settingsURL.path],
        revision: snapshot.state.revision)
      #expect(snapshot.contributions.count == 3)
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let active = try await Self.connect(fixture)
      client = active
      let projectedName = try await Self.checkActive(active, fixture: fixture)
      snapshot = try await fixture.host.pluginSnapshot()
      snapshot = try await Self.run(
        fixture, ["disable", "combined"], revision: snapshot.state.revision)
      try await Self.checkIndependent(active, fixture: fixture, removedCLI: projectedName)
      snapshot = try await Self.run(
        fixture, ["enable", "combined"], revision: snapshot.state.revision)
      #expect(try await Self.checkActive(active, fixture: fixture) == projectedName)
      await active.disconnect()
      client = nil
      await fixture.gateway.stop()
      snapshot = try await fixture.host.pluginSnapshot()
      try Self.checkExited(starts, count: 4)
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
      #expect(try await Self.checkActive(retained, fixture: fixture) == projectedName)
      await retained.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts, count: 6)

      snapshot = try await fixture.host.pluginSnapshot()
      var updatedEntries = entries
      updatedEntries[0].content = Self.manifest
        .replacingOccurrences(of: "version = '1.0.0'", with: "version = '1.1.0'")
      updatedEntries[1].content =
        serverProgram
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
      #expect(
        try await Self.checkActive(updated, fixture: fixture, reply: "updated MCP reply")
          == projectedName)
      await updated.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts, count: 8)
      snapshot = try await fixture.host.pluginSnapshot()

      let selection = installation.map { ["--installation-id", $0.id] } ?? ["--bundled"]
      snapshot = try await Self.run(
        fixture, ["select", "combined"] + selection, revision: snapshot.state.revision)
      #expect(snapshot.state.settings["combined"] == settings)
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let restored = try await Self.connect(fixture)
      client = restored
      #expect(try await Self.checkActive(restored, fixture: fixture) == projectedName)
      await restored.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts, count: 10)
      snapshot = try await fixture.host.pluginSnapshot()
      snapshot = try await Self.run(
        fixture, ["uninstall", updateID], revision: snapshot.state.revision)
      #expect(!FileManager.default.fileExists(atPath: updateRoot.path))
      #expect(snapshot.contributions.count == 3)
      snapshot = try await fixture.host.pluginSnapshot()
      snapshot = try await Self.run(
        fixture, ["disable", "combined"], revision: snapshot.state.revision)
      #expect(snapshot.contributions.isEmpty)
      try await fixture.gateway.start(profile: .chatGPTOperate)
      let disabled = try await Self.connect(fixture)
      client = disabled
      try await Self.checkIndependent(disabled, fixture: fixture, removedCLI: projectedName)
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
      try await Self.checkIndependent(removed, fixture: fixture, removedCLI: projectedName)
      await removed.disconnect()
      client = nil
      await fixture.gateway.stop()
      try Self.checkExited(starts, count: 10)
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

  private static func checkActive(
    _ client: Client, fixture: PluginControlFixture, reply: String = "combined MCP reply"
  )
    async throws -> String
  {
    let projects = try await call(client, "project.list")
    try #require(projects.isError != true, "\(projects)")
    try await approve(fixture, identity: .package("combined"))
    try await approve(fixture, identity: .localServer("manual"))
    try await discover(client, server: "combined-mcp")
    try await discover(client, server: "manual")
    let tools = try await allTools(client)
    #expect(tools.contains { $0.name == "combined.inspect" })
    let projected = try #require(
      tools.first { $0.title == "combined-cli" }, "Catalog: \(tools.map(\.name))")
    let mcp = try await call(client, "combined.inspect")
    #expect(mcp.isError != true, "\(mcp)")
    #expect(
      try JSONValue.encoded(mcp.content).arrayValue?.first?.objectValue?["text"] == .string(reply))
    let cli = try await call(
      client, projected.name, ["values": .array([.string("含 空格"), .string("-1"), .string("")])])
    #expect(cli.isError != true, "\(cli)")
    #expect(
      cli.structuredContent?.objectValue?["result"]?.objectValue?["stdout"]?.objectValue?["data"]
        == .string("含 空格\n-1\n\n"))
    let skill = try await call(
      client, "skills.read",
      ["root_id": .string("combined-skills"), "name": .string("combined-guide")])
    #expect(skill.isError != true, "Registered plugin skill result: \(skill)")
    #expect(
      skill.structuredContent?.objectValue?["result"]?.objectValue?["content"]?.stringValue?
        .contains("Read the combined fixture guidance.") == true,
      "Registered plugin skill result: \(skill)")
    return projected.name
  }

  private static func approve(_ fixture: PluginControlFixture, identity: PluginIdentity)
    async throws
  {
    let review = try await fixture.host.providerReview(identity)
    let view = try await fixture.host.permissionRequests()
    var permissions = Permissions.newPrincipal
    try permissions.set(.granted(.write), for: .project("fixture"))
    if let previous = view.providers.first(where: { $0.identity == identity }),
      previous.enabled, previous.sourceDigest == review.sourceDigest,
      previous.permissions.entries == permissions.entries, let consent = previous.fullAccessConsent
    {
      let runtime = try fixture.database.permissionRuntime(platform: fixture.host.platform)
      if try runtime.store.readWithDatabase({ _, ledger in
        ledger.isConsentValid(consent, for: .plugin(identity))
      }) {
        return
      }
    }
    _ = try await fixture.host.approveProvider(
      review, permissions: permissions, fullAccess: true,
      expectedProviderRevision: view.providers.first { $0.identity == identity }?.revision,
      expectedRevision: view.revision, expectedEpoch: #require(view.epoch))
  }

  private static func checkIndependent(
    _ client: Client, fixture: PluginControlFixture, removedCLI: String
  ) async throws {
    let projects = try await call(client, "project.list")
    try #require(projects.isError != true, "\(projects)")
    try await approve(fixture, identity: .localServer("manual"))
    try await discover(client, server: "manual")
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
    let removedSkill = try await call(
      client, "skills.read",
      ["root_id": .string("combined-skills"), "name": .string("combined-guide")])
    #expect(removedSkill.isError == true, "Disabled plugin skill result: \(removedSkill)")
    #expect(
      removedSkill.structuredContent?.objectValue?["error"]?.objectValue?["code"]
        == .string("gateway.invalid_arguments"),
      "Disabled plugin skill result: \(removedSkill)")
    let manualSkill = try await call(
      client, "skills.read",
      ["root_id": .string("manual-skills"), "name": .string("manual-guide")])
    #expect(manualSkill.isError != true, "Independent skill result: \(manualSkill)")
    #expect(
      manualSkill.structuredContent?.objectValue?["result"]?.objectValue?["name"]
        == .string("manual-guide"),
      "Independent skill result: \(manualSkill)")
    #expect(
      manualSkill.structuredContent?.objectValue?["result"]?.objectValue?["content"]?.stringValue?
        .contains("Read the combined fixture guidance.") == true,
      "Independent skill result: \(manualSkill)")
  }

  private static func call(_ client: Client, _ name: String, _ arguments: [String: MCP.Value] = [:])
    async throws -> MCP.CallTool.Result
  {
    let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
      name: name, arguments: arguments)
    return try await request.value
  }

  private static func discover(_ client: Client, server: String) async throws {
    let result = try await call(
      client, "mcp.tools.list", ["project_id": .string("fixture"), "server": .string(server)])
    try #require(result.isError != true, "Discovery for \(server): \(result)")
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
    let session = try #require(await fixture.gateway.controlSessions().first)
    _ = try await fixture.gateway.approveControlSession(
      id: session.id, expectedRevision: session.revision)
    return client
  }

  private static func run(_ fixture: PluginControlFixture, _ arguments: [String], revision: Int64)
    async throws -> PluginHostSnapshot
  {
    let result = try await fixture.cli(arguments + ["--expected-revision", String(revision)])
    try #require(result.exitCode == 0, "\(arguments): \(result.stdout)\n\(result.stderr)")
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
    plugin_api = 1
    [sandbox]
    full_access = true
    purpose = 'Run the fixture native commands'
    [[permissions]]
    id = 'project'
    access = 'write'
    purpose = 'Run the fixture commands'
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
        with open(os.path.join(os.environ["HOME"], "plugin-pids"), "a") as f: f.write(str(os.getpid()) + "\n")
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

/// These fixed programs create no descendants, so native root identity tracking
/// owns their complete lifetime without claiming a general Full access backend.
private struct CombinedWorkflowExecutionPlatform: ExecutionPlatform {
  let root: URL
  let sourceRoot: URL
  let scripts: [String]
  let worker: URL

  private var base: DarwinExecutionPlatform {
    DarwinExecutionPlatform(
      bootstrapExecutable: worker.deletingLastPathComponent()
        .appendingPathComponent("computer-mcp-execution-bootstrap"))
  }

  var supportsRecovery: Bool { true }
  var bootSessionID: String? { base.bootSessionID }
  var hostSystemReadPaths: [SandboxPath] { base.hostSystemReadPaths }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool {
    // Host-only library reads reserve a read-only execution without launching a program.
    sandboxed ? base.supportsDurableOwnership(sandboxed: true) : true
  }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    guard let prepared = try PreparedExecutionContext.current() else {
      try validateArchiveWorker(command, sandbox: sandbox, input: input)
      return try await base.start(
        command, sandbox: sandbox, method: method, input: input, output: output, error: error,
        bindOwnership: bindOwnership)
    }
    if sandbox != nil {
      return try await base.start(
        command, sandbox: sandbox, method: method, input: input, output: output, error: error,
        bindOwnership: bindOwnership)
    }
    guard case .fullAccess = prepared.mode,
      canonical(command.directory.value)
        == root.appendingPathComponent("project").resolvingSymlinksInPath().path,
      command.inheritedDescriptors.isEmpty
    else { throw unavailable(command) }

    let controlled: ExecutionCommand
    if command.executable.value == "/usr/bin/printf" {
      guard
        [
          ["--", "%s\n", "含 空格", "-1", ""],
          ["--", "%s\n", "retained"],
        ].contains(command.arguments)
      else { throw unavailable(command) }
      controlled = ExecutionCommand(
        executable: command.executable, arguments: Array(command.arguments.dropFirst()),
        directory: command.directory, environment: command.environment,
        directoryDescriptor: command.directoryDescriptor,
        inheritedDescriptors: command.inheritedDescriptors)
    } else {
      let script: String
      let arguments: [String]
      if command.executable.value == "/usr/bin/python3", let first = command.arguments.first {
        script = first
        arguments = Array(command.arguments.dropFirst())
      } else {
        script = command.executable.value
        arguments = command.arguments
      }
      let path = canonical(script)
      guard
        [root, sourceRoot].contains(where: {
          path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }),
        let contents = try? String(contentsOfFile: path, encoding: .utf8),
        scripts.contains(contents),
        arguments.isEmpty || arguments.count == 1 && arguments[0].hasSuffix("/plugin-pids")
      else { throw unavailable(command) }
      controlled = ExecutionCommand(
        executable: try SandboxPath("/usr/bin/python3"), arguments: ["-I", path] + arguments,
        directory: command.directory, environment: command.environment,
        directoryDescriptor: command.directoryDescriptor,
        inheritedDescriptors: command.inheritedDescriptors)
    }
    let ownership = try await base.start(
      controlled, sandbox: nil, method: method, input: input, output: output, error: error,
      bindOwnership: { bindOwnership(CombinedWorkflowOwnership(base: $0)) })
    return CombinedWorkflowOwnership(base: ownership)
  }

  private func validateArchiveWorker(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, input: Int32
  ) throws {
    var information = stat()
    let directory = URL(fileURLWithPath: command.directory.value).resolvingSymlinksInPath()
    guard let administration = ExecutionAdministration.current,
      case .fullAccess = administration.mode, sandbox == nil,
      canonical(command.executable.value) == worker.resolvingSymlinksInPath().path,
      command.arguments.count == 3,
      Array(command.arguments.prefix(2)) == ["_plugin-archive", "--sha256"],
      command.arguments[2].utf8.count == 64,
      command.arguments[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      directory.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
      UUID(uuidString: directory.lastPathComponent) != nil,
      command.environment == [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        "TMPDIR": command.directory.value,
      ],
      input > STDERR_FILENO, fstat(input, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      command.inheritedDescriptors.count <= 1,
      command.inheritedDescriptors.allSatisfy({
        $0.key > STDERR_FILENO && $0.key == $0.value && fcntl($0.value, F_GETFD) >= 0
      })
    else { throw unavailable(command) }
  }

  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    if state.sandboxed { return try await base.recover(state) }
    guard state.backend == CombinedWorkflowOwnership.backend, !state.sandboxed,
      state.root.processID > 0, state.root.identity > 0
    else {
      throw ExecutionEnvironmentError.unavailable("Invalid combined workflow fixture recovery")
    }
    try await base.interrupt([state.root])
    return CombinedWorkflowCompletedOwnership(state: state)
  }

  func interrupt(_ members: [ExecutionMember]) async throws { try await base.interrupt(members) }

  func releaseRecovery(_ state: ExecutionRecoveryState) throws {
    if state.sandboxed { return try base.releaseRecovery(state) }
    guard state.backend == CombinedWorkflowOwnership.backend, !state.sandboxed else {
      throw ExecutionEnvironmentError.unavailable("Invalid combined workflow fixture recovery")
    }
  }

  private func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  private func unavailable(_ command: ExecutionCommand) -> ExecutionEnvironmentError {
    Issue.record(
      "Unexpected combined workflow program: \(command.executable.value) \(command.arguments)")
    return .unavailable("The combined workflow backend accepts fixed fixture programs only")
  }
}

private struct CombinedWorkflowOwnership: ExecutionOwnership {
  static let backend = "combined-workflow-fixture"
  let base: any ExecutionOwnership

  func recoveryState() throws -> ExecutionRecoveryState {
    let state = try base.recoveryState()
    return ExecutionRecoveryState(root: state.root, sandboxed: false, backend: Self.backend)
  }
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
    base.beforeStart(handler)
  }
  func members() async throws -> [ExecutionMember] { try await base.members() }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) { base.onCancellation(handler) }
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    try await base.cancel(until: deadline)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    try await base.wait(until: deadline)
  }
}

private struct CombinedWorkflowCompletedOwnership: ExecutionOwnership {
  let state: ExecutionRecoveryState
  func recoveryState() throws -> ExecutionRecoveryState { state }
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {}
  func members() async throws -> [ExecutionMember] { [] }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    ExecutionExit(status: 128 + SIGTERM, signal: SIGTERM)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    ExecutionExit(status: 128 + SIGTERM, signal: SIGTERM)
  }
}
