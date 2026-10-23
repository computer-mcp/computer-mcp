import ComputerMCPCore

extension StructuredToolProvider {
  static func toolDefinitions(toolMeta: JSONValue?) -> [ToolDefinition] {
    [
      ToolDefinition(
        tool: MCPTool(
          name: "markdown.links",
          description:
            "Extract a bounded mechanical inventory of Markdown links from a project-contained UTF-8 Markdown file. This reports inline links, images, reference links, reference definitions, autolinks, and local target context; it does not follow links, fetch URLs, or infer document semantics.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative Markdown file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "markdown.links", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "markdown.tables",
          description:
            "Extract bounded GitHub-flavored pipe tables from a project-contained UTF-8 Markdown file. This reports headers, alignments, rows, line ranges, raw table text, and truncation flags; it does not infer table semantics, summarize content, or execute code blocks.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute Markdown file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "markdown.tables", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "markdown.section",
          description:
            "Extract one raw Markdown section by exact ATX heading text from a project-contained UTF-8 Markdown file. This uses explicit heading, optional level, and occurrence only; it does not search semantically, summarize, follow links, or parse arbitrary Markdown blocks.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute Markdown file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "markdown.section", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "markdown.frontmatter",
          description:
            "Read leading YAML or TOML frontmatter from a project-contained UTF-8 Markdown file. This only recognizes explicit opening delimiters at the start of the file, returns raw frontmatter plus parsed structured value when valid, and does not infer skill semantics, summarize, or scan the Markdown body.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute Markdown file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "markdown.frontmatter", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "markdown.link_check",
          description:
            "Check local Markdown links in one project-contained UTF-8 Markdown file. This resolves reference definitions, verifies project-contained local targets and Markdown fragments, and reports external URLs as unchecked; it does not fetch URLs, crawl documents, or infer document semantics.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema("Project-relative Markdown file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "markdown.link_check", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "image.info",
          description:
            "Read mechanical metadata for a project-contained image file using ImageIO. This reports format, MIME, dimensions, frame count, color metadata, and optional bounded raw properties; it does not decode pixels, OCR, classify, or generate previews.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute image file path."),
              "include_properties": boolSchema(
                "Whether to include bounded raw ImageIO property dictionaries. Defaults to false."
              ),
              "max_property_depth": integerSchema(
                "Maximum nested dictionary/array depth for raw properties when included. Defaults to 2."
              ),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "image.info", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "pdf.info",
          description:
            "Read mechanical metadata for a project-contained PDF file using PDFKit. This reports page count, encryption/permission flags, optional document attributes, and bounded page box metadata; it does not extract text, OCR, render pages, or summarize document contents.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute PDF file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "pdf.info", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "pdf.text",
          description:
            "Extract bounded searchable text from a project-contained PDF file using PDFKit page.string. This is read-only, respects PDF locking/copying flags, and does not OCR, render pages, inspect images, or summarize content.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute PDF file path."),
              "start_page": integerSchema(
                "One-based page number to start from. Defaults to 1."),
              "max_pages": integerSchema("Maximum pages to inspect. Defaults to 10."),
              "max_characters": integerSchema(
                "Maximum extracted characters to return across pages. Defaults to 100000."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "pdf.text", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "media.info",
          description:
            "Read mechanical metadata for a project-contained audio or video file using AVFoundation. This reports duration, playability, protected-content state, track types, codecs, frame-rate, dimensions, and data-rate; it does not decode samples, transcode, extract frames, play media, or infer content semantics.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute media file path."),
              "max_tracks": integerSchema(
                "Maximum track metadata rows to return. Defaults to 20; use 0 to omit track rows."
              ),
              "load_timeout_ms": integerSchema(
                "Maximum AVFoundation metadata load time per property. Defaults to 5000."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "media.info", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "json.read",
          description:
            "Read and parse a project-contained JSON file into a JSON value using the gateway JSON decoder. This is read-only and does not execute subprocesses.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute JSON file path."),
              "max_bytes": integerSchema(
                "Maximum JSON bytes to parse. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "json.read", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "jsonl.read",
          description:
            "Read a bounded preview of a project-contained JSON Lines / NDJSON UTF-8 file by parsing each nonblank line as an independent JSON value. This is read-only and does not infer data semantics.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute JSONL/NDJSON file path."),
              "start_line": integerSchema("One-based line to start scanning. Defaults to 1."),
              "max_records": integerSchema(
                "Maximum parsed records to return. Defaults to 100."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "jsonl.read", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "json.write",
          description:
            "Serialize a provided JSON value and write it to a project-contained file. Defaults to dry-run, sorted keys, pretty output, and requires confirm_write=true for real writes.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute JSON file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "json.write", risk: .destructive,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "toml.read",
          description:
            "Read and parse a project-contained TOML file into a JSON value using the existing swift-toml decoder. This is read-only and does not execute subprocesses.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute TOML file path."),
              "max_bytes": integerSchema(
                "Maximum TOML bytes to parse. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "toml.read", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "yaml.read",
          description:
            "Read and parse a project-contained YAML file into JSON-compatible values using Yams. This is read-only, supports multiple YAML documents, and does not execute subprocesses or infer business semantics.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute YAML file path."),
              "max_bytes": integerSchema(
                "Maximum YAML bytes to parse. Defaults to policy.max_output_bytes."),
              "max_documents": integerSchema(
                "Maximum YAML documents to return. Defaults to 50."),
              "max_depth": integerSchema(
                "Maximum nested YAML depth to convert. Defaults to 128."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "yaml.read", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "xml.read",
          description:
            "Read and parse a project-contained XML file into a bounded element tree using Foundation XMLParser. This is read-only, disables external entity resolution, and does not validate schemas or infer business semantics.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute XML file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "xml.read", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "plist.read",
          description:
            "Read and parse a project-contained macOS property list file into JSON using Foundation PropertyListSerialization. This is read-only and does not execute subprocesses.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute plist file path."),
              "max_bytes": integerSchema(
                "Maximum plist bytes to parse. Defaults to policy.max_output_bytes."),
            ],
            required: ["path"]
          ),
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "plist.read", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "structured.get",
          description:
            "Read one value at an explicit path from a project-contained JSON, YAML, TOML, or plist file. query_path is a mechanical array of object keys and array indexes; this is not JSONPath/JQ, does not filter or wildcard, and does not infer field semantics.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute structured data file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "structured.get", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "plist.write",
          description:
            "Serialize a provided JSON value as a project-contained macOS property list using Foundation PropertyListSerialization. Defaults to dry-run XML output and requires confirm_write=true for real writes. Typed date/data objects from plist.read can be written back.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute plist file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "plist.write", risk: .destructive,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "csv.read",
          description:
            "Read a bounded preview of a project-contained CSV/TSV-style delimited UTF-8 text file. This parses delimiter, quotes, rows, and cells mechanically; it does not infer business semantics or execute subprocesses.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute CSV/TSV file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "csv.read", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "sqlite.schema",
          description:
            "Inspect a project-contained SQLite database schema using fixed /usr/bin/sqlite3 -readonly -json argv. This returns sqlite_schema entries only; it does not execute user SQL or read table rows.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute SQLite database file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "sqlite.schema", risk: .readOnly,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "sqlite.query",
          description:
            "Run one read-only SELECT, WITH, or non-assigning PRAGMA statement against a project-contained SQLite database using fixed /usr/bin/sqlite3 -readonly -json argv. SELECT/WITH queries are wrapped with a max_rows LIMIT; write, DDL, attach, detach, vacuum, and multi-statement SQL are rejected mechanically.",
          inputSchema: objectSchema(
            properties: [
              "path": stringSchema(
                "Project-relative or in-project absolute SQLite database file path."),
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
          annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, openWorldHint: false),
          meta: toolMeta
        ),
        capability: CapabilityDescriptor(
          id: "sqlite.query", risk: .readOnly,
          projectRequirement: .optional,
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
