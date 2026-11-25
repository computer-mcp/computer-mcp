import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPWorktrees
import Foundation

/// Binds the routed project to the runtime's durable registration and live folder access.
package struct GatewayProviderProject: Sendable {
  let registration: DerivedProjectSource
  let access: ResolvedProjectAccess
  let wasDerived: Bool

  func validate(in database: GatewayDatabase, platform: PlatformServices) throws
    -> DerivedProjectRecord?
  {
    let (project, derived) = try database.connection.writer.read { sql in
      guard try ProjectAliasRecord.fetchOne(sql, key: registration.id) == nil else {
        throw ProjectBookmarkError.rootChanged(projectID: registration.id)
      }
      return (
        try ProjectRecord.fetchOne(sql, key: registration.id)?.value,
        try SQLiteDerivedProjectStore.record(registration.id, in: sql)
      )
    }
    guard let project, project.createdAt == registration.registeredAt,
      access.isActive, !wasDerived || derived != nil,
      try ProjectPathResolver.canonicalProject(URL(fileURLWithPath: project.rootPath)).path
        == registration.root
    else { throw ProjectBookmarkError.rootChanged(projectID: registration.id) }
    let live = try platform.projectGrants.resolve(project)
    defer { live.close() }
    guard live.rootIdentity == access.rootIdentity,
      try ProjectPathResolver.canonicalProject(live.rootURL).path == registration.root
    else { throw ProjectBookmarkError.rootChanged(projectID: registration.id) }
    return derived
  }

  func identity(content: ProviderProjectIdentity.Content) -> ProviderProjectIdentity {
    .init(
      projectID: registration.id, registeredAt: registration.registeredAt,
      root: access.rootIdentity,
      content: content)
  }
}

/// The source projection may open only the provider's verified private storage.
package struct GatewayProviderSourceSandbox: Sendable {
  let projectID: String
  let directory: SandboxPath
  let scratch: SandboxPath
  private let container: WorktreeDirectoryIdentity
  private let temporary: WorktreeDirectoryIdentity
  private let protected: [WorktreeDirectoryIdentity]

  init(project: GatewayProviderProject, container: GatewayProviderContainer, scratch: URL) throws {
    projectID = project.registration.id
    let source = try WorktreeDirectory(URL(fileURLWithPath: project.registration.root))
    directory = try SandboxPath(source.identity.path)
    temporary = try WorktreeDirectory(scratch).identity
    self.scratch = try SandboxPath(temporary.path)
    self.container = try WorktreeDirectory(URL(fileURLWithPath: container.root.string)).identity
    protected = try [source.identity] + source.sourceGitDirectories()
    try validate()
  }

  func validate() throws {
    let source = try WorktreeDirectory(URL(fileURLWithPath: directory.value))
    guard try [source.identity] + source.sourceGitDirectories() == protected else {
      throw WorktreeError.identityChanged("Source Git storage changed.")
    }
    for writable in [container, temporary] {
      guard try WorktreeDirectory(URL(fileURLWithPath: writable.path)).identity == writable else {
        throw WorktreeError.identityChanged("Provider writable storage changed.")
      }
      for root in protected {
        if try root.containsDirectory(writable) || writable.containsDirectory(root) {
          throw ExecutionEnvironmentError.unavailable(
            "Provider writable storage overlaps the source project or its Git storage")
        }
      }
    }
  }
}
