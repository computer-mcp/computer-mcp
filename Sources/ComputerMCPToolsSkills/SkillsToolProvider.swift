import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPToolKit
import ComputerMCPToolsStructured

package struct SkillsToolProvider: GatewayToolProvider {
  package static let toolCount = toolDefinitions(toolMeta: nil).count

  package let id = "skills"
  package let namespaces = ["skills"]
  let environment: ToolEnvironment
  let structured: StructuredToolProvider

  package init(environment: ToolEnvironment) {
    self.environment = environment
    self.structured = StructuredToolProvider(environment: environment)
  }

  var configuration: GatewayConfiguration { environment.configuration }

  package func definitions() throws -> [ToolDefinition] {
    guard configuration.skills.enabled else { return [] }
    return Self.toolDefinitions(toolMeta: environment.projectScope.toolMeta)
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
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

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }
}
