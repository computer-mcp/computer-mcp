import Foundation

/// A bounded, non-executing observation of a launch path and its script interpreters.
/// Passing these checks does not establish binary compatibility, trust, permissions or protocol health.
package struct ExecutableInspection: Codable, Equatable, Sendable {
  package enum Status: String, Codable, Sendable {
    case passed, missing, unreadable
    case invalidPath = "invalid_path"
    case notRegularFile = "not_regular_file"
    case notExecutable = "not_executable"
    case invalidShebang = "invalid_shebang"
    case interpreterUnavailable = "interpreter_unavailable"
    case interpreterRequired = "interpreter_required"
    case unverified
  }

  package var executable: String
  package var path: String?
  package var source: String
  package var exists = false
  package var isExecutable = false
  package var isRegularFile = false
  package var isScript = false
  package var status: Status = .missing
  package var interpreters: [ExecutableInspection] = []

  package var hasKnownFailure: Bool {
    switch status {
    case .passed, .unverified, .unreadable: false
    default: true
    }
  }

  package var message: String {
    switch status {
    case .passed: "File and interpreter checks passed; actual startup has not been verified."
    case .missing: "The executable was not found in the configured location or launch search path."
    case .invalidPath: "The executable path is empty, too long or contains NUL."
    case .notRegularFile: "The executable path does not identify a regular file."
    case .notExecutable: "The current user cannot execute this file."
    case .unreadable: "The executable header could not be safely read; check access and retry."
    case .invalidShebang: "The script has an invalid interpreter declaration for macOS."
    case .interpreterUnavailable:
      "A script interpreter is unavailable in the launch environment. Check its path and runtime installation."
    case .interpreterRequired:
      "This file requires an explicitly configured interpreter; it cannot be launched directly."
    case .unverified:
      "This interpreter invocation needs further verification; no script or probe was executed."
    }
  }

  package init(
    executable: String, path: String?, source: String, exists: Bool = false,
    isExecutable: Bool = false, isRegularFile: Bool = false, isScript: Bool = false,
    status: Status = .missing, interpreters: [ExecutableInspection] = []
  ) {
    self.executable = executable
    self.path = path
    self.source = source
    self.exists = exists
    self.isExecutable = isExecutable
    self.isRegularFile = isRegularFile
    self.isScript = isScript
    self.status = status
    self.interpreters = interpreters
  }
}
