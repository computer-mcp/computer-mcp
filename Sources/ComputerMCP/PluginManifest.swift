import Foundation
import TOML

package enum PluginManifestError: Error, Equatable, LocalizedError, Sendable {
  case invalid(String)

  package var errorDescription: String? {
    switch self {
    case .invalid(let reason): "Invalid plugin package: \(reason)"
    }
  }
}

/// Immutable package contributions. Local selection, authorization, and secrets live in the host.
package struct PluginManifest: Codable, Equatable, Sendable {
  package static let filename = "computer-mcp-plugin.toml"
  package let id: String
  package let name: String
  package let version: PluginVersion
  package let description: String?
  package let repository: String?
  package let compatibility: PluginCompatibility?
  package let dependencies: [PluginDependency]
  package let mcp: [PluginMCPContribution]
  package let cli: [PluginCLIContribution]
  package let skills: [PluginSkillContribution]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name, version, description, repository, compatibility, dependencies, mcp, cli, skills
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    version = try c.decode(PluginVersion.self, forKey: .version)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    repository = try c.decodeIfPresent(String.self, forKey: .repository)
    compatibility = try c.decodeIfPresent(PluginCompatibility.self, forKey: .compatibility)
    dependencies = try c.decodeIfPresent([PluginDependency].self, forKey: .dependencies) ?? []
    mcp = try c.decodeIfPresent([PluginMCPContribution].self, forKey: .mcp) ?? []
    cli = try c.decodeIfPresent([PluginCLIContribution].self, forKey: .cli) ?? []
    skills = try c.decodeIfPresent([PluginSkillContribution].self, forKey: .skills) ?? []
    try validate()
  }

  package static func parse(_ text: String) throws -> PluginManifest {
    guard text.utf8.count <= 1_048_576 else {
      throw PluginManifestError.invalid("Manifest exceeds 1 MiB.")
    }
    return try TOMLDecoder().decode(Self.self, from: text)
  }

  private func validate() throws {
    try validatePluginID(id)
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PluginManifestError.invalid("Package name is empty.")
    }
    if let repository {
      try validatePluginHTTPURL(repository, label: "repository", httpsOnly: true)
    }
    let contributionIDs = mcp.map(\.id) + cli.map(\.id) + skills.map(\.id)
    guard !contributionIDs.isEmpty, contributionIDs.count <= 1_024 else {
      throw PluginManifestError.invalid("A package must contain between 1 and 1024 contributions.")
    }
    try validatePluginIDs(contributionIDs, label: "contribution")
    try validatePluginIDs(dependencies.map(\.id), label: "dependency")
    let dependencyIDs = Set(dependencies.map(\.id))
    for executable in mcp.compactMap(\.executable) + cli.map(\.executable)
      + cli.compactMap({ $0.tree?.helper })
    {
      if let dependency = executable.dependency, !dependencyIDs.contains(dependency) {
        throw PluginManifestError.invalid(
          "Executable references unknown dependency '\(dependency)'.")
      }
    }
  }
}

package struct PluginCompatibility: Codable, Equatable, Sendable {
  package let minimumHost: PluginVersion?
  package let maximumHost: PluginVersion?
  package let architectures: [String]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case minimumHost = "minimum_host"
    case maximumHost = "maximum_host"
    case architectures
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    minimumHost = try c.decodeIfPresent(PluginVersion.self, forKey: .minimumHost)
    maximumHost = try c.decodeIfPresent(PluginVersion.self, forKey: .maximumHost)
    architectures = try c.decodeIfPresent([String].self, forKey: .architectures) ?? []
    if let minimumHost, let maximumHost, !minimumHost.precedes(maximumHost) {
      throw PluginManifestError.invalid("maximum_host must be greater than minimum_host.")
    }
    guard Set(architectures).count == architectures.count,
      architectures.allSatisfy({ ["arm64", "x86_64"].contains($0) })
    else {
      throw PluginManifestError.invalid(
        "Architectures must be unique supported macOS architectures.")
    }
  }

  package func permits(host: PluginVersion, architecture: String) -> Bool {
    (minimumHost.map { !host.precedes($0) } ?? true)
      && (maximumHost.map { host.precedes($0) } ?? true)
      && (architectures.isEmpty || architectures.contains(architecture))
  }
}

