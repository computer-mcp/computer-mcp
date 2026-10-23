import ComputerMCPCore
import ComputerMCPProcess
import ComputerMCPToolKit

package struct GitToolProvider: GatewayToolProvider {
  package let id = "git"
  package let namespaces = ["git"]
  let environment: ToolEnvironment

  package init(environment: ToolEnvironment) {
    self.environment = environment
  }

  package func definitions() throws -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: environment.projectScope.toolMeta).filter {
      environment.configuration.builtin.enabled.contains($0.tool.name)
    }.sorted { $0.tool.name < $1.tool.name }
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let descriptor = try definitions().first { $0.tool.name == invocation.name }?.capability
    let policy: HostExecutionPolicy =
      descriptor == nil || descriptor?.risk == .readOnly
        || descriptor?.projectRequirement == ProjectRequirement.none ? .readOnly : .fullAccess
    return try HostExecutionPolicy.$current.withValue(policy) { try dispatch(invocation) }
  }

  private func dispatch(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
    case "git.root":
      try requireBuiltinEnabled(name)
      return try textResult(gitRoot(arguments: object))

    case "git.config":
      try requireBuiltinEnabled(name)
      return try textResult(gitConfig(arguments: object))

    case "git.remotes":
      try requireBuiltinEnabled(name)
      return try textResult(gitRemotes(arguments: object))

    case "git.worktrees":
      try requireBuiltinEnabled(name)
      return try textResult(gitWorktrees(arguments: object))

    case "git.stashes":
      try requireBuiltinEnabled(name)
      return try textResult(gitStashes(arguments: object))

    case "git.stash_show":
      try requireBuiltinEnabled(name)
      return try textResult(gitStashShow(arguments: object))

    case "git.stash_push":
      try requireBuiltinEnabled(name)
      return try textResult(gitStashPush(arguments: object))

    case "git.tags":
      try requireBuiltinEnabled(name)
      return try textResult(gitTags(arguments: object))

    case "git.tag_show":
      try requireBuiltinEnabled(name)
      return try textResult(gitTagShow(arguments: object))

    case "git.tag_create":
      try requireBuiltinEnabled(name)
      return try textResult(gitTagCreate(arguments: object))

    case "git.tag_delete":
      try requireBuiltinEnabled(name)
      return try textResult(gitTagDelete(arguments: object))

    case "git.ignored":
      try requireBuiltinEnabled(name)
      return try textResult(gitIgnored(arguments: object))

    case "git.submodules":
      try requireBuiltinEnabled(name)
      return try textResult(gitSubmodules(arguments: object))

    case "git.files":
      try requireBuiltinEnabled(name)
      return try textResult(gitFiles(arguments: object))

    case "git.grep":
      try requireBuiltinEnabled(name)
      return try textResult(gitGrep(arguments: object))

    case "git.blame":
      try requireBuiltinEnabled(name)
      return try textResult(gitBlame(arguments: object))

    case "git.file_history":
      try requireBuiltinEnabled(name)
      return try textResult(gitFileHistory(arguments: object))

    case "git.file_at_revision":
      try requireBuiltinEnabled(name)
      return try textResult(gitFileAtRevision(arguments: object))

    case "git.staged_file":
      try requireBuiltinEnabled(name)
      return try textResult(gitStagedFile(arguments: object))

    case "git.conflicts":
      try requireBuiltinEnabled(name)
      return try textResult(gitConflicts(arguments: object))

    case "git.status":
      try requireBuiltinEnabled(name)
      return try textResult(gitStatus(arguments: object))

    case "git.tracking_status":
      try requireBuiltinEnabled(name)
      return try textResult(gitTrackingStatus(arguments: object))

    case "git.clean_preview":
      try requireBuiltinEnabled(name)
      return try textResult(gitCleanPreview(arguments: object))

    case "git.clean":
      try requireBuiltinEnabled(name)
      return try textResult(gitClean(arguments: object))

    case "git.reflog":
      try requireBuiltinEnabled(name)
      return try textResult(gitReflog(arguments: object))

    case "git.refs":
      try requireBuiltinEnabled(name)
      return try textResult(gitRefs(arguments: object))

    case "git.resolve_ref":
      try requireBuiltinEnabled(name)
      return try textResult(gitResolveRef(arguments: object))

    case "git.merge_base":
      try requireBuiltinEnabled(name)
      return try textResult(gitMergeBase(arguments: object))

    case "git.compare_refs":
      try requireBuiltinEnabled(name)
      return try textResult(gitCompareRefs(arguments: object))

    case "git.is_ancestor":
      try requireBuiltinEnabled(name)
      return try textResult(gitIsAncestor(arguments: object))

    case "git.diff":
      try requireBuiltinEnabled(name)
      return try textResult(gitDiff(arguments: object))

    case "git.diff_summary":
      try requireBuiltinEnabled(name)
      return try textResult(gitDiffSummary(arguments: object))

    case "git.diff_check":
      try requireBuiltinEnabled(name)
      return try textResult(gitDiffCheck(arguments: object))

    case "git.branch":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranch(arguments: object))

    case "git.branch_create":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranchCreate(arguments: object))

    case "git.branch_delete":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranchDelete(arguments: object))

    case "git.branch_rename":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranchRename(arguments: object))

    case "git.branch_switch":
      try requireBuiltinEnabled(name)
      return try textResult(gitBranchSwitch(arguments: object))

    case "git.log":
      try requireBuiltinEnabled(name)
      return try textResult(gitLog(arguments: object))

    case "git.commit_files":
      try requireBuiltinEnabled(name)
      return try textResult(gitCommitFiles(arguments: object))

    case "git.show":
      try requireBuiltinEnabled(name)
      return try textResult(gitShow(arguments: object))

    case "git.add":
      try requireBuiltinEnabled(name)
      return try textResult(gitAdd(arguments: object))

    case "git.unstage":
      try requireBuiltinEnabled(name)
      return try textResult(gitUnstage(arguments: object))

    case "git.restore_worktree":
      try requireBuiltinEnabled(name)
      return try textResult(gitRestoreWorktree(arguments: object))

    case "git.commit":
      try requireBuiltinEnabled(name)
      return try textResult(gitCommit(arguments: object))

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }

  private func requireBuiltinEnabled(_ name: String) throws {
    guard environment.configuration.builtin.enabled.contains(name) else {
      throw GatewayToolError.disabled("\(name) is disabled by configuration.")
    }
  }
}
