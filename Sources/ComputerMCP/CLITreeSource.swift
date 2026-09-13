import Foundation

/// Host-side location of an interface. Package references are resolved into this same
/// registration shape; dependency ownership remains with the package/host resolver.
package struct CLITreeSource: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable { case file, introspection, helper }
  package var kind: Kind
  package var path: String?
  package var helper: String?
  package var args: [String]
  /// Derived package containment anchor, never persisted into a user's registration.
  var packageRoot: URL? = nil

  package init(kind: Kind, path: String? = nil, helper: String? = nil, args: [String] = []) {
    self.kind = kind
    self.path = path
    self.helper = helper
    self.args = args
  }

  private enum CodingKeys: String, CodingKey { case kind, path, helper, args }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decode(Kind.self, forKey: .kind)
    path = try c.decodeIfPresent(String.self, forKey: .path)
    helper = try c.decodeIfPresent(String.self, forKey: .helper)
    args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    try validate()
  }

  func validate() throws {
    let valid: Bool
    switch kind {
    case .file: valid = path != nil && helper == nil && args.isEmpty
    case .introspection: valid = path == nil && helper == nil && !args.isEmpty
    case .helper: valid = path == nil && helper?.hasPrefix("/") == true
    }
    guard valid,
      [path, helper].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
      args.count <= 1_024, args.allSatisfy({ !$0.contains("\0") })
    else { throw ConfigurationError.invalid("CLI tree source fields do not match its kind.") }
  }

  func load(command: CLICommandConfig, workspace: URL, execution: CLIProcessExecution) throws
    -> CLITree
  {
    try validate()
    let cwd = command.resolvedWorkingDirectory(base: workspace) ?? workspace
    let data: Data
    switch kind {
    case .file:
      let url =
        path!.hasPrefix("/") ? URL(fileURLWithPath: path!) : cwd.appendingPathComponent(path!)
      // The common no-follow reader bounds regular-file reads and rejects FIFO/device sources.
      if let packageRoot {
        guard url.path.hasPrefix(packageRoot.path + "/") else {
          throw CLITreeError.invalid("Tree source is outside its owning package.")
        }
        data = try PluginPackageFiles(root: packageRoot)
          .read(String(url.path.dropFirst(packageRoot.path.count + 1)), maximumBytes: 4_194_304)
      } else {
        data = try PluginPackageFiles(root: url.deletingLastPathComponent())
          .read(url.lastPathComponent, maximumBytes: 4_194_304)
      }
    case .introspection, .helper:
      let result = try execution.run(
        executable: kind == .helper ? helper! : command.executable,
        invocation: .init(arguments: args, standardInput: Data()),
        cwd: cwd, environment: command.env, timeoutMilliseconds: 5_000, maxOutputBytes: 4_194_304)
      guard result.exitCode == 0, !result.timedOut, !result.cancelled,
        !result.stdout.truncated, !result.stdout.missedBytes, result.streamErrors.isEmpty,
        let encoded = result.stdout.base64, let output = Data(base64Encoded: encoded)
      else {
        throw CLITreeError.invalid("Interface exporter failed or returned incomplete output.")
      }
      data = output
    }
    return try CLITree.parse(data)
  }
}
