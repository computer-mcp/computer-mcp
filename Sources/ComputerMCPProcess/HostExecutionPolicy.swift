import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation

/// Selected by host tool semantics after authorization. This does not grant execution permission.
package enum HostExecutionPolicy: Sendable {
  case fullAccess
  case readOnly
  case networkDiagnostic

  @TaskLocal package static var current: Self = .fullAccess

  internal func prepare(
    directory: URL, environment: [String: String], systemReadPaths: [SandboxPath]
  ) throws -> HostExecutionSetup {
    if self == .fullAccess {
      return HostExecutionSetup(
        mode: .fullAccess, environment: try ExecutionEnvironment(fullAccessVariables: environment),
        temporary: nil)
    }
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-execution-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      let root = try SandboxPath(try ProjectPathResolver.canonicalProject(temporary).path)
      let configuration = try SandboxConfiguration(
        readOnly: true, hostNetwork: self == .networkDiagnostic,
        worktree: self == .networkDiagnostic
          ? root : SandboxPath(try ProjectPathResolver.canonicalProject(directory).path),
        temporaryDirectory: root, homeDirectory: root, cacheDirectory: root,
        readableRoots: self == .networkDiagnostic ? systemReadPaths : [SandboxPath("/")])
      let paths = try (environment["PATH"] ?? "/bin").split(
        separator: ":", omittingEmptySubsequences: false
      )
      .map { component in
        let path =
          component.hasPrefix("/")
          ? URL(fileURLWithPath: String(component))
          : directory.appendingPathComponent(String(component))
        return try SandboxPath(path.standardizedFileURL.path)
      }
      return HostExecutionSetup(
        mode: .sandbox(configuration),
        environment: try ExecutionEnvironment(
          searchPath: paths.isEmpty ? [SandboxPath("/bin")] : paths,
          home: root, temporary: root, cache: root,
          codexHome: try environment["CODEX_HOME"].map {
            try SandboxPath(URL(fileURLWithPath: $0).standardized.path)
          }), temporary: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

internal struct HostExecutionSetup: Sendable {
  let mode: ExecutionMode
  let environment: ExecutionEnvironment
  let temporary: URL?

  func removeTemporaryDirectory() {
    if let temporary { try? FileManager.default.removeItem(at: temporary) }
  }
}

/// Opaque host authorization identity, captured at the admitted provider call boundary.
package enum ExecutionRecovery {
  @TaskLocal package static var key: String?
}
