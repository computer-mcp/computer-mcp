import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPToolKit

package struct StructuredToolProvider: GatewayToolProvider {
  package let id = "structured"
  package let namespaces = [
    "json", "jsonl", "toml", "yaml", "xml", "plist", "csv", "sqlite", "structured", "markdown",
    "image", "pdf", "media",
  ]
  let environment: ToolEnvironment

  package init(environment: ToolEnvironment) {
    self.environment = environment
  }

  var configuration: GatewayConfiguration { environment.configuration }
  var projectScope: ProjectScope { environment.projectScope }

  package func definitions() throws -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: projectScope.toolMeta).filter {
      configuration.builtin.enabled.contains($0.tool.name)
    }.sorted { $0.tool.name < $1.tool.name }
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
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
