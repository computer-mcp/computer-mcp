import Foundation

public struct ValidationCapabilityContract: Codable, Equatable, Sendable {
  public let id: String
  public let risk: String
  public let workspaceRequirement: String
  public let localOnly: Bool
  public let usesNetwork: Bool
  public let tccServices: [String]
}

public struct ValidationToolContract: Codable, Equatable, Sendable {
  public let name: String
  public let title: String
  public let description: String
  public let inputSchema: JSONValue
  public let outputSchema: JSONValue?
  public let annotations: JSONValue?
  public let meta: JSONValue?
  public let capability: ValidationCapabilityContract

  public var tool: MCPTool {
    let hints = annotations?.objectValue
    return MCPTool(
      name: name,
      title: title,
      description: description,
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      annotations: annotations.map { _ in
        MCPToolAnnotations(
          readOnlyHint: hints?["readOnlyHint"]?.boolValue,
          destructiveHint: hints?["destructiveHint"]?.boolValue,
          idempotentHint: hints?["idempotentHint"]?.boolValue,
          openWorldHint: hints?["openWorldHint"]?.boolValue
        )
      },
      meta: meta
    )
  }
}

public struct ValidationToolInventoryContract: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let configuration: String
  public let server: String
  public let caller: String
  public let profile: String
  public let excludedDynamicReexports: [String]
  public let tools: [ValidationToolContract]

  public static func load(
    configurationURL: URL,
    caller: GatewayCallerKind? = nil,
    profileID: GatewayProfileID? = nil,
    executableURL: URL? = nil
  ) throws -> Self {
    var arguments = [
      "tools", "inventory", "--config", configurationURL.standardizedFileURL.path,
    ]
    if let caller { arguments += ["--caller", caller.rawValue] }
    if let profileID { arguments += ["--profile", profileID.rawValue] }
    let data = try ValidationProductCommand(executableURL: executableURL).run(arguments)
    let inventory = try ValidationCanonicalJSONCoding.decoder().decode(Self.self, from: data)
    guard inventory.schemaVersion == 1 else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Tool Inventory",
        expected: 1,
        actual: inventory.schemaVersion
      )
    }
    return inventory
  }
}

public enum ValidationDefaultManifest {
  public static func data(executableURL: URL? = nil) throws -> Data {
    try ValidationProductCommand(executableURL: executableURL).run(["config", "defaults"])
  }

  public static func write(
    to destination: URL,
    executableURL: URL? = nil
  ) throws {
    try data(executableURL: executableURL).write(
      to: destination.standardizedFileURL,
      options: .atomic
    )
  }
}
