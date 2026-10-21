import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation

package enum RegistrationClient: String, Codable, CaseIterable, Sendable {
  case codex
  case claudeCode = "claude-code"
  case claudeDesktop = "claude-desktop"

  package var appliesAfter: String {
    switch self {
    case .codex: "Start a new Codex session."
    case .claudeCode: "Start a new Claude Code session."
    case .claudeDesktop: "Reopen Claude Desktop."
    }
  }
}

package enum ClientRegistrationState: String, Codable, Sendable {
  case unavailable
  case notRegistered = "not_registered"
  case registered
  case different
  case unreadable

  var permitsWrite: Bool { self == .notRegistered || self == .registered || self == .different }
}

package enum ClientRegistrationOperation: String, Codable, Sendable {
  case register
  case remove
}

package struct ClientRegistrationCommand: Codable, Equatable, Sendable {
  package let executable: String
  package let arguments: [String]

  package init(executable: String, arguments: [String]) {
    self.executable = executable
    self.arguments = arguments
  }

  package static func app(executable: String, socket: String) -> Self {
    Self(
      executable: absolute(executable),
      arguments: [
        "bridge", "--client-identity", "local-mcp", "--socket", absolute(socket),
      ])
  }

  package static func standalone(executable: String, config: String) -> Self {
    Self(
      executable: absolute(executable), arguments: ["serve", "stdio", "--config", absolute(config)])
  }

  /// Removal compares strings without requiring that the server or manifest still exists.
  package func validateExecutable() throws {
    let inspection = ExecutableInspection.inspect(
      executable, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      environment: ["PATH": URL(fileURLWithPath: executable).deletingLastPathComponent().path])
    guard inspection.exists, !inspection.hasKnownFailure else {
      throw ClientRegistrationError(.invalidServerExecutable)
    }
  }

  static func absolute(_ path: String) -> String {
    URL(
      fileURLWithPath: path,
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
    .standardizedFileURL.path
  }
}

package struct ClientRegistrationLocation: Codable, Equatable, Sendable {
  package let configurationFile: String
  package let configurationVariable: String?
  /// Nil means the variable must be absent, not inherited from a later caller.
  package let configurationValue: String?

  enum CodingKeys: String, CodingKey {
    case configurationFile = "configuration_file"
    case configurationVariable = "configuration_variable"
    case configurationValue = "configuration_value"
  }
}

/// Only this projection of a client-owned entry may cross the presentation boundary.
package struct ClientRegistrationEntrySummary: Codable, Equatable, Sendable {
  package let type: String?
  package let command: String?
  package let urlOrigin: String?
  package let argumentCount: Int
  package let environmentNames: [String]
  package let headerNames: [String]

  enum CodingKeys: String, CodingKey {
    case type, command
    case urlOrigin = "url_origin"
    case argumentCount = "argument_count"
    case environmentNames = "environment_names"
    case headerNames = "header_names"
  }

  init(_ entry: JSONValue, client: RegistrationClient) {
    let object = client == .codex ? entry.objectValue?["transport"]?.objectValue : entry.objectValue
    type = object?["type"]?.stringValue
    command = object?["command"]?.stringValue
    argumentCount = object?["args"]?.arrayValue?.count ?? 0
    environmentNames = object?["env"]?.objectValue?.keys.sorted() ?? []
    headerNames = object?["headers"]?.objectValue?.keys.sorted() ?? []
    if let url = object?["url"]?.stringValue, let components = URLComponents(string: url),
      let scheme = components.scheme, let host = components.host
    {
      var origin = URLComponents()
      origin.scheme = scheme
      origin.host = host
      origin.port = components.port
      urlOrigin = origin.string
    } else {
      urlOrigin = nil
    }
  }
}

package struct ClientRegistrationAction: Codable, Equatable, Sendable {
  package let step: String
  package let command: ClientRegistrationCommand?
  package let file: String?
  package let before: ClientRegistrationEntrySummary?
  package let after: ClientRegistrationCommand?
}

package enum ClientRegistrationErrorCode: String, Codable, Sendable {
  case changedSincePreview = "changed_since_preview"
  case confirmationRequired = "confirmation_required"
  case unsupportedEntry = "unsupported_entry"
  case clientRunning = "client_running"
  case unavailable, unreadable
  case writerBusy = "writer_busy"
  case writeFailed = "write_failed"
  case invalidInput = "invalid_input"
  case invalidServerExecutable = "invalid_server_executable"
  case supportDirectoryMissing = "support_directory_missing"
  case processFailed = "process_failed"
  case uncertain
}

package struct ClientRegistrationError: Error, LocalizedError, Sendable {
  package let code: ClientRegistrationErrorCode
  package init(_ code: ClientRegistrationErrorCode) { self.code = code }
  package var errorDescription: String? { "Client registration failed [\(code.rawValue)]." }
}

package struct ClientRegistrationDisplayPlan: Codable, Equatable, Sendable {
  package let schemaVersion: Int
  package let client: RegistrationClient
  package let operation: ClientRegistrationOperation
  package let serverName: String
  package let location: ClientRegistrationLocation
  package let state: ClientRegistrationState
  package let observedEntry: ClientRegistrationEntrySummary?
  package let server: ClientRegistrationCommand
  package let actions: [ClientRegistrationAction]
  package let requiresConfirmation: Bool
  package let refusalCode: ClientRegistrationErrorCode?
  package let warnings: [String]
  package let appliesAfter: String
  package let fingerprint: String

  enum CodingKeys: String, CodingKey {
    case client, operation, location, state, server, actions, warnings, fingerprint
    case schemaVersion = "schema_version"
    case serverName = "server_name"
    case observedEntry = "observed_entry"
    case requiresConfirmation = "requires_confirmation"
    case refusalCode = "refusal_code"
    case appliesAfter = "applies_after"
  }
}

/// Holds private comparison/recovery data. It is deliberately not Encodable.
/// Its string and mirror representations contain only the displayable projection.
package struct ClientRegistrationPlan: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible,
  CustomReflectable
{
  let contents: RegistrationPlanContents
  package let display: ClientRegistrationDisplayPlan
  package var fingerprint: String { display.fingerprint }
  package var uncertainResult: ClientRegistrationResult? {
    guard let step = contents.observation.uncertainStep else { return nil }
    return .init(
      outcome: .uncertain, errorCode: .uncertain,
      steps: [.init(step: step, outcome: .uncertain, exitCode: nil)],
      finalState: contents.observation.state,
      finalEntry: contents.observation.entry.map { .init($0, client: contents.client) },
      appliesAfter: contents.client.appliesAfter)
  }
  package var description: String {
    "ClientRegistrationPlan(\(display.client.rawValue), \(fingerprint))"
  }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(reflecting: display) }
}

