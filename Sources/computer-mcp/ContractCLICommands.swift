import ArgumentParser
import ComputerMCP
import Foundation

enum BridgeClientIdentity: String, ExpressibleByArgument {
  case localMCP = "local-mcp"
  case localCLI = "local-cli"

  var gatewayIdentity: GatewaySocketClientIdentity {
    switch self {
    case .localMCP:
      return .localMCP
    case .localCLI:
      return .localCLI
    }
  }
}

struct ConfigDefaults: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "defaults",
    abstract: "Print the secret-free default schema-1 TOML manifest."
  )

  func run() throws {
    print(DefaultGatewayConfiguration.manifest, terminator: "")
    if !DefaultGatewayConfiguration.manifest.hasSuffix("\n") {
      print()
    }
  }
}

struct ToolsInventory: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inventory",
    abstract: "Emit the versioned tool and capability inventory for a standalone manifest."
  )

  @Option(name: .long, help: "Path to a schema-1 TOML manifest.")
  var config: String

  @Option(name: .long, help: "Bound caller identity for policy evaluation.")
  var caller: GatewayCallerKind?

  @Option(name: .long, help: "Bound gateway profile for policy evaluation.")
  var profile: GatewayProfileID?

  @Option(name: .long, help: "Optional default stable workspace id.")
  var workspaceID: String?

  func run() throws {
    let configurationURL = URL(fileURLWithPath: config).standardizedFileURL
    var gateway = try GatewayConfiguration.load(path: configurationURL.path)
    let excludedDynamicReexports = gateway.mcp.servers.filter {
      $0.exposure.includesReexport
    }.map(\.id).sorted()
    gateway.mcp.servers.removeAll { $0.exposure.includesReexport }
    let context = gateway.executionContext(
      caller: caller,
      profileID: profile,
      workspaceID: workspaceID,
      transportTrace: GatewayTransportTrace(transport: "cli-inventory")
    )
    let runtime = try GatewayRuntime(
      configuration: gateway,
      context: context,
      database: GatewayDatabase(inMemory: ())
    )
    let tools = try runtime.listTools().sorted { $0.name < $1.name }

    printJSON(
      .object([
        "schema_version": .number(1),
        "configuration": .string(configurationURL.lastPathComponent),
        "server": .string(gateway.server.name),
        "caller": .string(context.caller.rawValue),
        "profile": .string(context.profileID.rawValue),
        "excluded_dynamic_reexports": .array(
          excludedDynamicReexports.map(JSONValue.string)
        ),
        "tools": .array(
          try tools.map { tool in
            let descriptor = try runtime.capabilityDescriptor(named: tool.name)
            var object: [String: JSONValue] = [
              "name": .string(tool.name),
              "title": .string(tool.title),
              "description": .string(tool.description),
              "input_schema": tool.inputSchema,
              "capability": .object([
                "id": .string(descriptor.id),
                "risk": .string(descriptor.risk.rawValue),
                "workspace_requirement": .string(descriptor.workspaceRequirement.rawValue),
                "local_only": .bool(descriptor.localOnly),
                "uses_network": .bool(descriptor.usesNetwork),
                "tcc_services": .array(descriptor.tccServices.sorted().map(JSONValue.string)),
              ]),
            ]
            if let outputSchema = tool.outputSchema {
              object["output_schema"] = outputSchema
            }
            if let annotations = tool.annotations {
              object["annotations"] = annotations.json
            }
            if let meta = tool.meta {
              object["meta"] = meta
            }
            return .object(object)
          }
        ),
      ])
    )
  }
}

struct Audit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "audit",
    abstract: "Inspect bounded, argument-free audit evidence.",
    subcommands: [AuditExport.self]
  )
}

struct AuditExport: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "export",
    abstract: "Export versioned, secret-free audit evidence as JSON."
  )

  @Option(name: .long, help: "Path to the Gateway GRDB database.")
  var database: String

  @Option(name: .long, help: "Optional exact Gateway request id filter.")
  var requestID: String?

  @Option(name: .long, help: "Maximum events when no request id is supplied (1...1000).")
  var limit = 200

  func validate() throws {
    guard (1...1_000).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 1000.")
    }
  }

  func run() throws {
    let databaseURL = URL(fileURLWithPath: database).standardizedFileURL
    let gatewayDatabase = try GatewayDatabase(path: databaseURL.path)
    let events: [AuditEvent]
    if let requestID {
      events = try gatewayDatabase.auditEvents(requestID: requestID)
    } else {
      events = try gatewayDatabase.auditEvents(limit: limit)
    }
    printJSON(
      .object([
        "schema_version": .number(1),
        "events": .array(try events.map(contractJSON)),
      ])
    )
  }
}

struct Providers: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "providers",
    abstract: "Inspect external provider availability.",
    subcommands: [ProvidersDiscover.self]
  )
}

struct ProvidersDiscover: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "discover",
    abstract: "Emit bounded, versioned external-provider diagnostics as JSON."
  )

  @Option(name: .long, help: "Path to a schema-1 TOML manifest.")
  var config: String

  func run() throws {
    printJSON(try ComputerMCPProductContracts.providers(configPath: config))
  }
}

private func contractJSON<T: Encodable>(_ value: T) throws -> JSONValue {
  try ComputerMCPProductContracts.encode(value)
}
