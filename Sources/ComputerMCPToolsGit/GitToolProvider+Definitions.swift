import ComputerMCPCore

extension GitToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "git.root",
          description:
            "Return read-only git repository root and git-dir identity through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.root", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.config",
          description:
            "Return structured read-only Git configuration entries through the registered git CLI provider using fixed git config --list --show-origin --show-scope --null argv. Values are redacted by default, sensitive-looking values stay redacted even when include_values is true, and raw stdout is not returned.",
          inputSchema: objectSchema(
            properties: [
              "include_values": boolSchema(
                "Whether to include non-sensitive config values. Defaults to false."),
              "scope": stringSchema(
                "Optional scope filter: all, system, global, local, worktree, or command. Defaults to all."
              ),
              "max_results": integerSchema(
                "Maximum config entries to return. Defaults to 200."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.config", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.remotes",
          description:
            "Return read-only git remote URLs through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.remotes", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.worktrees",
          description:
            "Return read-only git worktree list through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.worktrees", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.stashes",
          description:
            "Return read-only git stash list through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.stashes", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.stash_show",
          description:
            "Return read-only details for one git stash through the registered git CLI provider. The stash ref is constrained to stash@{N}. When paths are supplied, the gateway uses fixed git diff argv so path filters are passed literally after --.",
          inputSchema: objectSchema(
            properties: [
              "stash": stringSchema(
                "Constrained stash ref in stash@{N} form. Defaults to stash@{0}."),
              "stat": boolSchema("Whether to include --stat output. Defaults to true."),
              "patch": boolSchema("Whether to include patch output."),
              "context_lines": integerSchema(
                "Optional patch context lines when patch is true, 0 through 100."),
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.stash_show", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.stash_push",
          description:
            "Create a git stash through the registered git CLI provider. This is a write operation that requires explicit paths or all_paths=true.",
          inputSchema: objectSchema(
            properties: [
              "message": stringSchema("Required stash message, up to 10000 characters."),
              "paths": stringArraySchema(
                "Literal workspace-relative paths passed after --. Required unless all_paths is true."
              ),
              "all_paths": boolSchema(
                "Whether to allow stashing all tracked workspace changes instead of passing explicit paths. Defaults to false."
              ),
              "include_untracked": boolSchema(
                "Whether to include untracked files with --include-untracked. Defaults to false."
              ),
              "keep_index": boolSchema(
                "Whether to keep staged changes in the index with --keep-index. Defaults to false."
              ),
              "dry_run": boolSchema(
                "Whether to preview matching workspace changes with git status --porcelain without creating a stash."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["message"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.stash_push", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.tags",
          description:
            "Return read-only git tag list through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.tags", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.tag_show",
          description:
            "Return read-only details for one local Git tag through the registered git CLI provider using fixed refs/tags/<name>. This does not accept arbitrary revisions, contact remotes, or change the index or working tree.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Required local tag name to inspect."),
              "stat": boolSchema(
                "Whether to include --stat output. Defaults to true; false uses --no-patch."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.tag_show", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.tag_create",
          description:
            "Create one lightweight local Git tag through the registered git CLI provider using fixed git tag <name> <target> argv. This does not sign, annotate, force-replace, push, fetch, or change the index or working tree. It defaults to gateway preflight dry-run and requires confirm_create=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Required local tag name to create."),
              "target": stringSchema(
                "Optional constrained Git object token to tag. Defaults to HEAD."),
              "dry_run": boolSchema(
                "Whether to run only gateway preflight checks without creating the tag. Defaults to true."
              ),
              "confirm_create": boolSchema(
                "Required as true when dry_run is false to create the tag."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.tag_create", risk: .workspaceWrite,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.tag_delete",
          description:
            "Delete one local Git tag through the registered git CLI provider using fixed git tag -d <name> argv. This does not push remote tag deletion, fetch, force-delete anything else, or change the index or working tree. It defaults to gateway preflight dry-run and requires confirm_delete=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Required local tag name to delete."),
              "dry_run": boolSchema(
                "Whether to run only gateway preflight checks without deleting the tag. Defaults to true."
              ),
              "confirm_delete": boolSchema(
                "Required as true when dry_run is false to delete the tag."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.tag_delete", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.ignored",
          description:
            "Return read-only git check-ignore output for explicit workspace-relative paths through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Required literal workspace-relative paths passed after --."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["paths"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.ignored", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.submodules",
          description:
            "Return read-only git submodule status through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.submodules", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.files",
          description:
            "Return read-only git tracked file index metadata through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.grep",
          description:
            "Search Git-tracked workspace content with fixed-string git grep through the registered git CLI provider. This is read-only, uses fixed argv, does not run shell commands, and returns file.read_lines context for selected matches.",
          inputSchema: objectSchema(
            properties: [
              "query": stringSchema("Required literal fixed string to search for."),
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "case_sensitive": boolSchema(
                "Whether matching is case-sensitive. Defaults to true."),
              "max_results": integerSchema(
                "Maximum parsed matches to return. Defaults to 200."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["query"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.grep", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.blame",
          description:
            "Return bounded read-only git blame output for one workspace-relative file through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Required literal workspace-relative file path passed after --."),
              "start_line": integerSchema("Optional one-based start line. Defaults to 1."),
              "max_lines": integerSchema(
                "Optional maximum line count, 1 through 1000. Defaults to 200."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.blame", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.file_history",
          description:
            "Return bounded read-only commit history for one workspace-relative file through the registered git CLI provider. Defaults to --follow and returns structured commit rows without changing refs or the working tree.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Required literal workspace-relative file path passed after --."),
              "limit": integerSchema(
                "Maximum history entries to ask Git for, 1 through 200. Defaults to 50."),
              "max_results": integerSchema(
                "Maximum parsed entries and raw lines to return, 1 through 200. Defaults to limit."
              ),
              "follow": boolSchema(
                "Whether to pass --follow to continue history across renames. Defaults to true."
              ),
              "include_merges": boolSchema(
                "Whether to include merge commits. Defaults to true."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.file_history", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.file_at_revision",
          description:
            "Return bounded UTF-8 content for one workspace-relative file at a constrained Git revision through the registered git CLI provider. This uses fixed git show <revision>:<path> argv and does not change refs or the working tree.",
          inputSchema: objectSchema(
            properties: [
              "revision": stringSchema(
                "Required constrained Git revision token such as HEAD, a branch or tag name, a remote branch, or a commit hash."
              ),
              "path": stringSchema(
                "Required literal workspace-relative file path read from that revision."),
              "max_bytes": integerSchema(
                "Maximum UTF-8 bytes of file content to return. Defaults to 65536 or policy.max_output_bytes if lower."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["revision", "path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.file_at_revision", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.staged_file",
          description:
            "Return bounded UTF-8 content for one workspace-relative file from the Git index through the registered git CLI provider. This uses fixed git show :<path> argv and does not change refs, the index, or the working tree.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Required literal workspace-relative file path read from the staged Git index."
              ),
              "max_bytes": integerSchema(
                "Maximum UTF-8 bytes of staged file content to return. Defaults to 65536 or policy.max_output_bytes if lower."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.staged_file", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.conflicts",
          description:
            "Return read-only git unmerged index entries through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.conflicts", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.status",
          description:
            "Return read-only git status through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.status", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.tracking_status",
          description:
            "Return structured read-only current Git branch/upstream tracking status by parsing git status --branch --porcelain=v1. This does not fetch, pull, or push.",
          inputSchema: objectSchema(
            properties: [
              "timeout_ms": integerSchema("Optional timeout in milliseconds.")
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.tracking_status", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.clean_preview",
          description:
            "Preview untracked files/directories Git would remove by running git clean --dry-run -d through the registered git CLI provider. This does not delete files.",
          inputSchema: objectSchema(
            properties: [
              "include_ignored": boolSchema(
                "Whether to include ignored files using -x. Defaults to false."),
              "ignored_only": boolSchema(
                "Whether to preview only ignored files using -X. Cannot be combined with include_ignored."
              ),
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "max_results": integerSchema(
                "Maximum parsed preview rows and raw lines to return, 1 through 5000. Defaults to 200."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.clean_preview", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.clean",
          description:
            "Remove untracked files/directories through the registered git CLI provider using git clean. This is destructive, defaults to dry-run, requires explicit paths or all_paths=true, and requires confirm_delete=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --. Cannot be combined with all_paths=true."
              ),
              "all_paths": boolSchema(
                "Whether to clean the whole repository instead of explicit paths. Defaults to false."
              ),
              "include_ignored": boolSchema(
                "Whether to include ignored files using -x. Defaults to false."),
              "ignored_only": boolSchema(
                "Whether to clean only ignored files using -X. Cannot be combined with include_ignored."
              ),
              "dry_run": boolSchema(
                "Whether to preview with git clean --dry-run without deleting files. Defaults to true."
              ),
              "confirm_delete": boolSchema(
                "Required as true when dry_run is false to delete untracked files/directories."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.clean", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.reflog",
          description:
            "Return bounded read-only local Git reflog entries for HEAD through the registered git CLI provider. This does not change refs or the working tree.",
          inputSchema: objectSchema(
            properties: [
              "limit": integerSchema(
                "Maximum reflog entries to ask Git for, 1 through 200. Defaults to 50."),
              "max_results": integerSchema(
                "Maximum parsed entries and raw lines to return, 1 through 200. Defaults to limit."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.reflog", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.refs",
          description:
            "Return a bounded read-only inventory of local Git branch, remote branch, and tag refs through the registered git CLI provider. This does not change refs or the working tree.",
          inputSchema: objectSchema(
            properties: [
              "include_branches": boolSchema(
                "Whether to include refs/heads local branches. Defaults to true."),
              "include_remotes": boolSchema(
                "Whether to include refs/remotes remote-tracking branches. Defaults to true."),
              "include_tags": boolSchema("Whether to include refs/tags. Defaults to false."),
              "limit": integerSchema(
                "Maximum refs to ask Git for, 1 through 1000. Defaults to 200."),
              "max_results": integerSchema(
                "Maximum parsed refs and raw lines to return, 1 through 1000. Defaults to limit."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.refs", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.compare_refs",
          description:
            "Return bounded read-only topology for two Git refs through the registered git CLI provider: base/head ahead-behind counts, merge base, and limited left-right commit rows. This does not fetch, push, merge, or change refs.",
          inputSchema: objectSchema(
            properties: [
              "base": stringSchema(
                "Required base ref, branch, tag, HEAD, or commit hash. Passed as a constrained Git revision token."
              ),
              "head": stringSchema(
                "Required head ref, branch, tag, HEAD, or commit hash. Passed as a constrained Git revision token."
              ),
              "limit": integerSchema(
                "Maximum left-right commit rows to ask Git for, 1 through 200. Defaults to 20."
              ),
              "max_results": integerSchema(
                "Maximum parsed commit rows and raw lines to return, 1 through 200. Defaults to limit."
              ),
              "cherry_pick": boolSchema(
                "Whether to pass --cherry-pick to suppress equivalent patch changes. Defaults to false."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["base", "head"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.compare_refs", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.resolve_ref",
          description:
            "Resolve one constrained Git ref, branch, tag, HEAD, or commit hash to an object id and object type through the registered git CLI provider using fixed git rev-parse and git cat-file argv. This does not fetch, push, merge, or change refs.",
          inputSchema: objectSchema(
            properties: [
              "ref": stringSchema(
                "Required ref, branch, tag, HEAD, or commit hash. Passed as a constrained Git revision token."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["ref"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.resolve_ref", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.merge_base",
          description:
            "Return read-only Git merge base object ids for 2 to 16 constrained refs through the registered git CLI provider using fixed git merge-base argv. Exit code 1 is reported as has_merge_base=false. This does not fetch, push, merge, or change refs.",
          inputSchema: objectSchema(
            properties: [
              "refs": stringArraySchema(
                "Required constrained Git refs, branches, tags, HEAD, or commit hashes. Must contain 2 to 16 values."
              ),
              "all": boolSchema("Whether to pass --all and return all best merge bases."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["refs"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.merge_base", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.is_ancestor",
          description:
            "Return whether one constrained Git ref is an ancestor of another through the registered git CLI provider using fixed git merge-base --is-ancestor argv. This does not fetch, push, merge, or change refs.",
          inputSchema: objectSchema(
            properties: [
              "ancestor": stringSchema(
                "Required ancestor candidate ref, branch, tag, HEAD, or commit hash. Passed as a constrained Git revision token."
              ),
              "descendant": stringSchema(
                "Required descendant candidate ref, branch, tag, HEAD, or commit hash. Passed as a constrained Git revision token."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["ancestor", "descendant"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.is_ancestor", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.diff",
          description:
            "Return read-only git diff through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "staged": boolSchema("Whether to diff staged changes with --cached."),
              "stat": boolSchema("Whether to return --stat output."),
              "context_lines": integerSchema(
                "Optional unified diff context lines, 0 through 100."),
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.diff", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.diff_summary",
          description:
            "Return structured read-only git diff file-level numstat and summary metadata through the registered git CLI provider. Use git.diff for raw patch text.",
          inputSchema: objectSchema(
            properties: [
              "staged": boolSchema("Whether to summarize staged changes with --cached."),
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "max_results": integerSchema(
                "Maximum file and summary rows to return, 1 through 5000. Defaults to 200."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.diff_summary", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.diff_check",
          description:
            "Run read-only git diff --check through the registered git CLI provider and return structured whitespace/conflict-marker issue lines plus bounded raw output.",
          inputSchema: objectSchema(
            properties: [
              "staged": boolSchema("Whether to check staged changes with --cached."),
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "max_results": integerSchema(
                "Maximum parsed issue rows and raw lines to return, 1 through 5000. Defaults to 200."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.diff_check", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.branch",
          description:
            "Return read-only git branch information through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "all": boolSchema("Whether to include all branches."),
              "verbose": boolSchema("Whether to include verbose branch details."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.branch", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.branch_create",
          description:
            "Create a local Git branch through the registered git CLI provider using fixed git branch <name> <start_point> argv. This does not checkout, fetch, push, set upstreams, or change working-tree files. It defaults to dry-run and requires confirm_create=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Required local branch name to create."),
              "start_point": stringSchema(
                "Optional constrained commit-ish ref to create from. Defaults to HEAD."),
              "dry_run": boolSchema(
                "Whether to run only preflight checks without creating the branch. Defaults to true."
              ),
              "confirm_create": boolSchema(
                "Required as true when dry_run is false to create the branch."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.branch_create", risk: .workspaceWrite,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.branch_delete",
          description:
            "Delete one local Git branch through the registered git CLI provider using fixed git branch -d/-D <name> argv. This does not checkout, fetch, push, delete remotes, or change working-tree files. It refuses to delete the current branch, defaults to dry-run, and requires confirm_delete=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Required local branch name to delete."),
              "force": boolSchema(
                "Whether to use git branch -D instead of -d. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to run only preflight checks without deleting the branch. Defaults to true."
              ),
              "confirm_delete": boolSchema(
                "Required as true when dry_run is false to delete the branch."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.branch_delete", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.branch_rename",
          description:
            "Rename one local Git branch through the registered git CLI provider using fixed git branch -m/-M <old_name> <new_name> argv. This does not checkout, fetch, push, set upstreams, delete remotes, or change working-tree files. It defaults to dry-run and requires confirm_rename=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "old_name": stringSchema("Required existing local branch name to rename."),
              "new_name": stringSchema("Required new local branch name."),
              "force": boolSchema(
                "Whether to use git branch -M instead of -m when the target branch exists. Defaults to false."
              ),
              "dry_run": boolSchema(
                "Whether to run only preflight checks without renaming the branch. Defaults to true."
              ),
              "confirm_rename": boolSchema(
                "Required as true when dry_run is false to rename the branch."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["old_name", "new_name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.branch_rename", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.branch_switch",
          description:
            "Switch to one existing local Git branch through the registered git CLI provider using fixed git switch --no-guess <name> argv. This does not create, fetch, guess remote branches, detach HEAD, force checkout, discard changes, merge, push, or set upstreams. It defaults to gateway preflight dry-run and requires confirm_switch=true when dry_run is false. Dirty working trees require allow_dirty=true.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Required existing local branch name to switch to."),
              "dry_run": boolSchema(
                "Whether to run only gateway preflight checks without switching. Defaults to true."
              ),
              "confirm_switch": boolSchema(
                "Required as true when dry_run is false to switch branches."),
              "allow_dirty": boolSchema(
                "Required as true when dry_run is false and the working tree has changes. Defaults to false."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.branch_switch", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.log",
          description:
            "Return bounded read-only git history through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "limit": integerSchema("Maximum commits to return, 1 through 200."),
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.log", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.commit_files",
          description:
            "Return bounded read-only file change metadata for one constrained Git revision through the registered git CLI provider. This uses fixed git show -s and git diff-tree --name-status -M argv and does not change refs, the index, or the working tree.",
          inputSchema: objectSchema(
            properties: [
              "revision": stringSchema(
                "Required constrained Git revision token such as HEAD, a branch or tag name, a remote branch, or a commit hash."
              ),
              "max_results": integerSchema(
                "Maximum parsed file change rows and raw records to return, 1 through 5000. Defaults to 200."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["revision"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.commit_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.show",
          description:
            "Return bounded read-only git object details through the registered git CLI provider.",
          inputSchema: objectSchema(
            properties: [
              "revision": stringSchema("Revision or object name. Defaults to HEAD."),
              "stat": boolSchema("Whether to include --stat output when patch is false."),
              "patch": boolSchema("Whether to include patch output."),
              "context_lines": integerSchema(
                "Optional patch context lines when patch is true, 0 through 100."),
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.show", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.add",
          description:
            "Stage explicit workspace-relative paths through the registered git CLI provider. This is a write operation.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Required literal workspace-relative paths passed after --."),
              "intent_to_add": boolSchema("Whether to use --intent-to-add."),
              "dry_run": boolSchema(
                "Whether to preview with git add --dry-run without changing the index."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["paths"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.add", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.unstage",
          description:
            "Unstage explicit workspace-relative paths through the registered git CLI provider using git restore --staged. This is a write operation on the Git index.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Required literal workspace-relative paths passed after --."),
              "dry_run": boolSchema(
                "Whether to preview staged path matches with git diff --cached --name-only without changing the index."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["paths"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.unstage", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.restore_worktree",
          description:
            "Discard unstaged working-tree changes for explicit workspace-relative paths through the registered git CLI provider using git restore --worktree. This is a destructive write operation and requires confirm_discard=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Required literal workspace-relative paths passed after --."),
              "dry_run": boolSchema(
                "Whether to preview matching unstaged path changes with git diff --name-only without changing files. Defaults to true."
              ),
              "confirm_discard": boolSchema(
                "Required as true when dry_run is false to discard working-tree changes."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["paths"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.restore_worktree", risk: .destructive,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "git.commit",
          description:
            "Create a git commit through the registered git CLI provider. This is a write operation.",
          inputSchema: objectSchema(
            properties: [
              "message": stringSchema("Commit message, up to 10000 characters."),
              "all": boolSchema("Whether to stage tracked modifications with --all."),
              "allow_empty": boolSchema("Whether to allow an empty commit."),
              "dry_run": boolSchema(
                "Whether to run git commit --dry-run without creating a commit."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["message"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "git.commit", risk: .workspaceWrite,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
    ]
  }

  private static func objectSchema(
    properties: [String: JSONValue] = [:],
    required: [String] = []
  ) -> JSONValue {
    var object: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
      object["required"] = .array(required.map { .string($0) })
    }
    return .object(object)
  }

  private static func stringSchema(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
  }

  private static func integerSchema(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
  }

  private static func boolSchema(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
  }

  private static func stringArraySchema(_ description: String) -> JSONValue {
    .object([
      "type": .string("array"),
      "items": .object(["type": .string("string")]),
      "description": .string(description),
    ])
  }
}
