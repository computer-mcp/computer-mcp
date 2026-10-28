import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import ComputerMCPWorktrees
import Foundation

/// Only the host repository service can mint this context from current topology.
package struct GatewayWorktreeExecution: Sendable {
  package let binding: WorktreeExecutionBinding
  package let directory: SandboxPath
  package let git: SandboxGitConfiguration

  package init(binding: WorktreeExecutionBinding) throws {
    try binding.verify()
    self.binding = binding
    func path(_ identity: WorktreeDirectoryIdentity) throws -> SandboxPath {
      try SandboxPath(
        ProjectPathResolver.canonicalProject(URL(fileURLWithPath: identity.path)).path)
    }
    directory = try path(binding.root)
    git = try .init(
      sharedDirectory: path(binding.common), repository: path(binding.repository))
  }
}

extension GatewayDatabase {
  func executionWorktree(projectID: String?, directory: URL?, platform: PlatformServices) throws
    -> GatewayWorktreeExecution?
  {
    guard let projectID,
      let record = try derivedProjects().first(where: { $0.projectID == projectID })
    else { return nil }
    guard case .host = record.provenance else { return nil }
    guard let storage = worktreeStorage, let directory,
      let source = try project(id: record.source.id),
      source.createdAt == record.source.registeredAt,
      Self.canonicalProjectRoot(source.rootPath) == record.source.root,
      try ProjectPathResolver.canonicalProject(directory)
        == ProjectPathResolver.canonicalProject(URL(fileURLWithPath: record.root))
    else { throw WorktreeError.identityChanged("Worktree source or working directory changed.") }
    let repository = try WorktreeRepository(
      source: record.source,
      store: derivedProjectStore(inspectNesting: { _ in
        throw PermissionModelError.invalidAuthorization
      }), storage: storage,
      executor: GatewayWorktreeGit(launcher: platform.launcher, executable: platform.gitExecutable),
      registeredProjectRoots: try projects().map { URL(fileURLWithPath: $0.rootPath) },
      timeoutMilliseconds: 30_000, maxOutputBytes: 16_777_216, lockTimeout: .seconds(30),
      owner: .init(bootSessionID: platform.launcher.bootSessionID))
    return try .init(binding: repository.executionBinding(projectID: projectID))
  }
}
