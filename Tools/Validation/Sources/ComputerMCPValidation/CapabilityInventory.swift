import CryptoKit
import Foundation

public struct CapabilityInventoryReport: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let generatedAt: String
  public let summary: CapabilityInventorySummary
  public let profiles: [CapabilityInventoryProfile]
  public let issues: [CapabilityInventoryIssue]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    generatedAt: String,
    summary: CapabilityInventorySummary,
    profiles: [CapabilityInventoryProfile],
    issues: [CapabilityInventoryIssue]
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.summary = summary
    self.profiles = profiles
    self.issues = issues
  }

  public var isValid: Bool {
    issues.isEmpty
  }

  public func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
    try ValidationJSONCoding.encode(self, prettyPrinted: prettyPrinted)
  }

  public static func decodeJSON(_ data: Data) throws -> CapabilityInventoryReport {
    let report = try ValidationJSONCoding.decode(Self.self, from: data)
    guard report.schemaVersion == currentSchemaVersion else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Capability Inventory",
        expected: currentSchemaVersion,
        actual: report.schemaVersion
      )
    }
    try ValidationJSONCoding.requireExactShape(
      report,
      input: data,
      artifact: "Capability Inventory"
    )
    return report
  }

  public func markdown() -> String {
    var lines = [
      "# Computer MCP Capability Inventory",
      "",
      "- Schema version: \(schemaVersion)",
      "- Generated at: \(generatedAt)",
      "- Profiles: \(summary.profileCount)",
      "- Profile tool entries: \(summary.profileToolCount)",
      "- Unique tools: \(summary.uniqueToolCount)",
      "- Issues: \(summary.issueCount)",
      "",
    ]

    for profile in profiles {
      lines.append("## \(profile.configuration)")
      lines.append("")
      lines.append("- Server: \(profile.serverName)")
      lines.append("- Binding: `\(profile.caller)` / `\(profile.profile)`")
      lines.append("- Tool count: \(profile.toolCount)")
      lines.append("- Duplicate tool names: \(profile.duplicateToolNames.count)")
      lines.append("")
      lines.append("| Domain | Tools |")
      lines.append("| --- | ---: |")
      for domain in profile.domains {
        lines.append("| \(domain.name) | \(domain.toolCount) |")
      }
      lines.append("")
      lines.append("| Tool | Domain | Input schema | Output schema | Annotations | Risk |")
      lines.append("| --- | --- | --- | --- | --- | --- |")
      for tool in profile.tools {
        lines.append(
          "| `\(tool.name)` | \(tool.domain) | \(yesNo(tool.hasInputSchema)) | "
            + "\(yesNo(tool.hasOutputSchema)) | \(yesNo(tool.hasAnnotations)) | "
            + "\(tool.risk) |"
        )
      }
      lines.append("")
    }

    lines.append("## Issues")
    lines.append("")
    if issues.isEmpty {
      lines.append("None.")
    } else {
      for issue in issues {
        let profile = issue.configuration.map { " (`\($0)`)" } ?? ""
        lines.append("- `\(issue.code)`\(profile): \(issue.message)")
      }
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
  }
}

public struct CapabilityInventorySummary: Codable, Equatable, Sendable {
  public let profileCount: Int
  public let profileToolCount: Int
  public let uniqueToolCount: Int
  public let issueCount: Int

  public init(
    profileCount: Int,
    profileToolCount: Int,
    uniqueToolCount: Int,
    issueCount: Int
  ) {
    self.profileCount = profileCount
    self.profileToolCount = profileToolCount
    self.uniqueToolCount = uniqueToolCount
    self.issueCount = issueCount
  }
}

public struct CapabilityInventoryProfile: Codable, Equatable, Sendable {
  public let configuration: String
  public let serverName: String
  public let caller: String
  public let profile: String
  public let toolCount: Int
  public let toolNames: [String]
  public let domains: [CapabilityInventoryDomain]
  public let tools: [CapabilityInventoryTool]
  public let duplicateToolNames: [String]
  public let requiresRuntimeEvidence: Bool
  public let acceptanceDigest: String

  public init(
    configuration: String,
    serverName: String,
    caller: String,
    profile: String,
    toolCount: Int,
    toolNames: [String],
    domains: [CapabilityInventoryDomain],
    tools: [CapabilityInventoryTool],
    duplicateToolNames: [String],
    requiresRuntimeEvidence: Bool = false,
    acceptanceDigest: String = ""
  ) {
    self.configuration = configuration
    self.serverName = serverName
    self.caller = caller
    self.profile = profile
    self.toolCount = toolCount
    self.toolNames = toolNames
    self.domains = domains
    self.tools = tools
    self.duplicateToolNames = duplicateToolNames
    self.requiresRuntimeEvidence = requiresRuntimeEvidence
    self.acceptanceDigest = acceptanceDigest
  }
}

