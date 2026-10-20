import ComputerMCPCore

extension WorkspaceToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.info",
          description:
            "Return a non-secret summary of the configured gateway workspace, policy, and providers.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.info", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.status",
          description:
            "Return read-only workspace root status, bounded top-level entry counts, and local VCS marker presence without reading file contents.",
          inputSchema: objectSchema(
            properties: [
              "include_hidden": boolSchema("Whether to include hidden top-level entries."),
              "max_entries": integerSchema(
                "Maximum top-level entries to scan before truncating. Defaults to 5000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.status", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.manifests",
          description:
            "Return existence/type metadata for a fixed catalog of common workspace manifest and config markers without reading file contents or inferring project type.",
          inputSchema: objectSchema(
            properties: [
              "include_missing": boolSchema(
                "Whether to include catalog entries that do not exist. Defaults to false."),
              "max_results": integerSchema(
                "Maximum catalog entries to return before truncating. Defaults to the catalog size."
              ),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.manifests", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.recent_files",
          description:
            "Return a bounded list of recently modified regular files under the configured workspace using filesystem metadata only. This does not read file contents, run Git, or infer project semantics.",
          inputSchema: objectSchema(
            properties: [
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_results": integerSchema(
                "Maximum recent files to return after sorting. Defaults to 25."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.recent_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.directory_stats",
          description:
            "Return bounded directory-level shape statistics grouped by the first child under a workspace-contained path. Counts files, directories, symlinks, bytes, and common workspace file categories using metadata only. This does not read file contents, infer architecture, or run tools.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative directory path. Defaults to workspace root."),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth per group. Defaults to 4."),
              "max_results": integerSchema(
                "Maximum directory groups to return after sorting. Defaults to 100."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.directory_stats", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.artifact_directories",
          description:
            "Return a bounded metadata-only list of common generated, build output, cache, dependency install, coverage, and temporary directories under a workspace-contained path. This does not read contents, run cleanup commands, or delete anything.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative directory path. Defaults to workspace root."),
              "include_hidden": boolSchema(
                "Whether to include hidden artifact/cache directories such as .build and .cache. Defaults to true."
              ),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum directories to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.artifact_directories", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.empty_directories",
          description:
            "Return a bounded list of actually empty directories under a workspace-contained path using filesystem metadata only. This does not delete directories, run cleanup commands, or treat directories containing hidden entries as empty.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative directory path. Defaults to workspace root."),
              "include_hidden": boolSchema(
                "Whether to include hidden directories in traversal/results. Defaults to false."
              ),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum empty directories to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.empty_directories", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.git_changes",
          description:
            "Return structured workspace-relative Git working tree change entries using fixed git status porcelain output through the registered git CLI provider. This does not read file contents, run diff, or infer tasks.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Optional literal workspace-relative paths passed after --."),
              "max_results": integerSchema(
                "Maximum change entries to return after parsing. Defaults to 200."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.git_changes", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.file_types",
          description:
            "Return a bounded extension histogram for regular files under the configured workspace using filesystem metadata only. This does not read file contents or infer project semantics.",
          inputSchema: objectSchema(
            properties: [
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_groups": integerSchema(
                "Maximum extension groups to return after sorting. Defaults to 50."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.file_types", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.large_files",
          description:
            "Return a bounded list of largest regular files under the configured workspace using filesystem metadata only. This does not read file contents, delete files, or run cleanup commands.",
          inputSchema: objectSchema(
            properties: [
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_results": integerSchema(
                "Maximum files to return after sorting by size. Defaults to 25."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.large_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.symlinks",
          description:
            "Return a bounded list of symbolic links under the configured workspace, including raw destinations and target containment metadata. This does not read target contents or follow links for execution.",
          inputSchema: objectSchema(
            properties: [
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_results": integerSchema(
                "Maximum symlinks to return after sorting by workspace path. Defaults to 100."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.symlinks", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.executable_files",
          description:
            "Return a bounded list of executable regular files under the configured workspace using filesystem metadata only. This does not read file contents, infer script language, or execute files.",
          inputSchema: objectSchema(
            properties: [
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_results": integerSchema(
                "Maximum executable files to return after sorting by workspace path. Defaults to 100."
              ),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 10000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.executable_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.todos",
          description:
            "Search the configured workspace for common TODO-style marker tokens using bounded UTF-8 file reads. This returns mechanical line matches and does not summarize, infer priority, or execute commands.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "markers": stringArraySchema(
                "Optional literal marker tokens to search for. Defaults to TODO, FIXME, HACK, and XXX."
              ),
              "case_sensitive": boolSchema(
                "Whether marker matching is case-sensitive. Defaults to false."),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_files": integerSchema("Optional scanned file cap. Defaults to 500."),
              "max_matches": integerSchema("Optional match cap. Defaults to 100."),
              "max_bytes_per_file": integerSchema(
                "Optional per-file read cap in bytes. Defaults to 1048576."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.todos", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.env_files",
          description:
            "Find workspace env files such as .env and .env.local and return only variable key metadata. Values are always redacted and never returned.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden_directories": boolSchema(
                "Whether to recurse into hidden directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
              "max_files": integerSchema("Optional env file cap. Defaults to 100."),
              "max_keys_per_file": integerSchema(
                "Optional key cap per env file. Defaults to 200."),
              "max_bytes_per_file": integerSchema(
                "Optional per-file read cap in bytes. Defaults to 262144."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.env_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.dependency_files",
          description:
            "Find common package manifest, dependency, lock, and checksum files under the workspace using filename metadata only. This does not read file contents, parse dependencies, or run package managers.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.dependency_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.project_roots",
          description:
            "Group common dependency manifest, lock, requirements, and checksum files by containing directory to find candidate project roots using filename metadata only. This does not read manifests, infer build graphs, or run package managers.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
              "max_results": integerSchema(
                "Maximum candidate project roots to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.project_roots", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.documentation_files",
          description:
            "Find README, AGENTS, CONTRIBUTING, SECURITY, SUPPORT, changelog, license, and docs-directory documentation files under the workspace using filename metadata only. This does not read contents, summarize documents, or infer policy.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.documentation_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.agent_files",
          description:
            "Find workspace agent instruction and skill entrypoint files such as AGENTS.md, CLAUDE.md, GEMINI.md, .github/copilot-instructions.md, Cursor/Windsurf rules, and skills/*/SKILL.md using path metadata only. This does not read instruction contents; use each row's file.read context to inspect selected files through the gateway.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to true because many agent instruction files live under hidden config directories."
              ),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 100."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.agent_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.instructions",
          description:
            "Return the bounded agent instruction files that apply to a target workspace path by walking from the workspace root to that path's scope directory. This reads only fixed instruction filenames and rule directories, does not summarize or merge instructions, and returns apply_order for the MCP consumer.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root. The path may be a future file that does not exist yet."
              ),
              "path_is_directory": boolSchema(
                "Whether to treat path as a directory. Defaults to filesystem metadata when the path exists, otherwise false unless path ends with '/'."
              ),
              "include_content": boolSchema(
                "Whether to include bounded UTF-8 instruction content. Defaults to true."),
              "max_bytes_per_file": integerSchema(
                "Maximum instruction bytes to read per file. Defaults to 65536."),
              "max_results": integerSchema(
                "Maximum instruction files to return. Defaults to 50."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.instructions", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.test_files",
          description:
            "Find likely test/spec files under the workspace using path and filename metadata only. This does not read file contents, infer test frameworks, or run tests.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.test_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.ci_files",
          description:
            "Find common CI/CD and hosted build pipeline configuration files under the workspace using path and filename metadata only. This does not read YAML or JSON contents, infer pipeline semantics, or run automation.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to true because many CI configs live under hidden config directories."
              ),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.ci_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.infra_files",
          description:
            "Find likely infrastructure, deployment, container, orchestration, and platform configuration files such as Dockerfile, docker-compose, devcontainer, Kubernetes manifests, Helm charts, Terraform, Packer, Nomad, Pulumi, Serverless, Cloudflare Wrangler, Vercel, Netlify, Fly, Render, Railway, and Procfile using filename, extension, and infra-directory metadata only. This does not read config contents, parse IaC, infer topology, validate manifests, or run deployment tools; use returned context objects for explicit follow-up inspection through the gateway.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false, but .devcontainer is scanned because it is a common infra directory."
              ),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.infra_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.config_files",
          description:
            "Find common editor, formatter, linter, toolchain, and build-tool configuration files under the workspace using path and filename metadata only. This does not read config contents, infer rules, or run tools.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to true because many config files are dotfiles."
              ),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.config_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.ignore_files",
          description:
            "Find common ignore-rule files such as .gitignore, .dockerignore, .rgignore, .prettierignore, deployment ignore files, and agent context ignore files using path metadata only. This does not parse ignore rules, decide whether a path is ignored, or read file contents; use each row's file.read context to inspect selected files through the gateway.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to true because ignore files are usually dotfiles."
              ),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.ignore_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.asset_files",
          description:
            "Find common project asset files such as images, icons, fonts, audio, video, PDFs, presentations, and design-source files under the workspace using extension and path metadata only. This does not read asset contents, generate previews, inspect dimensions, or infer usage.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 500."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.asset_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.archive_files",
          description:
            "Find common archive, compressed stream, installer, disk image, and application package files under the workspace using extension and path metadata only. This does not list archive entries, extract files, inspect package manifests, or read contents; use returned archive.list context for supported formats.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 500."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.archive_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.log_files",
          description:
            "Find likely log, process output, trace, and crash-report files under the workspace using filename, extension, and logs-directory metadata only. This does not read log contents, infer severity, summarize events, or follow live streams; use returned file.tail or file.search context for explicit follow-up inspection.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 500."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.log_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.data_files",
          description:
            "Find common data artifacts such as CSV, TSV, JSONL, SQLite, DuckDB, Parquet, Arrow, Avro, ORC, Excel, and structured files in data-like directories using path and extension metadata only. This does not read data contents, infer schemas, count rows, sample values, or inspect databases; use returned context objects for explicit follow-up inspection through the gateway.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 500."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.data_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.schema_files",
          description:
            "Find likely API, interface, data, and database schema/contract files such as OpenAPI, Swagger, AsyncAPI, GraphQL, Protocol Buffers, JSON Schema, Avro schema, Prisma, WSDL, XSD, Thrift, FlatBuffers, and SQL migrations using filename, extension, and schema-directory metadata only. This does not read schema contents, validate contracts, infer models, or inspect databases; use returned context objects for explicit follow-up inspection through the gateway.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 500."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.schema_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.source_files",
          description:
            "Find likely source, script, component, markup, style, header, and query files under the workspace using file extension and path metadata only. This does not read source contents, infer architecture, or run tools. Tests are excluded by default; use include_tests when needed.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "include_tests": boolSchema(
                "Whether to include files that also match workspace.test_files. Defaults to false."
              ),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema(
                "Maximum matching files to return after sorting. Defaults to 500."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.source_files", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.outline",
          description:
            "Return a bounded mechanical outline across outline-capable workspace files by extracting Markdown headings and common source declarations. This does not summarize, infer architecture, build a semantic graph, or run tools.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative directory or file path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "include_tests": boolSchema("Whether to include test files. Defaults to false."),
              "include_imports": boolSchema(
                "Whether to include import/use/require statements. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_files": integerSchema(
                "Maximum outline-capable files to read. Defaults to 200."),
              "max_items": integerSchema(
                "Maximum outline items to return across files. Defaults to 1000."),
              "max_bytes_per_file": integerSchema(
                "Maximum bytes to scan per file. Defaults to 262144."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.outline", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.commands",
          description:
            "Find deterministic project command entrypoints from common workspace manifests such as package.json scripts, Makefile targets, Justfile recipes, and standard SwiftPM/Cargo/Go commands. This reads only bounded manifest bytes, does not execute commands, and returns cli.exec context plus whether the suggested CLI provider is registered.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative file or directory path. Defaults to workspace root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files and directories. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 4."),
              "max_results": integerSchema(
                "Maximum command entries to return after sorting. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              "max_bytes_per_file": integerSchema(
                "Maximum manifest bytes to read per file. Defaults to 262144."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.commands", risk: .readOnly,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.open",
          description: "Open the configured workspace or an in-workspace path with macOS open.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative path. Defaults to workspace root."),
              "application": stringSchema("Optional macOS application name for open -a."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.open", risk: .workspaceWrite,
          workspaceRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "workspace.reveal",
          description: "Reveal a workspace-contained path in Finder using macOS open -R.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional workspace-relative path. Defaults to workspace root."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "workspace.reveal", risk: .workspaceWrite,
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
