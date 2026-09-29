import Foundation

/// Owns configured source definitions, gateway tool schemas, and dispatch.
internal final class GatewayToolRegistry: @unchecked Sendable {
  internal let configuration: GatewayConfiguration

  internal let commandRunner: CommandRunning

  internal let processManager: ProcessManaging

  internal let shellManager: ShellManaging

  internal let mcpClient: DownstreamMCPClient

  internal let environment: [String: String]

  internal let encoder: JSONEncoder

  internal let cliExecution: CLIProcessExecution

  internal init(
    configuration: GatewayConfiguration,
    commandRunner: CommandRunning? = nil,
    processManager: ProcessManaging = ManagedProcessRegistry(),
    shellManager: ShellManaging = SubprocessShellRuntime(),
    mcpClient: DownstreamMCPClient = MCPProxyClient(),
    hostContext: MCPHostContext? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    var enabledConfiguration = configuration
    let disabledMCPIDs = Set(configuration.mcp.servers.filter { !$0.enabled }.map(\.id))
    enabledConfiguration.mcp.servers.removeAll { !$0.enabled }
    enabledConfiguration.tools.removeAll { disabledMCPIDs.contains($0.source) }
    self.configuration = enabledConfiguration
    self.cliExecution = CLIProcessExecution(
      maxConcurrentCalls: configuration.policy.maxShellSessions, inheritsEnvironment: false)
    self.commandRunner = commandRunner ?? ProcessCommandRunner(environment: environment)
    self.processManager = processManager
    self.shellManager = shellManager
    self.mcpClient = mcpClient.makeScopedClient(
      workingDirectory: configuration.workspaceDirectory, environment: environment,
      hostContext: hostContext)
    self.environment = environment
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  internal var hasReexportedMCPServers: Bool {
    configuration.mcp.servers.contains { $0.exposure.includesReexport }
  }

  internal var hasCLITrees: Bool { configuration.cli.commands.contains { $0.tree != nil } }

  internal func cliTreeProviders() throws -> [any GatewayToolProvider] {
    try configuration.cli.commands.compactMap { command in
      guard let source = command.tree else { return nil }
      var command = command
      command.env = environment.merging(command.env) { _, value in value }
      let tree = try source.load(
        command: command, workspace: configuration.workspaceDirectory, execution: cliExecution)
      return CLITreeToolProvider(
        registration: command, tree: tree, workspace: configuration.workspaceDirectory,
        execution: cliExecution,
        timeoutMilliseconds: command.defaultTimeoutMs ?? configuration.policy.defaultTimeoutMs,
        maxOutputBytes: configuration.policy.maxOutputBytes)
    }
  }

  internal func toolChanges() -> AsyncStream<Void> { mcpClient.toolChanges() }

  internal func shutdown() async {
    await shellManager.shutdown()
    await cliExecution.shutdown()
    await mcpClient.shutdown()
  }

  /// Registered gateway and optionally reexported downstream MCP tools.
  internal func listTools() throws -> [MCPTool] {
    var tools = Self.gatewayTools(
      shellEnabled: configuration.policy.shellEnabled,
      builtins: Set(configuration.builtin.enabled),
      skillsEnabled: configuration.skills.enabled,
      hasCLIProviders: !configuration.cli.commands.isEmpty,
      hasMCPProviders: !configuration.mcp.servers.isEmpty,
      toolMeta: toolMeta()
    )

    for configuredTool in configuration.tools {
      guard let target = configuredTool.tool,
        let server = configuration.mcp.servers.first(where: { $0.id == configuredTool.source }),
        mcpClient.isServerVisible(server), server.permitsTool(target),
        let downstream = try permittedDownstreamTools(server: server).first(where: {
          $0.name == target
        })
      else { continue }
      try appendTool(try toolDefinition(for: configuredTool, downstream: downstream), to: &tools)
    }

    for server in configuration.mcp.servers where server.exposure.includesReexport {
      guard let prefix = server.prefix else {
        throw GatewayToolError.invalidArguments(
          "MCP server '\(server.id)' uses reexport exposure but has no prefix.")
      }
      let downstreamTools = try permittedDownstreamTools(server: server).map {
        $0.prefixed(prefix, serverID: server.id)
      }
      let existing = Set(tools.map(\.name))
      if let conflict = downstreamTools.first(where: { existing.contains($0.name) }) {
        throw GatewayToolError.invalidArguments("Reexported tool name conflicts: \(conflict.name)")
      }
      tools.append(contentsOf: downstreamTools)
    }

    return tools
  }

  /// Validates arguments, executes a tool, and returns MCP tool content.
  internal func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    let object = arguments?.objectValue ?? [:]

    switch name {
    case "cli.list":
      try requireCLIProviders()
      return try textResult(cliList())

    case "cli.describe":
      try requireCLIProviders()
      return try textResult(cliDescribe(arguments: object))

    case "cli.status":
      try requireCLIProviders()
      return try textResult(cliStatus(arguments: object))

    case "cli.help":
      try requireCLIProviders()
      return try textResult(runCLIHelp(arguments: object))

    case "cli.exec":
      try requireCLIProviders()
      return try textResult(runCLIExec(arguments: object))

    case "mcp.servers.list":
      try requireMCPProviders()
      return try textResult(mcpServerList())

    case "mcp.servers.status":
      try requireMCPProviders()
      return try textResult(mcpServerStatus(arguments: object))

    case "mcp.tools.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPTools(arguments: object))

    case "mcp.tools.describe":
      try requireMCPProviders()
      return try textResult(describeDownstreamMCPTool(arguments: object))

    case "mcp.tools.find":
      try requireMCPProviders()
      return try textResult(findDownstreamMCPTools(arguments: object))

    case "mcp.tools.call":
      try requireMCPProviders()
      return try callDownstreamMCPTool(arguments: object)

    case "mcp.resources.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPResources(arguments: object))

    case "mcp.resources.templates.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPResourceTemplates(arguments: object))

    case "mcp.resources.read":
      try requireMCPProviders()
      return try textResult(readDownstreamMCPResource(arguments: object))

    case "mcp.prompts.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPPrompts(arguments: object))

    case "mcp.prompts.get":
      try requireMCPProviders()
      return try textResult(getDownstreamMCPPrompt(arguments: object))

    case "mcp.events.read":
      try requireMCPProviders()
      return try textResult(readDownstreamMCPEvents(arguments: object))

    case "mcp.requests.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPRequests(arguments: object))

    case "mcp.requests.read":
      try requireMCPProviders()
      return try textResult(readDownstreamMCPRequest(arguments: object))

    case "mcp.requests.cancel":
      try requireMCPProviders()
      return try textResult(cancelDownstreamMCPRequest(arguments: object))

    case "mcp.connections.close":
      try requireMCPProviders()
      guard Set(object.keys) == ["server"] else {
        throw GatewayToolError.invalidArguments("Supply only the selected MCP server id.")
      }
      return try textResult(
        mcpClient.closeConnection(server: mcpServer(requiredString("server", in: object))))

    case "process.spawn":
      try requireCLIProviders()
      return try textResult(spawnProcess(arguments: object))

    case "process.list":
      try requireCLIProviders()
      return try textResult(listProcesses())

    case "process.read":
      try requireCLIProviders()
      return try textResult(readProcess(arguments: object))

    case "process.cancel":
      try requireCLIProviders()
      return try textResult(cancelProcess(arguments: object))

    case "skills.roots":
      try requireSkillsEnabled()
      return try textResult(skillsRoots())

    case "skills.list":
      try requireSkillsEnabled()
      return try textResult(skillsList(arguments: object))

    case "skills.describe":
      try requireSkillsEnabled()
      return try textResult(skillsDescribe(arguments: object))

    case "skills.validate":
      try requireSkillsEnabled()
      return try textResult(skillsValidate(arguments: object))

    case "skills.frontmatter":
      try requireSkillsEnabled()
      return try textResult(skillsFrontmatter(arguments: object))

    case "skills.read":
      try requireSkillsEnabled()
      return try textResult(skillsRead(arguments: object))

    case "skills.files":
      try requireSkillsEnabled()
      return try textResult(skillsFiles(arguments: object))

    case "skills.read_file":
      try requireSkillsEnabled()
      return try textResult(skillsReadFile(arguments: object))

    case "skills.read_files":
      try requireSkillsEnabled()
      return try textResult(skillsReadFiles(arguments: object))

    case "skills.read_package":
      try requireSkillsEnabled()
      return try textResult(skillsReadPackage(arguments: object))

    case "skills.outline":
      try requireSkillsEnabled()
      return try textResult(skillsOutline(arguments: object))

    case "skills.section":
      try requireSkillsEnabled()
      return try textResult(skillsSection(arguments: object))

    case "skills.tables":
      try requireSkillsEnabled()
      return try textResult(skillsTables(arguments: object))

    case "skills.links":
      try requireSkillsEnabled()
      return try textResult(skillsLinks(arguments: object))

    case "skills.link_check":
      try requireSkillsEnabled()
      return try textResult(skillsLinkCheck(arguments: object))

    case "skills.search":
      try requireSkillsEnabled()
      return try textResult(skillsSearch(arguments: object))

    case "skills.search_files":
      try requireSkillsEnabled()
      return try textResult(skillsSearchFiles(arguments: object))

    case "shell.run":
      try requireShellEnabled()
      return try textResult(runShell(arguments: object))

    case "shell.spawn":
      try requireShellEnabled()
      return try textResult(spawnShell(arguments: object))

    case "shell.list":
      try requireShellEnabled()
      return try textResult(listShellSessions(arguments: object))

    case "shell.read":
      try requireShellEnabled()
      return try textResult(readShellSession(arguments: object))

    case "shell.write":
      try requireShellEnabled()
      return try textResult(writeShellSession(arguments: object))

    case "shell.cancel":
      try requireShellEnabled()
      return try textResult(cancelShellSession(arguments: object))

    case "workspace.info":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceInfo())

    case "workspace.status":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceStatus(arguments: object))

