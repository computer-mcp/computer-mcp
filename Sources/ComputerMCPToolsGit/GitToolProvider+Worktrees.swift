import ComputerMCPCore
import ComputerMCPToolKit

extension GitToolProvider {
  static let lifecycleTools: Set<String> = [
    "git.worktree_add", "git.worktree_list", "git.worktree_remove", "git.merge",
    "git.branch_delete",
  ]

  func gitWorktree(_ name: String, arguments: [String: JSONValue]) throws -> JSONValue {
    guard let service = environment.worktrees else {
      throw GatewayToolError.disabled("Git lifecycle services require durable host storage.")
    }
    let operation: GitWorktreeOperation
    switch name {
    case "git.worktree_add":
      operation = .add(
        name: try requiredString("name", in: arguments),
        branch: try optionalString("branch", in: arguments),
        base: try optionalString("base", in: arguments))
    case "git.worktree_list": operation = .list
    case "git.worktree_remove":
      operation = .remove(force: try optionalBool("force", in: arguments) ?? false)
    case "git.merge": operation = .merge(branch: try requiredString("branch", in: arguments))
    case "git.branch_delete":
      let dryRun = try optionalBool("dry_run", in: arguments) ?? true
      let confirm = try optionalBool("confirm_delete", in: arguments) ?? false
      guard dryRun || confirm else {
        throw GatewayToolError.invalidArguments(
          "git.branch_delete requires confirm_delete=true when dry_run is false.")
      }
      operation = .deleteBranch(
        name: try requiredString("name", in: arguments),
        force: try optionalBool("force", in: arguments) ?? false, dryRun: dryRun, confirm: confirm)
    default: throw GatewayToolError.unknownTool(name)
    }
    return try service.call(operation)
  }

  static func lifecycleDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    func definition(
      _ name: String, _ description: String, properties: [String: JSONValue],
      required: [String] = [], readOnly: Bool = false, source: Bool = true
    ) -> ToolDefinition {
      .init(
        tool: .init(
          name: name, description: description,
          inputSchema: objectSchema(properties: properties, required: required),
          annotations: .init(
            readOnlyHint: readOnly, destructiveHint: !readOnly,
            idempotentHint: readOnly, openWorldHint: false), meta: toolMeta),
        capability: .init(
          id: name, risk: readOnly ? .readOnly : .projectWrite,
          requirement: .init(
            access: readOnly ? .read : (source ? .sourceProjectWrite : .projectWrite),
            paths: [.project(.read)]),
          projectRequirement: .required, localOnly: false, usesNetwork: false,
          hostOperation: .worktreeLifecycle))
    }
    return [
      definition(
        "git.worktree_add",
        "Create a persistent detached worktree and a new managed branch from the source project. Returns project_id, path, branch, base and submodule/LFS warnings.",
        properties: [
          "name": .object([
            "type": .string("string"),
            "description": .string("Worktree name: lowercase letters, digits and single hyphens."),
            "pattern": .string("^[a-z0-9]+(-[a-z0-9]+)*$"),
            "minLength": .number(1), "maxLength": .number(48),
          ]),
          "branch": stringSchema(
            "New branch name. Defaults to worktree/<name>; existing branches are refused."),
          "base": stringSchema(
            "Existing base branch. Defaults to the main checkout's branch; required when detached."),
        ], required: ["name"]),
      definition(
        "git.worktree_list",
        "List permission-filtered repository worktrees. Foreign base and comparison metrics are null when unavailable; unavailable explains missing state.",
        properties: [:], readOnly: true),
      definition(
        "git.worktree_remove",
        "Remove the current host worktree after terminating writers and preserving every private reference and reflog root. Keeps its branch and recovery records; force discards only uncommitted content. Returns project_id, branch, oid and terminationWarnings.",
        properties: ["force": boolSchema("Discard uncommitted content only. Defaults to false.")],
        source: false),
      definition(
        "git.merge",
        "Publish a host worktree branch and fast-forward the main checkout's current branch, which must be its recorded base. Call in the source project; refuses overwrites and non-fast-forward history.",
        properties: ["branch": stringSchema("Source host worktree branch to merge.")],
        required: ["branch"]),
    ]
  }
}
