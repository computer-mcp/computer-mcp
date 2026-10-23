import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPToolKit
import Foundation

package struct FilesToolProvider: GatewayToolProvider {
  package let id = "file"
  package let namespaces = ["file", "archive"]
  let environment: ToolEnvironment
  let fileMutationObserver:
    (@Sendable (String, URL, ProjectFileAccess.MutationPhase) throws -> Void)?

  package init(
    environment: ToolEnvironment,
    fileMutationObserver: (
      @Sendable (String, URL, ProjectFileAccess.MutationPhase) throws -> Void
    )? = nil
  ) {
    self.environment = environment
    self.fileMutationObserver = fileMutationObserver
  }

  var configuration: GatewayConfiguration { environment.configuration }
  var projectScope: ProjectScope { environment.projectScope }
  var registeredCommands: RegisteredCommands { environment.registeredCommands }
  var commandRunner: any CommandRunning { environment.commandRunner }

  package func definitions() throws -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: projectScope.toolMeta).filter {
      configuration.builtin.enabled.contains($0.tool.name)
    }.sorted { $0.tool.name < $1.tool.name }
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
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
