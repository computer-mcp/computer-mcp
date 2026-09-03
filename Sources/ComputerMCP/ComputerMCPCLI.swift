import Foundation

/// CLI metadata shared by the executable and library documentation.
package enum ComputerMCPCLI {
  /// Current package CLI version.
  package static let version = "1.0.28"

  /// Current package build number.
  package static let build = "29"

  /// Version string exposed by the command-line executable.
  package static let releaseVersion = "\(version) (\(build))"
}
