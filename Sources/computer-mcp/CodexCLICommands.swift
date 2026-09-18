import ArgumentParser
import ComputerMCP
import Foundation

struct CodexControl: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codex",
    abstract: "Inspect Computer MCP-owned Codex execution and thread handoff state.",
    subcommands: [
      CodexDiagnoseThread.self,
      CodexDiagnostics.self,
      CodexRecentThread.self,
      CodexReleaseThread.self,
    ]
  )
}

struct CodexReleaseThread: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "release-thread",
    abstract: "Release a thread and verify it is immediately claimable by another Codex client."
  )

  @Argument(help: "Opaque Codex thread ID.")
  var threadID: String

  @Option(name: .long, help: "Registered Computer MCP workspace ID.")
  var workspaceID: String

  @Flag(name: .long, help: "Explicitly interrupt an active turn before release.")
  var interruptActiveTurn = false

  @Flag(
    name: .long,
    help: "Stop only exact matching Computer-MCP-owned runtimes if graceful release cannot finish."
  )
  var forceOwnedRuntime = false

  func run() async throws {
    try await callCodexDiagnosticTool(
      name: "codex.app.thread.release",
      arguments: .object([
        "workspace_id": .string(workspaceID),
        "thread_id": .string(threadID),
        "interrupt_active_turn": .bool(interruptActiveTurn),
        "mode": .string(
          forceOwnedRuntime ? "force-computer-mcp-owned-runtime-only" : "graceful"
        ),
      ])
    )
  }
}

struct CodexRecentThread: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recent-thread",
    abstract: "Read bounded recent state without loading a thread's full history."
  )

  @Argument(help: "Opaque Codex thread ID.")
  var threadID: String

  @Option(name: .long, help: "Registered Computer MCP workspace ID.")
  var workspaceID: String

  @Option(name: .long, help: "Cursor returned by the previous newer page.")
  var beforeCursor: String?

  @Option(name: .long) var maxTurns = 10
  @Option(name: .long) var maxMessages = 50
  @Option(name: .long) var maxItems = 100
  @Option(name: .long) var maxBytes = 262_144
  @Option(name: .long) var maxOutputBytes = 524_288
  @Option(name: .long) var maxElapsedMilliseconds = 2_000

  func run() async throws {
    var arguments: [String: JSONValue] = [
      "workspace_id": .string(workspaceID),
      "thread_id": .string(threadID),
      "max_turns": .number(Double(maxTurns)),
      "max_messages": .number(Double(maxMessages)),
      "max_items": .number(Double(maxItems)),
      "max_bytes": .number(Double(maxBytes)),
      "max_output_bytes": .number(Double(maxOutputBytes)),
      "max_elapsed_milliseconds": .number(Double(maxElapsedMilliseconds)),
    ]
    if let beforeCursor { arguments["before_cursor"] = .string(beforeCursor) }
    try await callCodexDiagnosticTool(
      name: "codex.app.thread.recent",
      arguments: .object(arguments)
    )
  }
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
