import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPProcess
import ComputerMCPToolKit

package struct ProjectToolProvider: GatewayToolProvider {
  package let id = "project"
  package let namespaces = ["project"]
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

  var projectScope: ProjectScope { environment.projectScope }
  var registeredCommands: RegisteredCommands { environment.registeredCommands }

  package func definitions() throws -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: projectScope.toolMeta).filter {
      configuration.builtin.enabled.contains($0.tool.name)
    }.sorted { $0.tool.name < $1.tool.name }
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let descriptor = try definitions().first { $0.tool.name == invocation.name }?.capability
    let policy: HostExecutionPolicy =
      descriptor == nil || descriptor?.risk == .readOnly
        || descriptor?.projectRequirement == ProjectRequirement.none ? .readOnly : .fullAccess
    return try HostExecutionPolicy.$current.withValue(policy) { try dispatch(invocation) }
  }

  private func dispatch(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
    case "project.info":
      try requireBuiltinEnabled(name)
      return try textResult(projectInfo())

    case "project.status":
      try requireBuiltinEnabled(name)
      return try textResult(projectStatus(arguments: object))

    case "project.manifests":
      try requireBuiltinEnabled(name)
      return try textResult(projectManifests(arguments: object))

    case "project.recent_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectRecentFiles(arguments: object))

    case "project.directory_stats":
      try requireBuiltinEnabled(name)
      return try textResult(projectDirectoryStats(arguments: object))

    case "project.artifact_directories":
      try requireBuiltinEnabled(name)
      return try textResult(projectArtifactDirectories(arguments: object))

    case "project.empty_directories":
      try requireBuiltinEnabled(name)
      return try textResult(projectEmptyDirectories(arguments: object))

    case "project.git_changes":
      try requireBuiltinEnabled(name)
      return try textResult(projectGitChanges(arguments: object))

    case "project.file_types":
      try requireBuiltinEnabled(name)
      return try textResult(projectFileTypes(arguments: object))

    case "project.large_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectLargeFiles(arguments: object))

    case "project.symlinks":
      try requireBuiltinEnabled(name)
      return try textResult(projectSymlinks(arguments: object))

    case "project.executable_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectExecutableFiles(arguments: object))

    case "project.todos":
      try requireBuiltinEnabled(name)
      return try textResult(projectTodos(arguments: object))

    case "project.env_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectEnvFiles(arguments: object))

    case "project.dependency_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectDependencyFiles(arguments: object))

    case "project.project_roots":
      try requireBuiltinEnabled(name)
      return try textResult(projectRoots(arguments: object))

    case "project.documentation_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectDocumentationFiles(arguments: object))

    case "project.agent_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectAgentFiles(arguments: object))

    case "project.instructions":
      try requireBuiltinEnabled(name)
      return try textResult(projectInstructions(arguments: object))

    case "project.test_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectTestFiles(arguments: object))

    case "project.ci_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectCIFiles(arguments: object))

    case "project.infra_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectInfraFiles(arguments: object))

    case "project.config_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectConfigFiles(arguments: object))

    case "project.ignore_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectIgnoreFiles(arguments: object))

    case "project.asset_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectAssetFiles(arguments: object))

    case "project.archive_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectArchiveFiles(arguments: object))

    case "project.log_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectLogFiles(arguments: object))

    case "project.data_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectDataFiles(arguments: object))

    case "project.schema_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectSchemaFiles(arguments: object))

    case "project.source_files":
      try requireBuiltinEnabled(name)
      return try textResult(projectSourceFiles(arguments: object))

    case "project.outline":
      try requireBuiltinEnabled(name)
      return try textResult(projectOutline(arguments: object))

    case "project.commands":
      try requireBuiltinEnabled(name)
      return try textResult(projectCommands(arguments: object))

    case "project.open":
      try requireBuiltinEnabled(name)
      return try textResult(openProject(arguments: object))

    case "project.reveal":
      try requireBuiltinEnabled(name)
      return try textResult(revealProjectPath(arguments: object))

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
