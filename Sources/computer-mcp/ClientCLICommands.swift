import ArgumentParser
import ComputerMCP
import Foundation

struct Clients: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clients",
    abstract: "Inspect and authorize connected clients through the local owner control socket.",
    discussion:
      "Use list to review a connection. Full Access requires allow --full-access and defaults to This Session. Access changes apply to new requests; already started work retains its owner. Commands return JSON.",
    subcommands: [List.self, Allow.self, Limit.self, End.self, Trusts.self, Revoke.self])

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List client connections and their approval revisions.")
    @OptionGroup var page: ClientListOptions
    func run() async throws { try await page.run("clients.list") }
  }

  struct Trusts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "trusts", abstract: "List saved client approvals, including revoked records.")
    @OptionGroup var page: ClientListOptions
    func run() async throws { try await page.run("clients.trusts") }
  }

  struct Allow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "allow", abstract: "Explicitly approve Full Access for one connection.",
      discussion:
        "Full Access permits commands and access to files, processes, network and credentials available to your macOS user. A workspace is not a sandbox; macOS privacy permissions still apply. Standalone HTTP requires shell_enabled in its fixed configuration. The App safely enables the Shell facility when needed. Revisions are captured once when omitted; a stale request fails without retry."
    )
    @OptionGroup var selection: ClientSelectionOptions
    @Flag(name: .long, help: "Explicit consent to arbitrary execution as your macOS user.")
    var fullAccess = false
    @Flag(
      name: .long,
      help: "Save approval for this authenticated client; otherwise allow only this session.")
    var alwaysAllowClient = false
    @Option(
      name: .long,
      help: "Exact saved-trust revision reviewed by the caller; read once when omitted.")
    var expectedTrustRevision: Int64?

    func validate() throws {
      guard fullAccess else { throw ValidationError("Full Access requires --full-access.") }
      if let expectedTrustRevision, expectedTrustRevision < 0 {
        throw ValidationError("--expected-trust-revision must be non-negative.")
      }
    }

    func run() async throws {
      try await Clients.report {
        let client = try selection.connection.client()
        let current =
          selection.expectedRevision == nil || expectedTrustRevision == nil
          ? try await selection.read(client, trusts: false) : nil
        let revision = try selection.revision(from: current)
        guard
          let trustRevision = expectedTrustRevision
            ?? current?["trust_revision"]?.intValue.map(Int64.init)
        else {
          throw ControlSocketCallError(
            code: "control.invalid_response",
            message: "The selected client has no current trust revision. Run clients list again.")
        }
        return try await client.call(
          "clients.allow",
          arguments: .object([
            "id": .string(selection.id), "full_access": .bool(fullAccess),
            "always_allow_client": .bool(alwaysAllowClient),
            "expected_revision": .integer(revision),
            "expected_trust_revision": .integer(trustRevision),
          ]))
      }
    }
  }

  struct Limit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "limit", abstract: "Limit one connection to Observe or Restricted Access.")
    @OptionGroup var selection: ClientSelectionOptions
    @Option(name: .long, help: "Access ceiling: observe or restricted.") var mode: ClientAccessLimit
    func run() async throws {
      try await selection.mutate("clients.limit", extra: ["mode": .string(mode.rawValue)])
    }
  }

  struct End: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "end", abstract: "End this connection's access without cancelling started work.")
    @OptionGroup var selection: ClientSelectionOptions
    func run() async throws { try await selection.mutate("clients.end") }
  }

  static func report(_ operation: () async throws -> JSONValue) async throws {
    do {
      printJSON(try await operation())
    } catch {
      let failure = error as? ControlSocketCallError
      printJSON(
        .object([
          "error": .object([
            "code": .string(failure?.code ?? "control.unavailable"),
            "message": .string(
              failure?.message
                ?? "The owner control socket is unavailable. Inspect client access before retrying a change whose outcome is unknown."
            ),
          ])
        ]))
      throw ExitCode.failure
    }
  }

  struct Revoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "revoke", abstract: "Revoke one saved client approval by its trust ID.")
    @OptionGroup var selection: ClientSelectionOptions
    func run() async throws { try await selection.mutate("clients.revoke", trusts: true) }
  }
}

enum ClientAccessLimit: String, ExpressibleByArgument {
  case observe, restricted
}

struct ClientListOptions: ParsableArguments {
  @OptionGroup var connection: AppControlConnectionOptions
  @Option(name: .long, help: "Return only this exact connection or trust ID.") var id: String?
  @Option(name: .long, help: "Continue after the previous next_after_id cursor.") var afterID:
    String?
  @Option(name: .long, help: "Maximum records, from 1 to 200.") var limit = 100
  func validate() throws {
    guard (1...200).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 200.")
    }
  }
  func run(_ name: String) async throws {
    var arguments: [String: JSONValue] = ["limit": .integer(Int64(limit))]
    if let id { arguments["id"] = .string(id) }
    if let afterID { arguments["after_id"] = .string(afterID) }
    try await Clients.report {
      try await connection.client().call(name, arguments: .object(arguments))
    }
  }
}

struct ClientSelectionOptions: ParsableArguments {
  @OptionGroup var connection: AppControlConnectionOptions
  @Argument(help: "Exact connection ID from clients list, or trust ID from clients trusts.") var id:
    String
  @Option(
    name: .long,
    help: "Exact reviewed revision; read once when omitted. A stale write fails without retry.")
  var expectedRevision: Int64?

  func validate() throws {
    guard !id.isEmpty else { throw ValidationError("The client or trust ID cannot be empty.") }
    if let expectedRevision, expectedRevision < 0 {
      throw ValidationError("--expected-revision must be non-negative.")
    }
  }

  func read(_ client: AppControlPlaneServiceClient, trusts: Bool) async throws -> [String:
    JSONValue]
  {
    let key = trusts ? "trusts" : "sessions"
    let result = try await client.call(
      trusts ? "clients.trusts" : "clients.list",
      arguments: .object([
        "id": .string(id), "limit": .integer(1),
      ]))
    guard let row = result.objectValue?[key]?.arrayValue?.first?.objectValue,
      row["id"]?.stringValue == id
    else {
      throw ControlSocketCallError(
        code: "control.record_unavailable",
        message:
          "The selected \(trusts ? "saved approval" : "connection") is no longer available. Refresh clients \(trusts ? "trusts" : "list")."
      )
    }
    return row
  }

  func revision(from current: [String: JSONValue]?) throws -> Int64 {
    guard let revision = expectedRevision ?? current?["revision"]?.intValue.map(Int64.init) else {
      throw ControlSocketCallError(
        code: "control.invalid_response",
        message: "The selected record has no current revision. Refresh the client list.")
    }
    return revision
  }

  func mutate(_ name: String, trusts: Bool = false, extra: [String: JSONValue] = [:]) async throws {
    try await Clients.report {
      let client = try connection.client()
      let current = expectedRevision == nil ? try await read(client, trusts: trusts) : nil
      var arguments = extra
      arguments["id"] = .string(id)
      arguments["expected_revision"] = .integer(try revision(from: current))
      return try await client.call(name, arguments: .object(arguments))
    }
  }
}
