import ArgumentParser
import ComputerMCPValidation
import Darwin
import Foundation

struct GatewayProbeVerify: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract:
      "Regenerate deterministic fixtures and exercise core providers through a real Gateway HTTP server."
  )

  @Option(name: .long, help: "Fixture workspace owned by computer-mcp-validate.")
  var fixtureRoot = ".build/validation/fixtures"

  @Option(name: .long, help: "Generated fixture inventory JSON.")
  var fixturesJSON = ".build/validation/fixtures.json"

  @Option(name: .long, help: "Disposable fixture copy used for mutating probe calls.")
  var runtimeRoot = ".build/validation/core-runtime"

  @Option(name: .long, help: "computer-mcp executable used to host the temporary Gateway.")
  var gatewayExecutable = ".build/debug/computer-mcp"

  @Option(name: .long, help: "Generated temporary Gateway TOML manifest.")
  var config = ".build/validation/core-dogfood.toml"

  @Option(name: .long, help: "Generated bounded Gateway process log.")
  var log = ".build/validation/core-gateway.log"

  @Option(name: .long, help: "Loopback port for the temporary Gateway.")
  var port = 8881

  @Option(name: .long, help: "Destination for the bounded JSON report.")
  var json: String

  mutating func run() async throws {
    guard (1...65_535).contains(port) else {
      throw ValidationError("port must be between 1 and 65535.")
    }
    let rootURL = URL(fileURLWithPath: fixtureRoot, isDirectory: true).standardizedFileURL
    let fixtureReport = try CapabilityFixtureGenerator().generate(at: rootURL, force: true)
    let runtimeURL = URL(
      fileURLWithPath: runtimeRoot,
      isDirectory: true
    ).standardizedFileURL
    let runtimeReport = try CapabilityFixtureGenerator().generate(at: runtimeURL, force: true)
    guard runtimeReport.contentDigest == fixtureReport.contentDigest else {
      throw ValidationError("The immutable and runtime fixture digests do not match.")
    }
    defer {
      try? FileManager.default.removeItem(at: runtimeURL)
    }
    try writeCoreData(
      fixtureReport.encodedJSON(),
      destination: URL(fileURLWithPath: fixturesJSON).standardizedFileURL
    )
    let executableURL = URL(fileURLWithPath: gatewayExecutable).standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw ValidationError("Gateway executable is not executable: \(executableURL.path)")
    }

    let configURL = URL(fileURLWithPath: config).standardizedFileURL
    let product = try ValidationProductCommand(executableURL: executableURL)
    let defaultManifest = try product.run(["config", "defaults"])
    let defaultConfigURL = configURL.deletingLastPathComponent()
      .appendingPathComponent("core-product-defaults.toml")
    try writeCoreData(defaultManifest, destination: defaultConfigURL)
    defer {
      try? FileManager.default.removeItem(at: defaultConfigURL)
    }
    let observeToolNames = try productInventoryToolNames(
      product: product,
      configURL: defaultConfigURL,
      caller: .secureTunnel,
      profileID: .chatGPTObserve
    )
    try writeCoreGatewayManifest(
      fixtureRoot: runtimeURL,
      port: port,
      builtins: try defaultBuiltinCapabilities(in: defaultManifest),
      to: configURL
    )
    let logURL = URL(fileURLWithPath: log).standardizedFileURL
    let host = try TemporaryGatewayHost.start(
      executableURL: executableURL,
      configURL: configURL,
      logURL: logURL,
      port: port
    )
    let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!

    do {
      try await host.waitUntilHealthy()
      let session = try await GatewayClientSession.connectHTTP(endpoint: endpoint)
      do {
        let toolCatalog = try await session.listTools().map(\.validationTool)
        var runner = GatewayVerificationRunner(
          session: session,
          fixtureDigest: fixtureReport.contentDigest,
          runtimeWorkspacePath: runtimeURL.path,
          loopbackPort: port,
          toolCatalog: toolCatalog,
          observeToolNames: observeToolNames
        )
        let report = try await runner.run()
        await session.disconnect()
        host.stop()
        try writeCoreJSON(report, destination: json)
      } catch {
        await session.disconnect()
        host.stop()
        throw error
      }
    } catch {
      host.stop()
      throw error
    }
  }
}

private final class TemporaryGatewayHost {
  private let process: Process
  private let logHandle: FileHandle
  private let healthURL: URL
  private let logURL: URL

  private init(
    process: Process,
    logHandle: FileHandle,
    healthURL: URL,
    logURL: URL
  ) {
    self.process = process
    self.logHandle = logHandle
    self.healthURL = healthURL
    self.logURL = logURL
  }

  static func start(
    executableURL: URL,
    configURL: URL,
    logURL: URL,
    port: Int
  ) throws -> TemporaryGatewayHost {
    try FileManager.default.createDirectory(
      at: logURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: logURL.path) {
      try Data().write(to: logURL, options: .atomic)
    } else {
      try Data().write(to: logURL, options: .atomic)
    }
    let logHandle = try FileHandle(forWritingTo: logURL)
    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "serve",
      "http",
      "--config",
      configURL.path,
      "--host",
      "127.0.0.1",
      "--port",
      String(port),
      "--public-base-url",
      "http://127.0.0.1:\(port)",
      "--caller",
      "local-mcp",
      "--profile",
      "local-admin",
    ]
    process.standardOutput = logHandle
    process.standardError = logHandle
    try process.run()
    return TemporaryGatewayHost(
      process: process,
      logHandle: logHandle,
      healthURL: URL(string: "http://127.0.0.1:\(port)/health")!,
      logURL: logURL
    )
  }

  func waitUntilHealthy() async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while clock.now < deadline {
      if !process.isRunning {
        throw ValidationError(
          "Temporary Gateway exited before health became ready: \(boundedLogTail())"
        )
      }
      do {
        let (_, response) = try await URLSession.shared.data(from: healthURL)
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
          return
        }
      } catch {
        // The server is still binding. Retry until the bounded deadline.
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ValidationError(
      "Temporary Gateway health timed out: \(boundedLogTail())"
    )
  }

  func stop() {
    guard process.isRunning else {
      try? logHandle.close()
      return
    }
    process.terminate()
    for _ in 0..<50 where process.isRunning {
      usleep(20_000)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
    try? logHandle.close()
  }

  private func boundedLogTail() -> String {
    guard let data = try? Data(contentsOf: logURL) else {
      return "log unavailable"
    }
    let suffix = data.suffix(4_096)
    return String(decoding: suffix, as: UTF8.self)
      .replacingOccurrences(of: "\n", with: " ")
  }
}

private struct GatewayVerificationRunner {
  let session: GatewayClientSession
  let fixtureDigest: String
  let runtimeWorkspacePath: String
  let loopbackPort: Int
  let toolCatalog: [MCPTool]
  let observeToolNames: [String]

  private let fixtureWorkspace = "fixture"
  private let repositoryWorkspace = "repository"
  private var requestIDs: [String] = []
  private var completedTools = Set<String>()
  private var denials: [String: String] = [:]
  private var invokedMutationTools = Set<String>()
  private var schemaValidatedMutationTools = Set<String>()
  private var mutationAssertions: [String: JSONValue] = [:]

  init(
    session: GatewayClientSession,
    fixtureDigest: String,
    runtimeWorkspacePath: String,
    loopbackPort: Int,
    toolCatalog: [MCPTool],
    observeToolNames: [String]
  ) {
    self.session = session
    self.fixtureDigest = fixtureDigest
    self.runtimeWorkspacePath = runtimeWorkspacePath
    self.loopbackPort = loopbackPort
    self.toolCatalog = toolCatalog
    self.observeToolNames = observeToolNames
  }

