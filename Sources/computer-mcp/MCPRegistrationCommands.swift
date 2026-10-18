import ArgumentParser
import ComputerMCP
import Darwin
import Foundation

struct MCPRegistrations: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp", abstract: "Manage App-owned MCP registrations.",
    discussion:
      "List/show include ownership. Add/configure/enable/disable/remove preview by default. Apply requires the current digest from a reviewed preview and may reconnect an already running gateway. Outstanding calls may have an unknown outcome: reconnect and inspect before retrying. Plugin contributions are changed through plugins configure; registrations do not grant profile permissions or install dependencies.",
    subcommands: [
      List.self, Show.self, Doctor.self, Add.self, Configure.self, Enable.self, Disable.self,
      Remove.self, Credential.self, RecoverProcess.self,
    ])

  struct Credential: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "credential", abstract: "Manage a registration's bound Keychain bearer token.",
      discussion:
        "Configure authentication.endpoint and authentication.keychain_account first, then read status to obtain its binding digest. Tokens never appear in output or configuration. New HTTP requests read the current Keychain value; already issued requests are not revoked or replayed. This does not implement OAuth sign-in or install dependencies.",
      subcommands: [Status.self, Set.self, Remove.self])

    struct Status: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Read the credential binding and presence, never its value.")
      @Argument var id: String
      @OptionGroup var connection: AppControlConnectionOptions
      func run() async throws {
        printJSON(
          try await connection.client().call(
            "mcp.credential.status", arguments: .object(["id": .string(id)])))
      }
    }

    struct Change: ParsableArguments {
      @Argument var id: String
      @Option(name: .long, help: "Binding digest returned by credential status.")
      var expectedBindingDigest: String
      @OptionGroup var connection: AppControlConnectionOptions
      func perform(_ action: String, token: String? = nil) async throws {
        var arguments: [String: JSONValue] = [
          "id": .string(id), "expected_binding_digest": .string(expectedBindingDigest),
        ]
        if let token { arguments["token"] = .string(token) }
        printJSON(try await connection.client().call(action, arguments: .object(arguments)))
      }
    }

    struct Set: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Read one bearer token from a pipe and save it in the host Keychain.")
      @OptionGroup var change: Change
      @Flag(
        name: .long,
        help: "Read the token from non-terminal stdin; never put it in command arguments.")
      var stdin = false
      func run() async throws {
        guard stdin, isatty(STDIN_FILENO) == 0 else {
          throw ValidationError(
            "Provide --stdin with a pipe or redirected secret source, not an interactive terminal.")
        }
        let data = try FileHandle.standardInput.read(upToCount: 16_387) ?? Data()
        guard let value = String(data: data, encoding: .utf8), data.count <= 16_386 else {
          throw ValidationError("Token input exceeds 16 KiB or is not UTF-8.")
        }
        let token = value.trimmingCharacters(in: .newlines)
        try MCPHTTPAuthentication.validateToken(token)
        try await change.perform("mcp.credential.set", token: token)
      }
    }

    struct Remove: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete only the bound Keychain item, retaining registrations and grants.")
      @OptionGroup var change: Change
      func run() async throws { try await change.perform("mcp.credential.remove") }
    }
  }

  struct RecoverProcess: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "recover-process",
      abstract: "Retire one safely recoverable process record reported by mcp doctor.",
      discussion:
        "Requires the registration and receipt digests from a reviewed doctor report. The host rechecks the process lock and confirmed host-service cleanup. Running processes, damaged records and unconfirmed authorization cleanup cannot be cleared. Does not stop or start processes, change grants or replay calls."
    )
    @Argument var id: String
    @Option(name: .long) var workspaceID: String
    @Option(name: .long) var receiptID: String
    @Option(name: .long) var expectedReceiptDigest: String
    @Option(name: .long) var expectedCurrentDigest: String
    @OptionGroup var connection: AppControlConnectionOptions
    func run() async throws {
      printJSON(
        try await connection.client().call(
          "mcp.process.recover",
          arguments: .object([
            "id": .string(id), "workspace_id": .string(workspaceID),
            "receipt_id": .string(receiptID),
            "expected_receipt_digest": .string(expectedReceiptDigest),
            "expected_current_digest": .string(expectedCurrentDigest),
          ])))
    }
  }

  struct Mutation: ParsableArguments {
    @OptionGroup var connection: AppControlConnectionOptions
    @Flag(name: .long, help: "Apply this reviewed change through the App-owned control plane.")
    var apply = false
    @Option(name: .long, help: "Current digest returned by preview; required with --apply.")
    var expectedCurrentDigest: String?

    func call(_ name: String, arguments: [String: JSONValue]) async throws {
      if apply && expectedCurrentDigest == nil {
        throw ValidationError("--apply requires --expected-current-digest from a reviewed preview.")
      }
      var input = arguments
      input["apply"] = .bool(apply)
      if let expectedCurrentDigest {
        input["expected_current_digest"] = .string(expectedCurrentDigest)
      }
      printJSON(try await connection.client().call(name, arguments: .object(input)))
    }
  }

  struct Registration: ParsableArguments {
    @Option(
      name: .long,
      help:
        "MCP server JSON object, at most 1 MiB. Use mcp show to inspect existing fields; configure replaces the entire object."
    )
    var registrationFile: String

    func value() throws -> JSONValue {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: registrationFile))
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 1_048_577) ?? Data()
      guard data.count <= 1_048_576 else { throw ValidationError("Registration exceeds 1 MiB.") }
      return try JSONDecoder().decode(JSONValue.self, from: data)
    }
  }

  struct List: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List registrations and the current manifest digest.")
    func run() async throws { printJSON(try await connection.client().call("mcp.list")) }
  }
  struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "doctor", abstract: "Check one MCP's launch, connection and catalog as JSON.",
      discussion:
        "Actively initializes only the selected enabled MCP in the named registered workspace, then closes the probe. It uses a read-only host callback scope without persistence access. It does not call downstream tools, change grants, enable registrations, install dependencies or prove production permissions. Disabled registrations are reported without launching. Exit 1 means connection health was not verified."
    )
    @Argument var id: String
    @Option(name: .long) var workspaceID: String
    @OptionGroup var connection: AppControlConnectionOptions
    func run() async throws {
      let report = try await connection.client().call(
        "mcp.doctor",
        arguments: .object([
          "id": .string(id), "workspace_id": .string(workspaceID),
        ]))
      printJSON(report)
      if report.objectValue?["status"] != .string("passed") { throw ExitCode.failure }
    }
  }
  struct Show: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions
    static let configuration = CommandConfiguration(
      commandName: "show", abstract: "Read one registration, its settings and source.")
    @Argument var id: String
    func run() async throws {
      printJSON(
        try await connection.client().call("mcp.show", arguments: .object(["id": .string(id)])))
    }
  }
  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract: "Preview or add a manual registration; existing IDs are rejected.")
    @OptionGroup var registration: Registration
    @OptionGroup var mutation: Mutation
    func run() async throws {
      try await mutation.call("mcp.add", arguments: ["registration": registration.value()])
    }
  }
  struct Configure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "configure", abstract: "Preview or replace an existing manual registration.")
    @OptionGroup var registration: Registration
    @OptionGroup var mutation: Mutation
    func run() async throws {
      try await mutation.call("mcp.configure", arguments: ["registration": registration.value()])
    }
  }
  struct Enable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "enable", abstract: "Preview or enable a manual registration.")
    @Argument var id: String
    @OptionGroup var mutation: Mutation
    func run() async throws {
      try await mutation.call("mcp.enable", arguments: ["id": .string(id)])
    }
  }
  struct Disable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "disable",
      abstract: "Preview or disable a manual registration, retaining its settings and grants.")
    @Argument var id: String
    @OptionGroup var mutation: Mutation
    func run() async throws {
      try await mutation.call("mcp.disable", arguments: ["id": .string(id)])
    }
  }
  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "remove",
      abstract:
        "Preview or remove an unreferenced manual registration. External executables are retained.")
    @Argument var id: String
    @OptionGroup var mutation: Mutation
    func run() async throws {
      try await mutation.call("mcp.remove", arguments: ["id": .string(id)])
    }
  }
}