public struct CapabilityInventoryDomain: Codable, Equatable, Sendable {
  public let name: String
  public let toolCount: Int
  public let toolNames: [String]

  public init(name: String, toolCount: Int, toolNames: [String]) {
    self.name = name
    self.toolCount = toolCount
    self.toolNames = toolNames
  }
}

public struct CapabilityInventoryTool: Codable, Equatable, Sendable {
  public let name: String
  public let domain: String
  public let hasInputSchema: Bool
  public let hasOutputSchema: Bool
  public let hasAnnotations: Bool
  public let risk: String
  public let workspaceRequirement: String
  public let localOnly: Bool
  public let usesNetwork: Bool
  public let hasDescription: Bool
  public let schemaDigest: String
  public let tccServices: [String]

  public init(
    name: String,
    domain: String,
    hasInputSchema: Bool,
    hasOutputSchema: Bool,
    hasAnnotations: Bool,
    risk: String,
    workspaceRequirement: String,
    localOnly: Bool,
    usesNetwork: Bool,
    hasDescription: Bool = true,
    schemaDigest: String = "",
    tccServices: [String] = []
  ) {
    self.name = name
    self.domain = domain
    self.hasInputSchema = hasInputSchema
    self.hasOutputSchema = hasOutputSchema
    self.hasAnnotations = hasAnnotations
    self.risk = risk
    self.workspaceRequirement = workspaceRequirement
    self.localOnly = localOnly
    self.usesNetwork = usesNetwork
    self.hasDescription = hasDescription
    self.schemaDigest = schemaDigest
    self.tccServices = tccServices
  }
}

public struct CapabilityInventoryIssue: Codable, Equatable, Sendable {
  public let code: String
  public let configuration: String?
  public let toolName: String?
  public let message: String

  public init(
    code: String,
    configuration: String? = nil,
    toolName: String? = nil,
    message: String
  ) {
    self.code = code
    self.configuration = configuration
    self.toolName = toolName
    self.message = message
  }
}

public enum CapabilityInventoryError: Error, LocalizedError, Equatable {
  case examplesDirectoryUnavailable

  public var errorDescription: String? {
    switch self {
    case .examplesDirectoryUnavailable:
      "The examples directory does not exist or is not a directory."
    }
  }
}

public struct CapabilityInventoryConfiguration: Sendable {
  public var name: String
  public var configurationURL: URL
  public var caller: GatewayCallerKind?
  public var profileID: GatewayProfileID?
  public var requiresRuntimeEvidence: Bool

  public init(
    name: String,
    configurationURL: URL,
    caller: GatewayCallerKind? = nil,
    profileID: GatewayProfileID? = nil,
    requiresRuntimeEvidence: Bool = false
  ) {
    self.name = name
    self.configurationURL = configurationURL.standardizedFileURL
    self.caller = caller
    self.profileID = profileID
    self.requiresRuntimeEvidence = requiresRuntimeEvidence
  }

  public static func runtimeManifest(
    at manifestURL: URL
  ) throws -> [CapabilityInventoryConfiguration] {
    let standardizedURL = manifestURL.standardizedFileURL
    let namePrefix = standardizedURL.deletingPathExtension().lastPathComponent
    guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
      throw ValidationProcessError.executableUnavailable(standardizedURL.path)
    }

    return GatewayProfileID.builtIns.map { profileID in
      let caller: GatewayCallerKind =
        profileID == .localAdmin
        ? .localMCP
        : (profileID == .cloudflareObserve || profileID == .cloudflareOperate
          ? .cloudflareTunnel : .secureTunnel)
      return CapabilityInventoryConfiguration(
        name: "\(namePrefix).\(profileID.rawValue).toml",
        configurationURL: standardizedURL,
        caller: caller,
        profileID: profileID,
        requiresRuntimeEvidence: profileID != .localAdmin
      )
    }
  }
}

public struct CapabilityInventoryBuilder: Sendable {
  public init() {}

