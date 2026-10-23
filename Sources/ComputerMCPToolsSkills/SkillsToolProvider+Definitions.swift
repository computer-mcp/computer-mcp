import ComputerMCPCore

extension SkillsToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "skills.roots",
          description:
            "List skill roots configured on this main MCP gateway and their filesystem readiness. Any authorized MCP client, including ChatGPT or Codex, can use this independently of the coding provider. This does not read skill contents.",
          inputSchema: objectSchema(),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.roots", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.list",
          description:
            "List SKILL.md entries from skill roots configured on this main MCP gateway. Use skills.read to inspect a selected skill, then perform its instructions through tools on this gateway; do not assume a separate local or coding-provider execution path.",
          inputSchema: objectSchema(
            properties: [
              "root_id": stringSchema("Optional configured skill root id."),
              "max_results": integerSchema("Maximum skills to return. Defaults to 500."),
            ]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.list", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.describe",
          description:
            "Return a read-only package manifest for one configured local skill, including entrypoint metadata, resource directory counts, and follow-up contexts. This does not read file contents, execute scripts, or select skills semantically.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "max_depth": integerSchema(
                "Maximum recursive depth for package summary. Defaults to 6."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.describe", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.validate",
          description:
            "Mechanically validate one configured local skill package for required SKILL.md frontmatter, canonical naming hints, path readability, and symlink containment. This is read-only and does not execute bundled scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "max_bytes": integerSchema(
                "Maximum UTF-8 bytes of SKILL.md to inspect, capped by skills.max_bytes_per_skill."
              ),
              "max_depth": integerSchema(
                "Maximum recursive depth for package checks. Defaults to 6."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.validate", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.frontmatter",
          description:
            "Read leading YAML or TOML frontmatter from one Markdown file inside a configured local skill package. Defaults to SKILL.md, returns raw frontmatter plus parsed structured value when valid, and does not infer skill semantics, choose skills, or scan the Markdown body.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema(
                "Skill-relative Markdown file path to inspect. Defaults to SKILL.md."),
              "format": stringSchema(
                "Frontmatter format to accept: auto, yaml, or toml. Defaults to auto."
              ),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the source file, capped by skills.max_bytes_per_skill."
              ),
              "max_depth": integerSchema(
                "Maximum parsed YAML/TOML nesting depth. Defaults to 128."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.frontmatter", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.read",
          description:
            "Read the full bounded SKILL.md content for one skill configured on this main MCP gateway. This is read-only and does not execute scripts; follow the returned instructions by calling MCP tools through the same gateway, whether the client is ChatGPT, Codex, or another authorized MCP consumer.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "max_bytes": integerSchema(
                "Maximum UTF-8 bytes to read, capped by skills.max_bytes_per_skill."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.read", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.files",
          description:
            "List the complete bounded directory shape of one configured skill package, including references, scripts, agents, assets, and additional support directories. This main-gateway tool is client-neutral, read-only, and does not execute scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema(
                "Optional skill-relative directory path to list. Defaults to the skill root."),
              "include_hidden": boolSchema("Whether to include hidden files."),
              "max_depth": integerSchema("Maximum recursive depth. Defaults to 6."),
              "max_results": integerSchema("Maximum file entries to return. Defaults to 500."),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.files", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.read_file",
          description:
            "Read a bounded file from inside one configured local skill directory by skill-relative path. Supports utf8, base64, or auto output and rejects paths that escape the skill directory.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema("Skill-relative file path, such as references/guide.md."),
              "max_bytes": integerSchema(
                "Maximum bytes to read, capped by skills.max_bytes_per_skill."),
              "encoding": stringSchema("utf8, base64, or auto. Defaults to utf8."),
            ],
            required: ["name", "path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.read_file", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.read_files",
          description:
            "Read multiple bounded files from inside one configured local skill directory by explicit skill-relative paths. Supports uniform utf8, base64, or auto output, rejects paths that escape the skill directory, and does not execute scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "paths": stringArraySchema(
                "Skill-relative file paths to read. Must contain 1 to 50 values."),
              "max_bytes_per_file": integerSchema(
                "Maximum bytes to read per file, capped by skills.max_bytes_per_skill."),
              "encoding": stringSchema("utf8, base64, or auto. Defaults to utf8."),
            ],
            required: ["name", "paths"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.read_files", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.read_package",
          description:
            "Read a bounded snapshot of a complete configured skill package, including references, scripts, agents, assets, and other support files. This main-gateway tool is available to any authorized MCP client, is read-only and deterministic, and does not execute scripts or choose skills semantically.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema(
                "Optional skill-relative directory path to snapshot. Defaults to the skill root."
              ),
              "include_hidden": boolSchema("Whether to include hidden files."),
              "max_depth": integerSchema("Maximum recursive depth. Defaults to 6."),
              "max_files": integerSchema("Maximum file contents to return. Defaults to 100."),
              "max_bytes_per_file": integerSchema(
                "Maximum bytes to read per file, capped by skills.max_bytes_per_skill."),
              "max_total_bytes": integerSchema(
                "Maximum aggregate content bytes to return, capped by skills.max_bytes_per_skill."
              ),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              "encoding": stringSchema(
                "utf8, base64, or auto. Defaults to utf8; auto returns UTF-8 for text files and base64 for non-UTF-8 files."
              ),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.read_package", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.outline",
          description:
            "Return a bounded mechanical outline for one UTF-8 file inside a configured skill package, such as Markdown headings or source declarations. This is read-only, does not summarize content, and does not execute scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema(
                "Skill-relative file path to outline. Defaults to SKILL.md."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan, capped by skills.max_bytes_per_skill."),
              "max_results": integerSchema("Maximum outline items to return. Defaults to 200."),
              "include_imports": boolSchema(
                "Whether to include import/use/require statements for supported languages. Defaults to false."
              ),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.outline", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.section",
          description:
            "Extract one raw Markdown section by exact ATX heading text from one file inside a configured local skill package. Defaults to SKILL.md, uses explicit heading, optional level, and occurrence only, and does not search semantically, summarize, follow links, choose skills, or execute scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema(
                "Skill-relative Markdown file path to inspect. Defaults to SKILL.md."),
              "heading": stringSchema("Exact heading text as returned by skills.outline."),
              "level": integerSchema("Optional heading level from 1 to 6."),
              "occurrence": integerSchema(
                "One-based occurrence when the same heading appears more than once. Defaults to 1."
              ),
              "include_heading": boolSchema(
                "Whether to include the matched heading line in returned content. Defaults to true."
              ),
              "max_bytes": integerSchema(
                "Maximum Markdown bytes to scan from the file, capped by skills.max_bytes_per_skill."
              ),
              "max_section_bytes": integerSchema(
                "Maximum UTF-8 bytes of section content to return, capped by skills.max_bytes_per_skill."
              ),
            ],
            required: ["name", "heading"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.section", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.tables",
          description:
            "Extract bounded GitHub-flavored pipe tables from one Markdown file inside a configured local skill package. Defaults to SKILL.md, returns raw table rows plus mechanical execution contexts, and does not infer skill semantics or execute scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema(
                "Skill-relative Markdown file path to inspect. Defaults to SKILL.md."),
              "include_code_blocks": boolSchema(
                "Whether to scan fenced code blocks. Defaults to false."),
              "max_tables": integerSchema("Maximum tables to return. Defaults to 20."),
              "max_rows_per_table": integerSchema(
                "Maximum rows to return per table. Defaults to 100."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the source file, capped by skills.max_bytes_per_skill."
              ),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.tables", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.links",
          description:
            "Extract a bounded mechanical Markdown link inventory from one file inside a configured local skill package. Defaults to SKILL.md, resolves reference links when definitions are included, maps local targets to skill-relative paths, and does not fetch URLs, check existence, choose skills, or execute scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema(
                "Skill-relative Markdown file path to inspect. Defaults to SKILL.md."),
              "include_images": boolSchema("Whether to include image links. Defaults to true."),
              "include_reference_definitions": boolSchema(
                "Whether to include [label]: destination reference definitions and use them to resolve reference links. Defaults to true."
              ),
              "include_autolinks": boolSchema(
                "Whether to include angle-bracket autolinks such as <https://example.com>. Defaults to true."
              ),
              "include_code_blocks": boolSchema(
                "Whether to scan fenced code blocks. Defaults to false."),
              "max_links": integerSchema("Maximum links to return. Defaults to 200."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the source file, capped by skills.max_bytes_per_skill."
              ),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.links", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.link_check",
          description:
            "Check local Markdown links in one file inside a configured skill package. This resolves reference definitions, verifies targets stay inside the skill directory, checks local Markdown fragments when requested, and never fetches external URLs or executes scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "path": stringSchema(
                "Skill-relative Markdown file path to check. Defaults to SKILL.md."),
              "include_images": boolSchema("Whether to include image links. Defaults to true."),
              "include_reference_definitions": boolSchema(
                "Whether to include [label]: destination reference definitions as checked rows. Defaults to true."
              ),
              "include_autolinks": boolSchema(
                "Whether to include angle-bracket autolinks such as <https://example.com>. Defaults to true."
              ),
              "include_code_blocks": boolSchema(
                "Whether to scan fenced code blocks. Defaults to false."),
              "check_fragments": boolSchema(
                "Whether to check Markdown heading/id fragments for local Markdown targets. Defaults to true."
              ),
              "max_links": integerSchema("Maximum link checks to return. Defaults to 200."),
              "max_bytes": integerSchema(
                "Maximum bytes to scan from the source file, capped by skills.max_bytes_per_skill."
              ),
              "max_target_bytes": integerSchema(
                "Maximum bytes to scan from each Markdown target when checking fragments, capped by skills.max_bytes_per_skill."
              ),
            ],
            required: ["name"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.link_check", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.search",
          description:
            "Search configured local skills by deterministic substring matching over metadata and optionally bounded SKILL.md content. This is not semantic skill selection.",
          inputSchema: objectSchema(
            properties: [
              "query": stringSchema("Substring query."),
              "root_id": stringSchema("Optional configured skill root id."),
              "case_sensitive": boolSchema("Whether matching is case-sensitive."),
              "search_content": boolSchema(
                "Whether to search bounded SKILL.md content in addition to metadata. Defaults to false."
              ),
              "max_results": integerSchema("Maximum matches to return. Defaults to 100."),
              "max_bytes_per_skill": integerSchema(
                "Maximum bytes to read per skill when search_content is true, capped by skills.max_bytes_per_skill."
              ),
            ],
            required: ["query"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.search", risk: .readOnly,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "skills.search_files",
          description:
            "Search files inside one configured local skill package by deterministic substring matching over skill-relative paths and, when requested, bounded UTF-8 file content. This is read-only and does not execute scripts.",
          inputSchema: objectSchema(
            properties: [
              "name": stringSchema("Skill name or directory name."),
              "root_id": stringSchema(
                "Optional configured skill root id. Required when names are ambiguous."),
              "query": stringSchema("Substring query."),
              "case_sensitive": boolSchema("Whether matching is case-sensitive."),
              "search_content": boolSchema(
                "Whether to search bounded UTF-8 file content in addition to paths. Defaults to false."
              ),
              "max_depth": integerSchema("Maximum recursive depth. Defaults to 6."),
              "max_results": integerSchema(
                "Maximum matching files to return. Defaults to 100."),
              "max_matches_per_file": integerSchema(
                "Maximum content line matches per file. Defaults to 5."),
              "max_file_bytes": integerSchema(
                "Maximum bytes to read per file when search_content is true, capped by skills.max_bytes_per_skill. Defaults to 65536."
              ),
              "max_scan_entries": integerSchema(
                "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
            ],
            required: ["name", "query"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "skills.search_files", risk: .readOnly,
          projectRequirement: .none,
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
