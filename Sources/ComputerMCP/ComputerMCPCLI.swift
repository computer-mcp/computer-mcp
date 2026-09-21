import Foundation

/// CLI metadata shared by the executable and library documentation.
package enum ComputerMCPCLI {
  /// Current package CLI version.
  package static let version = "1.2.1"

  /// Current package build number.
  package static let build = "37"

  /// Version string exposed by the command-line executable.
  package static let releaseVersion = "\(version) (\(build))"
}
