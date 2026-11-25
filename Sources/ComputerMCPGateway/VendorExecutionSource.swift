import ComputerMCPConfiguration
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import ComputerMCPSandbox
import Crypto
import Foundation

/// Launch and effect data belong to the reviewed manifest and its file inventory.
struct VendorExecutionSource: Sendable {
  enum Effect: String, Decodable, Sendable {
    case acquire
    case detachedAcquire = "detached_acquire"
    case prompt
    case detachedPrompt = "detached_prompt"
    case mode, stop, answer, close, observe

    var acquires: Bool { self == .acquire || self == .detachedAcquire }
  }

  struct Signature: Decodable, Sendable {
    let capability: String
    let dependency: String
    let tools: [String: Effect]
    let probe: [String]
    let workload: [String]
    let versionStdout: String

    enum CodingKeys: String, CodingKey {
      case capability, dependency, tools, probe, workload
      case versionStdout = "version_stdout"
    }
  }

  static let capability = MCPChildProcessTransport.vendorExecutionCapability

  let pluginID: String
  let manifestDigest: String
  let registrationID: String
  let signature: Signature
  let executable: SandboxPath
  let dependencyFiles: [VerifiedFileIdentity]
  private let root: URL
  private let files: [String: String]

  static func resolve(
    server: MCPServerConfig, origin: PluginContributionOrigin, package: PluginPackage,
    state: PluginStoreSnapshot
  ) throws -> Self? {
    guard let contribution = package.manifest.mcp.first(where: { $0.id == origin.componentID })
    else { throw PermissionModelError.invalidAuthorization }
    guard let declaration = contribution.vendorExecution else {
      // This installed entry point is managed. Standalone adapters are direct MCP registrations.
      if origin.source.kind == .artifact, origin.pluginID == "cursor", origin.componentID == "acp" {
        throw PermissionModelError.invalidAuthorization
      }
      return nil
    }

    let digest = try PluginStore.manifestDigest(package.manifest)
    guard package.manifest.id == origin.pluginID, package.manifest.version == origin.version,
      package.root == origin.source.root, origin.reviewedRequirements?.sourceDigest == digest,
      let settings = state.settings[origin.pluginID], settings.enabled,
      let choice = settings.mcp[origin.componentID], choice.enabled, !choice.hostServices,
      choice.args == nil, server.enabled, !server.hostServices, server.transport == .stdio,
      server.id
        == PluginResolver.registrationID(
          pluginID: origin.pluginID, componentID: origin.componentID,
          override: choice.registrationID),
      let dependency = origin.vendorExecutable,
      dependency.isFileURL, dependency.path.hasPrefix("/")
    else { throw PermissionModelError.invalidAuthorization }

    if let selected = state.selectedInstallations[origin.pluginID] {
      guard
        state.installations.contains(where: {
          $0.id == selected && $0.pluginID == origin.pluginID && $0.source == origin.source
            && $0.version == origin.version && $0.manifestDigest == digest
        })
      else { throw PermissionModelError.invalidAuthorization }
    } else if origin.source.kind != .bundled {
      throw PermissionModelError.invalidAuthorization
    }

    guard
      let bytes = try verifyFiles(
        root: package.root, inventory: declaration.files, retaining: declaration.signature)
    else {
      throw PermissionModelError.invalidAuthorization
    }
    let signature = try JSONDecoder().decode(Signature.self, from: bytes)
    guard signature.capability == capability, signature.dependency == declaration.dependency,
      signature.probe == ["--version"],
      signature.tools.values.contains(where: \.acquires),
      signature.tools.keys.allSatisfy({
        !$0.isEmpty && !$0.contains("\0")
      }),
      !signature.workload.isEmpty, signature.workload.allSatisfy({ !$0.contains("\0") }),
      (1...65_536).contains(signature.versionStdout.utf8.count)
    else { throw PermissionModelError.invalidAuthorization }

    let inspection = ExecutableInspection.inspect(
      dependency.path, workingDirectory: package.root, environment: ["PATH": "/usr/bin:/bin"])
    let dependencyFiles = try identities(inspection)
    guard let executable = dependencyFiles.first else {
      throw PermissionModelError.invalidAuthorization
    }
    return try Self(
      pluginID: origin.pluginID, manifestDigest: digest, registrationID: server.id,
      signature: signature, executable: SandboxPath(executable.path),
      dependencyFiles: dependencyFiles, root: package.root, files: declaration.files)
  }

  func verify() throws {
    _ = try Self.verifyFiles(root: root, inventory: files)
    for file in dependencyFiles { try file.verify(URL(fileURLWithPath: file.path)) }
  }

  func verifyInterpreter(searchPath: [SandboxPath]) throws {
    let inspection = ExecutableInspection.inspect(
      executable.value, workingDirectory: root,
      environment: ["PATH": searchPath.map(\.value).joined(separator: ":")])
    guard try Self.identities(inspection) == dependencyFiles else {
      throw PermissionModelError.invalidAuthorization
    }
  }

  private static func identities(_ file: ExecutableInspection) throws -> [VerifiedFileIdentity] {
    guard !file.hasKnownFailure, let path = file.path else {
      throw PermissionModelError.invalidAuthorization
    }
    return try [VerifiedFileIdentity.capture(URL(fileURLWithPath: path))]
      + file.interpreters.flatMap(identities)
  }

  private static func verifyFiles(
    root: URL, inventory: [String: String], retaining signature: String? = nil
  ) throws -> Data? {
    let files = try PackageFiles(root: root)
    var result: Data?
    for (path, digest) in inventory {
      let url = root.appendingPathComponent(path)
      let identity = try VerifiedFileIdentity.capture(url)
      guard identity.path == url.path else { throw PermissionModelError.invalidAuthorization }
      let data = try files.read(path, maximumBytes: 1_048_576)
      guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest
      else { throw PermissionModelError.invalidAuthorization }
      try identity.verify(url)
      if path == signature { result = data }
    }
    return result
  }
}
