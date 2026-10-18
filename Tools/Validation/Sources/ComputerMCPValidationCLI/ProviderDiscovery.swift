import ArgumentParser
import ComputerMCPValidation
import Foundation

struct ProviderDiscover: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "discover",
    abstract: "Generate a bounded external-provider discovery and doctor report."
  )

  @Option(name: .long, help: "Gateway TOML used for configured provider resolution.")
  var config: String

  @Option(name: .long, help: "Destination for the bounded JSON report.")
  var json: String

  mutating func run() throws {
    let configURL = URL(fileURLWithPath: config).standardizedFileURL
    let data = try ValidationProductCommand().run(
      ["providers", "discover", "--config", configURL.path]
    )
    _ = try ValidationCanonicalJSONCoding.decoder().decode(JSONValue.self, from: data)
    try writeProviderDiscoverJSON(data, destination: json)
  }
}

private func writeProviderDiscoverJSON(
  _ data: Data,
  destination: String
) throws {
  let destinationURL = URL(fileURLWithPath: destination)
  try FileManager.default.createDirectory(
    at: destinationURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: destinationURL, options: .atomic)
}
