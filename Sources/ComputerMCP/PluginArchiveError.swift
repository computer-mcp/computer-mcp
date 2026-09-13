import Foundation

package enum PluginArchiveError: String, Error, Codable, Equatable, LocalizedError {
  case invalidInput = "invalid_input"
  case invalidArchive = "invalid_archive"
  case unsafePath = "unsafe_path"
  case conflictingPath = "conflicting_path"
  case unsupportedEntry = "unsupported_entry"
  case limitExceeded = "limit_exceeded"
  case fileSystemFailure = "file_system_failure"
  case checksumMismatch = "checksum_mismatch"
  case workerFailed = "worker_failed"
  case timedOut = "timed_out"
  case invalidPackage = "invalid_package"
  case identityMismatch = "identity_mismatch"
  case incompatiblePackage = "incompatible_package"
  case resourceLimitUnavailable = "resource_limit_unavailable"

  package var errorDescription: String? {
    switch self {
    case .invalidInput: "Plugin archive input or staging directory is invalid."
    case .invalidArchive: "Plugin archive is corrupt or has an unsupported format."
    case .unsafePath: "Plugin archive contains an unsafe file path."
    case .conflictingPath: "Plugin archive contains conflicting file paths."
    case .unsupportedEntry:
      "Plugin archives may contain only unencrypted regular files and directories."
    case .limitExceeded: "Plugin archive exceeds a resource limit."
    case .fileSystemFailure: "Cannot safely read or write the plugin staging files."
    case .checksumMismatch: "Plugin archive does not match the expected SHA-256 digest."
    case .workerFailed: "Plugin archive worker failed or returned an invalid result."
    case .timedOut: "Plugin archive preparation timed out."
    case .invalidPackage: "Plugin archive does not contain a valid package."
    case .identityMismatch:
      "Plugin package identity or version does not match the selected artifact."
    case .incompatiblePackage: "Plugin package is incompatible with this host."
    case .resourceLimitUnavailable: "Cannot establish plugin archive worker resource limits."
    }
  }
}
