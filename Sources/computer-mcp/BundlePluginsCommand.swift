import ArgumentParser
import ComputerMCP
import Foundation

struct BundlePluginsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_bundle-plugins",
    abstract: "Prepare pinned plugin archives in a new unsigned App resource directory.",
    shouldDisplay: false)

  @Option(name: .long) var index: String
  @Option(name: .long) var output: String
  @Option(name: .long, parsing: .upToNextOption) var architectures: [String]

  func run() async throws {
    do {
      guard let worker = Bundle.main.executableURL else { throw PluginArchiveError.invalidInput }
      let artifacts = try await BundledPluginDistribution.prepare(
        index: URL(fileURLWithPath: index), destination: URL(fileURLWithPath: output),
        workerExecutable: worker, hostVersion: PluginVersion(ComputerMCPCLI.version),
        architectures: architectures)
      try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(artifacts))
    } catch {
      let failure = error as? PluginArchiveError ?? .invalidInput
      try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(failure))
      throw ExitCode.failure
    }
  }
}
