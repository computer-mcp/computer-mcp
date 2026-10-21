import AppKit
import ComputerMCPControlPlane
import ComputerMCPGateway
import ComputerMCPPlatform
import Foundation

extension MacOSPlatform {
  /// All App distributions and the CLI share the production per-user writer lock.
  package static func clientRegistrationService(
    stateDirectory: URL? = nil,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ClientRegistrationService {
    let applications = services.applications
    let bundleIdentifier = "com.anthropic.claudefordesktop"
    return ClientRegistrationService(
      homeDirectory: homeDirectory,
      stateDirectory: stateDirectory
        ?? homeDirectory.appendingPathComponent(
          "Library/Application Support/\(AppDistributionEnvironment.production.applicationSupportDirectoryName)"
        ),
      executableSearchDirectories: services.executableSearchDirectories,
      environment: environment,
      desktop: ClaudeDesktopRegistration(
        configurationFile: homeDirectory.appendingPathComponent(
          "Library/Application Support/Claude/claude_desktop_config.json"),
        isInstalled: {
          if case .found = applications.locate(bundleIdentifier: bundleIdentifier) { return true }
          return false
        },
        isRunning: {
          !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        }
      )
    )
  }
}