  public func build(
    examplesDirectory: URL,
    additionalConfigurations: [CapabilityInventoryConfiguration] = [],
    generatedAt: Date = Date()
  ) throws -> CapabilityInventoryReport {
    let files = try configurationFiles(in: examplesDirectory)
    var profiles: [CapabilityInventoryProfile] = []
    var issues: [CapabilityInventoryIssue] = []

    if files.isEmpty && additionalConfigurations.isEmpty {
      issues.append(
        CapabilityInventoryIssue(
          code: "inventory.no_profiles",
          message: "No computer-mcp TOML profile files were found."
        )
      )
    }

    for file in files {
      let configurationName = file.lastPathComponent
      do {
        try appendProfile(
          configurationName: configurationName,
          configurationURL: file,
          caller: nil,
          profileID: nil,
          requiresRuntimeEvidence: false,
          profiles: &profiles,
          issues: &issues
        )
      } catch {
        issues.append(
          CapabilityInventoryIssue(
            code: "profile.inventory_failed",
            configuration: configurationName,
            message: "The profile could not be loaded and statically inventoried."
          )
        )
      }
    }

    for source in additionalConfigurations.sorted(by: { $0.name < $1.name }) {
      do {
        try appendProfile(
          configurationName: source.name,
          configurationURL: source.configurationURL,
          caller: source.caller,
          profileID: source.profileID,
          requiresRuntimeEvidence: source.requiresRuntimeEvidence,
          profiles: &profiles,
          issues: &issues
        )
      } catch {
        issues.append(
          CapabilityInventoryIssue(
            code: "profile.inventory_failed",
            configuration: source.name,
            message: "The generated profile could not be statically inventoried."
          )
        )
      }
    }

    profiles.sort { $0.configuration < $1.configuration }
    issues.sort(by: Self.issueOrdering)
    let uniqueToolNames = Set(profiles.flatMap(\.toolNames))
    let summary = CapabilityInventorySummary(
      profileCount: profiles.count,
      profileToolCount: profiles.reduce(0) { $0 + $1.toolCount },
      uniqueToolCount: uniqueToolNames.count,
      issueCount: issues.count
    )

    return CapabilityInventoryReport(
      generatedAt: Self.timestamp(generatedAt),
      summary: summary,
      profiles: profiles,
      issues: issues
    )
  }

