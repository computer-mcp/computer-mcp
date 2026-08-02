import Foundation

internal protocol GatewayToolProvider: Sendable {
  var id: String { get }
  func listTools() throws -> [MCPTool]
  func capability(for tool: MCPTool) -> CapabilityDescriptor
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue
  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
}

extension GatewayToolProvider {
  internal func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try callTool(name: name, arguments: arguments)
  }
}

internal struct GatewayCapabilityCatalog: Sendable {
  internal func descriptor(for tool: MCPTool) -> CapabilityDescriptor {
    let name = tool.name
    let risk: CapabilityRisk
    if name.hasPrefix("shell.") || name == "cli.exec" || name == "process.spawn" {
      risk = .fullShell
    } else if name == "operations.commit" {
      risk = .externalWrite
    } else if name.hasPrefix("mcp.") && name != "mcp.tools.call"
      && name != "mcp.requests.cancel"
    {
      risk = .readOnly
    } else if tool.annotations?.destructiveHint == true {
      risk = .destructive
    } else if tool.annotations?.readOnlyHint == true {
      risk = .readOnly
    } else if name.hasPrefix("file.") || name.hasPrefix("git.")
      || name.hasPrefix("workspace.")
    {
      risk = .workspaceWrite
    } else {
      risk = .externalWrite
    }

    let workspaceRequirement: WorkspaceRequirement
    if name == "workspace.list" || name == "workspace.describe"
      || name.hasPrefix("skills.") || name.hasPrefix("system.")
      || name.hasPrefix("macos.") || name.hasPrefix("network.")
      || name.hasPrefix("mcp.") || name == "cli.list" || name == "cli.status"
      || name == "cli.describe" || name == "cli.help"
    {
      workspaceRequirement = .none
    } else if name.hasPrefix("operations.") {
      workspaceRequirement = .optional
    } else if name.hasPrefix("shell.") {
      workspaceRequirement = .required
    } else if name.hasPrefix("file.") || name.hasPrefix("git.")
      || name.hasPrefix("workspace.") || name.hasPrefix("cli.")
      || name.hasPrefix("process.") || name.hasPrefix("codex.")
    {
      workspaceRequirement = .required
    } else {
      workspaceRequirement = .optional
    }

    return CapabilityDescriptor(
      id: name,
      risk: risk,
      workspaceRequirement: workspaceRequirement,
      localOnly: false,
      usesNetwork: name.hasPrefix("network.") || name.hasPrefix("mcp.")
    )
  }
}

internal struct GatewayDomainToolProvider: GatewayToolProvider, Sendable {
  internal let id: String
  private let registry: GatewayToolRegistry
  private let domain: GatewayToolDomain
  private let catalog: GatewayCapabilityCatalog
  private let tools: [MCPTool]

  internal init(
    id: String,
    registry: GatewayToolRegistry,
    domain: GatewayToolDomain,
    tools: [MCPTool],
    catalog: GatewayCapabilityCatalog = GatewayCapabilityCatalog()
  ) {
    self.id = id
    self.registry = registry
    self.domain = domain
    self.tools = tools
    self.catalog = catalog
  }

  internal func listTools() throws -> [MCPTool] {
    tools
  }

  internal func capability(for tool: MCPTool) -> CapabilityDescriptor {
    catalog.descriptor(for: tool)
  }

  internal func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    guard GatewayToolDomain.classify(name) == domain else {
      throw GatewayToolError.unknownTool(name)
    }
    return try registry.callTool(name: name, arguments: arguments)
  }
}

internal enum GatewayToolDomain: String, CaseIterable, Sendable {
  case cli
  case process
  case shell
  case mcp
  case skills
  case workspace
  case file
  case structured
  case git
  case system
  case network
  case macos
  case configured

  fileprivate static func classify(_ name: String) -> GatewayToolDomain {
    if name.hasPrefix("cli.") { return .cli }
    if name.hasPrefix("process.") { return .process }
    if name.hasPrefix("shell.") { return .shell }
    if name.hasPrefix("mcp.") { return .mcp }
    if name.hasPrefix("skills.") { return .skills }
    if name.hasPrefix("workspace.") { return .workspace }
    if name.hasPrefix("file.") || name.hasPrefix("archive.") { return .file }
    if name.hasPrefix("json.") || name.hasPrefix("jsonl.") || name.hasPrefix("toml.")
      || name.hasPrefix("yaml.") || name.hasPrefix("xml.") || name.hasPrefix("plist.")
      || name.hasPrefix("csv.") || name.hasPrefix("sqlite.")
      || name.hasPrefix("structured.") || name.hasPrefix("markdown.")
      || name.hasPrefix("image.") || name.hasPrefix("pdf.") || name.hasPrefix("media.")
    {
      return .structured
    }
    if name.hasPrefix("git.") { return .git }
    if name.hasPrefix("system.") || name.hasPrefix("logs.") || name.hasPrefix("service.")
      || name.hasPrefix("env.")
    {
      return .system
    }
    if name.hasPrefix("network.") { return .network }
    if name.hasPrefix("macos.") { return .macos }
    return .configured
  }
}

internal final class GatewayProviderRouter: GatewayToolServing, @unchecked Sendable {
  private let providers: [any GatewayToolProvider]

  internal init(providers: [any GatewayToolProvider]) throws {
    var names = Set<String>()
    for provider in providers {
      for tool in try provider.listTools() {
        guard names.insert(tool.name).inserted else {
          throw GatewayProviderRouterError.duplicateTool(tool.name)
        }
      }
    }
    self.providers = providers
  }

  internal convenience init(registry: GatewayToolRegistry) throws {
    try self.init(registry: registry, additionalProviders: [])
  }

  internal convenience init(
    registry: GatewayToolRegistry,
    additionalProviders: [any GatewayToolProvider]
  ) throws {
    let tools = try registry.listTools()
    try self.init(
      providers: GatewayToolDomain.allCases.map { domain in
        GatewayDomainToolProvider(
          id: domain.rawValue,
          registry: registry,
          domain: domain,
          tools: tools.filter { GatewayToolDomain.classify($0.name) == domain }
        )
      } + additionalProviders
    )
  }

  internal func listTools() throws -> [MCPTool] {
    try providers.flatMap { try $0.listTools() }
  }

  internal func capability(named name: String) throws -> CapabilityDescriptor {
    for provider in providers {
      if let tool = try provider.listTools().first(where: { $0.name == name }) {
        return provider.capability(for: tool)
      }
    }
    throw GatewayToolError.unknownTool(name)
  }

  internal func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    for provider in providers where try provider.listTools().contains(where: { $0.name == name }) {
      return try provider.callTool(name: name, arguments: arguments)
    }
    throw GatewayToolError.unknownTool(name)
  }

  internal func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    for provider in providers where try provider.listTools().contains(where: { $0.name == name }) {
      return try await provider.callToolAsync(name: name, arguments: arguments)
    }
    throw GatewayToolError.unknownTool(name)
  }
}

internal enum GatewayProviderRouterError: Error, LocalizedError, Equatable {
  case duplicateTool(String)

  internal var errorDescription: String? {
    switch self {
    case .duplicateTool(let name):
      return "Multiple gateway providers expose tool '\(name)'."
    }
  }
}
