import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPToolKit

package struct WorkspaceToolProvider: GatewayToolProvider {
  package let id = "workspace"
  package let namespaces = ["workspace"]
  let environment: ToolEnvironment
  let configuration: GatewayConfiguration

  package init(environment: ToolEnvironment) {
    self.environment = environment
    var configuration = environment.configuration
    let disabledMCPIDs = Set(configuration.mcp.servers.filter { !$0.enabled }.map(\.id))
    configuration.mcp.servers.removeAll { !$0.enabled }
    configuration.tools.removeAll { disabledMCPIDs.contains($0.source) }
    self.configuration = configuration
  }

  var workspaceScope: WorkspaceScope { environment.workspaceScope }
  var registeredCommands: RegisteredCommands { environment.registeredCommands }

  package func definitions() throws -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: workspaceScope.toolMeta).filter {
      configuration.builtin.enabled.contains($0.tool.name)
    }.sorted { $0.tool.name < $1.tool.name }
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
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

    case "workspace.open":
      try requireBuiltinEnabled(name)
      return try textResult(openWorkspace(arguments: object))

    case "workspace.reveal":
      try requireBuiltinEnabled(name)
      return try textResult(revealWorkspacePath(arguments: object))

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }

  private func requireBuiltinEnabled(_ name: String) throws {
    guard configuration.builtin.enabled.contains(name) else {
      throw GatewayToolError.disabled("\(name) is disabled by configuration.")
    }
  }
}
