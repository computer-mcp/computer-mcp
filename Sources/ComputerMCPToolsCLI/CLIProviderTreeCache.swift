import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPProcess
import ComputerMCPToolKit
import Foundation

/// One cache per provider assembly. Authority and executable identity are checked
/// before a cached success or failure can be reused.
final class CLIProviderTreeCache: @unchecked Sendable {
  private struct Key: Equatable {
    let declaration: String
    let executable: CLIExecutableIdentity
    let exporter: CLIExecutableIdentity
  }
  private struct Entry {
    let key: Key
    let result: Result<CLITree, any Error>
  }
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var errors: [String: String] = [:]

  var diagnostics: [String: String] { lock.withLock { errors } }

  func failed(_ id: String, error: any Error) {
    lock.withLock {
      entries[id] = nil
      errors[id] = error.localizedDescription
    }
  }

  func load(
    command: CLICommandConfig, project: URL, discovery: CLIProviderDiscovery,
    execution: CLIProcessExecution
  ) throws -> CLITree {
    try lock.withLock {
      let cwd = command.resolvedWorkingDirectory(base: project) ?? project
      func identity(_ executable: String) throws -> CLIExecutableIdentity {
        try CLIExecutableIdentity.capture(
          executable: executable, cwd: cwd,
          environment: command.env, interpreterBindings: command.interpreterBindings)
      }
      let source: CLITreeSource
      let executable: CLIExecutableIdentity
      let exporter: CLIExecutableIdentity
      let key: Key
      do {
        guard let tree = command.tree else { throw CLITreeError.invalid("Missing tree source.") }
        source = tree
        executable = try identity(command.executable)
        exporter = try identity(source.kind == .helper ? source.helper! : command.executable)
        key = Key(declaration: discovery.identity, executable: executable, exporter: exporter)
      } catch {
        entries[command.id] = nil
        errors[command.id] = error.localizedDescription
        throw error
      }
      if let entry = entries[command.id], entry.key == key {
        let tree = try entry.result.get()
        errors[command.id] = nil
        return tree
      }
      let result = Result<CLITree, any Error> {
        let prepared = try discovery.prepare()
        do {
          var source = source
          guard prepared.provider?.delegatingAuthorization == nil,
            case .sandbox = prepared.mode, let directory = prepared.providerWorkingDirectory
          else { throw CLITreeError.invalid("Exporter discovery requires a projectless sandbox.") }
          var resolved = command
          resolved.executable = exporter.executable
          if source.kind == .helper { source.helper = exporter.executable }
          source.args = exporter.arguments + source.args
          let tree = try InvocationExecution.$current.withValue(prepared) {
            try source.load(
              command: resolved, project: project, execution: execution,
              executionDirectory: URL(fileURLWithPath: directory.value))
          }
          try prepared.validateProviderLaunch()
          guard try identity(command.executable) == executable,
            try identity(command.tree!.kind == .helper ? command.tree!.helper! : command.executable)
              == exporter
          else { throw CLITreeError.invalid("The exporter changed during discovery.") }
          try prepared.finishAdmission()
          return tree
        } catch {
          // A failed closure remains owned by the coordinator until cleanup confirms.
          try prepared.finishAdmission()
          throw error
        }
      }
      entries[command.id] = Entry(key: key, result: result)
      switch result {
      case .success: errors[command.id] = nil
      case .failure(let error): errors[command.id] = error.localizedDescription
      }
      return try result.get()
    }
  }
}