    case "workspace.manifests":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceManifests(arguments: object))

    case "workspace.recent_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceRecentFiles(arguments: object))

    case "workspace.directory_stats":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceDirectoryStats(arguments: object))

    case "workspace.artifact_directories":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceArtifactDirectories(arguments: object))

    case "workspace.empty_directories":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceEmptyDirectories(arguments: object))

    case "workspace.git_changes":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceGitChanges(arguments: object))

    case "workspace.file_types":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceFileTypes(arguments: object))

    case "workspace.large_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceLargeFiles(arguments: object))

    case "workspace.symlinks":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceSymlinks(arguments: object))

    case "workspace.executable_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceExecutableFiles(arguments: object))

    case "workspace.todos":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceTodos(arguments: object))

    case "workspace.env_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceEnvFiles(arguments: object))

    case "workspace.dependency_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceDependencyFiles(arguments: object))

    case "workspace.project_roots":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceProjectRoots(arguments: object))

    case "workspace.documentation_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceDocumentationFiles(arguments: object))

    case "workspace.agent_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceAgentFiles(arguments: object))

    case "workspace.instructions":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceInstructions(arguments: object))

    case "workspace.test_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceTestFiles(arguments: object))

    case "workspace.ci_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceCIFiles(arguments: object))

    case "workspace.infra_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceInfraFiles(arguments: object))

    case "workspace.config_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceConfigFiles(arguments: object))

    case "workspace.ignore_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceIgnoreFiles(arguments: object))

    case "workspace.asset_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceAssetFiles(arguments: object))

    case "workspace.archive_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceArchiveFiles(arguments: object))

    case "workspace.log_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceLogFiles(arguments: object))

    case "workspace.data_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceDataFiles(arguments: object))

    case "workspace.schema_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceSchemaFiles(arguments: object))

    case "workspace.source_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceSourceFiles(arguments: object))

    case "workspace.outline":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceOutline(arguments: object))

    case "workspace.commands":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceCommands(arguments: object))

    case "workspace.governance_files":
      try requireBuiltinEnabled(name)
      return try textResult(workspaceGovernanceFiles(arguments: object))

    case "system.info":
      try requireBuiltinEnabled(name)
      return try textResult(systemInfo())

    case "system.kernel":
      try requireBuiltinEnabled(name)
      return try textResult(systemKernel())

    case "system.software":
      try requireBuiltinEnabled(name)
      return try textResult(systemSoftware(arguments: object))

    case "system.locale":
      try requireBuiltinEnabled(name)
      return try textResult(systemLocale())

    case "system.memory":
      try requireBuiltinEnabled(name)
      return try textResult(systemMemory())

    case "system.load":
      try requireBuiltinEnabled(name)
      return try textResult(systemLoad())

    case "system.cpu":
      try requireBuiltinEnabled(name)
      return try textResult(systemCPU())

    case "system.thermal":
      try requireBuiltinEnabled(name)
      return try textResult(systemThermal())

    case "system.time":
      try requireBuiltinEnabled(name)
      return try textResult(systemTime())

    case "system.uptime":
      try requireBuiltinEnabled(name)
      return try textResult(systemUptime())

    case "system.user":
      try requireBuiltinEnabled(name)
      return try textResult(systemUser())

    case "system.groups":
      try requireBuiltinEnabled(name)
      return try textResult(systemGroups())

    case "system.power":
      try requireBuiltinEnabled(name)
      return try textResult(systemPower(arguments: object))

    case "system.volumes":
      try requireBuiltinEnabled(name)
      return try textResult(systemVolumes(arguments: object))

    case "system.processes":
      try requireBuiltinEnabled(name)
      return try textResult(systemProcesses(arguments: object))

    case "system.which":
      try requireBuiltinEnabled(name)
      return try textResult(systemWhich(arguments: object))

    case "system.path":
      try requireBuiltinEnabled(name)
      return try textResult(systemPath(arguments: object))

    case "logs.query":
      try requireBuiltinEnabled(name)
      return try textResult(logsQuery(arguments: object))

    case "service.status":
      try requireBuiltinEnabled(name)
      return try textResult(serviceStatus(arguments: object))

    case "network.interfaces":
      try requireBuiltinEnabled(name)
      return try textResult(networkInterfaces(arguments: object))

    case "network.dns":
      try requireBuiltinEnabled(name)
      return try textResult(networkDNS(arguments: object))

    case "network.resolve":
      try requireBuiltinEnabled(name)
      return try textResult(networkResolve(arguments: object))

    case "network.proxy":
      try requireBuiltinEnabled(name)
      return try textResult(networkProxy(arguments: object))

    case "network.services":
      try requireBuiltinEnabled(name)
      return try textResult(networkServices(arguments: object))

    case "network.hardware_ports":
      try requireBuiltinEnabled(name)
      return try textResult(networkHardwarePorts(arguments: object))

    case "network.wifi":
      try requireBuiltinEnabled(name)
      return try textResult(networkWiFi(arguments: object))

    case "network.vpn":
      try requireBuiltinEnabled(name)
      return try textResult(networkVPN(arguments: object))

    case "network.locations":
      try requireBuiltinEnabled(name)
      return try textResult(networkLocations(arguments: object))

    case "network.routes":
      try requireBuiltinEnabled(name)
      return try textResult(networkRoutes(arguments: object))

    case "network.connections":
      try requireBuiltinEnabled(name)
      return try textResult(networkConnections(arguments: object))

    case "network.arp":
      try requireBuiltinEnabled(name)
      return try textResult(networkARP(arguments: object))

    case "network.ping":
      try requireBuiltinEnabled(name)
      return try textResult(networkPing(arguments: object))

    case "network.tcp_check":
      try requireBuiltinEnabled(name)
      return try textResult(networkTCPCheck(arguments: object))

    case "network.http_check":
      try requireBuiltinEnabled(name)
      return try textResult(networkHTTPCheck(arguments: object))

    case "network.listeners":
      try requireBuiltinEnabled(name)
      return try textResult(networkListeners(arguments: object))

    case "macos.user_directories":
      try requireBuiltinEnabled(name)
      return try textResult(macOSUserDirectories(arguments: object))

    case "macos.default_application":
      try requireBuiltinEnabled(name)
      return try textResult(macOSDefaultApplication(arguments: object))

    case "macos.applications":
      try requireBuiltinEnabled(name)
      return try textResult(macOSApplications(arguments: object))

    case "macos.screens":
      try requireBuiltinEnabled(name)
      return try textResult(macOSScreens())

    case "macos.spotlight_search":
      try requireBuiltinEnabled(name)
      return try textResult(macOSSpotlightSearch(arguments: object))

    case "macos.running_applications":
      try requireBuiltinEnabled(name)
      return try textResult(macOSRunningApplications(arguments: object))

    case "macos.frontmost_application":
      try requireBuiltinEnabled(name)
      return try textResult(macOSFrontmostApplication())

    case "env.describe":
      try requireBuiltinEnabled(name)
      return try textResult(describeEnvironment())

    case "file.exists":
      try requireBuiltinEnabled(name)
      return try textResult(fileExists(arguments: object))

    case "file.list":
      try requireBuiltinEnabled(name)
      return try textResult(listFiles(arguments: object))

    case "file.tree":
      try requireBuiltinEnabled(name)
      return try textResult(treeFiles(arguments: object))

    case "file.stat":
      try requireBuiltinEnabled(name)
      return try textResult(statFile(arguments: object))

    case "file.permissions":
      try requireBuiltinEnabled(name)
      return try textResult(filePermissions(arguments: object))

    case "file.chmod":
      try requireBuiltinEnabled(name)
      return try textResult(chmodFile(arguments: object))

    case "file.type":
      try requireBuiltinEnabled(name)
      return try textResult(typeFile(arguments: object))

    case "file.count":
      try requireBuiltinEnabled(name)
      return try textResult(countFile(arguments: object))

    case "file.disk_usage":
      try requireBuiltinEnabled(name)
      return try textResult(diskUsage(arguments: object))

    case "file.volume_info":
      try requireBuiltinEnabled(name)
      return try textResult(fileVolumeInfo(arguments: object))

    case "file.find":
      try requireBuiltinEnabled(name)
      return try textResult(findFiles(arguments: object))

    case "file.search":
      try requireBuiltinEnabled(name)
      return try textResult(searchFiles(arguments: object))

    case "file.timeline":
      try requireBuiltinEnabled(name)
      return try textResult(fileTimeline(arguments: object))

    case "file.read":
      try requireBuiltinEnabled(name)
      return try textResult(readFile(arguments: object))

    case "file.read_files":
      try requireBuiltinEnabled(name)
      return try textResult(readFiles(arguments: object))

    case "file.read_window":
      try requireBuiltinEnabled(name)
      return try textResult(readFileWindow(arguments: object))

    case "file.read_lines":
      try requireBuiltinEnabled(name)
      return try textResult(readFileLines(arguments: object))

    case "file.read_context":
      try requireBuiltinEnabled(name)
      return try textResult(readFileContext(arguments: object))

    case "file.head":
      try requireBuiltinEnabled(name)
      return try textResult(headFile(arguments: object))

    case "file.outline":
      try requireBuiltinEnabled(name)
      return try textResult(outlineFile(arguments: object))

    case "markdown.links":
      try requireBuiltinEnabled(name)
      return try textResult(markdownLinks(arguments: object))

    case "markdown.tables":
      try requireBuiltinEnabled(name)
      return try textResult(markdownTables(arguments: object))

    case "markdown.section":
      try requireBuiltinEnabled(name)
      return try textResult(markdownSection(arguments: object))

    case "markdown.frontmatter":
      try requireBuiltinEnabled(name)
      return try textResult(markdownFrontmatter(arguments: object))

    case "markdown.link_check":
      try requireBuiltinEnabled(name)
      return try textResult(markdownLinkCheck(arguments: object))

    case "file.tail":
      try requireBuiltinEnabled(name)
      return try textResult(tailFile(arguments: object))

    case "file.hexdump":
      try requireBuiltinEnabled(name)
      return try textResult(hexdumpFile(arguments: object))

    case "file.xattrs":
      try requireBuiltinEnabled(name)
      return try textResult(extendedAttributes(arguments: object))

    case "file.remove_xattr":
      try requireBuiltinEnabled(name)
      return try textResult(removeExtendedAttribute(arguments: object))

    case "file.metadata":
      try requireBuiltinEnabled(name)
      return try textResult(fileMetadata(arguments: object))

    case "file.readlink":
      try requireBuiltinEnabled(name)
      return try textResult(readSymbolicLink(arguments: object))

    case "file.resolve":
      try requireBuiltinEnabled(name)
      return try textResult(resolveFilePath(arguments: object))

    case "image.info":
      try requireBuiltinEnabled(name)
      return try textResult(imageInfo(arguments: object))

    case "pdf.info":
      try requireBuiltinEnabled(name)
      return try textResult(pdfInfo(arguments: object))

    case "pdf.text":
      try requireBuiltinEnabled(name)
      return try textResult(pdfText(arguments: object))

    case "media.info":
      try requireBuiltinEnabled(name)
      return try textResult(mediaInfo(arguments: object))

    case "json.read":
      try requireBuiltinEnabled(name)
      return try textResult(readJSON(arguments: object))

    case "jsonl.read":
      try requireBuiltinEnabled(name)
      return try textResult(readJSONLines(arguments: object))

    case "json.write":
      try requireBuiltinEnabled(name)
      return try textResult(writeJSON(arguments: object))

    case "toml.read":
      try requireBuiltinEnabled(name)
      return try textResult(readTOML(arguments: object))

    case "yaml.read":
      try requireBuiltinEnabled(name)
      return try textResult(readYAML(arguments: object))

    case "xml.read":
      try requireBuiltinEnabled(name)
      return try textResult(readXML(arguments: object))

    case "plist.read":
      try requireBuiltinEnabled(name)
      return try textResult(readPropertyList(arguments: object))

    case "structured.get":
      try requireBuiltinEnabled(name)
      return try textResult(getStructuredValue(arguments: object))

    case "plist.write":
      try requireBuiltinEnabled(name)
      return try textResult(writePropertyList(arguments: object))

    case "csv.read":
      try requireBuiltinEnabled(name)
      return try textResult(readCSV(arguments: object))

    case "sqlite.schema":
      try requireBuiltinEnabled(name)
      return try textResult(sqliteSchema(arguments: object))

    case "sqlite.query":
      try requireBuiltinEnabled(name)
      return try textResult(sqliteQuery(arguments: object))

    case "file.hash":
      try requireBuiltinEnabled(name)
      return try textResult(hashFile(arguments: object))

    case "file.diff":
      try requireBuiltinEnabled(name)
      return try textResult(diffFiles(arguments: object))

    case "file.compare_trees":
      try requireBuiltinEnabled(name)
      return try textResult(compareFileTrees(arguments: object))

    case "file.duplicates":
      try requireBuiltinEnabled(name)
      return try textResult(findDuplicateFiles(arguments: object))

    case "archive.list":
      try requireBuiltinEnabled(name)
      return try textResult(listArchive(arguments: object))

    case "archive.read_file":
      try requireBuiltinEnabled(name)
      return try textResult(readArchiveFile(arguments: object))

    case "archive.extract":
      try requireBuiltinEnabled(name)
      return try textResult(extractArchive(arguments: object))

    case "archive.create":
      try requireBuiltinEnabled(name)
      return try textResult(createArchive(arguments: object))

    case "file.download":
      try requireBuiltinEnabled(name)
      return try textResult(downloadFile(arguments: object))

    case "file.write":
      try requireBuiltinEnabled(name)
      return try textResult(writeFile(arguments: object))

    case "file.write_files":
      try requireBuiltinEnabled(name)
      return try textResult(writeFiles(arguments: object))

    case "file.append":
      try requireBuiltinEnabled(name)
      return try textResult(appendFile(arguments: object))

    case "file.replace_text":
      try requireBuiltinEnabled(name)
      return try textResult(replaceTextInFile(arguments: object))

    case "file.insert_text":
      try requireBuiltinEnabled(name)
      return try textResult(insertTextInFile(arguments: object))

    case "file.replace_lines":
      try requireBuiltinEnabled(name)
      return try textResult(replaceLinesInFile(arguments: object))

    case "file.touch":
      try requireBuiltinEnabled(name)
      return try textResult(touchFile(arguments: object))

    case "file.mkdir":
      try requireBuiltinEnabled(name)
      return try textResult(makeDirectory(arguments: object))

    case "file.copy":
      try requireBuiltinEnabled(name)
      return try textResult(copyFile(arguments: object))

    case "file.move":
      try requireBuiltinEnabled(name)
      return try textResult(moveFile(arguments: object))

    case "file.symlink":
      try requireBuiltinEnabled(name)
      return try textResult(createSymbolicLink(arguments: object))

    case "file.trash":
      try requireBuiltinEnabled(name)
      return try textResult(trashFile(arguments: object))

    case "workspace.open":
      try requireBuiltinEnabled(name)
      return try textResult(openWorkspace(arguments: object))

    case "workspace.reveal":
      try requireBuiltinEnabled(name)
      return try textResult(revealWorkspacePath(arguments: object))

    case "git.root":
      try requireBuiltinEnabled(name)
      return try textResult(gitRoot(arguments: object))

    case "git.config":
      try requireBuiltinEnabled(name)
      return try textResult(gitConfig(arguments: object))

    case "git.remotes":
      try requireBuiltinEnabled(name)
      return try textResult(gitRemotes(arguments: object))

    case "git.worktrees":
      try requireBuiltinEnabled(name)
      return try textResult(gitWorktrees(arguments: object))

    case "git.stashes":
      try requireBuiltinEnabled(name)
      return try textResult(gitStashes(arguments: object))

    case "git.stash_show":
      try requireBuiltinEnabled(name)
      return try textResult(gitStashShow(arguments: object))

    case "git.stash_push":
      try requireBuiltinEnabled(name)
      return try textResult(gitStashPush(arguments: object))

    case "git.tags":
      try requireBuiltinEnabled(name)
      return try textResult(gitTags(arguments: object))

    case "git.tag_show":
      try requireBuiltinEnabled(name)
      return try textResult(gitTagShow(arguments: object))

    case "git.tag_create":
      try requireBuiltinEnabled(name)
      return try textResult(gitTagCreate(arguments: object))

    case "git.tag_delete":
      try requireBuiltinEnabled(name)
      return try textResult(gitTagDelete(arguments: object))

    case "git.ignored":
      try requireBuiltinEnabled(name)
      return try textResult(gitIgnored(arguments: object))

    case "git.submodules":
      try requireBuiltinEnabled(name)
      return try textResult(gitSubmodules(arguments: object))

    case "git.files":
      try requireBuiltinEnabled(name)
      return try textResult(gitFiles(arguments: object))

    case "git.grep":
      try requireBuiltinEnabled(name)
      return try textResult(gitGrep(arguments: object))

    case "git.blame":
      try requireBuiltinEnabled(name)
      return try textResult(gitBlame(arguments: object))

    case "git.file_history":
      try requireBuiltinEnabled(name)
      return try textResult(gitFileHistory(arguments: object))

    case "git.file_at_revision":
      try requireBuiltinEnabled(name)
      return try textResult(gitFileAtRevision(arguments: object))

    case "git.staged_file":
      try requireBuiltinEnabled(name)
      return try textResult(gitStagedFile(arguments: object))

    case "git.conflicts":
      try requireBuiltinEnabled(name)
      return try textResult(gitConflicts(arguments: object))

    case "git.status":
      try requireBuiltinEnabled(name)
      return try textResult(gitStatus(arguments: object))

    case "git.tracking_status":
      try requireBuiltinEnabled(name)
      return try textResult(gitTrackingStatus(arguments: object))

    case "git.clean_preview":
      try requireBuiltinEnabled(name)
      return try textResult(gitCleanPreview(arguments: object))

    case "git.clean":
      try requireBuiltinEnabled(name)
      return try textResult(gitClean(arguments: object))

    case "git.reflog":
      try requireBuiltinEnabled(name)
      return try textResult(gitReflog(arguments: object))

    case "git.refs":
      try requireBuiltinEnabled(name)
      return try textResult(gitRefs(arguments: object))

    case "git.resolve_ref":
      try requireBuiltinEnabled(name)
      return try textResult(gitResolveRef(arguments: object))

    case "git.merge_base":
      try requireBuiltinEnabled(name)
      return try textResult(gitMergeBase(arguments: object))

    case "git.compare_refs":
      try requireBuiltinEnabled(name)
      return try textResult(gitCompareRefs(arguments: object))

    case "git.is_ancestor":
      try requireBuiltinEnabled(name)
      return try textResult(gitIsAncestor(arguments: object))

    case "git.diff":
      try requireBuiltinEnabled(name)
      return try textResult(gitDiff(arguments: object))

    case "git.diff_summary":
      try requireBuiltinEnabled(name)
      return try textResult(gitDiffSummary(arguments: object))

    case "git.diff_check":
      try requireBuiltinEnabled(name)
      return try textResult(gitDiffCheck(arguments: object))

    case "git.branch":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranch(arguments: object))

    case "git.branch_create":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranchCreate(arguments: object))

    case "git.branch_delete":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranchDelete(arguments: object))

    case "git.branch_rename":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranchRename(arguments: object))

    case "git.branch_switch":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranchSwitch(arguments: object))

    case "git.log":
      try requireBuiltinEnabled(name)
      return try textResult(gitLog(arguments: object))

    case "git.commit_files":
      try requireBuiltinEnabled(name)
      return try textResult(gitCommitFiles(arguments: object))

    case "git.show":
      try requireBuiltinEnabled(name)
      return try textResult(gitShow(arguments: object))

    case "git.add":
      try requireBuiltinEnabled(name)
      return try textResult(gitAdd(arguments: object))

    case "git.unstage":
      try requireBuiltinEnabled(name)
      return try textResult(gitUnstage(arguments: object))

    case "git.restore_worktree":
      try requireBuiltinEnabled(name)
      return try textResult(gitRestoreWorktree(arguments: object))

    case "git.commit":
      try requireBuiltinEnabled(name)
      return try textResult(gitCommit(arguments: object))

    default:
      if let configuredTool = configuration.tools.first(where: { $0.name == name }) {
        return try callConfiguredTool(configuredTool, arguments: object)
      }
      guard configuration.mcp.servers.contains(where: { $0.exposure.includesReexport }) else {
        throw GatewayToolError.unknownTool(name)
      }
      // Membership and routing come from the validated discovered definition,
      // including explicitly preserved native names, not a prefix guess.
      if let definition = try listTools().first(where: { $0.name == name }),
        definition.mcpReference != nil
      {
        return try callTool(definition: definition, arguments: arguments)
      }
      throw GatewayToolError.unknownTool(name)
    }
  }

  private func toolDefinition(for tool: ToolConfig, downstream: MCPTool) throws -> MCPTool {
    MCPTool(
      name: tool.name,
      description: tool.description
        ?? "Call configured \(tool.adapter.rawValue) tool \(tool.name).",
      inputSchema: try tool.inputSchemaValue(),
      outputSchema: nil,
      meta: downstream.meta,
      mcpReference: tool.tool.map { MCPToolReference(serverID: tool.source, toolName: $0) }
    )
  }

  private func appendTool(_ tool: MCPTool, to tools: inout [MCPTool]) throws {
    if tools.contains(where: { $0.name == tool.name }) {
      throw GatewayToolError.invalidArguments("Configured tool name conflicts: \(tool.name)")
    }
    tools.append(tool)
  }

  private func callConfiguredTool(_ tool: ToolConfig, arguments object: [String: JSONValue])
    throws -> JSONValue
  {
    switch tool.adapter {
    case .mcp:
      return try callConfiguredMCPTool(tool, arguments: object)
    }
  }

  private func callConfiguredMCPTool(_ tool: ToolConfig, arguments object: [String: JSONValue])
    throws -> JSONValue
  {
    guard let downstreamTool = tool.tool else {
      throw GatewayToolError.invalidArguments("MCP-backed tool '\(tool.name)' requires tool.")
    }
    let server = try mcpServer(tool.source)
    try requireDownstreamToolAllowed(downstreamTool, server: server)
    return try mcpClient.callTool(
      server: server,
      name: downstreamTool,
      arguments: .object(object)
    )
  }

  private func requireBuiltinEnabled(_ name: String) throws {
    guard configuration.builtin.enabled.contains(name) else {
      throw GatewayToolError.disabled("\(name) is disabled by configuration.")
    }
  }

  internal func capability(for tool: MCPTool) throws -> CapabilityDescriptor {
    guard let reference = tool.mcpReference else {
      return GatewayCapabilityCatalog().descriptor(for: tool)
    }
    return CapabilityDescriptor(
      id: tool.name,
      risk: try configuration.mcpRisk(for: reference, declaredBy: tool),
      workspaceRequirement: .optional,
      usesNetwork: true,
      mcpReference: reference,
      equivalentCapabilityIDs: configuration.mcpCapabilityIDs(for: reference),
      hostServiceAction: try tool.hostServiceAction
    )
  }

  internal func downstreamPolicy(for reference: MCPToolReference) throws -> MCPToolAdmissionPolicy {
    let server = try mcpServer(reference.serverID)
    try requireDownstreamToolAllowed(reference.toolName, server: server)
    guard
      let tool = try permittedDownstreamTools(server: server).first(where: {
        $0.name == reference.toolName
      })
    else {
      throw GatewayToolError.invalidArguments(
        "[mcp.tool_unavailable] The downstream tool is not available in the current authorized catalog."
      )
    }
    return try .init(
      risk: configuration.mcpRisk(for: reference, declaredBy: tool),
      hostServiceAction: tool.hostServiceAction)
  }

  internal func callTool(definition: MCPTool, arguments: JSONValue?) throws -> JSONValue {
    guard let reference = definition.mcpReference else {
      return try callTool(name: definition.name, arguments: arguments)
    }
    let server = try mcpServer(reference.serverID)
    try requireDownstreamToolAllowed(reference.toolName, server: server)
    return try mcpClient.callTool(
      server: server, name: reference.toolName, arguments: arguments ?? .object([:]))
  }

  internal func callToolAsync(definition: MCPTool, arguments: JSONValue?) async throws -> JSONValue
  {
    try Task.checkCancellation()
    if let reference = definition.mcpReference {
      let server = try mcpServer(reference.serverID)
      try requireDownstreamToolAllowed(reference.toolName, server: server)
      return try await mcpClient.callToolAsync(
        server: server, name: reference.toolName, arguments: arguments ?? .object([:]),
        requestID: nil)
    }
    if definition.name == "mcp.tools.call" {
      let object = arguments?.objectValue ?? [:]
      if try optionalBool("wait_for_result", in: object) ?? true {
        let server = try mcpServer(requiredString("server", in: object))
        let name = try requiredString("tool", in: object)
        try requireDownstreamToolAllowed(name, server: server)
        return try textResult(
          await mcpClient.callToolAsync(
            server: server, name: name, arguments: object["arguments"] ?? .object([:]),
            requestID: optionalString("request_id", in: object)))
      }
    }
    let authorization = MCPInvocationAdmission.current
    let target = MCPContinuationTarget.current
    let session = GatewayControlSession.current
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result {
            try MCPInvocationAdmission.$current.withValue(authorization) {
              try GatewayControlSession.$current.withValue(session) {
                try MCPContinuationTarget.$current.withValue(target) {
                  try self.callTool(definition: definition, arguments: arguments)
                }
              }
            }
          })
      }
    }
  }

  internal func toolMeta() -> JSONValue? {
    if configuration.server.http.accessTokenEnv == nil {
      return .object(["securitySchemes": .array([.object(["type": .string("noauth")])])])
    }

    return nil
  }
}