  private static let mutableBuiltinDomains = Set([
    "archive",
    "file",
    "git",
    "json",
    "plist",
    "workspace",
  ])

  private static let environmentGatedMutationTools = Set([
    "workspace.open",
    "workspace.reveal",
  ])

  mutating func run() async throws -> JSONValue {
    let names = try await session.listToolNames()
    let requiredTools = Set([
      "workspace.list",
      "workspace.describe",
      "file.read",
      "skills.read_package",
      "cli.exec",
      "process.spawn",
      "shell.run",
      "git.status",
      "operations.prepare",
      "operations.commit",
    ])
    guard requiredTools.isSubset(of: Set(names)) else {
      throw ValidationError("Temporary Gateway core catalog is incomplete.")
    }

    let observeProfile = try await exerciseObserveProfileFixturePlan()
    let workspace = try await exerciseWorkspaceAndFiles()
    let structured = try await exerciseStructuredFormats()
    let skills = try await exerciseSkills()
    let execution = try await exerciseExecution()
    let mutations = try await exerciseLocalMutations(advertisedToolNames: Set(names))
    let system = try await exerciseSystemState()

    return .object([
      "schema_version": .number(1),
      "generated_at": .string(ValidationTimestamp.now()),
      "fixture_digest": .string(fixtureDigest),
      "catalog_tool_count": .number(Double(names.count)),
      "completed_tool_count": .number(Double(completedTools.count)),
      "completed_tools": .array(completedTools.sorted().map(JSONValue.string)),
      "request_ids": .array(requestIDs.map(JSONValue.string)),
      "denials": .object(denials.mapValues(JSONValue.string)),
      "observe_profile": observeProfile,
      "workspace_and_files": workspace,
      "structured_formats": structured,
      "skills": skills,
      "execution": execution,
      "mutation_workflow": mutations,
      "system_state": system,
    ])
  }

  private mutating func exerciseObserveProfileFixturePlan() async throws -> JSONValue {
    let plan = CapabilityFixturePlan(
      workspaceID: fixtureWorkspace,
      repositoryWorkspaceID: repositoryWorkspace,
      fixturePrefix: ".",
      skillRootID: "fixture-skills",
      skillName: "fixture-skill",
      skillHeading: "Fixture Skill",
      skillContentMarker: "Fixture Skill",
      skillSectionMarker: "Read [the reference]",
      skillSearchQuery: "reference",
      skillSecondaryPath: "references/details.md",
      accessibilityProcessID: getpid(),
      loopbackHTTPURL: URL(string: "http://127.0.0.1:\(loopbackPort)/health")
    )
    let tccTools = Set([
      "computer.accessibility.query",
      "computer.screenshot",
      "computer.windows",
    ])
    let orderedTools: [String] =
      ["workspace.list", "computer.pointer.position"]
      + observeToolNames.filter {
        $0 != "workspace.list"
          && $0 != "computer.pointer.position"
          && $0 != "computer.verify"
      }
      + ["computer.verify"]
    var pointerPosition: (x: Double, y: Double)?
    var passed = 0
    var permissionDenied = 0
    var environmentUnavailable = 0

    for tool in orderedTools {
      guard
        let invocation = plan.invocation(
          for: tool,
          pointerPosition: pointerPosition
        )
      else {
        throw ValidationError("Observe fixture plan has no arguments for \(tool).")
      }

      do {
        let report = try await call(tool, arguments: invocation.arguments)
        let result = try payload(report)
        if let marker = invocation.expectedMarker, !contains(marker, in: result) {
          throw ValidationError(
            "Observe fixture plan marker did not round-trip for \(tool): \(marker)"
          )
        }
        if tool == "computer.pointer.position" {
          guard
            let x = result.objectValue?["x"]?.numberValue,
            let y = result.objectValue?["y"]?.numberValue
          else {
            throw ValidationError("computer.pointer.position returned no coordinate.")
          }
          pointerPosition = (x, y)
        }
        passed += 1
      } catch {
        let stableError = stableCoreError(error)
        guard tccTools.contains(tool) else {
          throw ValidationError(
            "Observe fixture plan call failed for \(tool): \(stableError)"
          )
        }
        if stableError.localizedCaseInsensitiveContains("permission") {
          permissionDenied += 1
        } else if tool == "computer.screenshot",
          stableError.localizedCaseInsensitiveContains(
            "computer_use.screenshot_source_unavailable"
          )
        {
          environmentUnavailable += 1
        } else {
          throw ValidationError(
            "Observe fixture plan call failed for \(tool): \(stableError)"
          )
        }
      }
    }

    guard passed + permissionDenied + environmentUnavailable == orderedTools.count else {
      throw ValidationError("Observe fixture plan did not account for every tool.")
    }
    return .object([
      "tool_count": .number(Double(orderedTools.count)),
      "passed_count": .number(Double(passed)),
      "permission_denied_count": .number(Double(permissionDenied)),
      "environment_unavailable_count": .number(Double(environmentUnavailable)),
      "complete": .bool(true),
    ])
  }

  private mutating func exerciseWorkspaceAndFiles() async throws -> JSONValue {
    let listed = try payload(await call("workspace.list"))
    guard contains(fixtureWorkspace, in: listed), contains(repositoryWorkspace, in: listed) else {
      throw ValidationError("workspace.list did not return both granted workspaces.")
    }
    _ = try payload(
      await call(
        "workspace.describe",
        arguments: ["workspace_id": .string(fixtureWorkspace)]
      )
    )
    let info = try payload(await call("workspace.info", workspaceID: fixtureWorkspace))
    let status = try payload(await call("workspace.status", workspaceID: fixtureWorkspace))
    let outline = try payload(await call("workspace.outline", workspaceID: fixtureWorkspace))
    let dataFiles = try payload(await call("workspace.data_files", workspaceID: fixtureWorkspace))
    let symlinks = try payload(await call("workspace.symlinks", workspaceID: fixtureWorkspace))
    guard contains("Data/sample.json", in: dataFiles) else {
      throw ValidationError("workspace.data_files omitted Data/sample.json.")
    }
    guard contains("Links/readme.md", in: symlinks) else {
      throw ValidationError("workspace.symlinks omitted Links/readme.md.")
    }

    let files = try payload(
      await call(
        "file.list",
        arguments: [
          "path": .string("Data"),
          "recursive_depth": .number(1),
        ],
        workspaceID: fixtureWorkspace
      )
    )
    let read = try payload(
      await call(
        "file.read",
        arguments: ["path": .string("Docs/guide.md")],
        workspaceID: fixtureWorkspace
      )
    )
    let search = try payload(
      await call(
        "file.search",
        arguments: [
          "path": .string("Docs"),
          "query": .string("CMCP-FIXTURE-ALPHA"),
        ],
        workspaceID: fixtureWorkspace
      )
    )
    let diff = try payload(
      await call(
        "file.diff",
        arguments: [
          "source": .string("Duplicates/first.txt"),
          "target": .string("Text/lines.txt"),
        ],
        workspaceID: fixtureWorkspace
      )
    )
    let duplicates = try payload(
      await call(
        "file.duplicates",
        arguments: ["path": .string("Duplicates")],
        workspaceID: fixtureWorkspace
      )
    )
    let link = try payload(
      await call(
        "file.readlink",
        arguments: ["path": .string("Links/readme.md")],
        workspaceID: fixtureWorkspace
      )
    )
    let checks = [
      "file.list": contains("sample.json", in: files),
      "file.read": contains("Fixture Guide", in: read),
      "file.search": contains("CMCP-FIXTURE-ALPHA", in: search),
      "file.diff": contains("duplicate-content", in: diff),
      "file.duplicates": contains("first.txt", in: duplicates),
      "file.readlink": contains("../README.md", in: link),
      "workspace.info": contains(runtimeWorkspacePath, in: info),
      "workspace.status": contains("entry", in: status),
      "workspace.outline": contains("README.md", in: outline),
    ]
    let failedChecks = checks.compactMap { name, passed in
      passed ? nil : name
    }.sorted()
    guard failedChecks.isEmpty else {
      throw ValidationError(
        "Core workspace/file fixture checks failed: \(failedChecks.joined(separator: ", "))."
      )
    }

    denials["missing_workspace"] = await expectedFailure(
      "file.read",
      arguments: ["path": .string("README.md")]
    )
    denials["path_traversal"] = await expectedFailure(
      "file.read",
      arguments: ["path": .string("../Package.swift")],
      workspaceID: fixtureWorkspace
    )
    guard denials["missing_workspace"] != "unexpected-success",
      denials["path_traversal"] != "unexpected-success"
    else {
      throw ValidationError("Workspace routing or path traversal was not denied.")
    }

    return .object([
      "workspace_count": .number(2),
      "classification_verified": .bool(true),
      "read_search_diff_duplicates_verified": .bool(true),
      "symlink_metadata_verified": .bool(true),
      "missing_workspace_denied": .bool(true),
      "path_traversal_denied": .bool(true),
    ])
  }

