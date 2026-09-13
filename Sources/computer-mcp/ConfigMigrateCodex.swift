import ArgumentParser
import ComputerMCP
import Darwin
import Foundation

struct ConfigMigrateCodex: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "migrate-codex",
    abstract: "Export embedded Codex settings for an independent plugin as JSON.",
    discussion:
      "Offline and read-only: does not contact the App, create files, copy state, start processes or activate settings. The report contains hostTOML, adapterConfiguration and pluginSettings for separate review and import. Preserve configurationDirectory when activating hostTOML. Stop and verify old writers before copying state and enabling the plugin; do not hot-swap the backend controlling this command. See Documentation/Reference/CodexMigration.md."
  )

  @Option(
    name: .long, help: "Explicit source TOML file; never defaults to production configuration.")
  var config: String

  @Option(name: .long, help: "Absolute destination for adapterConfiguration JSON; not written.")
  var adapterConfig: String

  @Option(name: .long, help: "Absolute adapter-owned state directory; not created or migrated.")
  var stateDirectory: String

  @Option(
    name: .long,
    help:
      "Existing plugin MCP registration ID needed by source profile references; repeat as needed.")
  var knownPluginMcpServer: [String] = []

  func run() throws {
    guard !config.contains("\0") else { throw ValidationError("--config must be NUL-free.") }
    let url = URL(fileURLWithPath: config).standardizedFileURL
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ValidationError("Cannot open --config for reading.") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size <= 1_048_576
    else { throw ValidationError("--config must be a regular file of at most 1 MiB.") }
    let data = try file.read(upToCount: 1_048_577) ?? Data()
    guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
      throw ValidationError("--config must be UTF-8 and at most 1 MiB.")
    }
    let migration = try CodexConfigurationMigration(
      text: text, baseURL: url.deletingLastPathComponent(), adapterConfigurationPath: adapterConfig,
      stateDirectory: stateDirectory, knownPluginMCPServerIDs: Set(knownPluginMcpServer))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(migration), as: UTF8.self))
  }
}