  private func appendProfile(
    configurationName: String,
    configurationURL: URL,
    caller: GatewayCallerKind?,
    profileID: GatewayProfileID?,
    requiresRuntimeEvidence: Bool,
    profiles: inout [CapabilityInventoryProfile],
    issues: inout [CapabilityInventoryIssue]
  ) throws {
    var arguments = ["tools", "inventory", "--config", configurationURL.path]
    if let caller {
      arguments += ["--caller", caller.rawValue]
    }
    if let profileID {
      arguments += ["--profile", profileID.rawValue]
    }
    let data = try ValidationProductCommand().run(arguments)
    let inventory = try ValidationCanonicalJSONCoding.decoder().decode(
      ProductInventory.self,
      from: data
    )
    guard inventory.schemaVersion == 1 else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Tool Inventory",
        expected: 1,
        actual: inventory.schemaVersion
      )
    }
    if !inventory.excludedDynamicReexports.isEmpty {
      issues.append(
        CapabilityInventoryIssue(
          code: "profile.dynamic_reexport_unsupported",
          configuration: configurationName,
          message:
            "Static inventory does not contact downstream MCP servers required for reexport."
        )
      )
    }
    let profile = try makeProfile(
      configurationName: configurationName,
      inventory: inventory,
      requiresRuntimeEvidence: requiresRuntimeEvidence
    )
    profiles.append(profile)
    issues.append(
      contentsOf: issuesForProfile(
        configurationName: configurationName,
        profile: profile
      )
    )
  }

  private func configurationFiles(in directory: URL) throws -> [URL] {
    var isDirectory = ObjCBool(false)
    guard
      FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CapabilityInventoryError.examplesDirectoryUnavailable
    }

    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    .filter { url in
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
      return values?.isRegularFile == true
        && url.pathExtension == "toml"
        && url.deletingPathExtension().lastPathComponent.hasPrefix("computer-mcp")
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func makeProfile(
    configurationName: String,
    inventory: ProductInventory,
    requiresRuntimeEvidence: Bool
  ) throws -> CapabilityInventoryProfile {
    let inventoryTools = try inventory.tools.map { tool in
      return CapabilityInventoryTool(
        name: tool.name,
        domain: Self.domain(for: tool.name),
        hasInputSchema: true,
        hasOutputSchema: tool.outputSchema != nil,
        hasAnnotations: tool.annotations != nil,
        risk: tool.capability.risk,
        workspaceRequirement: tool.capability.workspaceRequirement,
        localOnly: tool.capability.localOnly,
        usesNetwork: tool.capability.usesNetwork,
        hasDescription: !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        schemaDigest: try Self.digest(tool.gatewayToolJSON),
        tccServices: tool.capability.tccServices.sorted()
      )
    }
    .sorted { $0.name < $1.name }

    let grouped = Dictionary(grouping: inventoryTools, by: \.domain)
    let domains = grouped.keys.sorted().map { domain in
      let names = grouped[domain, default: []].map(\.name).sorted()
      return CapabilityInventoryDomain(
        name: domain,
        toolCount: names.count,
        toolNames: names
      )
    }

    let acceptanceDigest = try Self.digest(
      AcceptanceProfileDigestInput(
        serverName: inventory.server,
        caller: inventory.caller,
        profile: inventory.profile,
        tools: inventoryTools
      )
    )
    let duplicateToolNames = Dictionary(grouping: inventory.tools, by: \.name)
      .filter { $0.value.count > 1 }
      .map(\.key)
      .sorted()
    return CapabilityInventoryProfile(
      configuration: configurationName,
      serverName: inventory.server,
      caller: inventory.caller,
      profile: inventory.profile,
      toolCount: inventoryTools.count,
      toolNames: inventoryTools.map(\.name),
      domains: domains,
      tools: inventoryTools,
      duplicateToolNames: duplicateToolNames,
      requiresRuntimeEvidence: requiresRuntimeEvidence,
      acceptanceDigest: acceptanceDigest
    )
  }

  private func issuesForProfile(
    configurationName: String,
    profile: CapabilityInventoryProfile
  ) -> [CapabilityInventoryIssue] {
    var issues = profile.duplicateToolNames.map { name in
      CapabilityInventoryIssue(
        code: "profile.duplicate_tool",
        configuration: configurationName,
        toolName: name,
        message: "The profile exposes the same tool name more than once."
      )
    }

    if profile.tools.isEmpty {
      issues.append(
        CapabilityInventoryIssue(
          code: "profile.no_tools",
          configuration: configurationName,
          message: "The profile exposes no tools."
        )
      )
    }

    for tool in profile.tools {
      if !tool.hasInputSchema {
        issues.append(
          missingMetadataIssue(
            code: "tool.missing_input_schema",
            configurationName: configurationName,
            toolName: tool.name,
            label: "input schema"
          )
        )
      }
      if !tool.hasOutputSchema {
        issues.append(
          missingMetadataIssue(
            code: "tool.missing_output_schema",
            configurationName: configurationName,
            toolName: tool.name,
            label: "output schema"
          )
        )
      }
      if !tool.hasAnnotations {
        issues.append(
          missingMetadataIssue(
            code: "tool.missing_annotations",
            configurationName: configurationName,
            toolName: tool.name,
            label: "annotations"
          )
        )
      }
    }
    return issues
  }

  private func missingMetadataIssue(
    code: String,
    configurationName: String,
    toolName: String,
    label: String
  ) -> CapabilityInventoryIssue {
    CapabilityInventoryIssue(
      code: code,
      configuration: configurationName,
      toolName: toolName,
      message: "The tool does not expose \(label)."
    )
  }

  private static func domain(for toolName: String) -> String {
    guard let separator = toolName.firstIndex(of: "."), separator != toolName.startIndex else {
      return "configured"
    }
    return String(toolName[..<separator])
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  private static func digest<T: Encodable>(_ value: T) throws -> String {
    let encoder = CanonicalJSONCoding.encoder(
      outputFormatting: [.sortedKeys, .withoutEscapingSlashes]
    )
    let data = try encoder.encode(value)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct AcceptanceProfileDigestInput: Encodable {
    var serverName: String
    var caller: String
    var profile: String
    var tools: [CapabilityInventoryTool]
  }

  private struct ProductInventory: Decodable {
    let schemaVersion: Int
    let server: String
    let caller: String
    let profile: String
    let excludedDynamicReexports: [String]
    let tools: [ProductInventoryTool]
  }

  private struct ProductInventoryTool: Decodable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let annotations: JSONValue?
    let meta: JSONValue?
    let capability: ProductCapability

    var gatewayToolJSON: JSONValue {
      var value: [String: JSONValue] = [
        "name": .string(name),
        "title": .string(title),
        "description": .string(description),
        "inputSchema": inputSchema,
      ]
      if let outputSchema { value["outputSchema"] = outputSchema }
      if let annotations { value["annotations"] = annotations }
      if let meta { value["_meta"] = meta }
      return .object(value)
    }
  }

  private struct ProductCapability: Decodable {
    let id: String
    let risk: String
    let workspaceRequirement: String
    let localOnly: Bool
    let usesNetwork: Bool
    let tccServices: [String]
  }

  private static func issueOrdering(
    _ lhs: CapabilityInventoryIssue,
    _ rhs: CapabilityInventoryIssue
  ) -> Bool {
    (
      lhs.configuration ?? "",
      lhs.toolName ?? "",
      lhs.code,
      lhs.message
    ) < (
      rhs.configuration ?? "",
      rhs.toolName ?? "",
      rhs.code,
      rhs.message
    )
  }
}
