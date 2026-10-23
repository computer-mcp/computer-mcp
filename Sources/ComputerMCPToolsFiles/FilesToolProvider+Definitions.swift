import ComputerMCPCore

extension FilesToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "file.exists",
          description:
            "Check whether a project-contained path exists without treating absence as an error.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path.")
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.exists", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.list",
          description:
            "List entries under a project-contained directory with deterministic ordering and bounded output.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional project-relative or in-project absolute directory path. Defaults to project root."
              ),
              "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
              "recursive_depth": integerSchema(
                "Optional recursive depth. Defaults to 0 for direct children only."),
              "max_entries": integerSchema("Optional entry cap. Defaults to 200."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.list", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.tree",
          description:
            "Return a bounded hierarchical tree for a project-contained directory. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional project-relative or in-project absolute directory path. Defaults to project root."
              ),
              "include_hidden": boolSchema(
                "Whether to include hidden files. Defaults to false."),
              "max_depth": integerSchema("Maximum child depth to traverse. Defaults to 2."),
              "max_entries": integerSchema("Maximum tree nodes to return. Defaults to 500."),
              "directories_only": boolSchema(
                "Whether to include only directories. Defaults to false."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.tree", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.stat",
          description:
            "Return file metadata for a project-contained path without reading file content.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path.")
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.stat", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.permissions",
          description:
            "Return POSIX mode, owner/group, current-process access, and common macOS file flags for a project-contained path. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path.")
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.permissions", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.chmod",
          description:
            "Set the POSIX mode for a project-contained path without invoking chmod. This is non-recursive.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path."),
              "mode": stringSchema(
                "3- or 4-digit octal POSIX mode, for example 0644 or 0755."),
              "expected_current_mode": stringSchema(
                "Optional 3- or 4-digit octal mode assertion before changing permissions."),
              "dry_run": boolSchema(
                "Whether to validate the mode change without changing permissions. Defaults to false."
              ),
            ],
            required: ["path", "mode"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.chmod", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.type",
          description:
            "Return MIME type and charset for a project-contained file using fixed /usr/bin/file -b --mime argv. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.type", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.count",
          description:
            "Return line, word, and byte counts for a project-contained file using fixed /usr/bin/wc -l -w -c argv. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.count", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.disk_usage",
          description:
            "Return disk usage for a project-contained file or directory using fixed /usr/bin/du -sk argv. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.disk_usage", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.volume_info",
          description:
            "Return the mounted volume and filesystem capability metadata for a project-contained path using Foundation URL resource values. This is read-only and does not run shell commands.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional project-relative or in-project absolute path. Defaults to project root."
              )
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.volume_info", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.find",
          description:
            "Find project-contained paths by file or directory name using bounded deterministic traversal.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional project-relative directory path. Defaults to project root."),
              "query": stringSchema("Name query to match."),
              "match": stringSchema("Match mode: contains, prefix, suffix, or exact."),
              "case_sensitive": boolSchema("Whether name matching is case-sensitive."),
              "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema("Optional result cap. Defaults to 200."),
              "max_visited": integerSchema("Optional visited-entry cap. Defaults to 20000."),
            ],
            required: ["query"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.find", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.search",
          description:
            "Search UTF-8 text content under a project-contained path with bounded files, bytes, and matches.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional project-relative file or directory path. Defaults to project root."
              ),
              "query": stringSchema("Text query to search for."),
              "case_sensitive": boolSchema("Whether text matching is case-sensitive."),
              "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_files": integerSchema("Optional scanned file cap. Defaults to 500."),
              "max_matches": integerSchema("Optional match cap. Defaults to 100."),
              "max_bytes_per_file": integerSchema(
                "Optional per-file read cap in bytes. Defaults to 1048576."),
            ],
            required: ["query"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.search", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.timeline",
          description:
            "List regular files under a project-contained directory by modification time with optional ISO8601 modified_after/modified_before filters. This is read-only, uses filesystem metadata only, and does not infer recency semantics.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Optional project-relative directory path. Defaults to project root."),
              "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
              "modified_after": stringSchema(
                "Optional inclusive ISO8601 lower modification-time bound, such as 2026-07-09T00:00:00Z."
              ),
              "modified_before": stringSchema(
                "Optional inclusive ISO8601 upper modification-time bound, such as 2026-07-10T00:00:00Z."
              ),
              "sort": stringSchema(
                "Sort order: modified_desc, modified_asc, or path. Defaults to modified_desc."),
              "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
              "max_results": integerSchema("Optional result cap. Defaults to 200."),
              "max_scan_entries": integerSchema(
                "Optional scanned-entry cap. Defaults to 20000."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.timeline", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.read",
          description: "Read a UTF-8 file under the configured project directory.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "max_bytes": integerSchema("Optional maximum bytes to return."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.read", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.read_files",
          description:
            "Read multiple explicitly named project-contained files in one call. This is read-only, supports uniform utf8 or base64 output, and does not search, infer, or follow references.",
          inputSchema: objectSchema(
            properties: [
              "paths": stringArraySchema(
                "Project-relative or in-project absolute file paths. Must contain 1 to 50 values."
              ),
              "max_bytes_per_file": integerSchema(
                "Maximum bytes to read per file. Defaults to policy.max_output_bytes."),
              "encoding": stringSchema("utf8 or base64. Defaults to utf8."),
            ],
            required: ["paths"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.read_files", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.read_window",
          description:
            "Read a UTF-8 text byte window from a project-contained file using offset_bytes and max_bytes. This is read-only and reports whether the selected byte window is valid UTF-8.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "offset_bytes": integerSchema(
                "Zero-based byte offset where reading starts. Defaults to 0."),
              "max_bytes": integerSchema(
                "Maximum bytes to read from the offset. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.read_window", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.read_lines",
          description:
            "Read a bounded UTF-8 line range from a project-contained file.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "start_line": integerSchema("One-based starting line. Defaults to 1."),
              "max_lines": integerSchema("Maximum lines to return. Defaults to 200."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the start of the file."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.read_lines", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.read_context",
          description:
            "Read bounded UTF-8 line context around a one-based target line in a project-contained file.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "line": integerSchema("One-based target line number."),
              "before": integerSchema("Number of lines before the target line. Defaults to 5."),
              "after": integerSchema("Number of lines after the target line. Defaults to 5."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
              ),
            ],
            required: ["path", "line"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.read_context", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.head",
          description:
            "Read the first lines from a project-contained UTF-8 file using a bounded byte window.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "max_lines": integerSchema("Maximum head lines to return. Defaults to 200."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
              ),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.head", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.outline",
          description:
            "Return a bounded mechanical outline for a project-contained UTF-8 file by extracting Markdown headings and common source declaration lines. This does not summarize, infer architecture, or build a semantic graph.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative file path."),
              "include_imports": boolSchema(
                "Whether to include import/package/use/mod lines. Defaults to false."),
              "max_results": integerSchema(
                "Maximum outline items to return. Defaults to 200."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
              ),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.outline", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.tail",
          description:
            "Read the last lines from a project-contained UTF-8 file using a bounded tail window.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "max_lines": integerSchema("Maximum tail lines to return. Defaults to 200."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the end of the file."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.tail", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.hexdump",
          description:
            "Read a bounded byte window from a project-contained file and return deterministic hex/ascii rows. This is read-only and useful for binary inspection.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "offset_bytes": integerSchema("Starting byte offset. Defaults to 0."),
              "max_bytes": integerSchema("Maximum bytes to return. Defaults to 256."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.hexdump", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.xattrs",
          description:
            "List extended attributes for a project-contained file or directory, with optional bounded value previews. This is read-only and useful for macOS metadata such as quarantine flags and Finder tags.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path."),
              "include_values": boolSchema(
                "Whether to include bounded attribute value previews. Defaults to false."),
              "max_value_bytes": integerSchema(
                "Maximum attribute value size to read when include_values is true. Larger values are reported as truncated without reading. Defaults to 1024."
              ),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.xattrs", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.remove_xattr",
          description:
            "Remove one extended attribute from a project-contained path using the macOS xattr API. This is non-recursive.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path."),
              "name": stringSchema("Extended attribute name to remove."),
              "dry_run": boolSchema(
                "Whether to validate the removal without deleting the extended attribute. Defaults to false."
              ),
            ],
            required: ["path", "name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.remove_xattr", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.metadata",
          description:
            "Read Spotlight metadata for a project-contained file or directory using fixed /usr/bin/mdls -plist argv. This is read-only and macOS-specific.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path."),
              "attributes": stringArraySchema(
                "Optional Spotlight metadata attribute names to return after plist parsing."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.metadata", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.readlink",
          description:
            "Read the raw destination of a project-contained symbolic link without following the final link. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute symlink path.")
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.readlink", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.resolve",
          description:
            "Resolve a project-contained path mechanically, preserving the final symlink for inspection and reporting whether the resolved destination remains in the project.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute path.")
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.resolve", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.hash",
          description:
            "Compute a SHA-256 hash for a project-contained file without returning content.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "algorithm": stringSchema("Hash algorithm. Only sha256 is currently supported."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.hash", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.diff",
          description:
            "Return a bounded unified diff between two project-contained files using fixed /usr/bin/diff argv. This is read-only.",
          inputSchema: objectSchema(
            properties: [
              "source": stringSchema(
                "Project-relative or in-project absolute source file."),
              "target": stringSchema(
                "Project-relative or in-project absolute target file."),
              "context_lines": integerSchema("Unified diff context lines. Defaults to 3."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ],
            required: ["source", "target"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.diff", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.compare_trees",
          description:
            "Compare two project-contained directory trees by relative path using bounded deterministic traversal. Defaults to metadata-only comparison; set compare_hashes=true to SHA-256 compare same-size files within explicit hash limits. This is read-only and does not run shell commands.",
          inputSchema: objectSchema(
            properties: [
              "left": stringSchema(
                "Project-relative or in-project absolute left directory."),
              "right": stringSchema(
                "Project-relative or in-project absolute right directory."),
              "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
              "max_depth": integerSchema("Maximum recursive depth. Defaults to 8."),
              "max_entries": integerSchema(
                "Maximum entries to scan per tree. Defaults to 20000."),
              "max_results": integerSchema(
                "Maximum difference rows to return. Defaults to 200."),
              "compare_hashes": boolSchema(
                "Whether to SHA-256 compare same-size files within hash limits. Defaults to false."
              ),
              "max_hash_files": integerSchema(
                "Maximum files to hash when compare_hashes is true. Defaults to 1000."),
              "max_hash_file_bytes": integerSchema(
                "Maximum bytes per file eligible for hashing. Defaults to 10485760."),
            ],
            required: ["left", "right"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.compare_trees", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.duplicates",
          description:
            "Find duplicate regular files under a project-contained directory by size bucket and bounded SHA-256 hashing. This is read-only, skips symlinks, does not delete files, and returns deterministic duplicate groups plus follow-up contexts.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute directory. Defaults to project root."
              ),
              "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
              "min_size_bytes": integerSchema(
                "Minimum file size eligible for duplicate detection. Defaults to 1."),
              "max_depth": integerSchema("Maximum recursive depth. Defaults to 8."),
              "max_entries": integerSchema(
                "Maximum filesystem entries to scan. Defaults to 20000."),
              "max_hash_files": integerSchema(
                "Maximum candidate files to hash. Defaults to 5000."),
              "max_hash_file_bytes": integerSchema(
                "Maximum bytes per file eligible for hashing. Defaults to 10485760."),
              "max_groups": integerSchema(
                "Maximum duplicate groups to return. Defaults to 100."),
              "max_files_per_group": integerSchema(
                "Maximum files to return per duplicate group. Defaults to 20."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.duplicates", risk: .readOnly,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "archive.list",
          description:
            "List entries in a project-contained zip or tar archive using fixed read-only argv. This does not extract files.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute archive path."),
              "max_entries": integerSchema("Maximum entries to return. Defaults to 1000."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "archive.list", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "archive.read_file",
          description:
            "Read one file member from a project-contained zip or tar archive using fixed read-only argv, returning UTF-8 text or base64 bytes. This streams the selected member to stdout without extracting files or writing to disk. Entry paths are normalized and must not be directories, absolute paths, parent escapes, option-like names, or archive wildcard patterns.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute archive path."),
              "entry": stringSchema("Archive member path to read."),
              "encoding": stringSchema(
                "utf8, base64, or auto. Defaults to utf8. Use base64 for binary members."),
              "max_bytes": integerSchema(
                "Maximum stdout bytes to capture from the member. Defaults to policy.max_output_bytes."
              ),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
            ],
            required: ["path", "entry"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "archive.read_file", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "archive.extract",
          description:
            "Extract a project-contained zip or tar archive using fixed argv. Defaults to dry-run; validates one listing, refuses unsafe paths, links and special files, extracts once into staging inside the destination, checks the tree, preserves member modification times, and publishes with anchored renames. Requires confirm_extract=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute archive path."),
              "destination": stringSchema(
                "Project-relative or in-project absolute destination directory."),
              "create_directories": boolSchema(
                "Whether to create the destination directory if missing. Defaults to false."),
              "overwrite": boolSchema(
                "Whether extraction may overwrite existing destination paths. Defaults to false."
              ),
              "dry_run": boolSchema(
                "Whether to validate and preview extraction without writing files. Defaults to true."
              ),
              "confirm_extract": boolSchema(
                "Required as true when dry_run is false to extract files."),
              "max_entries": integerSchema(
                "Maximum archive entries to validate, 1 through 100000. Defaults to 100000."),
              "max_preview_entries": integerSchema(
                "Maximum validated entries to return, 0 through 5000. Defaults to 100."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum list/extract stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
              ),
            ],
            required: ["path", "destination"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "archive.extract", risk: .destructive,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "archive.create",
          description:
            "Create a zip or tar archive from explicit project-contained sources using fixed argv. This defaults to dry-run, refuses symlink sources/entries, prevents output inside sources, and requires confirm_create=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute output archive path."),
              "sources": stringArraySchema(
                "Project-relative or in-project absolute source files/directories to archive."
              ),
              "format": stringSchema(
                "Optional archive family, zip or tar. When omitted it is inferred from the path suffix."
              ),
              "create_directories": boolSchema(
                "Whether to create the archive parent directory if missing. Defaults to false."),
              "overwrite": boolSchema(
                "Whether an existing archive file may be replaced. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to validate and preview archive creation without writing files. Defaults to true."
              ),
              "confirm_create": boolSchema(
                "Required as true when dry_run is false to create the archive."),
              "max_entries": integerSchema(
                "Maximum source entries to validate, 1 through 100000. Defaults to 100000."),
              "max_preview_entries": integerSchema(
                "Maximum source entries to return, 0 through 5000. Defaults to 100."),
              "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              "max_output_bytes": integerSchema(
                "Maximum create stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
              ),
            ],
            required: ["path", "sources"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "archive.create", risk: .destructive,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.download",
          description:
            "Download an absolute HTTP or HTTPS URL to a project-contained file using fixed /usr/bin/curl argv. This defaults to dry-run, streams into a host-opened temporary descriptor and rechecks the destination, rejects credentials in URLs, sends no custom headers/cookies/request body, and requires confirm_download=true when dry_run is false.",
          inputSchema: objectSchema(
            properties: [
              "url": stringSchema("Absolute http or https URL to download."),
              "path": stringSchema(
                "Project-relative or in-project absolute destination file path."),
              "create_directories": boolSchema(
                "Whether to create the destination parent directory if missing. Defaults to false."
              ),
              "overwrite": boolSchema(
                "Whether an existing destination file may be replaced. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to validate and preview download without writing files. Defaults to true."
              ),
              "confirm_download": boolSchema(
                "Required as true when dry_run is false to write the downloaded file."),
              "follow_redirects": boolSchema(
                "Whether curl should follow redirects. Defaults to false."),
              "max_redirects": integerSchema(
                "Maximum redirects when following. Defaults to 5."),
              "connect_timeout_seconds": integerSchema(
                "Connection timeout in seconds. Defaults to 5; max 60."),
              "timeout_ms": integerSchema(
                "Process timeout in milliseconds. Defaults to 30000."),
              "max_download_bytes": integerSchema(
                "Maximum downloaded file size in bytes. Defaults to 10485760."),
              "max_output_bytes": integerSchema(
                "Maximum curl stdout/stderr bytes per stream. Defaults to a small metadata allowance."
              ),
            ],
            required: ["url", "path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.download", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: true
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.write",
          description:
            "Write UTF-8 content to a file under the configured project directory.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "content": stringSchema("UTF-8 content to write."),
              "overwrite": boolSchema(
                "Whether to overwrite an existing file. Defaults to true."),
              "create_directories": boolSchema(
                "Whether to create missing parent directories. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to validate the write without creating directories or writing content. Defaults to false."
              ),
              "include_preview": boolSchema(
                "Whether to include a bounded content preview. Defaults to dry_run."),
              "preview_max_bytes": integerSchema(
                "Maximum UTF-8 bytes for the content preview. Defaults to 8192."),
            ],
            required: ["path", "content"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.write", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.write_files",
          description:
            "Write multiple explicitly named UTF-8 files under the configured project directory. Defaults to dry-run and requires confirm_write=true for real writes.",
          inputSchema: objectSchema(
            properties: [
              "files": .object([
                "type": .string("array"),
                "description": .string(
                  "File entries to write. Each entry must be an object with path and content. Must contain 1 to 50 entries."
                ),
                "items": .object([
                  "type": .string("object"),
                  "additionalProperties": .bool(false),
                  "properties": .object([
                    "path": stringSchema(
                      "Project-relative or in-project absolute file path."),
                    "content": stringSchema("UTF-8 content to write."),
                  ]),
                  "required": .array([.string("path"), .string("content")]),
                ]),
              ]),
              "overwrite": boolSchema(
                "Whether existing files may be replaced. Defaults to false."),
              "create_directories": boolSchema(
                "Whether to create missing parent directories. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to validate and preview without writing files. Defaults to true."),
              "confirm_write": boolSchema(
                "Required as true when dry_run is false to write files."),
              "include_preview": boolSchema(
                "Whether to include bounded content previews. Defaults to dry_run."),
              "preview_max_bytes": integerSchema(
                "Maximum UTF-8 bytes per content preview. Defaults to 8192."),
            ],
            required: ["files"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.write_files", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.append",
          description:
            "Append UTF-8 content to a project-contained file without rewriting existing content.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "content": stringSchema("UTF-8 content to append."),
              "create_if_missing": boolSchema(
                "Whether to create the file when it is missing. Defaults to true."),
              "create_directories": boolSchema(
                "Whether to create missing parent directories. Defaults to false."),
              "append_newline": boolSchema(
                "Whether to append a newline after content. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to validate the append without creating the file/directories or writing content. Defaults to false."
              ),
              "include_preview": boolSchema(
                "Whether to include a bounded content preview. Defaults to dry_run."),
              "preview_max_bytes": integerSchema(
                "Maximum UTF-8 bytes for the content preview. Defaults to 8192."),
            ],
            required: ["path", "content"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.append", risk: .projectWrite,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.replace_text",
          description:
            "Perform exact UTF-8 text replacement in a project-contained file without semantic editing.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "search": stringSchema("Non-empty exact text to find."),
              "replacement": stringSchema("Replacement text. May be empty."),
              "replace_all": boolSchema(
                "Whether to replace all non-overlapping matches. Defaults to false."),
              "expected_replacements": integerSchema(
                "Optional exact number of replacements that must be performed."),
              "dry_run": boolSchema(
                "Whether to validate match counts and preview the replacement without writing. Defaults to false."
              ),
              "include_preview": boolSchema(
                "Whether to include bounded search/replacement text previews. Defaults to dry_run."
              ),
              "preview_max_bytes": integerSchema(
                "Maximum UTF-8 bytes per preview string. Defaults to 8192."),
              "max_bytes": integerSchema(
                "Maximum file bytes to read and edit. Defaults to policy.max_output_bytes."),
            ],
            required: ["path", "search", "replacement"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.replace_text", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.insert_text",
          description:
            "Insert exact UTF-8 text before or after a one-based line in a project-contained file.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "line": integerSchema("One-based target line number. Defaults to 1."),
              "content": stringSchema("UTF-8 text to insert."),
              "position": stringSchema("before or after. Defaults to before."),
              "expected_line": stringSchema(
                "Optional exact target line text assertion before inserting."),
              "append_newline": boolSchema(
                "Whether to append a newline to inserted content if missing. Defaults to true."),
              "dry_run": boolSchema(
                "Whether to validate and preview the insertion without writing. Defaults to false."
              ),
              "include_preview": boolSchema(
                "Whether to include bounded target-line/inserted-content previews. Defaults to dry_run."
              ),
              "preview_max_bytes": integerSchema(
                "Maximum UTF-8 bytes per preview string. Defaults to 8192."),
              "max_bytes": integerSchema(
                "Maximum file bytes to read and edit. Defaults to policy.max_output_bytes."),
            ],
            required: ["path", "content"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.insert_text", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.replace_lines",
          description:
            "Replace or delete an exact one-based line range in a project-contained UTF-8 file without semantic editing.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "start_line": integerSchema("One-based first line to replace."),
              "end_line": integerSchema("One-based last line to replace, inclusive."),
              "content": stringSchema("Replacement UTF-8 text. May be empty to delete lines."),
              "expected_content": stringSchema(
                "Optional exact selected-line text assertion before replacing."),
              "append_newline": boolSchema(
                "Whether to append a newline to non-empty replacement content if missing. Defaults to true."
              ),
              "dry_run": boolSchema(
                "Whether to validate and preview the replacement without writing. Defaults to false."
              ),
              "include_preview": boolSchema(
                "Whether to include bounded selected/replacement text previews. Defaults to dry_run."
              ),
              "preview_max_bytes": integerSchema(
                "Maximum UTF-8 bytes per preview string. Defaults to 8192."),
              "max_bytes": integerSchema(
                "Maximum file bytes to read and edit. Defaults to policy.max_output_bytes."),
            ],
            required: ["path", "start_line", "end_line", "content"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.replace_lines", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.touch",
          description:
            "Create an empty project-contained file if missing or update an existing file modification time.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative or in-project absolute file path."),
              "create_if_missing": boolSchema(
                "Whether to create an empty file when the path is missing. Defaults to true."),
              "create_directories": boolSchema(
                "Whether to create missing parent directories. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to validate the touch without creating the file/directories or updating timestamps. Defaults to false."
              ),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.touch", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.mkdir",
          description: "Create a directory under the configured project directory.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute directory path."),
              "intermediate_directories": boolSchema(
                "Whether to create missing parent directories. Defaults to true."),
              "dry_run": boolSchema(
                "Whether to validate directory creation without creating directories. Defaults to false."
              ),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.mkdir", risk: .projectWrite,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.copy",
          description:
            "Copy a file or directory between two project-contained paths. On macOS preserves data, extended attributes, resource forks, ACLs, mode and times. Does not overwrite unless requested.",
          inputSchema: objectSchema(
            properties: [
              "source": stringSchema(
                "Project-relative or in-project absolute source path."),
              "destination": stringSchema(
                "Project-relative or in-project absolute destination path."),
              "overwrite": boolSchema(
                "Whether to overwrite an existing destination. Defaults to false."),
              "create_directories": boolSchema(
                "Whether to create missing destination parent directories. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to validate the copy without creating directories, overwriting, or copying content. Defaults to false."
              ),
            ],
            required: ["source", "destination"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.copy", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.move",
          description:
            "Move or rename a file or directory between two project-contained paths. Does not overwrite unless requested.",
          inputSchema: objectSchema(
            properties: [
              "source": stringSchema(
                "Project-relative or in-project absolute source path."),
              "destination": stringSchema(
                "Project-relative or in-project absolute destination path."),
              "overwrite": boolSchema(
                "Whether to overwrite an existing destination. Defaults to false."),
              "create_directories": boolSchema(
                "Whether to create missing destination parent directories. Defaults to false."),
              "dry_run": boolSchema(
                "Whether to validate the move without creating directories, overwriting, moving, or removing the source. Defaults to false."
              ),
            ],
            required: ["source", "destination"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.move", risk: .destructive,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.symlink",
          description:
            "Create a symbolic link at a project-contained path. By default the destination must resolve inside the project.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute path where the symlink will be created."
              ),
              "destination": stringSchema(
                "Raw symlink destination string. Relative destinations are resolved from the link parent for containment checks."
              ),
              "overwrite": boolSchema(
                "Whether to overwrite an existing destination path. Defaults to false."),
              "create_directories": boolSchema(
                "Whether to create missing link parent directories. Defaults to false."),
              "allow_external_destination": boolSchema(
                "Whether to allow the symlink destination to resolve outside the project. Defaults to false."
              ),
              "dry_run": boolSchema(
                "Whether to validate symlink creation without creating directories, overwriting, or creating the link. Defaults to false."
              ),
            ],
            required: ["path", "destination"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
          ),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.symlink", risk: .projectWrite,
          projectRequirement: .required,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "file.trash",
          description:
            "Move a project-contained file or directory to the macOS Trash. Refuses the project root and checks every member for protected paths and unsafe types before the platform move. Allows multiply linked regular files. This is a write operation.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute path to trash."),
              "dry_run": boolSchema(
                "Whether to validate the trash operation without moving the path to Trash. Defaults to false."
              ),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "file.trash", risk: .destructive,
          projectRequirement: .required,
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
