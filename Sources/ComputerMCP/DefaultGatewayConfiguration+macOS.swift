import ComputerMCPConfiguration
import ComputerMCPCore
import Foundation

extension DefaultGatewayConfiguration {
  package static let manifest = makeManifest(
    environment: ProcessInfo.processInfo.environment,
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser)

  /// Resolves the Codex CLI from `PATH`, then from the ChatGPT and Codex App bundles and
  /// the usual macOS install locations.
  static func makeManifest(environment: [String: String], homeDirectory: URL) -> String {
    let candidates = [
      URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
      URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
      homeDirectory.appendingPathComponent(".local/bin/codex"),
      homeDirectory.appendingPathComponent("bin/codex"),
      URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
      URL(fileURLWithPath: "/usr/local/bin/codex"),
    ]
    return makeManifest(
      homeDirectory: homeDirectory,
      codexExecutable: resolvedExecutable(
        named: "codex", environment: environment, candidates: candidates))
  }

  package static func configuration(for profileID: GatewayProfileID) throws
    -> GatewayConfiguration
  {
    try configuration(for: profileID, manifest: manifest)
  }
}