  private mutating func exerciseStructuredFormats() async throws -> JSONValue {
    let checks: [(String, [String: JSONValue], String)] = [
      ("json.read", ["path": .string("Data/sample.json")], "computer-mcp"),
      ("jsonl.read", ["path": .string("Data/sample.jsonl")], "gamma"),
      ("yaml.read", ["path": .string("Data/sample.yaml")], "alpha"),
      ("toml.read", ["path": .string("Data/sample.toml")], "limits"),
      ("xml.read", ["path": .string("Data/sample.xml")], "fixture"),
      ("plist.read", ["path": .string("Data/sample.plist")], "computer-mcp"),
      ("csv.read", ["path": .string("Data/sample.csv")], "gamma"),
      ("sqlite.schema", ["path": .string("Data/sample.sqlite")], "items"),
      (
        "sqlite.query",
        [
          "path": .string("Data/sample.sqlite"),
          "query": .string("SELECT name FROM items ORDER BY id"),
        ],
        "gamma"
      ),
      ("image.info", ["path": .string("Artifacts/pixel.png")], "png"),
      ("pdf.info", ["path": .string("Artifacts/report.pdf")], "page"),
      ("pdf.text", ["path": .string("Artifacts/report.pdf")], "fixture PDF"),
      ("media.info", ["path": .string("Artifacts/silence.wav")], "audio"),
      ("archive.list", ["path": .string("Artifacts/sample.zip")], "hello.txt"),
      (
        "archive.read_file",
        [
          "path": .string("Artifacts/sample.zip"),
          "entry": .string("ArchiveSource/hello.txt"),
        ],
        "hello from archive"
      ),
      (
        "structured.get",
        [
          "path": .string("Data/sample.json"),
          "query_path": .array([.string("items"), .number(1)]),
        ],
        "beta"
      ),
      (
        "markdown.frontmatter",
        ["path": .string("Skills/fixture-skill/SKILL.md")],
        "Validate folded YAML"
      ),
    ]
    for (tool, arguments, marker) in checks {
      let value = try payload(
        await call(tool, arguments: arguments, workspaceID: fixtureWorkspace)
      )
      guard contains(marker, in: value) else {
        throw ValidationError("\(tool) did not preserve expected marker '\(marker)'.")
      }
    }
    denials["sqlite_write"] = await expectedFailure(
      "sqlite.query",
      arguments: [
        "path": .string("Data/sample.sqlite"),
        "query": .string("DELETE FROM items"),
      ],
      workspaceID: fixtureWorkspace
    )
    guard denials["sqlite_write"] != "unexpected-success" else {
      throw ValidationError("sqlite.query accepted a mutating statement.")
    }
    return .object([
      "parser_count": .number(Double(checks.count)),
      "all_fixture_markers_verified": .bool(true),
      "sqlite_write_denied": .bool(true),
    ])
  }

  private mutating func exerciseSkills() async throws -> JSONValue {
    let roots = try payload(await call("skills.roots"))
    let list = try payload(
      await call("skills.list", arguments: ["root_id": .string("fixture-skills")])
    )
    let describe = try payload(
      await call(
        "skills.describe",
        arguments: [
          "root_id": .string("fixture-skills"),
          "name": .string("fixture-skill"),
        ]
      )
    )
    let validation = try payload(
      await call(
        "skills.validate",
        arguments: [
          "root_id": .string("fixture-skills"),
          "name": .string("fixture-skill"),
        ]
      )
    )
    let frontmatter = try payload(
      await call(
        "skills.frontmatter",
        arguments: [
          "root_id": .string("fixture-skills"),
          "name": .string("fixture-skill"),
        ]
      )
    )
    let package = try payload(
      await call(
        "skills.read_package",
        arguments: [
          "root_id": .string("fixture-skills"),
          "name": .string("fixture-skill"),
        ]
      )
    )
    let search = try payload(
      await call(
        "skills.search_files",
        arguments: [
          "root_id": .string("fixture-skills"),
          "name": .string("fixture-skill"),
          "query": .string("Stable reference content"),
          "search_content": .bool(true),
        ]
      )
    )
    let folded =
      "Validate folded YAML frontmatter and complete skill-package reading through Computer MCP."
    guard
      contains("fixture-skills", in: roots),
      contains(folded, in: list),
      contains(folded, in: describe),
      !contains("\">-\"", in: list),
      contains("\"valid\":true", in: validation),
      contains(folded, in: frontmatter),
      contains("references/details.md", in: package),
      contains("scripts/run.sh", in: package),
      contains("Stable reference content", in: search)
    else {
      throw ValidationError("Skill metadata or package content did not round-trip.")
    }
    return .object([
      "root_ready": .bool(true),
      "folded_description_decoded": .bool(true),
      "package_containment_verified": .bool(true),
      "reference_and_script_read": .bool(true),
    ])
  }

