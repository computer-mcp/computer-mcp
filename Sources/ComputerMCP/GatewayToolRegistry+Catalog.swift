import Foundation

extension GatewayToolRegistry {
  internal static func gatewayTools(
    shellEnabled: Bool,
    builtins: Set<String>,
    skillsEnabled: Bool,
    hasCLIProviders: Bool,
    hasMCPProviders: Bool,
    toolMeta: JSONValue?
  ) -> [MCPTool] {
    var tools = [
      MCPTool(
        name: "cli.list",
        description: "List CLI executables registered in the local gateway configuration.",
        inputSchema: objectSchema(),
        meta: toolMeta
      ),
      MCPTool(
        name: "cli.describe",
        description:
          "Describe a registered CLI provider, its mechanical interface, and any declared CLI Tree source.",
        inputSchema: objectSchema(
          properties: ["id": stringSchema("Registered CLI id.")],
          required: ["id"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "cli.status",
        description:
          "Report whether registered CLI provider executables can be resolved without invoking their command trees.",
        inputSchema: objectSchema(
          properties: ["id": stringSchema("Optional registered CLI id. Omit to inspect all.")]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "cli.help",
        description:
          "Return declared metadata for a file-backed CLI Tree path without executing it. For a CLI without a tree, return raw help and follow-up cli.exec context. Executable tree exporters are not run by this read-only tool.",
        inputSchema: objectSchema(
          properties: [
            "id": stringSchema("Registered CLI id."),
            "path": stringArraySchema("Command path before --help."),
            "timeout_ms": integerSchema("Optional timeout in milliseconds."),
          ],
          required: ["id"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "cli.exec",
        description:
          "Execute explicit argv for a registered CLI that grants unrestricted arguments. Tree-backed CLIs use their projected typed tools. Keep execution inside this gateway's authorization boundary.",
        inputSchema: objectSchema(
          properties: [
            "id": stringSchema("Registered CLI id."),
            "argv": stringArraySchema("Argument vector passed to the executable."),
            "timeout_ms": integerSchema("Optional timeout in milliseconds."),
          ],
          required: ["id", "argv"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.servers.list",
        description: "List downstream MCP servers registered in the local gateway.",
        inputSchema: objectSchema(),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.servers.status",
        description:
          "Report deterministic downstream MCP provider readiness metadata without starting servers or calling tools.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Optional registered MCP server id. Omit to inspect all.")
          ]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.tools.list",
        description: "List tools from one registered downstream MCP server.",
        inputSchema: objectSchema(
          properties: ["server": stringSchema("Registered MCP server id.")],
          required: ["server"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.tools.describe",
        description:
          "Return the exact definition and input schema for one downstream MCP tool by name, plus call_context for mcp.tools.call. This is deterministic exact matching, not semantic tool selection.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "tool": stringSchema("Exact downstream tool name."),
          ],
          required: ["server", "tool"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.tools.find",
        description:
          "Filter tools from one registered downstream MCP server by deterministic string matching over name and description.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "query": stringSchema("String query to match."),
            "match": stringSchema("Match mode: contains, prefix, suffix, or exact."),
            "field": stringSchema("Field to match: name, description, or all."),
            "case_sensitive": boolSchema("Whether matching is case-sensitive."),
            "max_results": integerSchema("Optional result cap. Defaults to 50."),
          ],
          required: ["server", "query"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.tools.call",
        description:
          "Call a tool on one registered downstream MCP server. A request_id deduplicates the exact input across synchronous and asynchronous calls. Set wait_for_result to false to return after dispatch; query the retained result with mcp.requests.read or request cancellation with mcp.requests.cancel.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "tool": stringSchema("Downstream tool name."),
            "workspace_id": stringSchema(
              "Stable workspace id returned by workspace.list. Required for host-service calls when multiple workspaces are registered."
            ),
            "request_id": stringSchema(
              "Optional caller-stable deduplication id, at most 256 UTF-8 bytes. Reuse only for identical inputs; query using mcp.requests.read. Required when wait_for_result is false."
            ),
            "wait_for_result": boolSchema(
              "Whether to wait for the downstream result. Defaults to true. When false, request_id is required and the call returns after the request starts."
            ),
            "arguments": .object([
              "type": .string("object"),
              "description": .string("Arguments passed to the downstream tool."),
              "additionalProperties": .bool(true),
            ]),
          ],
          required: ["server", "tool"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.resources.list",
        description:
          "List resources from one registered downstream MCP server through resources/list. Returned resources include read_context for mcp.resources.read when a URI is present.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "cursor": stringSchema("Optional downstream pagination cursor."),
          ],
          required: ["server"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.resources.templates.list",
        description:
          "List resource templates from one registered downstream MCP server through resources/templates/list. This does not expand URI templates.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "cursor": stringSchema("Optional downstream pagination cursor."),
          ],
          required: ["server"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.resources.read",
        description:
          "Read one resource URI from a registered downstream MCP server through resources/read. The gateway forwards the URI exactly and does not interpret it locally.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "uri": stringSchema("Exact downstream resource URI."),
          ],
          required: ["server", "uri"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.prompts.list",
        description:
          "List prompts from one registered downstream MCP server through prompts/list. Returned prompts include get_context for mcp.prompts.get when a name is present.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "cursor": stringSchema("Optional downstream pagination cursor."),
          ],
          required: ["server"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.prompts.get",
        description:
          "Get one prompt from a registered downstream MCP server through prompts/get. Prompt arguments, when provided, must be string values and are forwarded exactly.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "name": stringSchema("Exact downstream prompt name."),
            "arguments": .object([
              "type": .string("object"),
              "description": .string(
                "Optional downstream prompt arguments. Values must be strings."),
              "additionalProperties": .object(["type": .string("string")]),
            ]),
          ],
          required: ["server", "name"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.events.read",
        description:
          "Read cursor-paginated list-changed and connection events from one persistent downstream MCP session.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "session_id": stringSchema(
              "Session identity from a previous event page. Supply it when continuing a cursor so a replaced session cannot be mistaken for the original. Reading events never starts a server."
            ),
            "after_cursor": integerSchema(
              "Return events after this cursor. Defaults to 0."
            ),
            "max_results": integerSchema(
              "Maximum events to return from 1 through 500. Defaults to 100."
            ),
          ],
          required: ["server"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.requests.list",
        description:
          "List currently active tool requests on one persistent downstream MCP session.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id.")
          ],
          required: ["server"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.requests.cancel",
        description:
          "Send the MCP cancellation notification for one active downstream tool request.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "request_id": stringSchema(
              "Caller-stable request id supplied to mcp.tools.call."
            ),
            "reason": stringSchema("Optional human-readable cancellation reason."),
          ],
          required: ["server", "request_id"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "mcp.connections.close",
        description:
          "Close one exact retained MCP connection and join its managed-process teardown. This stops all work on that connection, not just the locating resource. Requires a live owner selected through runtime.owners.call; use that same owner for operations.prepare/commit when approval is required. Remote or detached work may remain uncertain; transport closure does not prove work stopped.",
        inputSchema: objectSchema(
          properties: ["server": stringSchema("Registered MCP server id of the selected owner.")],
          required: ["server"]),
        meta: toolMeta),
      MCPTool(
        name: "mcp.requests.read",
        description:
          "Read a retained MCP execution result without starting a connection or replaying work. Continue with next_offset for bounded JSON output; expired, unavailable and unknown outcomes are explicit.",
        inputSchema: objectSchema(
          properties: [
            "server": stringSchema("Registered MCP server id."),
            "request_id": stringSchema("Caller-stable request id supplied to mcp.tools.call."),
            "offset": integerSchema("UTF-8 byte offset returned as next_offset. Defaults to zero."),
            "max_bytes": integerSchema(
              "Maximum output bytes from 4 through 65536. Defaults to 32768."),
          ],
          required: ["server", "request_id"]),
        meta: toolMeta),
      MCPTool(
        name: "process.spawn",
        description: "Spawn a registered CLI command for long-running work.",
        inputSchema: objectSchema(
          properties: [
            "id": stringSchema("Registered CLI id."),
            "argv": stringArraySchema("Argument vector passed to the executable."),
          ],
          required: ["id", "argv"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "process.list",
        description:
          "List gateway-managed process sessions spawned through process.spawn. Does not inspect the OS process table.",
        inputSchema: objectSchema(),
        meta: toolMeta
      ),
      MCPTool(
        name: "process.read",
        description: "Read buffered stdout/stderr and status for a spawned process.",
        inputSchema: objectSchema(
          properties: ["process_id": stringSchema("Process id returned by process.spawn.")],
          required: ["process_id"]
        ),
        meta: toolMeta
      ),
      MCPTool(
        name: "process.cancel",
        description: "Terminate a spawned process.",
        inputSchema: objectSchema(
          properties: ["process_id": stringSchema("Process id returned by process.spawn.")],
          required: ["process_id"]
        ),
        meta: toolMeta
      ),
    ]

    if !hasCLIProviders {
      tools.removeAll { $0.name.hasPrefix("cli.") || $0.name.hasPrefix("process.") }
    }
    if !hasMCPProviders {
      tools.removeAll { $0.name.hasPrefix("mcp.") }
    }

    if skillsEnabled {
      tools.append(
        contentsOf: [
          MCPTool(
            name: "skills.roots",
            description:
              "List skill roots configured on this main MCP gateway and their filesystem readiness. Any authorized MCP client, including ChatGPT or Codex, can use this independently of the coding provider. This does not read skill contents.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ),
          MCPTool(
            name: "skills.list",
            description:
              "List SKILL.md entries from skill roots configured on this main MCP gateway. Use skills.read to inspect a selected skill, then perform its instructions through tools on this gateway; do not assume a separate local or coding-provider execution path.",
            inputSchema: objectSchema(
              properties: [
                "root_id": stringSchema("Optional configured skill root id."),
                "max_results": integerSchema("Maximum skills to return. Defaults to 500."),
              ]
            ),
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
            meta: toolMeta
          ),
          MCPTool(
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
                "max_results": integerSchema("Maximum matching files to return. Defaults to 100."),
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
            meta: toolMeta
          ),
        ]
      )
    }

    if shellEnabled {
      tools.append(
        contentsOf: [
          MCPTool(
            name: "shell.run",
            description:
              "Run one Full Shell command synchronously through this MCP gateway. Supports shell-script or explicit argv mode, cwd, environment, bounded stdout/stderr, timeout, and process-group cancellation. This grants the caller the effective authority of the current macOS user and is exposed only when the active profile enables Full Shell.",
            inputSchema: shellLaunchSchema(includeTimeout: true, includeStandardInput: true),
            meta: toolMeta
          ),
          MCPTool(
            name: "shell.spawn",
            description:
              "Start a long-lived Full Shell session through this MCP gateway. Continue interacting only through shell.write, shell.read, and shell.cancel using the returned session_id.",
            inputSchema: shellLaunchSchema(includeTimeout: true, includeStandardInput: false),
            meta: toolMeta
          ),
          MCPTool(
            name: "shell.list",
            description:
              "List gateway-owned Full Shell sessions and their lifecycle state. This does not inspect unrelated operating-system processes.",
            inputSchema: objectSchema(
              properties: [
                "max_bytes": integerSchema(
                  "Optional output bytes per stream. Defaults to 0 for metadata only."
                ),
                "encoding": stringSchema("utf8 or base64. Defaults to utf8."),
              ]
            ),
            meta: toolMeta
          ),
          MCPTool(
            name: "shell.read",
            description:
              "Read incremental stdout and stderr from a gateway-owned Full Shell session using absolute byte cursors. Use returned next_cursor values for the next MCP call.",
            inputSchema: objectSchema(
              properties: [
                "session_id": stringSchema("Session id returned by shell.spawn."),
                "stdout_cursor": integerSchema("Absolute stdout byte cursor. Defaults to 0."),
                "stderr_cursor": integerSchema("Absolute stderr byte cursor. Defaults to 0."),
                "max_bytes": integerSchema(
                  "Maximum bytes returned per stream. Defaults to policy.max_output_bytes."
                ),
                "encoding": stringSchema("utf8 or base64. Defaults to utf8."),
              ],
              required: ["session_id"]
            ),
            meta: toolMeta
          ),
          MCPTool(
            name: "shell.write",
            description:
              "Write UTF-8 text or Base64 bytes to a gateway-owned Full Shell session stdin and optionally close stdin. All interaction remains inside this MCP gateway.",
            inputSchema: objectSchema(
              properties: [
                "session_id": stringSchema("Session id returned by shell.spawn."),
                "text": stringSchema("Optional UTF-8 input."),
                "base64": stringSchema("Optional Base64-encoded binary input."),
                "close": boolSchema("Close stdin after writing. Defaults to false."),
              ],
              required: ["session_id"]
            ),
            meta: toolMeta
          ),
          MCPTool(
            name: "shell.cancel",
            description:
              "Terminate a gateway-owned Full Shell process group, escalating from SIGTERM to SIGKILL after the configured grace period.",
            inputSchema: objectSchema(
              properties: [
                "session_id": stringSchema("Session id returned by shell.spawn.")
              ],
              required: ["session_id"]
            ),
            meta: toolMeta
          ),
        ]
      )
    }

    for builtin in builtins.sorted() {
      switch builtin {
      case "workspace.info":
        tools.append(
          MCPTool(
            name: "workspace.info",
            description:
              "Return a non-secret summary of the configured gateway workspace, policy, and providers.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "workspace.status":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.manifests":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.recent_files":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.directory_stats":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.artifact_directories":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.empty_directories":
        tools.append(
          MCPTool(
            name: "workspace.empty_directories",
            description:
              "Return a bounded list of actually empty directories under a workspace-contained path using filesystem metadata only. This does not delete directories, run cleanup commands, or treat directories containing hidden entries as empty.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden directories in traversal/results. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                "max_results": integerSchema(
                  "Maximum empty directories to return after sorting. Defaults to 200."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.git_changes":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.file_types":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.large_files":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.symlinks":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.executable_files":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.todos":
        tools.append(
          MCPTool(
            name: "workspace.todos",
            description:
              "Search the configured workspace for common TODO-style marker tokens using bounded UTF-8 file reads. This returns mechanical line matches and does not summarize, infer priority, or execute commands.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.env_files":
        tools.append(
          MCPTool(
            name: "workspace.env_files",
            description:
              "Find workspace env files such as .env and .env.local and return only variable key metadata. Values are always redacted and never returned.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.dependency_files":
        tools.append(
          MCPTool(
            name: "workspace.dependency_files",
            description:
              "Find common package manifest, dependency, lock, and checksum files under the workspace using filename metadata only. This does not read file contents, parse dependencies, or run package managers.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
                "max_results": integerSchema(
                  "Maximum matching files to return after sorting. Defaults to 200."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.project_roots":
        tools.append(
          MCPTool(
            name: "workspace.project_roots",
            description:
              "Group common dependency manifest, lock, requirements, and checksum files by containing directory to find candidate project roots using filename metadata only. This does not read manifests, infer build graphs, or run package managers.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
                "max_results": integerSchema(
                  "Maximum candidate project roots to return after sorting. Defaults to 200."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.documentation_files":
        tools.append(
          MCPTool(
            name: "workspace.documentation_files",
            description:
              "Find README, AGENTS, CONTRIBUTING, SECURITY, SUPPORT, changelog, license, and docs-directory documentation files under the workspace using filename metadata only. This does not read contents, summarize documents, or infer policy.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 6."),
                "max_results": integerSchema(
                  "Maximum matching files to return after sorting. Defaults to 200."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.agent_files":
        tools.append(
          MCPTool(
            name: "workspace.agent_files",
            description:
              "Find workspace agent instruction and skill entrypoint files such as AGENTS.md, CLAUDE.md, GEMINI.md, .github/copilot-instructions.md, Cursor/Windsurf rules, and skills/*/SKILL.md using path metadata only. This does not read instruction contents; use each row's file.read context to inspect selected files through the gateway.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.instructions":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.test_files":
        tools.append(
          MCPTool(
            name: "workspace.test_files",
            description:
              "Find likely test/spec files under the workspace using path and filename metadata only. This does not read file contents, infer test frameworks, or run tests.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                "max_results": integerSchema(
                  "Maximum matching files to return after sorting. Defaults to 200."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.ci_files":
        tools.append(
          MCPTool(
            name: "workspace.ci_files",
            description:
              "Find common CI/CD and hosted build pipeline configuration files under the workspace using path and filename metadata only. This does not read YAML or JSON contents, infer pipeline semantics, or run automation.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.infra_files":
        tools.append(
          MCPTool(
            name: "workspace.infra_files",
            description:
              "Find likely infrastructure, deployment, container, orchestration, and platform configuration files such as Dockerfile, docker-compose, devcontainer, Kubernetes manifests, Helm charts, Terraform, Packer, Nomad, Pulumi, Serverless, Cloudflare Wrangler, Vercel, Netlify, Fly, Render, Railway, and Procfile using filename, extension, and infra-directory metadata only. This does not read config contents, parse IaC, infer topology, validate manifests, or run deployment tools; use returned context objects for explicit follow-up inspection through the gateway.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.config_files":
        tools.append(
          MCPTool(
            name: "workspace.config_files",
            description:
              "Find common editor, formatter, linter, toolchain, and build-tool configuration files under the workspace using path and filename metadata only. This does not read config contents, infer rules, or run tools.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.ignore_files":
        tools.append(
          MCPTool(
            name: "workspace.ignore_files",
            description:
              "Find common ignore-rule files such as .gitignore, .dockerignore, .rgignore, .prettierignore, deployment ignore files, and agent context ignore files using path metadata only. This does not parse ignore rules, decide whether a path is ignored, or read file contents; use each row's file.read context to inspect selected files through the gateway.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.asset_files":
        tools.append(
          MCPTool(
            name: "workspace.asset_files",
            description:
              "Find common project asset files such as images, icons, fonts, audio, video, PDFs, presentations, and design-source files under the workspace using extension and path metadata only. This does not read asset contents, generate previews, inspect dimensions, or infer usage.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                "max_results": integerSchema(
                  "Maximum matching files to return after sorting. Defaults to 500."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.archive_files":
        tools.append(
          MCPTool(
            name: "workspace.archive_files",
            description:
              "Find common archive, compressed stream, installer, disk image, and application package files under the workspace using extension and path metadata only. This does not list archive entries, extract files, inspect package manifests, or read contents; use returned archive.list context for supported formats.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                "max_results": integerSchema(
                  "Maximum matching files to return after sorting. Defaults to 500."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.log_files":
        tools.append(
          MCPTool(
            name: "workspace.log_files",
            description:
              "Find likely log, process output, trace, and crash-report files under the workspace using filename, extension, and logs-directory metadata only. This does not read log contents, infer severity, summarize events, or follow live streams; use returned file.tail or file.search context for explicit follow-up inspection.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                "max_results": integerSchema(
                  "Maximum matching files to return after sorting. Defaults to 500."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.data_files":
        tools.append(
          MCPTool(
            name: "workspace.data_files",
            description:
              "Find common data artifacts such as CSV, TSV, JSONL, SQLite, DuckDB, Parquet, Arrow, Avro, ORC, Excel, and structured files in data-like directories using path and extension metadata only. This does not read data contents, infer schemas, count rows, sample values, or inspect databases; use returned context objects for explicit follow-up inspection through the gateway.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                "max_results": integerSchema(
                  "Maximum matching files to return after sorting. Defaults to 500."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.schema_files":
        tools.append(
          MCPTool(
            name: "workspace.schema_files",
            description:
              "Find likely API, interface, data, and database schema/contract files such as OpenAPI, Swagger, AsyncAPI, GraphQL, Protocol Buffers, JSON Schema, Avro schema, Prisma, WSDL, XSD, Thrift, FlatBuffers, and SQL migrations using filename, extension, and schema-directory metadata only. This does not read schema contents, validate contracts, infer models, or inspect databases; use returned context objects for explicit follow-up inspection through the gateway.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to false."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                "max_results": integerSchema(
                  "Maximum matching files to return after sorting. Defaults to 500."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "workspace.source_files":
        tools.append(
          MCPTool(
            name: "workspace.source_files",
            description:
              "Find likely source, script, component, markup, style, header, and query files under the workspace using file extension and path metadata only. This does not read source contents, infer architecture, or run tools. Tests are excluded by default; use include_tests when needed.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.outline":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.commands":
        tools.append(
          MCPTool(
            name: "workspace.commands",
            description:
              "Find deterministic project command entrypoints from common workspace manifests such as package.json scripts, Makefile targets, Justfile recipes, and standard SwiftPM/Cargo/Go commands. This reads only bounded manifest bytes, does not execute commands, and returns cli.exec context plus whether the suggested CLI provider is registered.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "workspace.governance_files":
        tools.append(
          MCPTool(
            name: "workspace.governance_files",
            description:
              "Find workspace governance and collaboration entrypoints such as _ops/bin/workspace, refs manifests, references/upstreams or references/forks roots, workspace skill instructions, AGENTS.md, and CODEOWNERS using path and filename metadata only. This does not execute the workspace CLI, mutate refs, parse governance files, inspect Git internals, or infer policy; use returned context objects for explicit follow-up inspection through the gateway.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
                "include_hidden": boolSchema(
                  "Whether to include hidden files and directories. Defaults to true because workspace governance markers commonly live under hidden agent directories."
                ),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 8."),
                "max_results": integerSchema(
                  "Maximum matching entries to return after sorting. Defaults to 200."),
                "max_scan_entries": integerSchema(
                  "Maximum filesystem entries to scan before truncating. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "system.info":
        tools.append(
          MCPTool(
            name: "system.info",
            description:
              "Return a non-secret read-only macOS system and current gateway process summary.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.kernel":
        tools.append(
          MCPTool(
            name: "system.kernel",
            description:
              "Return read-only macOS kernel and machine identity from uname, plus OS version and processor counts. This does not run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.software":
        tools.append(
          MCPTool(
            name: "system.software",
            description:
              "Return read-only macOS product name, version, and build version using fixed /usr/bin/sw_vers argv, plus ProcessInfo version fields. This does not run shell commands.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "system.locale":
        tools.append(
          MCPTool(
            name: "system.locale",
            description:
              "Return read-only current locale, preferred languages, calendar, and time-zone summary from Foundation. This does not run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.memory":
        tools.append(
          MCPTool(
            name: "system.memory",
            description:
              "Return read-only macOS virtual-memory page counters and memory event counters using host_statistics64. This does not inspect processes or run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.load":
        tools.append(
          MCPTool(
            name: "system.load",
            description:
              "Return read-only macOS load averages from getloadavg, with values normalized by active processor count. This does not inspect processes or run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.cpu":
        tools.append(
          MCPTool(
            name: "system.cpu",
            description:
              "Return read-only CPU and hardware identifier details from ProcessInfo, sysctlbyname, and uname. This does not inspect processes or run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.thermal":
        tools.append(
          MCPTool(
            name: "system.thermal",
            description:
              "Return read-only thermal state and low-power-mode status from ProcessInfo. This does not inspect processes or run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.time":
        tools.append(
          MCPTool(
            name: "system.time",
            description:
              "Return the current local time, Unix timestamp, time zone, and system uptime. This is read-only.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.uptime":
        tools.append(
          MCPTool(
            name: "system.uptime",
            description:
              "Return read-only system uptime and derived boot time from ProcessInfo.systemUptime. This does not run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.user":
        tools.append(
          MCPTool(
            name: "system.user",
            description:
              "Return read-only POSIX identity for the current gateway process using getuid/getgid/getpwuid/getgrgid. This does not enumerate users or run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.groups":
        tools.append(
          MCPTool(
            name: "system.groups",
            description:
              "Return read-only supplementary POSIX groups for the current gateway process using getgroups/getgrgid. This does not enumerate all system groups or run shell commands.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "system.power":
        tools.append(
          MCPTool(
            name: "system.power",
            description:
              "Return raw macOS battery and power-source status using /usr/bin/pmset -g batt. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "system.volumes":
        tools.append(
          MCPTool(
            name: "system.volumes",
            description: "List mounted macOS volumes with non-secret capacity and mount metadata.",
            inputSchema: objectSchema(
              properties: [
                "include_hidden": boolSchema(
                  "Whether to include hidden volumes. Defaults to false.")
              ]
            ),
            meta: toolMeta
          ))

      case "system.processes":
        tools.append(
          MCPTool(
            name: "system.processes",
            description:
              "Return a bounded read-only macOS process snapshot using fixed /bin/ps argv. This reports executable command names, not full argument strings.",
            inputSchema: objectSchema(
              properties: [
                "query": stringSchema(
                  "Optional case-insensitive filter over user, state, command, or raw line."),
                "max_results": integerSchema("Maximum processes to return. Defaults to 200."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "system.which":
        tools.append(
          MCPTool(
            name: "system.which",
            description:
              "Locate an executable basename on the gateway process PATH without running a shell or invoking the executable. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "name": stringSchema(
                  "Executable basename to find, for example cloudflared, tunnel-client, or codex."),
                "all_matches": boolSchema(
                  "Whether to return every executable match on PATH. Defaults to false."),
              ],
              required: ["name"]
            ),
            meta: toolMeta
          ))

      case "system.path":
        tools.append(
          MCPTool(
            name: "system.path",
            description:
              "Return structured gateway process PATH search directories without exposing other environment values and without running a shell.",
            inputSchema: objectSchema(
              properties: [
                "include_missing": boolSchema(
                  "Whether to include PATH entries that do not currently exist. Defaults to true."),
                "max_entries": integerSchema(
                  "Maximum entries to return. Defaults to 200; max 1000."),
              ]
            ),
            meta: toolMeta
          ))

      case "logs.query":
        tools.append(
          MCPTool(
            name: "logs.query",
            description:
              "Query a bounded recent window of the macOS unified log using fixed /usr/bin/log show --style ndjson argv. This is read-only but can expose sensitive local activity, so it belongs only in explicitly trusted profiles. It never starts a live stream or invokes a shell.",
            inputSchema: objectSchema(
              properties: [
                "last_seconds": integerSchema(
                  "Required recent time window in seconds, from 1 through 604800."),
                "max_entries": integerSchema(
                  "Required maximum captured log lines to return, from 1 through 10000."),
                "predicate": stringSchema(
                  "Optional NSPredicate expression passed as one argv value to log show --predicate; max 4096 UTF-8 bytes."
                ),
                "include_info": boolSchema(
                  "Whether to include Info events. Defaults to false."),
                "include_debug": boolSchema(
                  "Whether to include Debug events. Defaults to false."),
                "timeout_ms": integerSchema(
                  "Optional execution timeout in milliseconds. Defaults to 30000."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["last_seconds", "max_entries"]
            ),
            meta: toolMeta
          ))

      case "service.status":
        tools.append(
          MCPTool(
            name: "service.status",
            description:
              "Inspect one macOS launchd service with fixed /bin/launchctl print argv. The domain and label are explicit; user/gui domains are restricted to the current gateway uid. This returns an allowlisted status summary and never returns launchd environment blocks, raw output, or mutation controls.",
            inputSchema: objectSchema(
              properties: [
                "domain": stringSchema(
                  "Required launchd domain: system, user, or gui. user/gui use the current gateway uid."
                ),
                "label": stringSchema(
                  "Required launch service label containing only letters, digits, dot, underscore, or hyphen."
                ),
                "timeout_ms": integerSchema(
                  "Optional execution timeout in milliseconds. Defaults to 10000."),
                "max_output_bytes": integerSchema(
                  "Maximum captured stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["domain", "label"]
            ),
            meta: toolMeta
          ))

      case "network.interfaces":
        tools.append(
          MCPTool(
            name: "network.interfaces",
            description:
              "Return raw macOS network interface status using /sbin/ifconfig. This is read-only and runs fixed argv only.",
            inputSchema: objectSchema(
              properties: [
                "interface": stringSchema(
                  "Optional interface name such as en0 or lo0. Omit to run ifconfig -a."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.dns":
        tools.append(
          MCPTool(
            name: "network.dns",
            description:
              "Return raw macOS DNS resolver configuration using /usr/sbin/scutil --dns. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "network.resolve":
        tools.append(
          MCPTool(
            name: "network.resolve",
            description:
              "Resolve a hostname or IP address through the system resolver using getaddrinfo. This is read-only and does not run shell commands.",
            inputSchema: objectSchema(
              properties: [
                "host": stringSchema("Hostname or IP address to resolve."),
                "family": stringSchema(
                  "Address family: any, all, ipv4, inet, ipv6, or inet6. Defaults to any."),
                "max_results": integerSchema("Maximum addresses to return. Defaults to 50."),
              ],
              required: ["host"]
            ),
            meta: toolMeta
          ))

      case "network.proxy":
        tools.append(
          MCPTool(
            name: "network.proxy",
            description:
              "Return raw macOS network proxy settings using /usr/sbin/scutil --proxy. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "network.services":
        tools.append(
          MCPTool(
            name: "network.services",
            description:
              "Return the raw macOS network service list using fixed /usr/sbin/networksetup -listallnetworkservices argv. This is read-only and does not make outbound network requests.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.hardware_ports":
        tools.append(
          MCPTool(
            name: "network.hardware_ports",
            description:
              "Return the raw macOS network hardware port list using fixed /usr/sbin/networksetup -listallhardwareports argv. This is read-only and may reveal local network hardware identifiers.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.wifi":
        tools.append(
          MCPTool(
            name: "network.wifi",
            description:
              "Return read-only current macOS Wi-Fi interface status using fixed /usr/sbin/networksetup argv. The gateway discovers or accepts a Wi-Fi device, then queries power and current network association. This does not scan nearby networks, join networks, change settings, make outbound network requests, or expose full hardware-port raw output.",
            inputSchema: objectSchema(
              properties: [
                "device": stringSchema(
                  "Optional network interface device such as en0. Omit to discover the first Wi-Fi/AirPort hardware port."
                ),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.vpn":
        tools.append(
          MCPTool(
            name: "network.vpn",
            description:
              "Return read-only macOS Network Connection/VPN service list using fixed /usr/sbin/scutil --nc list argv. The gateway parses enabled state, connection status, service id, name, protocol, and type. This does not start, stop, select, trigger, enable, disable, or show detailed VPN configuration.",
            inputSchema: objectSchema(
              properties: [
                "max_results": integerSchema("Maximum services to return. Defaults to 100."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.locations":
        tools.append(
          MCPTool(
            name: "network.locations",
            description:
              "Return the raw current and configured macOS network locations using fixed /usr/sbin/networksetup -getcurrentlocation and -listlocations argv. This is read-only and does not make outbound network requests.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.routes":
        tools.append(
          MCPTool(
            name: "network.routes",
            description:
              "Return the raw macOS routing table using fixed /usr/sbin/netstat -rn argv. This is read-only and does not make outbound network requests.",
            inputSchema: objectSchema(
              properties: [
                "family": stringSchema("Address family: all, inet, or inet6. Defaults to all."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.connections":
        tools.append(
          MCPTool(
            name: "network.connections",
            description:
              "Return the raw local network connection table using fixed /usr/sbin/netstat -an argv. This is read-only and may reveal local and remote endpoints.",
            inputSchema: objectSchema(
              properties: [
                "family": stringSchema("Address family: all, inet, or inet6. Defaults to all."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.arp":
        tools.append(
          MCPTool(
            name: "network.arp",
            description:
              "Return the raw local IPv4 ARP neighbor cache using fixed /usr/sbin/arp -an argv. This is read-only and may reveal local network devices.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "network.ping":
        tools.append(
          MCPTool(
            name: "network.ping",
            description:
              "Run a bounded ICMP ping to a hostname or IP address using fixed /sbin/ping -c argv. This performs network I/O.",
            inputSchema: objectSchema(
              properties: [
                "host": stringSchema("Hostname or IP address to ping. URLs are rejected."),
                "count": integerSchema("Number of echo requests. Defaults to 3; max 10."),
                "timeout_ms": integerSchema("Process timeout in milliseconds. Defaults to 30000."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ],
              required: ["host"]
            ),
            meta: toolMeta
          ))

      case "network.tcp_check":
        tools.append(
          MCPTool(
            name: "network.tcp_check",
            description:
              "Check TCP connectivity to a host and port using fixed /usr/bin/nc -G <seconds> -zv argv. This performs network I/O.",
            inputSchema: objectSchema(
              properties: [
                "host": stringSchema("Hostname or IP address to connect to. URLs are rejected."),
                "port": integerSchema("TCP port number, 1 through 65535."),
                "connect_timeout_seconds": integerSchema(
                  "nc connection timeout in seconds. Defaults to 5; max 60."),
                "timeout_ms": integerSchema("Process timeout in milliseconds. Defaults to 30000."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ],
              required: ["host", "port"]
            ),
            meta: toolMeta
          ))

      case "network.http_check":
        tools.append(
          MCPTool(
            name: "network.http_check",
            description:
              "Check an absolute HTTP or HTTPS URL using fixed /usr/bin/curl argv. This performs bounded network I/O, supports HEAD or GET, returns curl metadata such as HTTP status and effective URL, and optionally returns a bounded GET body prefix. It does not send custom headers, request bodies, cookies, or shell commands.",
            inputSchema: objectSchema(
              properties: [
                "url": stringSchema("Absolute http or https URL to check."),
                "method": stringSchema("HTTP method: HEAD or GET. Defaults to HEAD."),
                "include_body": boolSchema(
                  "Whether to include a bounded GET response body prefix. Defaults to false and is ignored for HEAD."
                ),
                "follow_redirects": boolSchema(
                  "Whether curl should follow redirects. Defaults to false."),
                "max_redirects": integerSchema("Maximum redirects when following. Defaults to 5."),
                "connect_timeout_seconds": integerSchema(
                  "Connection timeout in seconds. Defaults to 5; max 60."),
                "timeout_ms": integerSchema("Process timeout in milliseconds. Defaults to 30000."),
                "max_body_bytes": integerSchema(
                  "Maximum GET body bytes to return when include_body is true. Defaults to 4096."
                ),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to max_body_bytes plus metadata allowance."
                ),
              ],
              required: ["url"]
            ),
            meta: toolMeta
          ))

      case "network.listeners":
        tools.append(
          MCPTool(
            name: "network.listeners",
            description:
              "Return raw local TCP listening sockets using fixed /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN argv. This is read-only but may reveal local process names and ports.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds. Defaults to 10000."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ]
            ),
            meta: toolMeta
          ))

      case "macos.user_directories":
        tools.append(
          MCPTool(
            name: "macos.user_directories",
            description:
              "Return a fixed read-only catalog of common macOS user and application directories such as Home, Desktop, Documents, Downloads, Movies, Music, Pictures, user Library, user Applications, /Applications, /System/Applications, and the current process temporary directory. This reports existence and filesystem metadata only; it does not list directory contents, read files, open Finder, or run shell commands.",
            inputSchema: objectSchema(
              properties: [
                "include_missing": boolSchema(
                  "Whether to include catalog entries that do not exist on disk. Defaults to true."
                ),
                "include_system": boolSchema(
                  "Whether to include system-wide application directories. Defaults to true."
                ),
                "include_temporary": boolSchema(
                  "Whether to include the current process temporary directory. Defaults to true."),
              ]
            ),
            meta: toolMeta
          ))

      case "macos.default_application":
        tools.append(
          MCPTool(
            name: "macos.default_application",
            description:
              "Return the default macOS application, and optionally candidate applications, that LaunchServices would use for a workspace-contained file path or an http, https, or mailto URL. This is read-only and does not open the file, launch an application, make network requests, or inspect UI content.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Existing workspace-relative or workspace-contained absolute file/directory path to query."
                ),
                "url": stringSchema(
                  "Absolute http, https, or mailto URL to query without opening."),
                "include_candidates": boolSchema(
                  "Whether to include candidate applications returned by LaunchServices. Defaults to false."
                ),
                "max_candidates": integerSchema(
                  "Maximum candidate applications to return. Defaults to 20."),
              ]
            ),
            meta: toolMeta
          ))

      case "macos.applications":
        tools.append(
          MCPTool(
            name: "macos.applications",
            description:
              "List installed macOS application bundles from standard Applications directories.",
            inputSchema: objectSchema(
              properties: [
                "include_system": boolSchema(
                  "Whether to include /Applications and /System/Applications. Defaults to true."),
                "include_user": boolSchema(
                  "Whether to include ~/Applications. Defaults to true."),
                "max_results": integerSchema("Optional application cap. Defaults to 500."),
                "max_depth": integerSchema("Optional recursive depth. Defaults to 3."),
                "max_visited": integerSchema(
                  "Optional visited-entry cap. Defaults to 20000."),
              ]
            ),
            meta: toolMeta
          ))

      case "macos.screens":
        tools.append(
          MCPTool(
            name: "macos.screens",
            description:
              "List attached macOS screens with frame, visible frame, scale, and color-space metadata. This is read-only.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "macos.spotlight_search":
        tools.append(
          MCPTool(
            name: "macos.spotlight_search",
            description:
              "Search the macOS Spotlight index under a workspace-contained directory using fixed /usr/bin/mdfind -onlyin argv. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative directory path to constrain mdfind. Defaults to workspace root."
                ),
                "query": stringSchema("Raw Spotlight query string passed to mdfind."),
                "max_results": integerSchema(
                  "Maximum contained results to return. Defaults to 100."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum raw stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["query"]
            ),
            meta: toolMeta
          ))

      case "macos.running_applications":
        tools.append(
          MCPTool(
            name: "macos.running_applications",
            description:
              "List running macOS applications visible to the current user session. This is read-only and does not inspect windows or UI content.",
            inputSchema: objectSchema(
              properties: [
                "include_background": boolSchema(
                  "Whether to include accessory/background apps. Defaults to false."),
                "query": stringSchema(
                  "Optional string matched against app name, bundle id, bundle path, or executable path."
                ),
                "match": stringSchema("contains, prefix, suffix, or exact. Defaults to contains."),
                "case_sensitive": boolSchema("Whether query matching is case-sensitive."),
                "max_results": integerSchema("Optional result cap. Defaults to 200."),
              ]
            ),
            meta: toolMeta
          ))

      case "macos.frontmost_application":
        tools.append(
          MCPTool(
            name: "macos.frontmost_application",
            description:
              "Return the current frontmost macOS application visible to the user session. This is read-only.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "env.describe":
        tools.append(
          MCPTool(
            name: "env.describe",
            description:
              "Describe only environment variable names declared by gateway config and whether they are present. Values are always redacted.",
            inputSchema: objectSchema(),
            meta: toolMeta
          ))

      case "file.exists":
        tools.append(
          MCPTool(
            name: "file.exists",
            description:
              "Check whether a workspace-contained path exists without treating absence as an error.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path.")
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.list":
        tools.append(
          MCPTool(
            name: "file.list",
            description:
              "List entries under a workspace-contained directory with deterministic ordering and bounded output.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative or in-workspace absolute directory path. Defaults to workspace root."
                ),
                "include_hidden": boolSchema("Whether to include dotfiles. Defaults to false."),
                "recursive_depth": integerSchema(
                  "Optional recursive depth. Defaults to 0 for direct children only."),
                "max_entries": integerSchema("Optional entry cap. Defaults to 200."),
              ]
            ),
            meta: toolMeta
          ))

      case "file.tree":
        tools.append(
          MCPTool(
            name: "file.tree",
            description:
              "Return a bounded hierarchical tree for a workspace-contained directory. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative or in-workspace absolute directory path. Defaults to workspace root."
                ),
                "include_hidden": boolSchema("Whether to include hidden files. Defaults to false."),
                "max_depth": integerSchema("Maximum child depth to traverse. Defaults to 2."),
                "max_entries": integerSchema("Maximum tree nodes to return. Defaults to 500."),
                "directories_only": boolSchema(
                  "Whether to include only directories. Defaults to false."),
              ]
            ),
            meta: toolMeta
          ))

      case "file.stat":
        tools.append(
          MCPTool(
            name: "file.stat",
            description:
              "Return file metadata for a workspace-contained path without reading file content.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path.")
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.permissions":
        tools.append(
          MCPTool(
            name: "file.permissions",
            description:
              "Return POSIX mode, owner/group, current-process access, and common macOS file flags for a workspace-contained path. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path.")
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.chmod":
        tools.append(
          MCPTool(
            name: "file.chmod",
            description:
              "Set the POSIX mode for a workspace-contained path without invoking chmod. This is non-recursive.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path."),
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
            meta: toolMeta
          ))

      case "file.type":
        tools.append(
          MCPTool(
            name: "file.type",
            description:
              "Return MIME type and charset for a workspace-contained file using fixed /usr/bin/file -b --mime argv. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.count":
        tools.append(
          MCPTool(
            name: "file.count",
            description:
              "Return line, word, and byte counts for a workspace-contained file using fixed /usr/bin/wc -l -w -c argv. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.disk_usage":
        tools.append(
          MCPTool(
            name: "file.disk_usage",
            description:
              "Return disk usage for a workspace-contained file or directory using fixed /usr/bin/du -sk argv. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.volume_info":
        tools.append(
          MCPTool(
            name: "file.volume_info",
            description:
              "Return the mounted volume and filesystem capability metadata for a workspace-contained path using Foundation URL resource values. This is read-only and does not run shell commands.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative or in-workspace absolute path. Defaults to workspace root."
                )
              ]
            ),
            meta: toolMeta
          ))

      case "file.find":
        tools.append(
          MCPTool(
            name: "file.find",
            description:
              "Find workspace-contained paths by file or directory name using bounded deterministic traversal.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "file.search":
        tools.append(
          MCPTool(
            name: "file.search",
            description:
              "Search UTF-8 text content under a workspace-contained path with bounded files, bytes, and matches.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative file or directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "file.timeline":
        tools.append(
          MCPTool(
            name: "file.timeline",
            description:
              "List regular files under a workspace-contained directory by modification time with optional ISO8601 modified_after/modified_before filters. This is read-only, uses filesystem metadata only, and does not infer recency semantics.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative directory path. Defaults to workspace root."),
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
            meta: toolMeta
          ))

      case "file.read":
        tools.append(
          MCPTool(
            name: "file.read",
            description: "Read a UTF-8 file under the configured workspace directory.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "max_bytes": integerSchema("Optional maximum bytes to return."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.read_files":
        tools.append(
          MCPTool(
            name: "file.read_files",
            description:
              "Read multiple explicitly named workspace-contained files in one call. This is read-only, supports uniform utf8 or base64 output, and does not search, infer, or follow references.",
            inputSchema: objectSchema(
              properties: [
                "paths": stringArraySchema(
                  "Workspace-relative or in-workspace absolute file paths. Must contain 1 to 50 values."
                ),
                "max_bytes_per_file": integerSchema(
                  "Maximum bytes to read per file. Defaults to policy.max_output_bytes."),
                "encoding": stringSchema("utf8 or base64. Defaults to utf8."),
              ],
              required: ["paths"]
            ),
            meta: toolMeta
          ))

      case "file.read_window":
        tools.append(
          MCPTool(
            name: "file.read_window",
            description:
              "Read a UTF-8 text byte window from a workspace-contained file using offset_bytes and max_bytes. This is read-only and reports whether the selected byte window is valid UTF-8.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "offset_bytes": integerSchema(
                  "Zero-based byte offset where reading starts. Defaults to 0."),
                "max_bytes": integerSchema(
                  "Maximum bytes to read from the offset. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.read_lines":
        tools.append(
          MCPTool(
            name: "file.read_lines",
            description:
              "Read a bounded UTF-8 line range from a workspace-contained file.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "start_line": integerSchema("One-based starting line. Defaults to 1."),
                "max_lines": integerSchema("Maximum lines to return. Defaults to 200."),
                "max_bytes": integerSchema(
                  "Maximum bytes to scan from the start of the file."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.read_context":
        tools.append(
          MCPTool(
            name: "file.read_context",
            description:
              "Read bounded UTF-8 line context around a one-based target line in a workspace-contained file.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "line": integerSchema("One-based target line number."),
                "before": integerSchema("Number of lines before the target line. Defaults to 5."),
                "after": integerSchema("Number of lines after the target line. Defaults to 5."),
                "max_bytes": integerSchema(
                  "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path", "line"]
            ),
            meta: toolMeta
          ))

      case "file.head":
        tools.append(
          MCPTool(
            name: "file.head",
            description:
              "Read the first lines from a workspace-contained UTF-8 file using a bounded byte window.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "max_lines": integerSchema("Maximum head lines to return. Defaults to 200."),
                "max_bytes": integerSchema(
                  "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.outline":
        tools.append(
          MCPTool(
            name: "file.outline",
            description:
              "Return a bounded mechanical outline for a workspace-contained UTF-8 file by extracting Markdown headings and common source declaration lines. This does not summarize, infer architecture, or build a semantic graph.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative file path."),
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
            meta: toolMeta
          ))

      case "markdown.links":
        tools.append(
          MCPTool(
            name: "markdown.links",
            description:
              "Extract a bounded mechanical inventory of Markdown links from a workspace-contained UTF-8 Markdown file. This reports inline links, images, reference links, reference definitions, autolinks, and local target context; it does not follow links, fetch URLs, or infer document semantics.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative Markdown file path."),
                "include_images": boolSchema("Whether to include image links. Defaults to true."),
                "include_reference_definitions": boolSchema(
                  "Whether to include [label]: destination reference definitions. Defaults to true."
                ),
                "include_autolinks": boolSchema(
                  "Whether to include angle-bracket autolinks such as <https://example.com>. Defaults to true."
                ),
                "include_code_blocks": boolSchema(
                  "Whether to scan fenced code blocks. Defaults to false."),
                "max_links": integerSchema("Maximum links to return. Defaults to 200."),
                "max_bytes": integerSchema(
                  "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "markdown.tables":
        tools.append(
          MCPTool(
            name: "markdown.tables",
            description:
              "Extract bounded GitHub-flavored pipe tables from a workspace-contained UTF-8 Markdown file. This reports headers, alignments, rows, line ranges, raw table text, and truncation flags; it does not infer table semantics, summarize content, or execute code blocks.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute Markdown file path."),
                "include_code_blocks": boolSchema(
                  "Whether to scan fenced code blocks for tables. Defaults to false."),
                "max_tables": integerSchema("Maximum tables to return. Defaults to 20."),
                "max_rows_per_table": integerSchema(
                  "Maximum data rows to return per table. Defaults to 100."),
                "max_bytes": integerSchema(
                  "Maximum bytes to scan from the start of the file. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "markdown.section":
        tools.append(
          MCPTool(
            name: "markdown.section",
            description:
              "Extract one raw Markdown section by exact ATX heading text from a workspace-contained UTF-8 Markdown file. This uses explicit heading, optional level, and occurrence only; it does not search semantically, summarize, follow links, or parse arbitrary Markdown blocks.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute Markdown file path."),
                "heading": stringSchema("Exact heading text as returned by file.outline."),
                "level": integerSchema("Optional heading level from 1 to 6."),
                "occurrence": integerSchema(
                  "One-based occurrence when the same heading appears more than once. Defaults to 1."
                ),
                "include_heading": boolSchema(
                  "Whether to include the matched heading line in returned content. Defaults to true."
                ),
                "max_bytes": integerSchema(
                  "Maximum Markdown bytes to scan from the file. Defaults to policy.max_output_bytes."
                ),
                "max_section_bytes": integerSchema(
                  "Maximum UTF-8 bytes of section content to return. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path", "heading"]
            ),
            meta: toolMeta
          ))

      case "markdown.frontmatter":
        tools.append(
          MCPTool(
            name: "markdown.frontmatter",
            description:
              "Read leading YAML or TOML frontmatter from a workspace-contained UTF-8 Markdown file. This only recognizes explicit opening delimiters at the start of the file, returns raw frontmatter plus parsed structured value when valid, and does not infer skill semantics, summarize, or scan the Markdown body.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute Markdown file path."),
                "format": stringSchema(
                  "Frontmatter format to accept: auto, yaml, or toml. Defaults to auto."
                ),
                "max_bytes": integerSchema(
                  "Maximum Markdown bytes to scan from the file. Defaults to policy.max_output_bytes."
                ),
                "max_depth": integerSchema(
                  "Maximum parsed YAML/TOML nesting depth. Defaults to 128."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "markdown.link_check":
        tools.append(
          MCPTool(
            name: "markdown.link_check",
            description:
              "Check local Markdown links in one workspace-contained UTF-8 Markdown file. This resolves reference definitions, verifies workspace-contained local targets and Markdown fragments, and reports external URLs as unchecked; it does not fetch URLs, crawl documents, or infer document semantics.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative Markdown file path."),
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
                  "Maximum bytes to scan from the source file. Defaults to policy.max_output_bytes."
                ),
                "max_target_bytes": integerSchema(
                  "Maximum bytes to scan from each Markdown target when checking fragments. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.tail":
        tools.append(
          MCPTool(
            name: "file.tail",
            description:
              "Read the last lines from a workspace-contained UTF-8 file using a bounded tail window.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "max_lines": integerSchema("Maximum tail lines to return. Defaults to 200."),
                "max_bytes": integerSchema(
                  "Maximum bytes to scan from the end of the file."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.hexdump":
        tools.append(
          MCPTool(
            name: "file.hexdump",
            description:
              "Read a bounded byte window from a workspace-contained file and return deterministic hex/ascii rows. This is read-only and useful for binary inspection.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "offset_bytes": integerSchema("Starting byte offset. Defaults to 0."),
                "max_bytes": integerSchema("Maximum bytes to return. Defaults to 256."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.xattrs":
        tools.append(
          MCPTool(
            name: "file.xattrs",
            description:
              "List extended attributes for a workspace-contained file or directory, with optional bounded value previews. This is read-only and useful for macOS metadata such as quarantine flags and Finder tags.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                "include_values": boolSchema(
                  "Whether to include bounded attribute value previews. Defaults to false."),
                "max_value_bytes": integerSchema(
                  "Maximum attribute value size to read when include_values is true. Larger values are reported as truncated without reading. Defaults to 1024."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.remove_xattr":
        tools.append(
          MCPTool(
            name: "file.remove_xattr",
            description:
              "Remove one extended attribute from a workspace-contained path using the macOS xattr API. This is non-recursive.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                "name": stringSchema("Extended attribute name to remove."),
                "dry_run": boolSchema(
                  "Whether to validate the removal without deleting the extended attribute. Defaults to false."
                ),
              ],
              required: ["path", "name"]
            ),
            meta: toolMeta
          ))

      case "file.metadata":
        tools.append(
          MCPTool(
            name: "file.metadata",
            description:
              "Read Spotlight metadata for a workspace-contained file or directory using fixed /usr/bin/mdls -plist argv. This is read-only and macOS-specific.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path."),
                "attributes": stringArraySchema(
                  "Optional Spotlight metadata attribute names to return after plist parsing."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.readlink":
        tools.append(
          MCPTool(
            name: "file.readlink",
            description:
              "Read the raw destination of a workspace-contained symbolic link without following the final link. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute symlink path.")
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.resolve":
        tools.append(
          MCPTool(
            name: "file.resolve",
            description:
              "Resolve a workspace-contained path mechanically, preserving the final symlink for inspection and reporting whether the resolved destination remains in the workspace.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path.")
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "image.info":
        tools.append(
          MCPTool(
            name: "image.info",
            description:
              "Read mechanical metadata for a workspace-contained image file using ImageIO. This reports format, MIME, dimensions, frame count, color metadata, and optional bounded raw properties; it does not decode pixels, OCR, classify, or generate previews.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute image file path."),
                "include_properties": boolSchema(
                  "Whether to include bounded raw ImageIO property dictionaries. Defaults to false."
                ),
                "max_property_depth": integerSchema(
                  "Maximum nested dictionary/array depth for raw properties when included. Defaults to 2."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "pdf.info":
        tools.append(
          MCPTool(
            name: "pdf.info",
            description:
              "Read mechanical metadata for a workspace-contained PDF file using PDFKit. This reports page count, encryption/permission flags, optional document attributes, and bounded page box metadata; it does not extract text, OCR, render pages, or summarize document contents.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute PDF file path."),
                "max_pages": integerSchema(
                  "Maximum page metadata rows to return. Defaults to 20; use 0 to omit page rows."
                ),
                "include_page_boxes": boolSchema(
                  "Whether to include media/crop/bleed/trim/art boxes for returned pages. Defaults to true."
                ),
                "include_attributes": boolSchema(
                  "Whether to include bounded PDF document attributes. Defaults to true."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "pdf.text":
        tools.append(
          MCPTool(
            name: "pdf.text",
            description:
              "Extract bounded searchable text from a workspace-contained PDF file using PDFKit page.string. This is read-only, respects PDF locking/copying flags, and does not OCR, render pages, inspect images, or summarize content.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute PDF file path."),
                "start_page": integerSchema("One-based page number to start from. Defaults to 1."),
                "max_pages": integerSchema("Maximum pages to inspect. Defaults to 10."),
                "max_characters": integerSchema(
                  "Maximum extracted characters to return across pages. Defaults to 100000."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "media.info":
        tools.append(
          MCPTool(
            name: "media.info",
            description:
              "Read mechanical metadata for a workspace-contained audio or video file using AVFoundation. This reports duration, playability, protected-content state, track types, codecs, frame-rate, dimensions, and data-rate; it does not decode samples, transcode, extract frames, play media, or infer content semantics.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute media file path."),
                "max_tracks": integerSchema(
                  "Maximum track metadata rows to return. Defaults to 20; use 0 to omit track rows."
                ),
                "load_timeout_ms": integerSchema(
                  "Maximum AVFoundation metadata load time per property. Defaults to 5000."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "json.read":
        tools.append(
          MCPTool(
            name: "json.read",
            description:
              "Read and parse a workspace-contained JSON file into a JSON value using the gateway JSON decoder. This is read-only and does not execute subprocesses.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute JSON file path."),
                "max_bytes": integerSchema(
                  "Maximum JSON bytes to parse. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "jsonl.read":
        tools.append(
          MCPTool(
            name: "jsonl.read",
            description:
              "Read a bounded preview of a workspace-contained JSON Lines / NDJSON UTF-8 file by parsing each nonblank line as an independent JSON value. This is read-only and does not infer data semantics.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute JSONL/NDJSON file path."),
                "start_line": integerSchema("One-based line to start scanning. Defaults to 1."),
                "max_records": integerSchema("Maximum parsed records to return. Defaults to 100."),
                "max_errors": integerSchema("Maximum parse errors to return. Defaults to 50."),
                "skip_blank_lines": boolSchema(
                  "Whether to skip blank lines before parsing. Defaults to true."),
                "include_partial_line": boolSchema(
                  "Whether to parse the last line when the byte window cuts through it. Defaults to false."
                ),
                "max_bytes": integerSchema(
                  "Maximum bytes to read from the file. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "json.write":
        tools.append(
          MCPTool(
            name: "json.write",
            description:
              "Serialize a provided JSON value and write it to a workspace-contained file. Defaults to dry-run, sorted keys, pretty output, and requires confirm_write=true for real writes.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute JSON file path."),
                "value": .object([
                  "description": .string(
                    "Any JSON value to encode: object, array, string, number, boolean, or null.")
                ]),
                "pretty": boolSchema("Whether to pretty-print JSON. Defaults to true."),
                "sorted_keys": boolSchema("Whether to sort object keys. Defaults to true."),
                "append_newline": boolSchema(
                  "Whether to append a trailing newline. Defaults to true."),
                "overwrite": boolSchema(
                  "Whether an existing destination file may be replaced. Defaults to false."),
                "create_directories": boolSchema(
                  "Whether to create missing parent directories. Defaults to false."),
                "dry_run": boolSchema(
                  "Whether to validate and preview without writing. Defaults to true."),
                "confirm_write": boolSchema(
                  "Required as true when dry_run is false to write the JSON file."),
                "include_preview": boolSchema(
                  "Whether to include a bounded encoded JSON preview. Defaults to dry_run."),
                "preview_max_bytes": integerSchema(
                  "Maximum UTF-8 bytes for the encoded JSON preview. Defaults to 8192."),
                "max_bytes": integerSchema(
                  "Maximum encoded JSON bytes allowed. Defaults to policy.max_output_bytes."),
              ],
              required: ["path", "value"]
            ),
            meta: toolMeta
          ))

      case "toml.read":
        tools.append(
          MCPTool(
            name: "toml.read",
            description:
              "Read and parse a workspace-contained TOML file into a JSON value using the existing swift-toml decoder. This is read-only and does not execute subprocesses.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute TOML file path."),
                "max_bytes": integerSchema(
                  "Maximum TOML bytes to parse. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "yaml.read":
        tools.append(
          MCPTool(
            name: "yaml.read",
            description:
              "Read and parse a workspace-contained YAML file into JSON-compatible values using Yams. This is read-only, supports multiple YAML documents, and does not execute subprocesses or infer business semantics.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute YAML file path."),
                "max_bytes": integerSchema(
                  "Maximum YAML bytes to parse. Defaults to policy.max_output_bytes."),
                "max_documents": integerSchema(
                  "Maximum YAML documents to return. Defaults to 50."),
                "max_depth": integerSchema(
                  "Maximum nested YAML depth to convert. Defaults to 128."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "xml.read":
        tools.append(
          MCPTool(
            name: "xml.read",
            description:
              "Read and parse a workspace-contained XML file into a bounded element tree using Foundation XMLParser. This is read-only, disables external entity resolution, and does not validate schemas or infer business semantics.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute XML file path."),
                "max_bytes": integerSchema(
                  "Maximum XML bytes to parse. Defaults to policy.max_output_bytes."),
                "max_nodes": integerSchema(
                  "Maximum XML elements to return. Defaults to 10000."),
                "max_depth": integerSchema(
                  "Maximum XML nesting depth to return. Defaults to 64."),
                "max_text_bytes": integerSchema(
                  "Maximum direct text bytes to retain per element. Defaults to 8192."),
                "trim_text": boolSchema(
                  "Whether to trim whitespace-only text in returned element text. Defaults to true."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "plist.read":
        tools.append(
          MCPTool(
            name: "plist.read",
            description:
              "Read and parse a workspace-contained macOS property list file into JSON using Foundation PropertyListSerialization. This is read-only and does not execute subprocesses.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute plist file path."),
                "max_bytes": integerSchema(
                  "Maximum plist bytes to parse. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "structured.get":
        tools.append(
          MCPTool(
            name: "structured.get",
            description:
              "Read one value at an explicit path from a workspace-contained JSON, YAML, TOML, or plist file. query_path is a mechanical array of object keys and array indexes; this is not JSONPath/JQ, does not filter or wildcard, and does not infer field semantics.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute structured data file path."),
                "format": stringSchema(
                  "auto, json, yaml, toml, or plist. Defaults to auto from file extension."),
                "query_path": .object([
                  "type": .string("array"),
                  "items": .object([
                    "oneOf": .array([
                      .object(["type": .string("string")]),
                      .object([
                        "type": .string("integer"),
                        "minimum": .number(0),
                      ]),
                    ])
                  ]),
                  "description": .string(
                    "Exact path segments. Strings select object keys; non-negative integers select array indexes."
                  ),
                ]),
                "max_bytes": integerSchema(
                  "Maximum bytes to parse. Defaults to policy.max_output_bytes."),
                "max_documents": integerSchema(
                  "Maximum YAML documents to return before path selection. Defaults to 50."),
                "max_depth": integerSchema(
                  "Maximum YAML nesting depth to convert. Defaults to 128."),
              ],
              required: ["path", "query_path"]
            ),
            meta: toolMeta
          ))

      case "plist.write":
        tools.append(
          MCPTool(
            name: "plist.write",
            description:
              "Serialize a provided JSON value as a workspace-contained macOS property list using Foundation PropertyListSerialization. Defaults to dry-run XML output and requires confirm_write=true for real writes. Typed date/data objects from plist.read can be written back.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute plist file path."),
                "value": .object([
                  "description": .string(
                    "Property list value to encode: object, array, string, finite number, boolean, or typed {type:\"date\", iso8601:\"...\"} / {type:\"data\", base64:\"...\"}. Null is not supported."
                  )
                ]),
                "format": stringSchema("xml or binary. Defaults to xml."),
                "overwrite": boolSchema(
                  "Whether an existing destination file may be replaced. Defaults to false."),
                "create_directories": boolSchema(
                  "Whether to create missing parent directories. Defaults to false."),
                "dry_run": boolSchema(
                  "Whether to validate and preview without writing. Defaults to true."),
                "confirm_write": boolSchema(
                  "Required as true when dry_run is false to write the property list file."),
                "include_preview": boolSchema(
                  "Whether to include a bounded encoded preview. Defaults to dry_run."),
                "preview_max_bytes": integerSchema(
                  "Maximum bytes for the encoded preview. Defaults to 8192."),
                "max_bytes": integerSchema(
                  "Maximum encoded property-list bytes allowed. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path", "value"]
            ),
            meta: toolMeta
          ))

      case "csv.read":
        tools.append(
          MCPTool(
            name: "csv.read",
            description:
              "Read a bounded preview of a workspace-contained CSV/TSV-style delimited UTF-8 text file. This parses delimiter, quotes, rows, and cells mechanically; it does not infer business semantics or execute subprocesses.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute CSV/TSV file path."),
                "delimiter": stringSchema(
                  "auto, comma, tab, semicolon, pipe, or one non-newline character. Defaults to auto."
                ),
                "has_header": boolSchema(
                  "Whether to treat the first record as headers. Defaults to true."),
                "max_rows": integerSchema("Maximum data rows to return. Defaults to 100."),
                "max_columns": integerSchema(
                  "Maximum columns to return per record. Defaults to 200."),
                "max_bytes": integerSchema(
                  "Maximum bytes to read from the file. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "sqlite.schema":
        tools.append(
          MCPTool(
            name: "sqlite.schema",
            description:
              "Inspect a workspace-contained SQLite database schema using fixed /usr/bin/sqlite3 -readonly -json argv. This returns sqlite_schema entries only; it does not execute user SQL or read table rows.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute SQLite database file path."),
                "include_views": boolSchema("Whether to include views. Defaults to true."),
                "include_indexes": boolSchema("Whether to include indexes. Defaults to true."),
                "include_triggers": boolSchema(
                  "Whether to include triggers. Defaults to true."),
                "include_internal": boolSchema(
                  "Whether to include internal sqlite_* schema entries. Defaults to false."),
                "include_sql": boolSchema(
                  "Whether to include CREATE SQL text from sqlite_schema.sql. Defaults to true."),
                "max_entries": integerSchema("Maximum schema rows to return. Defaults to 500."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum sqlite3 stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "sqlite.query":
        tools.append(
          MCPTool(
            name: "sqlite.query",
            description:
              "Run one read-only SELECT, WITH, or non-assigning PRAGMA statement against a workspace-contained SQLite database using fixed /usr/bin/sqlite3 -readonly -json argv. SELECT/WITH queries are wrapped with a max_rows LIMIT; write, DDL, attach, detach, vacuum, and multi-statement SQL are rejected mechanically.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute SQLite database file path."),
                "query": stringSchema(
                  "One read-only SELECT, WITH, or PRAGMA statement. Multiple statements and mutating SQL are rejected."
                ),
                "max_rows": integerSchema(
                  "Maximum rows to return. Defaults to 100. SELECT/WITH queries are executed through an outer LIMIT max_rows+1."
                ),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum sqlite3 stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."
                ),
              ],
              required: ["path", "query"]
            ),
            meta: toolMeta
          ))

      case "file.hash":
        tools.append(
          MCPTool(
            name: "file.hash",
            description:
              "Compute a SHA-256 hash for a workspace-contained file without returning content.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "algorithm": stringSchema("Hash algorithm. Only sha256 is currently supported."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.diff":
        tools.append(
          MCPTool(
            name: "file.diff",
            description:
              "Return a bounded unified diff between two workspace-contained files using fixed /usr/bin/diff argv. This is read-only.",
            inputSchema: objectSchema(
              properties: [
                "source": stringSchema("Workspace-relative or in-workspace absolute source file."),
                "target": stringSchema("Workspace-relative or in-workspace absolute target file."),
                "context_lines": integerSchema("Unified diff context lines. Defaults to 3."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ],
              required: ["source", "target"]
            ),
            meta: toolMeta
          ))

      case "file.compare_trees":
        tools.append(
          MCPTool(
            name: "file.compare_trees",
            description:
              "Compare two workspace-contained directory trees by relative path using bounded deterministic traversal. Defaults to metadata-only comparison; set compare_hashes=true to SHA-256 compare same-size files within explicit hash limits. This is read-only and does not run shell commands.",
            inputSchema: objectSchema(
              properties: [
                "left": stringSchema("Workspace-relative or in-workspace absolute left directory."),
                "right": stringSchema(
                  "Workspace-relative or in-workspace absolute right directory."),
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
            meta: toolMeta
          ))

      case "file.duplicates":
        tools.append(
          MCPTool(
            name: "file.duplicates",
            description:
              "Find duplicate regular files under a workspace-contained directory by size bucket and bounded SHA-256 hashing. This is read-only, skips symlinks, does not delete files, and returns deterministic duplicate groups plus follow-up contexts.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute directory. Defaults to workspace root."
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
                "max_groups": integerSchema("Maximum duplicate groups to return. Defaults to 100."),
                "max_files_per_group": integerSchema(
                  "Maximum files to return per duplicate group. Defaults to 20."),
              ]
            ),
            meta: toolMeta
          ))

      case "archive.list":
        tools.append(
          MCPTool(
            name: "archive.list",
            description:
              "List entries in a workspace-contained zip or tar archive using fixed read-only argv. This does not extract files.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute archive path."),
                "max_entries": integerSchema("Maximum entries to return. Defaults to 1000."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
                "max_output_bytes": integerSchema(
                  "Maximum stdout/stderr bytes per stream. Defaults to policy.max_output_bytes."),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "archive.read_file":
        tools.append(
          MCPTool(
            name: "archive.read_file",
            description:
              "Read one file member from a workspace-contained zip or tar archive using fixed read-only argv, returning UTF-8 text or base64 bytes. This streams the selected member to stdout without extracting files or writing to disk. Entry paths are normalized and must not be directories, absolute paths, parent escapes, option-like names, or archive wildcard patterns.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute archive path."),
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
            meta: toolMeta
          ))

      case "archive.extract":
        tools.append(
          MCPTool(
            name: "archive.extract",
            description:
              "Extract a workspace-contained zip or tar archive into a workspace-contained destination using fixed argv. This defaults to dry-run, validates entry paths, refuses link entries, and requires confirm_extract=true when dry_run is false.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute archive path."),
                "destination": stringSchema(
                  "Workspace-relative or in-workspace absolute destination directory."),
                "create_directories": boolSchema(
                  "Whether to create the destination directory if missing. Defaults to false."),
                "overwrite": boolSchema(
                  "Whether extraction may overwrite existing destination paths. Defaults to false."),
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
            meta: toolMeta
          ))

      case "archive.create":
        tools.append(
          MCPTool(
            name: "archive.create",
            description:
              "Create a zip or tar archive from explicit workspace-contained sources using fixed argv. This defaults to dry-run, refuses symlink sources/entries, prevents output inside sources, and requires confirm_create=true when dry_run is false.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute output archive path."),
                "sources": stringArraySchema(
                  "Workspace-relative or in-workspace absolute source files/directories to archive."
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
            meta: toolMeta
          ))

      case "file.download":
        tools.append(
          MCPTool(
            name: "file.download",
            description:
              "Download an absolute HTTP or HTTPS URL to a workspace-contained file using fixed /usr/bin/curl argv. This defaults to dry-run, writes through a deterministic temp file, rejects credentials in URLs, sends no custom headers/cookies/request body, and requires confirm_download=true when dry_run is false.",
            inputSchema: objectSchema(
              properties: [
                "url": stringSchema("Absolute http or https URL to download."),
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute destination file path."),
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
                "max_redirects": integerSchema("Maximum redirects when following. Defaults to 5."),
                "connect_timeout_seconds": integerSchema(
                  "Connection timeout in seconds. Defaults to 5; max 60."),
                "timeout_ms": integerSchema("Process timeout in milliseconds. Defaults to 30000."),
                "max_download_bytes": integerSchema(
                  "Maximum downloaded file size in bytes. Defaults to 10485760."),
                "max_output_bytes": integerSchema(
                  "Maximum curl stdout/stderr bytes per stream. Defaults to a small metadata allowance."
                ),
              ],
              required: ["url", "path"]
            ),
            meta: toolMeta
          ))

      case "file.write":
        tools.append(
          MCPTool(
            name: "file.write",
            description: "Write UTF-8 content to a file under the configured workspace directory.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
                "content": stringSchema("UTF-8 content to write."),
                "overwrite": boolSchema("Whether to overwrite an existing file. Defaults to true."),
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
            meta: toolMeta
          ))

      case "file.write_files":
        tools.append(
          MCPTool(
            name: "file.write_files",
            description:
              "Write multiple explicitly named UTF-8 files under the configured workspace directory. Defaults to dry-run and requires confirm_write=true for real writes.",
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
                        "Workspace-relative or in-workspace absolute file path."),
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
            meta: toolMeta
          ))

      case "file.append":
        tools.append(
          MCPTool(
            name: "file.append",
            description:
              "Append UTF-8 content to a workspace-contained file without rewriting existing content.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
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
            meta: toolMeta
          ))

      case "file.replace_text":
        tools.append(
          MCPTool(
            name: "file.replace_text",
            description:
              "Perform exact UTF-8 text replacement in a workspace-contained file without semantic editing.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
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
            meta: toolMeta
          ))

      case "file.insert_text":
        tools.append(
          MCPTool(
            name: "file.insert_text",
            description:
              "Insert exact UTF-8 text before or after a one-based line in a workspace-contained file.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
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
            meta: toolMeta
          ))

      case "file.replace_lines":
        tools.append(
          MCPTool(
            name: "file.replace_lines",
            description:
              "Replace or delete an exact one-based line range in a workspace-contained UTF-8 file without semantic editing.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
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
            meta: toolMeta
          ))

      case "file.touch":
        tools.append(
          MCPTool(
            name: "file.touch",
            description:
              "Create an empty workspace-contained file if missing or update an existing file modification time.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute file path."),
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
            meta: toolMeta
          ))

      case "file.mkdir":
        tools.append(
          MCPTool(
            name: "file.mkdir",
            description: "Create a directory under the configured workspace directory.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute directory path."),
                "intermediate_directories": boolSchema(
                  "Whether to create missing parent directories. Defaults to true."),
                "dry_run": boolSchema(
                  "Whether to validate directory creation without creating directories. Defaults to false."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "file.copy":
        tools.append(
          MCPTool(
            name: "file.copy",
            description:
              "Copy a file or directory between two workspace-contained paths. Does not overwrite unless requested.",
            inputSchema: objectSchema(
              properties: [
                "source": stringSchema("Workspace-relative or in-workspace absolute source path."),
                "destination": stringSchema(
                  "Workspace-relative or in-workspace absolute destination path."),
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
            meta: toolMeta
          ))

      case "file.move":
        tools.append(
          MCPTool(
            name: "file.move",
            description:
              "Move or rename a file or directory between two workspace-contained paths. Does not overwrite unless requested.",
            inputSchema: objectSchema(
              properties: [
                "source": stringSchema("Workspace-relative or in-workspace absolute source path."),
                "destination": stringSchema(
                  "Workspace-relative or in-workspace absolute destination path."),
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
            meta: toolMeta
          ))

      case "file.symlink":
        tools.append(
          MCPTool(
            name: "file.symlink",
            description:
              "Create a symbolic link at a workspace-contained path. By default the destination must resolve inside the workspace.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Workspace-relative or in-workspace absolute path where the symlink will be created."
                ),
                "destination": stringSchema(
                  "Raw symlink destination string. Relative destinations are resolved from the link parent for containment checks."
                ),
                "overwrite": boolSchema(
                  "Whether to overwrite an existing destination path. Defaults to false."),
                "create_directories": boolSchema(
                  "Whether to create missing link parent directories. Defaults to false."),
                "allow_external_destination": boolSchema(
                  "Whether to allow the symlink destination to resolve outside the workspace. Defaults to false."
                ),
                "dry_run": boolSchema(
                  "Whether to validate symlink creation without creating directories, overwriting, or creating the link. Defaults to false."
                ),
              ],
              required: ["path", "destination"]
            ),
            meta: toolMeta
          ))

      case "file.trash":
        tools.append(
          MCPTool(
            name: "file.trash",
            description:
              "Move a workspace-contained file or directory to the macOS Trash. This is a write operation.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema("Workspace-relative or in-workspace absolute path to trash."),
                "dry_run": boolSchema(
                  "Whether to validate the trash operation without moving the path to Trash. Defaults to false."
                ),
              ],
              required: ["path"]
            ),
            meta: toolMeta
          ))

      case "workspace.open":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "workspace.reveal":
        tools.append(
          MCPTool(
            name: "workspace.reveal",
            description: "Reveal a workspace-contained path in Finder using macOS open -R.",
            inputSchema: objectSchema(
              properties: [
                "path": stringSchema(
                  "Optional workspace-relative path. Defaults to workspace root."),
                "timeout_ms": integerSchema("Optional timeout in milliseconds."),
              ]
            ),
            meta: toolMeta
          ))

      case "git.root":
        tools.append(
          MCPTool(
            name: "git.root",
            description:
              "Return read-only git repository root and git-dir identity through the registered git CLI provider.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "git.config":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.remotes":
        tools.append(
          MCPTool(
            name: "git.remotes",
            description:
              "Return read-only git remote URLs through the registered git CLI provider.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "git.worktrees":
        tools.append(
          MCPTool(
            name: "git.worktrees",
            description:
              "Return read-only git worktree list through the registered git CLI provider.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "git.stashes":
        tools.append(
          MCPTool(
            name: "git.stashes",
            description:
              "Return read-only git stash list through the registered git CLI provider.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "git.stash_show":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.stash_push":
        tools.append(
          MCPTool(
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
                  "Whether to include untracked files with --include-untracked. Defaults to false."),
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
            meta: toolMeta
          ))

      case "git.tags":
        tools.append(
          MCPTool(
            name: "git.tags",
            description:
              "Return read-only git tag list through the registered git CLI provider.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "git.tag_show":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.tag_create":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.tag_delete":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.ignored":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.submodules":
        tools.append(
          MCPTool(
            name: "git.submodules",
            description:
              "Return read-only git submodule status through the registered git CLI provider.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "git.files":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.grep":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.blame":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.file_history":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.file_at_revision":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.staged_file":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.conflicts":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.status":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.tracking_status":
        tools.append(
          MCPTool(
            name: "git.tracking_status",
            description:
              "Return structured read-only current Git branch/upstream tracking status by parsing git status --branch --porcelain=v1. This does not fetch, pull, or push.",
            inputSchema: objectSchema(
              properties: [
                "timeout_ms": integerSchema("Optional timeout in milliseconds.")
              ]
            ),
            meta: toolMeta
          ))

      case "git.clean_preview":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.clean":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.reflog":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.refs":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.compare_refs":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.resolve_ref":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.merge_base":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.is_ancestor":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.diff":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.diff_summary":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.diff_check":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.branch":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.branch_create":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.branch_delete":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.branch_rename":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.branch_switch":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.log":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.commit_files":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.show":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.add":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.unstage":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.restore_worktree":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      case "git.commit":
        tools.append(
          MCPTool(
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
            meta: toolMeta
          ))

      default:
        continue
      }
    }

    return tools.map { tool in
      guard tool.annotations == nil else {
        return tool
      }
      return tool.withAnnotations(toolAnnotations(for: tool.name, builtins: builtins))
    }
  }

  private static let mutatingBuiltinNames: Set<String> = [
    "archive.create",
    "archive.extract",
    "file.append",
    "file.chmod",
    "file.copy",
    "file.download",
    "file.insert_text",
    "file.mkdir",
    "file.move",
    "file.remove_xattr",
    "file.replace_lines",
    "file.replace_text",
    "file.symlink",
    "file.touch",
    "file.trash",
    "file.write",
    "file.write_files",
    "git.add",
    "git.branch_create",
    "git.branch_delete",
    "git.branch_rename",
    "git.branch_switch",
    "git.clean",
    "git.commit",
    "git.restore_worktree",
    "git.stash_push",
    "git.tag_create",
    "git.tag_delete",
    "git.unstage",
    "json.write",
    "plist.write",
    "workspace.open",
    "workspace.reveal",
  ]

  private static let additiveBuiltinNames: Set<String> = [
    "file.append",
    "file.mkdir",
    "file.symlink",
    "git.branch_create",
    "git.commit",
    "git.tag_create",
    "workspace.open",
    "workspace.reveal",
  ]

  private static func toolAnnotations(
    for name: String,
    builtins: Set<String>
  ) -> MCPToolAnnotations {
    if builtins.contains(name) {
      let mutating = mutatingBuiltinNames.contains(name)
      let destructive = mutating && !additiveBuiltinNames.contains(name)
      let openWorld = name.hasPrefix("network.") || name == "file.download"
      return MCPToolAnnotations(
        readOnlyHint: !mutating,
        destructiveHint: destructive,
        idempotentHint: mutating ? false : nil,
        openWorldHint: openWorld
      )
    }

    if name.hasPrefix("skills.") {
      return MCPToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: false
      )
    }

    switch name {
    case "cli.list", "cli.describe", "cli.status", "cli.help",
      "mcp.servers.list", "mcp.servers.status", "mcp.tools.list", "mcp.tools.describe",
      "mcp.tools.find", "mcp.resources.list", "mcp.resources.templates.list",
      "mcp.resources.read", "mcp.prompts.list", "mcp.prompts.get", "mcp.events.read",
      "mcp.requests.list", "mcp.requests.read", "process.list",
      "process.read", "shell.list", "shell.read":
      return MCPToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: name.hasPrefix("mcp.")
      )

    case "workspace.open":
      return MCPToolAnnotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      )

    default:
      return MCPToolAnnotations(
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      )
    }
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

  private static func shellLaunchSchema(
    includeTimeout: Bool,
    includeStandardInput: Bool
  ) -> JSONValue {
    var properties: [String: JSONValue] = [
      "mode": stringSchema(
        "shell or argv. Shell mode runs command through the configured shell; argv mode runs executable with argv directly. Defaults to shell."
      ),
      "command": stringSchema("Command string required by shell mode."),
      "executable": stringSchema("Executable name or absolute path required by argv mode."),
      "argv": stringArraySchema("Argument vector used by argv mode."),
      "shell": stringSchema(
        "Optional absolute shell executable override for shell mode."
      ),
      "cwd": stringSchema(
        "Optional absolute or gateway-workspace-relative working directory."
      ),
      "env": .object([
        "type": .string("object"),
        "description": .string(
          "Optional environment overrides merged with the gateway process environment."
        ),
        "additionalProperties": .object(["type": .string("string")]),
      ]),
    ]
    if includeTimeout {
      properties["timeout_ms"] = integerSchema(
        "Optional positive timeout in milliseconds. For shell.spawn, omit for no timeout."
      )
    }
    if includeStandardInput {
      properties["stdin_text"] = stringSchema(
        "Optional UTF-8 stdin written before stdin is closed."
      )
      properties["stdin_base64"] = stringSchema(
        "Optional Base64 stdin written before stdin is closed."
      )
    }
    return objectSchema(properties: properties)
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
