import ArgumentParser
import ComputerMCP
import Foundation

struct CodexControl: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codex",
    abstract: "Inspect Computer MCP-owned Codex execution and thread handoff state.",
    subcommands: [CodexDiagnoseThread.self, CodexDiagnostics.self]
  )
}

struct CodexDiagnoseThread: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diagnose-thread",
    abstract: "Check thread ownership and show safe handoff actions."
  )

  @Argument(help: "Opaque Codex thread ID.")
  var threadID: String

  @Option(name: .long, help: "Registered Computer MCP workspace ID.")
  var workspaceID: String

  @Option(
    name: .long,
    help: "Optional error reported by Codex Desktop or another official client."
  )
  var observedError: String?

  func run() async throws {
    var toolArguments: [String: JSONValue] = [
      "thread_id": .string(threadID),
      "workspace_id": .string(workspaceID),
    ]
    if let observedError {
      toolArguments["observed_error"] = .string(observedError)
    }
    try await callCodexDiagnosticTool(
      name: "codex.app.handoff.diagnose",
      arguments: .object(toolArguments)
    )
  }
}

struct CodexDiagnostics: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diagnostics",
    abstract: "Show a redacted operational snapshot for one registered workspace."
  )

  @Option(name: .long, help: "Registered Computer MCP workspace ID.")
  var workspaceID: String

  @Option(name: .long, help: "Maximum recent records per diagnostic category.")
  var limit = 100

  func validate() throws {
    guard (1...1_000).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 1000.")
    }
  }

  func run() async throws {
    try await callCodexDiagnosticTool(
      name: "codex.diagnostics.snapshot",
      arguments: .object([
        "workspace_id": .string(workspaceID),
        "limit": .number(Double(limit)),
      ])
    )
  }
}

private func callCodexDiagnosticTool(name: String, arguments: JSONValue) async throws {
  let result = try await AppControlPlaneServiceClient.live().call(
    "tools.call",
    arguments: .object([
      "name": .string(name),
      "arguments": arguments,
    ])
  )
  printJSON(result)
  if result.objectValue?["isError"]?.boolValue == true {
    throw ExitCode.failure
  }
}