package struct PluginDependency: Codable, Equatable, Sendable {
  package let id: String
  package let commands: [String]
  package let applications: [PluginApplicationLocator]
  package let instructions: String
  package let documentation: String?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, commands, applications, instructions, documentation
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
    applications =
      try c.decodeIfPresent([PluginApplicationLocator].self, forKey: .applications) ?? []
    instructions = try c.decode(String.self, forKey: .instructions)
    documentation = try c.decodeIfPresent(String.self, forKey: .documentation)
    try validatePluginID(id)
    guard !commands.isEmpty || !applications.isEmpty,
      applications.count <= 32, Set(applications).count == applications.count,
      Set(commands).count == commands.count,
      commands.allSatisfy({
        !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0")
      }),
      !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PluginManifestError.invalid(
        "Dependencies require command names or application locators and human setup instructions.")
    }
    if let documentation {
      try validatePluginHTTPURL(documentation, label: "documentation", httpsOnly: true)
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(commands, forKey: .commands)
    // Empty optional locators must not change installed command-only manifest digests.
    if !applications.isEmpty { try c.encode(applications, forKey: .applications) }
    try c.encode(instructions, forKey: .instructions)
    try c.encodeIfPresent(documentation, forKey: .documentation)
  }
}

package struct PluginApplicationLocator: Codable, Hashable, Sendable {
  package let bundleIdentifier: String
  package let executable: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case bundleIdentifier = "bundle_identifier"
    case executable
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
    executable = try c.decode(String.self, forKey: .executable)
    guard (1...255).contains(bundleIdentifier.utf8.count),
      bundleIdentifier.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 46
      }), !bundleIdentifier.split(separator: ".", omittingEmptySubsequences: false).contains("")
    else { throw PluginManifestError.invalid("Application locators require a bundle identifier.") }
    try validatePluginRelativePath(executable)
  }
}

/// A package-owned relative executable or a reference to a user-owned external dependency.
package struct PluginExecutable: Codable, Equatable, Sendable {
  package let path: String?
  package let dependency: String?

  private enum CodingKeys: String, CodingKey, CaseIterable { case path, dependency }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    try self.init(
      path: c.decodeIfPresent(String.self, forKey: .path),
      dependency: c.decodeIfPresent(String.self, forKey: .dependency))
  }

  init(path: String? = nil, dependency: String? = nil) throws {
    guard (path != nil) != (dependency != nil) else {
      throw PluginManifestError.invalid("Executable requires exactly one of path or dependency.")
    }
    if let path { try validatePluginRelativePath(path) }
    if let dependency { try validatePluginID(dependency) }
    self.path = path
    self.dependency = dependency
  }
}

package struct PluginMCPContribution: Codable, Equatable, Sendable {
  package let id: String
  package let transport: MCPTransport
  package let executable: PluginExecutable?
  package let url: String?
  package let args: [String]
  package let cwd: String?
  package let prefix: String?
  package let capabilities: [String]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, transport, executable, url, args, cwd, prefix, capabilities
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    transport = try c.decode(MCPTransport.self, forKey: .transport)
    executable = try c.decodeIfPresent(PluginExecutable.self, forKey: .executable)
    url = try c.decodeIfPresent(String.self, forKey: .url)
    args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
    capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? ["tools"]
    if transport == .stdio {
      guard executable != nil, url == nil else {
        throw PluginManifestError.invalid("Stdio contributions require an executable and no URL.")
      }
    } else {
      guard let url, executable == nil, args.isEmpty, cwd == nil else {
        throw PluginManifestError.invalid("HTTP contributions require a URL and no process fields.")
      }
      try validatePluginHTTPURL(url, label: "MCP endpoint", httpsOnly: false)
    }
    if let cwd { try validatePluginRelativePath(cwd) }
    if let prefix { try validatePluginID(prefix, allowDots: true) }
    guard args.allSatisfy({ !$0.contains("\0") }), Set(capabilities).count == capabilities.count,
      capabilities.allSatisfy({ ["tools", "resources", "prompts", "events"].contains($0) })
    else {
      throw PluginManifestError.invalid("Invalid MCP arguments or protocol capabilities.")
    }
  }
}

