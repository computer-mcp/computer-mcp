import ArgumentParser
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPMacOS
import ComputerMCPPlatform
import ComputerMCPPlugins
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
        architectures: architectures, directoryFactory: MacOSPlatform.services.pluginDirectories)
      try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(artifacts))
    } catch let refusal as PluginCompatibilityRefusal {
      printJSON(.object(["error": try ControlToolResponse.errorPayload(refusal)]))
      throw ExitCode.failure
    } catch let invalid as PluginManifestError {
      printJSON(.object(["error": try ControlToolResponse.errorPayload(invalid)]))
      throw ExitCode.failure
    } catch {
      let failure = error as? PluginArchiveError ?? .invalidInput
      try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(failure))
      throw ExitCode.failure
    }
  }
}