struct RegistrationObservation: Codable, Equatable, Sendable {
  let state: ClientRegistrationState
  let entry: JSONValue?
  /// Claude Desktop's whole-file SHA-256; nil when its configuration file is absent.
  var fileSHA256: String?
  /// The process whose exit was unconfirmed; no subsequent step may run.
  var uncertainStep: String?
}

struct RegistrationPlanContents: Codable, Sendable {
  let client: RegistrationClient
  let operation: ClientRegistrationOperation
  let serverName: String
  let location: ClientRegistrationLocation
  let server: ClientRegistrationCommand
  let clientExecutable: String?
  let environment: [String: String]
  let observation: RegistrationObservation
  let actions: [ClientRegistrationAction]
  let refusalCode: ClientRegistrationErrorCode?
  let warnings: [String]
}

package struct ClientRegistrationStep: Codable, Equatable, Sendable {
  package enum Outcome: String, Codable, Sendable {
    case succeeded, failed
    case timedOut = "timed_out"
    case launchFailed = "launch_failed"
    case uncertain
  }
  package let step: String
  package let outcome: Outcome
  package let exitCode: Int32?
  enum CodingKeys: String, CodingKey {
    case step, outcome
    case exitCode = "exit_code"
  }
}

package enum ClientRegistrationRecovery: String, Codable, Sendable {
  case restored
  case notRestored = "not_restored"
}

package struct ClientRegistrationResult: Codable, Sendable {
  package enum Outcome: String, Codable, Sendable { case succeeded, failed, uncertain }
  package let outcome: Outcome
  package let errorCode: ClientRegistrationErrorCode?
  package let steps: [ClientRegistrationStep]
  package let finalState: ClientRegistrationState
  package let finalEntry: ClientRegistrationEntrySummary?
  package let appliesAfter: String
  /// Compares the reconciled entry with the private original after Claude Code recovery.
  package let recovery: ClientRegistrationRecovery?

  package init(
    outcome: Outcome, errorCode: ClientRegistrationErrorCode?, steps: [ClientRegistrationStep],
    finalState: ClientRegistrationState, finalEntry: ClientRegistrationEntrySummary?,
    appliesAfter: String, recovery: ClientRegistrationRecovery? = nil
  ) {
    self.outcome = outcome
    self.errorCode = errorCode
    self.steps = steps
    self.finalState = finalState
    self.finalEntry = finalEntry
    self.appliesAfter = appliesAfter
    self.recovery = recovery
  }

  enum CodingKeys: String, CodingKey {
    case outcome, steps, recovery
    case errorCode = "error_code"
    case finalState = "final_state"
    case finalEntry = "final_entry"
    case appliesAfter = "applies_after"
  }
}