package struct PluginCLIContribution: Codable, Equatable, Sendable {
  package let id: String
  package let executable: PluginExecutable
  package let description: String?
  package let cwd: String?
  package let tree: PluginCLITreeSource?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, executable, description, cwd, tree
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    executable = try c.decode(PluginExecutable.self, forKey: .executable)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    tree = try c.decodeIfPresent(PluginCLITreeSource.self, forKey: .tree)
    if let cwd { try validatePluginRelativePath(cwd) }
  }
}

package struct PluginCLITreeSource: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable { case file, introspection, helper }
  package let kind: Kind
  package let path: String?
  package let helper: PluginExecutable?
  package let args: [String]

  private enum CodingKeys: String, CodingKey, CaseIterable { case kind, path, helper, args }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    kind = try c.decode(Kind.self, forKey: .kind)
    path = try c.decodeIfPresent(String.self, forKey: .path)
    helper = try c.decodeIfPresent(PluginExecutable.self, forKey: .helper)
    args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    let valid: Bool
    switch kind {
    case .file: valid = path != nil && helper == nil && args.isEmpty
    case .introspection: valid = path == nil && helper == nil && !args.isEmpty
    case .helper: valid = path == nil && helper != nil
    }
    guard valid, args.allSatisfy({ !$0.contains("\0") }) else {
      throw PluginManifestError.invalid("CLI tree source fields do not match its kind.")
    }
    if let path { try validatePluginRelativePath(path) }
  }
}

package struct PluginSkillContribution: Codable, Equatable, Sendable {
  package let id: String
  package let path: String
  package let description: String?

  private enum CodingKeys: String, CodingKey, CaseIterable { case id, path, description }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    path = try c.decode(String.self, forKey: .path)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    try validatePluginRelativePath(path)
  }
}

func validatePluginRelativePath(_ path: String) throws {
  let parts = path.split(separator: "/", omittingEmptySubsequences: false)
  guard !path.isEmpty, !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\0"),
    parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
  else {
    throw PluginManifestError.invalid("Package paths must be normalized relative paths.")
  }
}

func validatePluginID(_ id: String, allowDots: Bool = false) throws {
  guard (1...128).contains(id.utf8.count),
    id.utf8.allSatisfy({
      (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        || (allowDots && $0 == 46)
    }), id.first?.isLetter == true || id.first?.isNumber == true
  else {
    throw PluginManifestError.invalid(
      "IDs must start with a lowercase ASCII letter or digit and use lowercase letters, digits, '-' or '_'."
    )
  }
}

private func validatePluginIDs(_ ids: [String], label: String) throws {
  for id in ids { try validatePluginID(id) }
  guard Set(ids).count == ids.count else {
    throw PluginManifestError.invalid("Duplicate \(label) ID.")
  }
}

private func validatePluginHTTPURL(_ value: String, label: String, httpsOnly: Bool) throws {
  guard let url = URLComponents(string: value),
    (httpsOnly ? ["https"] : ["https", "http"]).contains(url.scheme ?? ""),
    let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil
  else {
    throw PluginManifestError.invalid(
      "Invalid \(label) URL; credentials and fragments are not permitted.")
  }
}

private struct PluginCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

extension Decoder {
  func pluginContainer<Key: CodingKey & CaseIterable>(keyedBy type: Key.Type) throws
    -> KeyedDecodingContainer<Key>
  {
    let raw = try container(keyedBy: PluginCodingKey.self)
    let allowed = Set(Key.allCases.map(\.stringValue))
    let unknown = Set(raw.allKeys.map(\.stringValue)).subtracting(allowed).sorted()
    guard unknown.isEmpty else {
      let location = codingPath.map(\.stringValue).joined(separator: ".")
      throw PluginManifestError.invalid(
        "Unknown fields at '\(location)': \(unknown.joined(separator: ", ")).")
    }
    return try container(keyedBy: type)
  }
}