  private mutating func exerciseExecution() async throws -> JSONValue {
    let cliList = try payload(await call("cli.list"))
    let cliStatus = try payload(await call("cli.status"))
    let cliDescribe = try payload(
      await call("cli.describe", arguments: ["id": .string("echo")])
    )
    let cliHelp = try payload(
      await call(
        "cli.help",
        arguments: ["id": .string("git"), "path": .array([])],
        workspaceID: repositoryWorkspace
      )
    )
    let cliExec = try await call(
      "cli.exec",
      arguments: [
        "id": .string("echo"),
        "argv": .array([.string("CMCP_CLI_OK")]),
      ],
      workspaceID: fixtureWorkspace
    )
    guard
      contains("echo", in: cliList),
      contains("\"is_executable\":true", in: cliStatus),
      contains("/bin/echo", in: cliDescribe),
      contains("cli.exec", in: cliHelp),
      contains("CMCP_CLI_OK", in: cliExec.result)
    else {
      throw ValidationError("CLI discovery, help, and execution did not round-trip.")
    }
    denials["unknown_cli"] = await expectedFailure(
      "cli.exec",
      arguments: [
        "id": .string("missing"),
        "argv": .array([]),
      ],
      workspaceID: fixtureWorkspace
    )

    let processSpawn = try await call(
      "process.spawn",
      arguments: [
        "id": .string("sh"),
        "argv": .array([
          .string("-c"),
          .string("printf CMCP_PROCESS_OK; sleep 30"),
        ]),
      ],
      workspaceID: fixtureWorkspace
    )
    let processID = try requiredString("process_id", in: payload(processSpawn))
    _ = try payload(await call("process.list", workspaceID: fixtureWorkspace))
    var processRead: JSONValue = .null
    for _ in 0..<50 {
      processRead = try payload(
        await call(
          "process.read",
          arguments: ["process_id": .string(processID)],
          workspaceID: fixtureWorkspace
        )
      )
      if contains("CMCP_PROCESS_OK", in: processRead) {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard contains("CMCP_PROCESS_OK", in: processRead) else {
      throw ValidationError("process.read did not return streamed output.")
    }
    denials["process_cross_workspace"] = await expectedFailure(
      "process.read",
      arguments: ["process_id": .string(processID)],
      workspaceID: repositoryWorkspace
    )
    _ = try await destructiveCall(
      "process.cancel",
      arguments: ["process_id": .string(processID)],
      workspaceID: fixtureWorkspace
    )

    let shellRun = try await call(
      "shell.run",
      arguments: [
        "mode": .string("argv"),
        "executable": .string("/bin/echo"),
        "argv": .array([.string("CMCP_SHELL_RUN_OK")]),
      ],
      workspaceID: fixtureWorkspace
    )
    guard contains("CMCP_SHELL_RUN_OK", in: shellRun.result) else {
      throw ValidationError("shell.run did not preserve argv output.")
    }
    let shellSpawn = try await call(
      "shell.spawn",
      arguments: [
        "mode": .string("argv"),
        "executable": .string("/bin/sh"),
        "argv": .array([
          .string("-c"),
          .string("read line; printf 'CMCP_SHELL_STDIN:%s\\n' \"$line\"; sleep 30"),
        ]),
      ],
      workspaceID: fixtureWorkspace
    )
    let shellID = try requiredString("session_id", in: payload(shellSpawn))
    _ = try payload(await call("shell.list", workspaceID: fixtureWorkspace))
    _ = try await call(
      "shell.write",
      arguments: [
        "session_id": .string(shellID),
        "text": .string("gateway-input\n"),
      ],
      workspaceID: fixtureWorkspace
    )
    var shellRead: JSONValue = .null
    for _ in 0..<50 {
      shellRead = try payload(
        await call(
          "shell.read",
          arguments: ["session_id": .string(shellID)],
          workspaceID: fixtureWorkspace
        )
      )
      if contains("CMCP_SHELL_STDIN:gateway-input", in: shellRead) {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard contains("CMCP_SHELL_STDIN:gateway-input", in: shellRead) else {
      throw ValidationError("shell.write/read did not preserve stdin and stdout.")
    }
    denials["shell_cross_workspace"] = await expectedFailure(
      "shell.read",
      arguments: ["session_id": .string(shellID)],
      workspaceID: repositoryWorkspace
    )
    _ = try await call(
      "shell.cancel",
      arguments: ["session_id": .string(shellID)],
      workspaceID: fixtureWorkspace
    )

    guard denials.values.allSatisfy({ $0 != "unexpected-success" }) else {
      throw ValidationError("One execution isolation or provider denial unexpectedly succeeded.")
    }
    return .object([
      "cli_discovery_help_and_exec": .bool(true),
      "process_stream_cancel": .bool(true),
      "shell_run_stdin_stream_cancel": .bool(true),
      "workspace_session_isolation": .bool(true),
      "unknown_cli_denied": .bool(true),
    ])
  }

  private mutating func exerciseLocalMutations(
    advertisedToolNames: Set<String>
  ) async throws -> JSONValue {
    let advertisedMutableTools = Set(
      toolCatalog.compactMap { tool -> String? in
        guard advertisedToolNames.contains(tool.name),
          tool.annotations?.readOnlyHint == false,
          let domain = tool.name.split(separator: ".", maxSplits: 1).first.map(String.init),
          Self.mutableBuiltinDomains.contains(domain)
        else {
          return nil
        }
        return tool.name
      }
    )
    let environmentGated = advertisedMutableTools.intersection(
      Self.environmentGatedMutationTools
    )
    let applicable = advertisedMutableTools.subtracting(environmentGated)

    guard environmentGated == Self.environmentGatedMutationTools else {
      let missing = Self.environmentGatedMutationTools.subtracting(environmentGated).sorted()
      throw ValidationError(
        "Generated local-admin catalog omitted environment-gated mutations: \(missing.joined(separator: ", "))."
      )
    }

    try await exerciseFileMutations()
    try await exerciseGitMutations()

    let omitted = applicable.subtracting(invokedMutationTools)
    let unexpected = invokedMutationTools.subtracting(applicable)
    let missingSchemaValidation = applicable.subtracting(schemaValidatedMutationTools)
    guard omitted.isEmpty, unexpected.isEmpty, missingSchemaValidation.isEmpty else {
      throw ValidationError(
        "Mutable builtin coverage mismatch. omitted=\(omitted.sorted()) unexpected=\(unexpected.sorted()) schema_unvalidated=\(missingSchemaValidation.sorted())"
      )
    }

    return .object([
      "advertised_mutable_tool_count": .number(Double(advertisedMutableTools.count)),
      "applicable_tool_count": .number(Double(applicable.count)),
      "invoked_tool_count": .number(Double(invokedMutationTools.count)),
      "schema_validated_tool_count": .number(Double(schemaValidatedMutationTools.count)),
      "advertised_mutable_tools": .array(
        advertisedMutableTools.sorted().map(JSONValue.string)
      ),
      "applicable_tools": .array(applicable.sorted().map(JSONValue.string)),
      "invoked_tools": .array(invokedMutationTools.sorted().map(JSONValue.string)),
      "environment_gated_tools": .array(environmentGated.sorted().map(JSONValue.string)),
      "environment_gate_reason": .string(
        "workspace.open and workspace.reveal require a safe interactive macOS desktop target; core probe classifies them without opening applications or Finder."
      ),
      "omitted_tools": .array([]),
      "unexpected_tools": .array([]),
      "schema_unvalidated_tools": .array([]),
      "assertions": .object(mutationAssertions),
      "complete": .bool(true),
      "runtime_cleanup": .string(
        "The disposable runtime workspace is removed by the command after the report is written."
      ),
    ])
  }

  private mutating func exerciseFileMutations() async throws {
    _ = try await mutationCall(
      "file.mkdir",
      arguments: [
        "path": .string("Mutation/batch"),
        "intermediate_directories": .bool(true),
      ],
      workspaceID: fixtureWorkspace
    )
    try await assertExists(
      "Mutation/batch",
      expected: true,
      for: "file.mkdir",
      workspaceID: fixtureWorkspace
    )

    let writeArguments: [String: JSONValue] = [
      "path": .string("Mutation/text.txt"),
      "content": .string("alpha\nbeta\ngamma\n"),
      "create_directories": .bool(true),
    ]
    try validateMutationArguments(tool: "file.write", arguments: writeArguments)
    let prepared = try payload(
      await call(
        "operations.prepare",
        arguments: [
          "tool": .string("file.write"),
          "arguments": .object(writeArguments),
        ],
        workspaceID: fixtureWorkspace
      )
    )
    let ticketID = try requiredString("ticket_id", in: prepared)
    denials["operation_ticket_mismatch"] = await expectedFailure(
      "operations.commit",
      arguments: [
        "ticket_id": .string(ticketID),
        "tool": .string("file.write"),
        "arguments": .object([
          "path": .string("Mutation/different.txt"),
          "content": .string("different"),
          "create_directories": .bool(true),
        ]),
      ],
      workspaceID: fixtureWorkspace
    )
    _ = try await mutationCall(
      "file.write",
      arguments: writeArguments,
      workspaceID: fixtureWorkspace
    )
    try await assertFileContains(
      "Mutation/text.txt",
      marker: "beta",
      for: "file.write",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.append",
      arguments: [
        "path": .string("Mutation/text.txt"),
        "content": .string("delta"),
        "append_newline": .bool(true),
      ],
      workspaceID: fixtureWorkspace
    )
    try await assertFileContains(
      "Mutation/text.txt",
      marker: "delta",
      for: "file.append",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.replace_text",
      arguments: [
        "path": .string("Mutation/text.txt"),
        "search": .string("beta"),
        "replacement": .string("BETA"),
        "expected_replacements": .number(1),
      ],
      workspaceID: fixtureWorkspace
    )
    try await assertFileContains(
      "Mutation/text.txt",
      marker: "BETA",
      for: "file.replace_text",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.insert_text",
      arguments: [
        "path": .string("Mutation/text.txt"),
        "line": .number(2),
        "content": .string("CMCP_INSERTED_LINE"),
        "position": .string("after"),
        "expected_line": .string("BETA"),
      ],
      workspaceID: fixtureWorkspace
    )
    try await assertFileContains(
      "Mutation/text.txt",
      marker: "CMCP_INSERTED_LINE",
      for: "file.insert_text",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.replace_lines",
      arguments: [
        "path": .string("Mutation/text.txt"),
        "start_line": .number(3),
        "end_line": .number(3),
        "content": .string("CMCP_REPLACED_LINE"),
      ],
      workspaceID: fixtureWorkspace
    )
    try await assertFileContains(
      "Mutation/text.txt",
      marker: "CMCP_REPLACED_LINE",
      for: "file.replace_lines",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.write_files",
      arguments: [
        "files": .array([
          .object([
            "path": .string("Mutation/batch/a.txt"),
            "content": .string("CMCP_BATCH_A\n"),
          ]),
          .object([
            "path": .string("Mutation/batch/b.txt"),
            "content": .string("CMCP_BATCH_B\n"),
          ]),
        ]),
        "overwrite": .bool(false),
        "create_directories": .bool(true),
        "dry_run": .bool(false),
        "confirm_write": .bool(true),
      ],
      workspaceID: fixtureWorkspace
    )
    let batchA = try payload(
      await call(
        "file.read",
        arguments: ["path": .string("Mutation/batch/a.txt")],
        workspaceID: fixtureWorkspace
      )
    )
    let batchB = try payload(
      await call(
        "file.read",
        arguments: ["path": .string("Mutation/batch/b.txt")],
        workspaceID: fixtureWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "file.write_files",
      passed: contains("CMCP_BATCH_A", in: batchA) && contains("CMCP_BATCH_B", in: batchB),
      postcondition: "Both bounded batch files are readable with their expected markers."
    )

    _ = try await mutationCall(
      "file.copy",
      arguments: [
        "source": .string("Mutation/batch/a.txt"),
        "destination": .string("Mutation/batch/copied.txt"),
      ],
      workspaceID: fixtureWorkspace
    )
    try await assertFileContains(
      "Mutation/batch/copied.txt",
      marker: "CMCP_BATCH_A",
      for: "file.copy",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.move",
      arguments: [
        "source": .string("Mutation/batch/copied.txt"),
        "destination": .string("Mutation/batch/moved.txt"),
      ],
      workspaceID: fixtureWorkspace
    )
    let sourceExists = try payload(
      await call(
        "file.exists",
        arguments: ["path": .string("Mutation/batch/copied.txt")],
        workspaceID: fixtureWorkspace
      )
    )
    let destination = try payload(
      await call(
        "file.read",
        arguments: ["path": .string("Mutation/batch/moved.txt")],
        workspaceID: fixtureWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "file.move",
      passed: contains("\"exists\":false", in: sourceExists)
        && contains("CMCP_BATCH_A", in: destination),
      postcondition: "The source is absent and the destination preserves content."
    )

    _ = try await mutationCall(
      "file.touch",
      arguments: ["path": .string("Mutation/batch/touched.txt")],
      workspaceID: fixtureWorkspace
    )
    try await assertExists(
      "Mutation/batch/touched.txt",
      expected: true,
      for: "file.touch",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.symlink",
      arguments: [
        "path": .string("Mutation/moved-link.txt"),
        "destination": .string("batch/moved.txt"),
      ],
      workspaceID: fixtureWorkspace
    )
    let link = try payload(
      await call(
        "file.readlink",
        arguments: ["path": .string("Mutation/moved-link.txt")],
        workspaceID: fixtureWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "file.symlink",
      passed: contains("batch/moved.txt", in: link),
      postcondition: "The raw in-workspace link destination matches the requested path."
    )

    _ = try await mutationCall(
      "file.chmod",
      arguments: [
        "path": .string("Mutation/batch/moved.txt"),
        "mode": .string("0600"),
      ],
      workspaceID: fixtureWorkspace
    )
    let permissions = try payload(
      await call(
        "file.permissions",
        arguments: ["path": .string("Mutation/batch/moved.txt")],
        workspaceID: fixtureWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "file.chmod",
      passed: contains("\"mode_octal\":\"0600\"", in: permissions),
      postcondition: "file.permissions reports mode_octal 0600."
    )

    _ = try await mutationCall(
      "file.remove_xattr",
      arguments: [
        "path": .string("Xattrs/tagged.txt"),
        "name": .string("com.showxu.computer-mcp.fixture"),
      ],
      workspaceID: fixtureWorkspace
    )
    let xattrs = try payload(
      await call(
        "file.xattrs",
        arguments: ["path": .string("Xattrs/tagged.txt")],
        workspaceID: fixtureWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "file.remove_xattr",
      passed: !contains("com.showxu.computer-mcp.fixture", in: xattrs),
      postcondition: "The deterministic fixture extended attribute is absent."
    )

    _ = try await mutationCall(
      "json.write",
      arguments: [
        "path": .string("Mutation/generated.json"),
        "value": .object(["marker": .string("CMCP_JSON_WRITE_OK")]),
        "dry_run": .bool(false),
        "confirm_write": .bool(true),
        "create_directories": .bool(true),
      ],
      workspaceID: fixtureWorkspace
    )
    let generatedJSON = try payload(
      await call(
        "json.read",
        arguments: ["path": .string("Mutation/generated.json")],
        workspaceID: fixtureWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "json.write",
      passed: contains("CMCP_JSON_WRITE_OK", in: generatedJSON),
      postcondition: "json.read returns the written structured marker."
    )

    _ = try await mutationCall(
      "plist.write",
      arguments: [
        "path": .string("Mutation/generated.plist"),
        "value": .object(["marker": .string("CMCP_PLIST_WRITE_OK")]),
        "dry_run": .bool(false),
        "confirm_write": .bool(true),
        "create_directories": .bool(true),
      ],
      workspaceID: fixtureWorkspace
    )
    let generatedPlist = try payload(
      await call(
        "plist.read",
        arguments: ["path": .string("Mutation/generated.plist")],
        workspaceID: fixtureWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "plist.write",
      passed: contains("CMCP_PLIST_WRITE_OK", in: generatedPlist),
      postcondition: "plist.read returns the written structured marker."
    )

    _ = try await mutationCall(
      "archive.create",
      arguments: [
        "path": .string("Mutation/created.zip"),
        "sources": .array([.string("Mutation/batch")]),
        "dry_run": .bool(false),
        "confirm_create": .bool(true),
      ],
      workspaceID: fixtureWorkspace
    )
    let createdArchive = try payload(
      await call(
        "archive.list",
        arguments: ["path": .string("Mutation/created.zip")],
        workspaceID: fixtureWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "archive.create",
      passed: contains("moved.txt", in: createdArchive),
      postcondition: "archive.list returns a file from the explicit source directory."
    )

    _ = try await mutationCall(
      "archive.extract",
      arguments: [
        "path": .string("Artifacts/sample.zip"),
        "destination": .string("Mutation/extracted"),
        "dry_run": .bool(false),
        "confirm_extract": .bool(true),
        "create_directories": .bool(true),
      ],
      workspaceID: fixtureWorkspace
    )
    try await assertFileContains(
      "Mutation/extracted/ArchiveSource/hello.txt",
      marker: "hello from archive",
      for: "archive.extract",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.download",
      arguments: [
        "url": .string("http://127.0.0.1:\(loopbackPort)/health"),
        "path": .string("Mutation/downloaded-health.json"),
        "dry_run": .bool(false),
        "confirm_download": .bool(true),
        "max_download_bytes": .number(65_536),
      ],
      workspaceID: fixtureWorkspace
    )
    try await assertExists(
      "Mutation/downloaded-health.json",
      expected: true,
      for: "file.download",
      workspaceID: fixtureWorkspace
    )

    _ = try await mutationCall(
      "file.write",
      arguments: [
        "path": .string("Mutation/trash-me.txt"),
        "content": .string("CMCP_TRASH_ME"),
      ],
      workspaceID: fixtureWorkspace
    )
    let trashReport = try await mutationCall(
      "file.trash",
      arguments: ["path": .string("Mutation/trash-me.txt")],
      workspaceID: fixtureWorkspace
    )
    try await assertExists(
      "Mutation/trash-me.txt",
      expected: false,
      for: "file.trash",
      workspaceID: fixtureWorkspace
    )
    let trashResult = try payload(trashReport)
    guard let trashedPath = trashResult.objectValue?["trashed_path"]?.stringValue else {
      throw ValidationError("file.trash returned no cleanup path.")
    }
    let trashURL = URL(fileURLWithPath: trashedPath).standardizedFileURL
    let userTrash = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".Trash", isDirectory: true)
      .standardizedFileURL
    guard trashURL.deletingLastPathComponent() == userTrash,
      trashURL.lastPathComponent.hasPrefix("trash-me")
    else {
      throw ValidationError("Refusing to clean an unexpected file.trash result: \(trashedPath)")
    }
    try FileManager.default.removeItem(at: trashURL)
    try recordMutationAssertion(
      tool: "file.trash",
      passed: !FileManager.default.fileExists(atPath: trashURL.path),
      postcondition:
        "The source is absent and the harness removed the owned fixture item from the current user's Trash."
    )

    guard denials["operation_ticket_mismatch"] != "unexpected-success" else {
      throw ValidationError("Operation ticket argument binding was bypassed.")
    }
  }

  private mutating func exerciseGitMutations() async throws {
    let gitStatus = try payload(await call("git.status", workspaceID: repositoryWorkspace))
    let gitLog = try payload(await call("git.log", workspaceID: repositoryWorkspace))
    guard contains("untracked.txt", in: gitStatus), contains("Initial fixture", in: gitLog) else {
      throw ValidationError("Git read atomics did not preserve fixture repository state.")
    }

    _ = try await mutationCall(
      "git.unstage",
      arguments: [
        "paths": .array([.string("staged.txt")]),
        "dry_run": .bool(false),
      ],
      workspaceID: repositoryWorkspace
    )
    let unstaged = try payload(await call("git.status", workspaceID: repositoryWorkspace))
    try recordMutationAssertion(
      tool: "git.unstage",
      passed: contains("staged.txt", in: unstaged),
      postcondition: "git.status still reports staged.txt after its index entry is removed."
    )

    _ = try await mutationCall(
      "git.restore_worktree",
      arguments: [
        "paths": .array([.string("Sources/main.swift")]),
        "dry_run": .bool(false),
        "confirm_discard": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    let restored = try payload(
      await call(
        "file.read",
        arguments: ["path": .string("Sources/main.swift")],
        workspaceID: repositoryWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "git.restore_worktree",
      passed: contains("fixture repository", in: restored)
        && !contains("unstaged change", in: restored),
      postcondition: "The tracked source file matches the committed fixture content."
    )

    _ = try await mutationCall(
      "git.add",
      arguments: [
        "paths": .array([.string("staged.txt")])
      ],
      workspaceID: repositoryWorkspace
    )
    let staged = try payload(
      await call(
        "git.staged_file",
        arguments: ["path": .string("staged.txt")],
        workspaceID: repositoryWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "git.add",
      passed: contains("staged fixture", in: staged),
      postcondition: "git.staged_file returns the staged fixture content."
    )

    _ = try await mutationCall(
      "git.commit",
      arguments: [
        "message": .string("Validation acceptance commit staged fixture")
      ],
      workspaceID: repositoryWorkspace
    )
    let commitFiles = try payload(
      await call(
        "git.commit_files",
        arguments: ["revision": .string("HEAD")],
        workspaceID: repositoryWorkspace
      )
    )
    try recordMutationAssertion(
      tool: "git.commit",
      passed: contains("staged.txt", in: commitFiles),
      postcondition: "The new HEAD commit contains staged.txt."
    )

    _ = try await mutationCall(
      "file.write",
      arguments: [
        "path": .string("README.md"),
        "content": .string("# Fixture Repository\n\nCMCP_STASH_CHANGE\n"),
        "overwrite": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    _ = try await mutationCall(
      "git.stash_push",
      arguments: [
        "message": .string("CMCP validation stash"),
        "paths": .array([.string("README.md")]),
      ],
      workspaceID: repositoryWorkspace
    )
    let stashes = try payload(await call("git.stashes", workspaceID: repositoryWorkspace))
    try recordMutationAssertion(
      tool: "git.stash_push",
      passed: contains("CMCP validation stash", in: stashes),
      postcondition: "git.stashes reports the newly created bounded stash."
    )

    _ = try await mutationCall(
      "git.clean",
      arguments: [
        "paths": .array([.string("untracked.txt")]),
        "dry_run": .bool(false),
        "confirm_delete": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    try await assertExists(
      "untracked.txt",
      expected: false,
      for: "git.clean",
      workspaceID: repositoryWorkspace
    )

    _ = try await mutationCall(
      "git.branch_create",
      arguments: [
        "name": .string("cmcp-validation-branch"),
        "dry_run": .bool(false),
        "confirm_create": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    let createdBranches = try payload(
      await call("git.branch", workspaceID: repositoryWorkspace)
    )
    try recordMutationAssertion(
      tool: "git.branch_create",
      passed: contains("cmcp-validation-branch", in: createdBranches),
      postcondition: "git.branch reports the created local branch."
    )

    _ = try await mutationCall(
      "git.branch_rename",
      arguments: [
        "old_name": .string("cmcp-validation-branch"),
        "new_name": .string("cmcp-validation-renamed"),
        "dry_run": .bool(false),
        "confirm_rename": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    let renamedBranches = try payload(
      await call("git.branch", workspaceID: repositoryWorkspace)
    )
    try recordMutationAssertion(
      tool: "git.branch_rename",
      passed: contains("cmcp-validation-renamed", in: renamedBranches)
        && !contains("cmcp-validation-branch", in: renamedBranches),
      postcondition: "Only the renamed branch appears in git.branch."
    )

    _ = try await mutationCall(
      "git.branch_switch",
      arguments: [
        "name": .string("cmcp-validation-renamed"),
        "dry_run": .bool(false),
        "confirm_switch": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    let switched = try payload(
      await call("git.tracking_status", workspaceID: repositoryWorkspace)
    )
    try recordMutationAssertion(
      tool: "git.branch_switch",
      passed: contains("cmcp-validation-renamed", in: switched),
      postcondition: "git.tracking_status reports the requested branch as current."
    )

    _ = try await mutationCall(
      "git.branch_switch",
      arguments: [
        "name": .string("main"),
        "dry_run": .bool(false),
        "confirm_switch": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    _ = try await mutationCall(
      "git.branch_delete",
      arguments: [
        "name": .string("cmcp-validation-renamed"),
        "dry_run": .bool(false),
        "confirm_delete": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    let deletedBranches = try payload(
      await call("git.branch", workspaceID: repositoryWorkspace)
    )
    try recordMutationAssertion(
      tool: "git.branch_delete",
      passed: !contains("cmcp-validation-renamed", in: deletedBranches),
      postcondition: "git.branch no longer reports the deleted local branch."
    )

    _ = try await mutationCall(
      "git.tag_create",
      arguments: [
        "name": .string("cmcp-validation-tag"),
        "dry_run": .bool(false),
        "confirm_create": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    let createdTags = try payload(await call("git.tags", workspaceID: repositoryWorkspace))
    try recordMutationAssertion(
      tool: "git.tag_create",
      passed: contains("cmcp-validation-tag", in: createdTags),
      postcondition: "git.tags reports the created local tag."
    )

    _ = try await mutationCall(
      "git.tag_delete",
      arguments: [
        "name": .string("cmcp-validation-tag"),
        "dry_run": .bool(false),
        "confirm_delete": .bool(true),
      ],
      workspaceID: repositoryWorkspace
    )
    let deletedTags = try payload(await call("git.tags", workspaceID: repositoryWorkspace))
    try recordMutationAssertion(
      tool: "git.tag_delete",
      passed: !contains("cmcp-validation-tag", in: deletedTags),
      postcondition: "git.tags no longer reports the deleted local tag."
    )
  }

  private mutating func exerciseSystemState() async throws -> JSONValue {
    let info = try payload(await call("system.info"))
    let time = try payload(await call("system.time"))
    let screens = try payload(await call("macos.screens"))
    let permissions = try payload(await call("computer.permissions"))
    let displays = try payload(await call("computer.displays"))
    let pointer = try payload(await call("computer.pointer.position"))
    guard
      let pointerX = pointer.objectValue?["x"]?.numberValue,
      let pointerY = pointer.objectValue?["y"]?.numberValue
    else {
      throw ValidationError("computer.pointer.position returned no coordinate.")
    }
    let verification = try payload(
      await call(
        "computer.verify",
        arguments: [
          "verification": .object([
            "type": .string("pointer-position"),
            "point": .object([
              "x": .number(pointerX),
              "y": .number(pointerY),
            ]),
            "tolerance": .number(1),
          ]),
          "policy": .object([
            "timeout_milliseconds": .number(0),
            "poll_interval_milliseconds": .number(20),
          ]),
        ]
      )
    )
    let resolve = try payload(
      await call(
        "network.resolve",
        arguments: ["host": .string("localhost")]
      )
    )
    guard
      contains("macOS", in: info),
      contains("time", in: time),
      contains("screen", in: screens),
      contains("accessibility", in: permissions),
      contains("pixel", in: displays),
      contains("pointer-position", in: verification),
      contains("127.0.0.1", in: resolve) || contains("::1", in: resolve)
    else {
      throw ValidationError(
        "System, macOS, Computer Use, or local network state did not round-trip."
      )
    }
    return .object([
      "system_info_and_time": .bool(true),
      "macos_screens": .bool(true),
      "computer_permissions_displays_pointer_verify": .bool(true),
      "localhost_resolution": .bool(true),
    ])
  }

  private mutating func call(
    _ tool: String,
    arguments: [String: JSONValue] = [:],
    workspaceID: String? = nil
  ) async throws -> GatewayCallReport {
    var bound = arguments
    if let workspaceID {
      bound["workspace_id"] = .string(workspaceID)
    }
    let report = try await session.call(
      toolName: tool,
      arguments: .object(bound)
    )
    requestIDs.append(report.requestID)
    guard report.result.objectValue?["isError"]?.boolValue != true else {
      throw ValidationError("Tool \(tool) returned an MCP error result.")
    }
    completedTools.insert(tool)
    return report
  }

  private mutating func mutationCall(
    _ tool: String,
    arguments: [String: JSONValue],
    workspaceID: String
  ) async throws -> GatewayCallReport {
    try validateMutationArguments(tool: tool, arguments: arguments)
    let definition = try mutationToolDefinition(named: tool)
    let report: GatewayCallReport
    if definition.annotations?.destructiveHint == true {
      report = try await destructiveCall(
        tool,
        arguments: arguments,
        workspaceID: workspaceID
      )
    } else {
      report = try await call(
        tool,
        arguments: arguments,
        workspaceID: workspaceID
      )
    }
    invokedMutationTools.insert(tool)
    schemaValidatedMutationTools.insert(tool)
    return report
  }

  private mutating func destructiveCall(
    _ tool: String,
    arguments: [String: JSONValue],
    workspaceID: String
  ) async throws -> GatewayCallReport {
    let prepared = try payload(
      await call(
        "operations.prepare",
        arguments: [
          "tool": .string(tool),
          "arguments": .object(arguments),
        ],
        workspaceID: workspaceID
      )
    )
    let ticketID = try requiredString("ticket_id", in: prepared)
    let report = try await call(
      "operations.commit",
      arguments: [
        "ticket_id": .string(ticketID),
        "tool": .string(tool),
        "arguments": .object(arguments),
      ],
      workspaceID: workspaceID
    )
    completedTools.insert(tool)
    return report
  }

  private func mutationToolDefinition(named name: String) throws -> MCPTool {
    guard let definition = toolCatalog.first(where: { $0.name == name }) else {
      throw ValidationError("Generated local-admin registry omitted mutable tool \(name).")
    }
    guard definition.annotations?.readOnlyHint == false else {
      throw ValidationError("Mutable workflow tool \(name) is not annotated readOnlyHint=false.")
    }
    return definition
  }

  private func validateMutationArguments(
    tool: String,
    arguments: [String: JSONValue]
  ) throws {
    let definition = try mutationToolDefinition(named: tool)
    guard let schema = definition.inputSchema.objectValue,
      schema["type"] == .string("object"),
      let properties = schema["properties"]?.objectValue
    else {
      throw ValidationError("Mutable tool \(tool) has no object input schema.")
    }
    let unknown = Set(arguments.keys).subtracting(properties.keys)
    guard unknown.isEmpty else {
      throw ValidationError(
        "Mutable tool \(tool) arguments are not declared by its live schema: \(unknown.sorted())."
      )
    }
    let required = Set(
      schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    )
    let missing = required.subtracting(arguments.keys)
    guard missing.isEmpty else {
      throw ValidationError(
        "Mutable tool \(tool) is missing live-schema required arguments: \(missing.sorted())."
      )
    }
  }

  private mutating func assertFileContains(
    _ path: String,
    marker: String,
    for tool: String,
    workspaceID: String
  ) async throws {
    let value = try payload(
      await call(
        "file.read",
        arguments: ["path": .string(path)],
        workspaceID: workspaceID
      )
    )
    try recordMutationAssertion(
      tool: tool,
      passed: contains(marker, in: value),
      postcondition: "\(path) contains the bounded marker \(marker)."
    )
  }

  private mutating func assertExists(
    _ path: String,
    expected: Bool,
    for tool: String,
    workspaceID: String
  ) async throws {
    let value = try payload(
      await call(
        "file.exists",
        arguments: ["path": .string(path)],
        workspaceID: workspaceID
      )
    )
    try recordMutationAssertion(
      tool: tool,
      passed: contains("\"exists\":\(expected)", in: value),
      postcondition: "\(path) exists=\(expected)."
    )
  }

  private mutating func recordMutationAssertion(
    tool: String,
    passed: Bool,
    postcondition: String
  ) throws {
    mutationAssertions[tool] = .object([
      "passed": .bool(passed),
      "postcondition": .string(postcondition),
    ])
    guard passed else {
      throw ValidationError("Mutation postcondition failed for \(tool): \(postcondition)")
    }
  }

  private mutating func expectedFailure(
    _ tool: String,
    arguments: [String: JSONValue],
    workspaceID: String? = nil
  ) async -> String {
    do {
      _ = try await call(tool, arguments: arguments, workspaceID: workspaceID)
      return "unexpected-success"
    } catch {
      return "request-failed"
    }
  }

  private func payload(_ report: GatewayCallReport) throws -> JSONValue {
    guard let structured = report.result.objectValue?["structuredContent"] else {
      throw ValidationError("Tool \(report.toolName) returned no structuredContent.")
    }
    return structured.objectValue?["result"] ?? structured
  }

  private func requiredString(_ key: String, in value: JSONValue) throws -> String {
    guard let string = value.objectValue?[key]?.stringValue, !string.isEmpty else {
      throw ValidationError("Required response field '\(key)' is missing.")
    }
    return string
  }

  private func contains(_ marker: String, in value: JSONValue) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
      return false
    }
    return String(decoding: data, as: UTF8.self)
      .localizedCaseInsensitiveContains(marker)
  }
}

private func stableCoreError(_ error: Error) -> String {
  if let localized = error as? any LocalizedError,
    let description = localized.errorDescription
  {
    return description
  }
  return String(describing: error)
}

private struct ProductInventoryNames: Decodable {
  struct Tool: Decodable {
    let name: String
  }

  let schemaVersion: Int
  let tools: [Tool]
}

private func productInventoryToolNames(
  product: ValidationProductCommand,
  configURL: URL,
  caller: GatewayCallerKind,
  profileID: GatewayProfileID
) throws -> [String] {
  let data = try product.run([
    "tools", "inventory", "--config", configURL.path,
    "--caller", caller.rawValue,
    "--profile", profileID.rawValue,
  ])
  let inventory = try ValidationCanonicalJSONCoding.decoder().decode(
    ProductInventoryNames.self,
    from: data
  )
  guard inventory.schemaVersion == 1 else {
    throw ValidationArtifactError.unsupportedSchema(
      artifact: "Tool Inventory",
      expected: 1,
      actual: inventory.schemaVersion
    )
  }
  return inventory.tools.map(\.name).sorted()
}

private func defaultBuiltinCapabilities(in manifest: Data) throws -> [String] {
  let text = String(decoding: manifest, as: UTF8.self)
  guard let section = text.range(of: "\n[builtin]\n"),
    let assignment = text.range(of: "enabled = [", range: section.upperBound..<text.endIndex),
    let closing = text[assignment.upperBound...].firstIndex(of: "]")
  else {
    throw ValidationProcessError.launchFailed(
      "The shipped default manifest has no bounded [builtin] enabled array."
    )
  }
  let body = String(text[assignment.upperBound..<closing])
  let expression = try NSRegularExpression(pattern: #""([^"\\]+)""#)
  let range = NSRange(body.startIndex..<body.endIndex, in: body)
  let values = expression.matches(in: body, range: range).compactMap { match -> String? in
    guard let valueRange = Range(match.range(at: 1), in: body) else { return nil }
    return String(body[valueRange])
  }
  guard !values.isEmpty else {
    throw ValidationProcessError.launchFailed(
      "The shipped default manifest exposes no builtin capabilities."
    )
  }
  return values.sorted()
}

private func writeCoreGatewayManifest(
  fixtureRoot: URL,
  port: Int,
  builtins: [String],
  to destination: URL
) throws {
  let manifest = """
    schema_version = 1

    [server]
    name = "computer-mcp-core-dogfood"

    [runtime]
    caller = "local-mcp"
    profile = "local-admin"

    [server.http]
    host = "127.0.0.1"
    port = \(port)
    path = "/mcp"
    health_path = "/health"

    [policy]
    default_timeout_ms = 30000
    max_output_bytes = 1048576
    shell_enabled = true

    [[workspaces]]
    id = "fixture"
    display_name = "Capability WorkspaceFixtureGenerate"
    path = \(coreTOMLString(fixtureRoot.path))

    [[workspaces]]
    id = "repository"
    display_name = "Fixture Git Repository"
    path = \(coreTOMLString(fixtureRoot.appendingPathComponent("Repository").path))

    [[profiles]]
    id = "local-admin"
    capabilities = ["*"]
    workspaces = ["fixture", "repository"]
    allowed_callers = ["local-app", "local-cli", "local-mcp"]
    full_shell_enabled = true

    [skills]
    enabled = true
    max_bytes_per_skill = 1048576

    [[skills.roots]]
    id = "fixture-skills"
    path = \(coreTOMLString(fixtureRoot.appendingPathComponent("Skills").path))
    description = "Deterministic validation skill packages."

    [[cli.commands]]
    id = "echo"
    executable = "/bin/echo"
    cwd = "workspace"
    allow_any_args = true
    risk = "read-only"
    discovery = ["help"]

    [[cli.commands]]
    id = "sh"
    executable = "/bin/sh"
    cwd = "workspace"
    allow_any_args = true
    risk = "workspace-write-capable"
    discovery = ["help"]

    [[cli.commands]]
    id = "git"
    executable = "/usr/bin/git"
    cwd = "workspace"
    allow_any_args = true
    risk = "workspace-write-capable"
    discovery = ["help"]

    [builtin]
    enabled = \(coreTOMLArray(builtins))
    """
  try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data(manifest.utf8).write(to: destination, options: .atomic)
}

private func coreTOMLArray(_ values: [String]) -> String {
  guard !values.isEmpty else {
    return "[]"
  }
  return "[\n" + values.map { "  \(coreTOMLString($0))," }.joined(separator: "\n") + "\n]"
}

private func coreTOMLString(_ value: String) -> String {
  var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
  escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
  escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
  return "\"\(escaped)\""
}

private func writeCoreJSON(_ value: JSONValue, destination: String) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let destinationURL = URL(fileURLWithPath: destination)
  try writeCoreData(try encoder.encode(value), destination: destinationURL)
}

private func writeCoreData(_ data: Data, destination: URL) throws {
  try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: destination, options: .atomic)
}
