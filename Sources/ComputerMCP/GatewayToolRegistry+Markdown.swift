import Foundation
import TOML
import Yams

extension GatewayToolRegistry {
  internal func markdownLinks(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let includeImages = try optionalBool("include_images", in: object) ?? true
    let includeReferenceDefinitions =
      try optionalBool("include_reference_definitions", in: object) ?? true
    let includeAutolinks = try optionalBool("include_autolinks", in: object) ?? true
    let includeCodeBlocks = try optionalBool("include_code_blocks", in: object) ?? false
    let maxLinks = optionalInt("max_links", in: object) ?? 200
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxLinks, name: "max_links", upperBound: 100_000)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)

    let inventory = try readMarkdownLinkInventory(
      path: path,
      includeImages: includeImages,
      includeReferenceDefinitions: includeReferenceDefinitions,
      includeAutolinks: includeAutolinks,
      includeCodeBlocks: includeCodeBlocks,
      maxBytes: maxBytes
    )

    let returnedLinks = Array(inventory.links.prefix(maxLinks))
    let resultTruncated = inventory.links.count > returnedLinks.count

    return .object([
      "operation": .string("markdown.links"),
      "path": .string(inventory.url.path),
      "workspace_relative_path": .string(inventory.info.workspaceRelativePath),
      "encoding": .string("utf-8"),
      "include_images": .bool(includeImages),
      "include_reference_definitions": .bool(includeReferenceDefinitions),
      "include_autolinks": .bool(includeAutolinks),
      "include_code_blocks": .bool(includeCodeBlocks),
      "max_links": .integer(Int64(maxLinks)),
      "max_bytes": .integer(Int64(maxBytes)),
      "bytes_scanned": .integer(Int64(inventory.bytesScanned)),
      "file_truncated": .bool(inventory.fileTruncated),
      "link_count": .integer(Int64(inventory.links.count)),
      "returned_count": .integer(Int64(returnedLinks.count)),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(inventory.fileTruncated || resultTruncated),
      "links": .array(returnedLinks.map(\.json)),
    ])
  }

  internal func markdownTables(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let includeCodeBlocks = try optionalBool("include_code_blocks", in: object) ?? false
    let maxTables = optionalInt("max_tables", in: object) ?? 20
    let maxRowsPerTable = optionalInt("max_rows_per_table", in: object) ?? 100
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxTables, name: "max_tables", upperBound: 10_000)
    try validateBoundedPositive(maxRowsPerTable, name: "max_rows_per_table", upperBound: 100_000)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let fileTruncated = data.count > maxBytes
    let contentData = fileTruncated ? Data(data.prefix(maxBytes)) : data
    guard let content = String(data: contentData, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("Markdown file is not valid UTF-8: \(path)")
    }

    let tables = markdownTablesInContent(content, includeCodeBlocks: includeCodeBlocks)
    let returnedTables = Array(tables.prefix(maxTables))
    let tableResultTruncated = tables.count > returnedTables.count
    let rowTruncatedCount = returnedTables.filter { $0.rows.count > maxRowsPerTable }.count

    return .object([
      "operation": .string("markdown.tables"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "encoding": .string("utf-8"),
      "include_code_blocks": .bool(includeCodeBlocks),
      "max_tables": .integer(Int64(maxTables)),
      "max_rows_per_table": .integer(Int64(maxRowsPerTable)),
      "max_bytes": .integer(Int64(maxBytes)),
      "bytes_scanned": .integer(Int64(contentData.count)),
      "file_truncated": .bool(fileTruncated),
      "table_count": .integer(Int64(tables.count)),
      "returned_count": .integer(Int64(returnedTables.count)),
      "row_truncated_table_count": .integer(Int64(rowTruncatedCount)),
      "result_truncated": .bool(tableResultTruncated),
      "truncated": .bool(tableResultTruncated || rowTruncatedCount > 0 || fileTruncated),
      "tables": .array(returnedTables.map { $0.json(maxRowsPerTable: maxRowsPerTable) }),
    ])
  }

  internal func markdownTablesInContent(
    _ content: String,
    includeCodeBlocks: Bool
  ) -> [MarkdownTableInfo] {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var tables: [MarkdownTableInfo] = []
    var insideFence = false
    var index = 0

    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if markdownFenceToggleLine(trimmed) {
        insideFence.toggle()
        index += 1
        continue
      }
      if insideFence && !includeCodeBlocks {
        index += 1
        continue
      }
      guard index + 1 < lines.count,
        let header = markdownTableCells(lines[index]),
        let delimiter = markdownTableDelimiter(lines[index + 1]),
        header.count == delimiter.count
      else {
        index += 1
        continue
      }

      var rows: [MarkdownTableRowInfo] = []
      var rowIndex = index + 2
      while rowIndex < lines.count {
        let rowTrimmed = lines[rowIndex].trimmingCharacters(in: .whitespaces)
        if markdownFenceToggleLine(rowTrimmed) {
          break
        }
        guard let cells = markdownTableCells(lines[rowIndex]) else {
          break
        }
        rows.append(MarkdownTableRowInfo(line: rowIndex + 1, cells: cells))
        rowIndex += 1
      }

      let rawEndIndex = max(index + 2, rowIndex)
      let raw = Array(lines[index..<rawEndIndex]).joined(separator: "\n")
      tables.append(
        MarkdownTableInfo(
          startLine: index + 1,
          endLine: rawEndIndex,
          headerLine: index + 1,
          delimiterLine: index + 2,
          headers: header,
          alignments: delimiter,
          rows: rows,
          raw: raw
        ))
      index = rawEndIndex
    }

    return tables
  }

  private func markdownTableCells(_ line: String) -> [String]? {
    guard line.contains("|") else {
      return nil
    }
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in line {
      if escaped {
        current.append(character)
        escaped = false
        continue
      }
      if character == "\\" {
        escaped = true
        current.append(character)
        continue
      }
      if character == "|" {
        cells.append(markdownTableCellText(current))
        current = ""
      } else {
        current.append(character)
      }
    }
    cells.append(markdownTableCellText(current))
    if cells.first == "" {
      cells.removeFirst()
    }
    if cells.last == "" {
      cells.removeLast()
    }
    return cells.count >= 2 ? cells : nil
  }

  private func markdownTableCellText(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|")
  }

  private func markdownTableDelimiter(_ line: String) -> [String]? {
    guard let cells = markdownTableCells(line) else {
      return nil
    }
    var alignments: [String] = []
    for cell in cells {
      guard let alignment = markdownTableDelimiterAlignment(cell) else {
        return nil
      }
      alignments.append(alignment)
    }
    return alignments
  }

  private func markdownTableDelimiterAlignment(_ cell: String) -> String? {
    let trimmed = cell.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else {
      return nil
    }
    var body = trimmed
    let left = body.first == ":"
    if left {
      body.removeFirst()
    }
    let right = body.last == ":"
    if right {
      body.removeLast()
    }
    guard body.count >= 3, body.allSatisfy({ $0 == "-" }) else {
      return nil
    }
    if left && right {
      return "center"
    }
    if right {
      return "right"
    }
    if left {
      return "left"
    }
    return "none"
  }

  internal func markdownFenceToggleLine(_ trimmedLine: String) -> Bool {
    trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
  }

  internal func markdownSection(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let heading = try requiredString("heading", in: object)
    let level = optionalInt("level", in: object)
    let occurrence = optionalInt("occurrence", in: object) ?? 1
    let includeHeading = try optionalBool("include_heading", in: object) ?? true
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let maxSectionBytes =
      optionalInt("max_section_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(
      maxSectionBytes, name: "max_section_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(occurrence, name: "occurrence", upperBound: 10_000)
    if let level {
      try validateBoundedPositive(level, name: "level", upperBound: 6)
    }

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let fileTruncated = data.count > maxBytes
    let contentData = fileTruncated ? Data(data.prefix(maxBytes)) : data
    guard let content = String(data: contentData, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("Markdown file is not valid UTF-8: \(path)")
    }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var insideFence = false
    var matchCount = 0
    var selectedHeading: FileOutlineItem?
    var selectedStartIndex: Int?
    var selectedEndIndex: Int?
    var followingHeading: FileOutlineItem?

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        insideFence.toggle()
        continue
      }
      guard !insideFence, let item = markdownHeading(trimmed, lineNumber: index + 1),
        item.kind == "heading", let itemLevel = item.level
      else {
        continue
      }

      if let selectedStartIndex, selectedEndIndex == nil,
        let selectedLevel = selectedHeading?.level,
        index > selectedStartIndex,
        itemLevel <= selectedLevel
      {
        selectedEndIndex = index
        followingHeading = item
      }

      if item.name == heading && (level == nil || itemLevel == level) {
        matchCount += 1
        if matchCount == occurrence {
          selectedHeading = item
          selectedStartIndex = index
        }
      }
    }

    guard let selectedHeading, let selectedStartIndex else {
      return .object([
        "operation": .string("markdown.section"),
        "path": .string(url.path),
        "workspace_relative_path": .string(info.workspaceRelativePath),
        "encoding": .string("utf-8"),
        "heading": .string(heading),
        "level": level.map { .integer(Int64($0)) } ?? .null,
        "occurrence": .integer(Int64(occurrence)),
        "include_heading": .bool(includeHeading),
        "max_bytes": .integer(Int64(maxBytes)),
        "max_section_bytes": .integer(Int64(maxSectionBytes)),
        "bytes_scanned": .integer(Int64(contentData.count)),
        "file_truncated": .bool(fileTruncated),
        "match_count": .integer(Int64(matchCount)),
        "matched": .bool(false),
        "failure": .object([
          "reason": .string("missing_heading")
        ]),
        "section": .null,
        "outline_context": markdownSectionOutlineContext(info.workspaceRelativePath),
      ])
    }

    let endIndex = selectedEndIndex ?? lines.count
    let contentStartIndex = includeHeading ? selectedStartIndex : selectedStartIndex + 1
    let selectedLines =
      contentStartIndex < endIndex ? Array(lines[contentStartIndex..<endIndex]) : []
    let rawSection = selectedLines.joined(separator: "\n")
    let rawSectionData = Data(rawSection.utf8)
    let sectionData =
      rawSectionData.count > maxSectionBytes
      ? Data(rawSectionData.prefix(maxSectionBytes)) : rawSectionData
    let sectionContentTruncated = rawSectionData.count > sectionData.count
    let sectionMayBeTruncated = fileTruncated && selectedEndIndex == nil
    let startLine = selectedLines.isEmpty ? selectedHeading.line : contentStartIndex + 1
    let endLine =
      selectedLines.isEmpty ? selectedHeading.line : contentStartIndex + selectedLines.count

    return .object([
      "operation": .string("markdown.section"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "encoding": .string("utf-8"),
      "heading": .string(heading),
      "level": level.map { .integer(Int64($0)) } ?? .null,
      "occurrence": .integer(Int64(occurrence)),
      "include_heading": .bool(includeHeading),
      "max_bytes": .integer(Int64(maxBytes)),
      "max_section_bytes": .integer(Int64(maxSectionBytes)),
      "bytes_scanned": .integer(Int64(contentData.count)),
      "file_truncated": .bool(fileTruncated),
      "match_count": .integer(Int64(matchCount)),
      "matched": .bool(true),
      "failure": .null,
      "matched_heading": selectedHeading.json,
      "following_heading": followingHeading?.json ?? .null,
      "section": .object([
        "start_line": .integer(Int64(startLine)),
        "end_line": .integer(Int64(endLine)),
        "heading_line": .integer(Int64(selectedHeading.line)),
        "line_count": .integer(Int64(selectedLines.count)),
        "content_bytes": .integer(Int64(rawSectionData.count)),
        "returned_content_bytes": .integer(Int64(sectionData.count)),
        "content_truncated": .bool(sectionContentTruncated),
        "section_may_be_truncated": .bool(sectionMayBeTruncated),
        "content": .string(String(decoding: sectionData, as: UTF8.self)),
      ]),
      "read_context": .object([
        "tool": .string("file.read_context"),
        "arguments": .object([
          "path": .string(info.workspaceRelativePath),
          "line": .integer(Int64(selectedHeading.line)),
          "before": .number(2),
          "after": .number(20),
        ]),
      ]),
      "outline_context": markdownSectionOutlineContext(info.workspaceRelativePath),
    ])
  }

  private func markdownSectionOutlineContext(_ path: String) -> JSONValue {
    .object([
      "tool": .string("file.outline"),
      "arguments": .object([
        "path": .string(path)
      ]),
    ])
  }

  internal func markdownFrontmatter(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let requestedFormat = try optionalString("format", in: object) ?? "auto"
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let maxDepth = optionalInt("max_depth", in: object) ?? 128
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 512)
    let formats = try markdownFrontmatterFormats(requestedFormat)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let data = try readBoundedFileData(url: url, path: path, maxBytes: maxBytes)
    guard let content = String(data: data, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("Markdown file is not valid UTF-8: \(path)")
    }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
      let opening = markdownFrontmatterOpening(firstLine, allowedFormats: formats)
    else {
      return markdownFrontmatterPayload(
        path: url.path,
        workspaceRelativePath: info.workspaceRelativePath,
        requestedFormat: requestedFormat,
        format: nil,
        maxBytes: maxBytes,
        maxDepth: maxDepth,
        bytesScanned: data.count,
        lineCount: lines.count,
        hasOpening: false,
        hasClosing: false,
        found: false,
        raw: nil,
        rawStartLine: nil,
        rawEndLine: nil,
        closingLine: nil,
        bodyStartLine: nil,
        parsed: false,
        value: .null,
        documentMetadata: .null,
        failureReason: "missing_frontmatter",
        parseError: nil
      )
    }

    let closingIndex = lines.dropFirst().enumerated().first { _, line in
      markdownFrontmatterClosing(
        line.trimmingCharacters(in: .whitespacesAndNewlines),
        format: opening.format
      )
    }?.offset

    guard let closingOffset = closingIndex else {
      return markdownFrontmatterPayload(
        path: url.path,
        workspaceRelativePath: info.workspaceRelativePath,
        requestedFormat: requestedFormat,
        format: opening.format,
        maxBytes: maxBytes,
        maxDepth: maxDepth,
        bytesScanned: data.count,
        lineCount: lines.count,
        hasOpening: true,
        hasClosing: false,
        found: false,
        raw: nil,
        rawStartLine: nil,
        rawEndLine: nil,
        closingLine: nil,
        bodyStartLine: nil,
        parsed: false,
        value: .null,
        documentMetadata: .null,
        failureReason: "unterminated_frontmatter",
        parseError: nil
      )
    }

    let closingLineIndex = closingOffset + 1
    let rawLines = closingLineIndex > 1 ? Array(lines[1..<closingLineIndex]) : []
    let raw = rawLines.joined(separator: "\n")
    let rawData = Data(raw.utf8)
    let parsedDocument: StructuredDocument?
    let parseError: String?
    do {
      parsedDocument = try parseStructuredValue(
        data: rawData,
        format: opening.format,
        path: path,
        maxBytes: max(rawData.count, 1),
        maxDocuments: 1,
        maxDepth: maxDepth
      )
      parseError = nil
    } catch {
      parsedDocument = nil
      parseError = error.localizedDescription
    }

    return markdownFrontmatterPayload(
      path: url.path,
      workspaceRelativePath: info.workspaceRelativePath,
      requestedFormat: requestedFormat,
      format: opening.format,
      maxBytes: maxBytes,
      maxDepth: maxDepth,
      bytesScanned: data.count,
      lineCount: lines.count,
      hasOpening: true,
      hasClosing: true,
      found: true,
      raw: raw,
      rawStartLine: 2,
      rawEndLine: closingLineIndex,
      closingLine: closingLineIndex + 1,
      bodyStartLine: closingLineIndex + 2,
      parsed: parsedDocument != nil,
      value: parsedDocument?.value ?? .null,
      documentMetadata: parsedDocument?.metadata ?? .null,
      failureReason: nil,
      parseError: parseError
    )
  }

  internal func markdownFrontmatterFormats(_ requestedFormat: String) throws -> Set<String> {
    let normalized = requestedFormat.lowercased()
    switch normalized {
    case "auto":
      return ["yaml", "toml"]
    case "yaml", "toml":
      return [normalized]
    default:
      throw GatewayToolError.invalidArguments("format must be one of: auto, yaml, toml.")
    }
  }

  internal func markdownFrontmatterOpening(
    _ line: String,
    allowedFormats: Set<String>
  ) -> (format: String, delimiter: String)? {
    if line == "---", allowedFormats.contains("yaml") {
      return ("yaml", "---")
    }
    if line == "+++", allowedFormats.contains("toml") {
      return ("toml", "+++")
    }
    return nil
  }

  internal func markdownFrontmatterClosing(_ line: String, format: String) -> Bool {
    switch format {
    case "yaml":
      return line == "---" || line == "..."
    case "toml":
      return line == "+++"
    default:
      return false
    }
  }

  private func markdownFrontmatterPayload(
    path: String,
    workspaceRelativePath: String,
    requestedFormat: String,
    format: String?,
    maxBytes: Int,
    maxDepth: Int,
    bytesScanned: Int,
    lineCount: Int,
    hasOpening: Bool,
    hasClosing: Bool,
    found: Bool,
    raw: String?,
    rawStartLine: Int?,
    rawEndLine: Int?,
    closingLine: Int?,
    bodyStartLine: Int?,
    parsed: Bool,
    value: JSONValue,
    documentMetadata: JSONValue,
    failureReason: String?,
    parseError: String?
  ) -> JSONValue {
    .object([
      "operation": .string("markdown.frontmatter"),
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "encoding": .string("utf-8"),
      "requested_format": .string(requestedFormat),
      "format": format.map(JSONValue.string) ?? .null,
      "max_bytes": .integer(Int64(maxBytes)),
      "max_depth": .integer(Int64(maxDepth)),
      "bytes_scanned": .integer(Int64(bytesScanned)),
      "line_count": .integer(Int64(lineCount)),
      "has_opening_delimiter": .bool(hasOpening),
      "has_closing_delimiter": .bool(hasClosing),
      "found": .bool(found),
      "raw": raw.map(JSONValue.string) ?? .null,
      "raw_bytes": raw.map { .integer(Int64(Data($0.utf8).count)) } ?? .null,
      "raw_start_line": rawStartLine.map { .integer(Int64($0)) } ?? .null,
      "raw_end_line": rawEndLine.map { .integer(Int64($0)) } ?? .null,
      "closing_line": closingLine.map { .integer(Int64($0)) } ?? .null,
      "body_start_line": bodyStartLine.map { .integer(Int64($0)) } ?? .null,
      "parsed": .bool(parsed),
      "parse_error": parseError.map(JSONValue.string) ?? .null,
      "failure": failureReason.map { .object(["reason": .string($0)]) } ?? .null,
      "value": value,
      "document_metadata": documentMetadata,
      "structured_get_context": found && parsed
        ? .object([
          "tool": .string("structured.get"),
          "note": .string(
            "For field-level access, copy this frontmatter value or read a standalone structured file; embedded Markdown frontmatter is not a filesystem path."
          ),
        ]) : .null,
    ])
  }

  internal func markdownLinkCheck(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let includeImages = try optionalBool("include_images", in: object) ?? true
    let includeReferenceDefinitions =
      try optionalBool("include_reference_definitions", in: object) ?? true
    let includeAutolinks = try optionalBool("include_autolinks", in: object) ?? true
    let includeCodeBlocks = try optionalBool("include_code_blocks", in: object) ?? false
    let checkFragments = try optionalBool("check_fragments", in: object) ?? true
    let maxLinks = optionalInt("max_links", in: object) ?? 200
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let maxTargetBytes =
      optionalInt("max_target_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxLinks, name: "max_links", upperBound: 100_000)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxTargetBytes, name: "max_target_bytes", upperBound: 20_971_520)

    let inventory = try readMarkdownLinkInventory(
      path: path,
      includeImages: includeImages,
      includeReferenceDefinitions: true,
      includeAutolinks: includeAutolinks,
      includeCodeBlocks: includeCodeBlocks,
      maxBytes: maxBytes
    )
    let definitions = markdownReferenceDefinitions(inventory.links)
    let linksToCheck = inventory.links.filter {
      includeReferenceDefinitions || $0.kind != "reference_definition"
    }

    var checks: [MarkdownLinkCheckResult] = []
    var okCount = 0
    var brokenCount = 0
    var uncheckedCount = 0
    var localCount = 0
    var externalCount = 0
    var fragmentCount = 0
    var targetTruncatedCount = 0

    for link in linksToCheck {
      let result = markdownLinkCheckResult(
        link: link,
        sourceURL: inventory.url,
        definitions: definitions,
        checkFragments: checkFragments,
        maxTargetBytes: maxTargetBytes
      )
      checks.append(result)
      switch result.category {
      case "ok":
        okCount += 1
      case "broken":
        brokenCount += 1
      default:
        uncheckedCount += 1
      }
      if result.isLocal {
        localCount += 1
      }
      if result.isExternal {
        externalCount += 1
      }
      if result.hasFragment {
        fragmentCount += 1
      }
      if result.targetTruncated {
        targetTruncatedCount += 1
      }
    }

    let returnedChecks = Array(checks.prefix(maxLinks))
    let resultTruncated = checks.count > returnedChecks.count

    return .object([
      "operation": .string("markdown.link_check"),
      "path": .string(inventory.url.path),
      "workspace_relative_path": .string(inventory.info.workspaceRelativePath),
      "encoding": .string("utf-8"),
      "include_images": .bool(includeImages),
      "include_reference_definitions": .bool(includeReferenceDefinitions),
      "include_autolinks": .bool(includeAutolinks),
      "include_code_blocks": .bool(includeCodeBlocks),
      "check_fragments": .bool(checkFragments),
      "max_links": .integer(Int64(maxLinks)),
      "max_bytes": .integer(Int64(maxBytes)),
      "max_target_bytes": .integer(Int64(maxTargetBytes)),
      "bytes_scanned": .integer(Int64(inventory.bytesScanned)),
      "file_truncated": .bool(inventory.fileTruncated),
      "check_count": .integer(Int64(checks.count)),
      "returned_count": .integer(Int64(returnedChecks.count)),
      "ok_count": .integer(Int64(okCount)),
      "broken_count": .integer(Int64(brokenCount)),
      "unchecked_count": .integer(Int64(uncheckedCount)),
      "local_count": .integer(Int64(localCount)),
      "external_count": .integer(Int64(externalCount)),
      "fragment_count": .integer(Int64(fragmentCount)),
      "target_truncated_count": .integer(Int64(targetTruncatedCount)),
      "reference_definition_count": .integer(Int64(definitions.count)),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(inventory.fileTruncated || resultTruncated || targetTruncatedCount > 0),
      "checks": .array(returnedChecks.map(\.json)),
    ])
  }

  private func readMarkdownLinkInventory(
    path: String,
    includeImages: Bool,
    includeReferenceDefinitions: Bool,
    includeAutolinks: Bool,
    includeCodeBlocks: Bool,
    maxBytes: Int
  ) throws -> MarkdownLinkInventory {
    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let fileTruncated = data.count > maxBytes
    let contentData = fileTruncated ? Data(data.prefix(maxBytes)) : data
    guard let content = String(data: contentData, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("Markdown file is not valid UTF-8: \(path)")
    }

    let links = markdownLinksInContent(
      content,
      sourceURL: url,
      includeImages: includeImages,
      includeReferenceDefinitions: includeReferenceDefinitions,
      includeAutolinks: includeAutolinks,
      includeCodeBlocks: includeCodeBlocks
    )
    return MarkdownLinkInventory(
      url: url,
      info: info,
      bytesScanned: contentData.count,
      fileTruncated: fileTruncated,
      links: links
    )
  }

  internal func markdownLinksInContent(
    _ content: String,
    sourceURL: URL,
    includeImages: Bool,
    includeReferenceDefinitions: Bool,
    includeAutolinks: Bool,
    includeCodeBlocks: Bool
  ) -> [MarkdownLinkInfo] {
    var links: [MarkdownLinkInfo] = []
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var insideFence = false
    for (index, line) in lines.enumerated() {
      let lineNumber = index + 1
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        if includeCodeBlocks {
          links.append(
            contentsOf: markdownLinksInLine(
              line,
              lineNumber: lineNumber,
              sourceURL: sourceURL,
              includeImages: includeImages,
              includeReferenceDefinitions: includeReferenceDefinitions,
              includeAutolinks: includeAutolinks
            ))
        }
        insideFence.toggle()
        continue
      }
      if insideFence && !includeCodeBlocks {
        continue
      }
      links.append(
        contentsOf: markdownLinksInLine(
          line,
          lineNumber: lineNumber,
          sourceURL: sourceURL,
          includeImages: includeImages,
          includeReferenceDefinitions: includeReferenceDefinitions,
          includeAutolinks: includeAutolinks
        ))
    }
    return links
  }

  internal func markdownReferenceDefinitions(_ links: [MarkdownLinkInfo]) -> [String:
    MarkdownLinkInfo]
  {
    var definitions: [String: MarkdownLinkInfo] = [:]
    for link in links where link.kind == "reference_definition" {
      guard let label = link.referenceLabel ?? link.label else {
        continue
      }
      let key = markdownReferenceKey(label)
      if !key.isEmpty, definitions[key] == nil {
        definitions[key] = link
      }
    }
    return definitions
  }

  internal func markdownReferenceKey(_ label: String) -> String {
    label
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private func markdownLinkCheckResult(
    link: MarkdownLinkInfo,
    sourceURL: URL,
    definitions: [String: MarkdownLinkInfo],
    checkFragments: Bool,
    maxTargetBytes: Int
  ) -> MarkdownLinkCheckResult {
    var resolvedDestination = link.destination
    var resolvedTarget = link.target
    var resolvedViaReferenceDefinition = false
    var referenceDefinitionLine: Int?

    if resolvedDestination == nil, link.kind == "reference_link" || link.kind == "reference_image" {
      let key = markdownReferenceKey(link.referenceLabel ?? link.label ?? "")
      if let definition = definitions[key] {
        resolvedDestination = definition.destination
        resolvedTarget = definition.target
        resolvedViaReferenceDefinition = true
        referenceDefinitionLine = definition.line
      } else {
        return MarkdownLinkCheckResult(
          link: link,
          resolvedDestination: nil,
          resolvedViaReferenceDefinition: false,
          referenceDefinitionLine: nil,
          status: "missing_reference_definition",
          category: "broken",
          issue: "Reference link has no matching reference definition.",
          target: nil
        )
      }
    }

    guard let destination = resolvedDestination, !destination.isEmpty else {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "empty_destination",
        category: "broken",
        issue: "Link destination is empty.",
        target: resolvedTarget
      )
    }
    guard let target = resolvedTarget else {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: destination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "external_unchecked",
        category: "unchecked",
        issue: "Destination target was not resolved by the Markdown parser.",
        target: nil
      )
    }

    switch target.kind {
    case "url", "email":
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: destination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "external_unchecked",
        category: "unchecked",
        issue: "External destinations are not fetched by the gateway.",
        target: target,
        isExternal: true
      )

    case "empty":
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: destination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "empty_destination",
        category: "broken",
        issue: "Link destination is empty.",
        target: target
      )

    case "fragment":
      return markdownLocalLinkCheckResult(
        link: link,
        resolvedDestination: destination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        target: target,
        targetURL: sourceURL,
        fragment: target.fragment,
        checkFragments: checkFragments,
        maxTargetBytes: maxTargetBytes
      )

    case "relative_path", "absolute_path":
      guard target.targetWorkspaceContained == true, let targetPath = target.targetPath else {
        return MarkdownLinkCheckResult(
          link: link,
          resolvedDestination: destination,
          resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
          referenceDefinitionLine: referenceDefinitionLine,
          status: "outside_workspace",
          category: "broken",
          issue: "Local link target is outside the configured workspace.",
          target: target,
          isLocal: true
        )
      }
      return markdownLocalLinkCheckResult(
        link: link,
        resolvedDestination: destination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        target: target,
        targetURL: URL(fileURLWithPath: targetPath),
        fragment: target.fragment,
        checkFragments: checkFragments,
        maxTargetBytes: maxTargetBytes
      )

    default:
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: destination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "external_unchecked",
        category: "unchecked",
        issue: "Unsupported Markdown target kind: \(target.kind)",
        target: target
      )
    }
  }

  private func markdownLocalLinkCheckResult(
    link: MarkdownLinkInfo,
    resolvedDestination: String,
    resolvedViaReferenceDefinition: Bool,
    referenceDefinitionLine: Int?,
    target: MarkdownLinkTargetInfo,
    targetURL: URL,
    fragment: String?,
    checkFragments: Bool,
    maxTargetBytes: Int
  ) -> MarkdownLinkCheckResult {
    var isDirectory = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
    guard exists else {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "missing_target",
        category: "broken",
        issue: "Local link target does not exist.",
        target: target,
        targetExists: false,
        isLocal: true,
        hasFragment: fragment != nil
      )
    }

    guard let fragment else {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "ok",
        category: "ok",
        issue: nil,
        target: target,
        targetExists: true,
        targetIsDirectory: isDirectory.boolValue,
        isLocal: true
      )
    }

    if fragment.isEmpty {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "ok",
        category: "ok",
        issue: nil,
        target: target,
        targetExists: true,
        targetIsDirectory: isDirectory.boolValue,
        isLocal: true,
        hasFragment: true,
        fragmentChecked: false
      )
    }

    guard checkFragments else {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "fragment_unchecked",
        category: "unchecked",
        issue: "Fragment checking is disabled.",
        target: target,
        targetExists: true,
        targetIsDirectory: isDirectory.boolValue,
        isLocal: true,
        hasFragment: true,
        fragmentChecked: false
      )
    }

    guard !isDirectory.boolValue, outlineLanguage(for: targetURL) == "markdown" else {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "fragment_unchecked",
        category: "unchecked",
        issue: "Fragments are checked only for Markdown file targets.",
        target: target,
        targetExists: true,
        targetIsDirectory: isDirectory.boolValue,
        isLocal: true,
        hasFragment: true,
        fragmentChecked: false
      )
    }

    let scan: MarkdownAnchorScanResult
    do {
      scan = try markdownAnchorScan(url: targetURL, maxBytes: maxTargetBytes)
    } catch {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "fragment_unchecked",
        category: "unchecked",
        issue: "Unable to read Markdown target for fragment checking.",
        target: target,
        targetExists: true,
        targetIsDirectory: false,
        isLocal: true,
        hasFragment: true,
        fragmentChecked: false
      )
    }

    let normalizedFragment = markdownAnchorKey(fragment)
    let fragmentFound = scan.anchors.contains(normalizedFragment)
    if fragmentFound {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "ok",
        category: "ok",
        issue: nil,
        target: target,
        targetExists: true,
        targetIsDirectory: false,
        isLocal: true,
        hasFragment: true,
        fragmentChecked: true,
        fragmentFound: true,
        targetBytesScanned: scan.bytesScanned,
        targetTruncated: scan.truncated
      )
    }

    if scan.truncated {
      return MarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "fragment_unchecked",
        category: "unchecked",
        issue: "Markdown target was truncated before the fragment was found.",
        target: target,
        targetExists: true,
        targetIsDirectory: false,
        isLocal: true,
        hasFragment: true,
        fragmentChecked: true,
        fragmentFound: false,
        targetBytesScanned: scan.bytesScanned,
        targetTruncated: true
      )
    }

    return MarkdownLinkCheckResult(
      link: link,
      resolvedDestination: resolvedDestination,
      resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
      referenceDefinitionLine: referenceDefinitionLine,
      status: "missing_fragment",
      category: "broken",
      issue: "Markdown fragment was not found in the target file.",
      target: target,
      targetExists: true,
      targetIsDirectory: false,
      isLocal: true,
      hasFragment: true,
      fragmentChecked: true,
      fragmentFound: false,
      targetBytesScanned: scan.bytesScanned,
      targetTruncated: false
    )
  }

  internal func markdownAnchorScan(url: URL, maxBytes: Int) throws -> MarkdownAnchorScanResult {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let truncated = data.count > maxBytes
    let contentData = truncated ? Data(data.prefix(maxBytes)) : data
    guard let content = String(data: contentData, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("Markdown target is not valid UTF-8: \(url.path)")
    }

    var anchors = Set<String>()
    var slugCounts: [String: Int] = [:]
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let heading = markdownHeading(trimmed, lineNumber: index + 1) {
        anchors.insert(markdownAnchorKey(heading.name))
        let slug = markdownHeadingSlug(heading.name)
        if !slug.isEmpty {
          let count = slugCounts[slug] ?? 0
          slugCounts[slug] = count + 1
          anchors.insert(count == 0 ? slug : "\(slug)-\(count)")
        }
      }
      for anchor in markdownExplicitAnchors(in: line) {
        anchors.insert(markdownAnchorKey(anchor))
      }
    }
    return MarkdownAnchorScanResult(
      anchors: anchors,
      bytesScanned: contentData.count,
      truncated: truncated
    )
  }

  internal func markdownAnchorKey(_ value: String) -> String {
    (value.removingPercentEncoding ?? value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private func markdownHeadingSlug(_ heading: String) -> String {
    let trimmed = heading.trimmingCharacters(in: .whitespacesAndNewlines)
    var scalars: [UnicodeScalar] = []
    var previousWasHyphen = false
    for scalar in trimmed.lowercased().unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
        scalars.append(scalar)
        previousWasHyphen = false
      } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" {
        if !previousWasHyphen, !scalars.isEmpty {
          scalars.append("-")
          previousWasHyphen = true
        }
      }
    }
    while scalars.last == "-" {
      scalars.removeLast()
    }
    return String(String.UnicodeScalarView(scalars))
  }

  private func markdownExplicitAnchors(in line: String) -> [String] {
    let pattern = #"(?:id|name)\s*=\s*["']([^"']+)["']"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else {
      return []
    }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    return regex.matches(in: line, options: [], range: range).compactMap { match in
      guard match.numberOfRanges > 1,
        let matchRange = Range(match.range(at: 1), in: line)
      else {
        return nil
      }
      return String(line[matchRange])
    }
  }

  private func markdownLinksInLine(
    _ line: String,
    lineNumber: Int,
    sourceURL: URL,
    includeImages: Bool,
    includeReferenceDefinitions: Bool,
    includeAutolinks: Bool
  ) -> [MarkdownLinkInfo] {
    var links: [MarkdownLinkInfo] = []
    if includeReferenceDefinitions,
      let definition = markdownReferenceDefinition(
        line, lineNumber: lineNumber, sourceURL: sourceURL)
    {
      links.append(definition)
    }
    if includeAutolinks {
      links.append(
        contentsOf: markdownAutolinks(line, lineNumber: lineNumber, sourceURL: sourceURL))
    }

    var index = line.startIndex
    while index < line.endIndex {
      guard line[index] == "[" else {
        index = line.index(after: index)
        continue
      }
      let isImage = index > line.startIndex && line[line.index(before: index)] == "!"
      if isImage && !includeImages {
        index = line.index(after: index)
        continue
      }
      if index > line.startIndex, line[line.index(before: index)] == "\\" {
        index = line.index(after: index)
        continue
      }
      guard let close = markdownClosingBracket(in: line, open: index) else {
        index = line.index(after: index)
        continue
      }

      let labelStart = line.index(after: index)
      let label = String(line[labelStart..<close])
      let next = line.index(after: close)
      if next < line.endIndex, line[next] == "(",
        let closeParen = markdownClosingParen(in: line, open: next)
      {
        let targetStart = line.index(after: next)
        let rawTarget = String(line[targetStart..<closeParen])
        let target = markdownInlineTarget(rawTarget)
        links.append(
          markdownLinkInfo(
            lineNumber: lineNumber,
            kind: isImage ? "inline_image" : "inline_link",
            label: label,
            referenceLabel: nil,
            destination: target.destination,
            title: target.title,
            raw: String(line[(isImage ? line.index(before: index) : index)...closeParen]),
            isImage: isImage,
            sourceURL: sourceURL
          ))
        index = line.index(after: closeParen)
        continue
      }
      if next < line.endIndex, line[next] == "[",
        let referenceClose = markdownClosingBracket(in: line, open: next)
      {
        let referenceStart = line.index(after: next)
        let referenceLabel = String(line[referenceStart..<referenceClose])
        links.append(
          markdownLinkInfo(
            lineNumber: lineNumber,
            kind: isImage ? "reference_image" : "reference_link",
            label: label,
            referenceLabel: referenceLabel.isEmpty ? label : referenceLabel,
            destination: nil,
            title: nil,
            raw: String(line[(isImage ? line.index(before: index) : index)...referenceClose]),
            isImage: isImage,
            sourceURL: sourceURL
          ))
        index = line.index(after: referenceClose)
        continue
      }

      index = line.index(after: close)
    }
    return links
  }

  private func markdownReferenceDefinition(
    _ line: String,
    lineNumber: Int,
    sourceURL: URL
  ) -> MarkdownLinkInfo? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[") else {
      return nil
    }
    guard let close = markdownClosingBracket(in: trimmed, open: trimmed.startIndex) else {
      return nil
    }
    let afterClose = trimmed.index(after: close)
    guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else {
      return nil
    }
    let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
    let restStart = trimmed.index(after: afterClose)
    let rest = trimmed[restStart...].trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty, !rest.isEmpty else {
      return nil
    }
    let target = markdownInlineTarget(rest)
    return markdownLinkInfo(
      lineNumber: lineNumber,
      kind: "reference_definition",
      label: label,
      referenceLabel: label,
      destination: target.destination,
      title: target.title,
      raw: trimmed,
      isImage: false,
      sourceURL: sourceURL
    )
  }

  private func markdownAutolinks(
    _ line: String,
    lineNumber: Int,
    sourceURL: URL
  ) -> [MarkdownLinkInfo] {
    var links: [MarkdownLinkInfo] = []
    var index = line.startIndex
    while index < line.endIndex {
      guard line[index] == "<" else {
        index = line.index(after: index)
        continue
      }
      guard let close = line[index...].firstIndex(of: ">") else {
        break
      }
      let valueStart = line.index(after: index)
      let value = String(line[valueStart..<close])
      if isMarkdownAutolinkDestination(value) {
        links.append(
          markdownLinkInfo(
            lineNumber: lineNumber,
            kind: "autolink",
            label: value,
            referenceLabel: nil,
            destination: value,
            title: nil,
            raw: String(line[index...close]),
            isImage: false,
            sourceURL: sourceURL
          ))
      }
      index = line.index(after: close)
    }
    return links
  }

  private func isMarkdownAutolinkDestination(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
      || lowercased.hasPrefix("mailto:")
    {
      return true
    }
    return value.contains("@") && value.contains(".") && !value.contains(" ")
  }

  private func markdownClosingBracket(in line: String, open: String.Index) -> String.Index? {
    var index = line.index(after: open)
    while index < line.endIndex {
      if line[index] == "]", index == line.startIndex || line[line.index(before: index)] != "\\" {
        return index
      }
      index = line.index(after: index)
    }
    return nil
  }

  private func markdownClosingParen(in line: String, open: String.Index) -> String.Index? {
    var index = line.index(after: open)
    var inSingleQuote = false
    var inDoubleQuote = false
    var angleDepth = 0
    while index < line.endIndex {
      let character = line[index]
      let escaped = index > line.startIndex && line[line.index(before: index)] == "\\"
      if !escaped {
        if character == "\"", !inSingleQuote {
          inDoubleQuote.toggle()
        } else if character == "'", !inDoubleQuote {
          inSingleQuote.toggle()
        } else if character == "<", !inSingleQuote, !inDoubleQuote {
          angleDepth += 1
        } else if character == ">", !inSingleQuote, !inDoubleQuote, angleDepth > 0 {
          angleDepth -= 1
        } else if character == ")", !inSingleQuote, !inDoubleQuote, angleDepth == 0 {
          return index
        }
      }
      index = line.index(after: index)
    }
    return nil
  }

  private func markdownInlineTarget(_ raw: String) -> (destination: String?, title: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (nil, nil)
    }
    if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
      let destination = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
      let title = markdownTitle(String(trimmed[trimmed.index(after: close)...]))
      return (destination, title)
    }
    var destinationEnd = trimmed.endIndex
    var index = trimmed.startIndex
    while index < trimmed.endIndex {
      if trimmed[index].isWhitespace {
        destinationEnd = index
        break
      }
      index = trimmed.index(after: index)
    }
    let destination = String(trimmed[..<destinationEnd])
    let title = markdownTitle(String(trimmed[destinationEnd...]))
    return (destination.isEmpty ? nil : destination, title)
  }

  private func markdownTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else {
      return nil
    }
    if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
      || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
    {
      return String(trimmed.dropFirst().dropLast())
    }
    if trimmed.hasPrefix("("), trimmed.hasSuffix(")") {
      return String(trimmed.dropFirst().dropLast())
    }
    return nil
  }

  private func markdownLinkInfo(
    lineNumber: Int,
    kind: String,
    label: String?,
    referenceLabel: String?,
    destination: String?,
    title: String?,
    raw: String,
    isImage: Bool,
    sourceURL: URL
  ) -> MarkdownLinkInfo {
    MarkdownLinkInfo(
      line: lineNumber,
      kind: kind,
      label: label,
      referenceLabel: referenceLabel,
      destination: destination,
      title: title,
      raw: raw,
      isImage: isImage,
      target: destination.flatMap { markdownLinkTarget(destination: $0, sourceURL: sourceURL) }
    )
  }

  private func markdownLinkTarget(destination: String, sourceURL: URL) -> MarkdownLinkTargetInfo {
    let normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      return MarkdownLinkTargetInfo(kind: "empty")
    }
    if normalized.hasPrefix("#") {
      return MarkdownLinkTargetInfo(kind: "fragment", fragment: String(normalized.dropFirst()))
    }
    if let scheme = markdownDestinationScheme(normalized) {
      return MarkdownLinkTargetInfo(kind: scheme == "mailto" ? "email" : "url", scheme: scheme)
    }

    let split = markdownDestinationPathAndFragment(normalized)
    let targetURL: URL
    let kind: String
    if split.path.hasPrefix("/") {
      targetURL = URL(fileURLWithPath: split.path).standardizedFileURL
      kind = "absolute_path"
    } else {
      targetURL =
        sourceURL.deletingLastPathComponent().appendingPathComponent(split.path)
        .standardizedFileURL
      kind = "relative_path"
    }
    let contained = isWorkspaceContained(targetURL)
    return MarkdownLinkTargetInfo(
      kind: kind,
      fragment: split.fragment,
      targetPath: targetURL.path,
      targetWorkspaceRelativePath: contained ? workspaceRelativePath(targetURL) : nil,
      targetWorkspaceContained: contained
    )
  }

  internal func markdownDestinationScheme(_ destination: String) -> String? {
    guard let colon = destination.firstIndex(of: ":") else {
      return nil
    }
    if let slash = destination.firstIndex(of: "/"), slash < colon {
      return nil
    }
    let scheme = String(destination[..<colon]).lowercased()
    guard !scheme.isEmpty,
      scheme.allSatisfy({
        $0.isLetter || $0.isNumber || $0 == "+"
          || $0 == "-" || $0 == "."
      })
    else {
      return nil
    }
    return scheme
  }

  internal func markdownDestinationPathAndFragment(_ destination: String) -> (
    path: String, fragment: String?
  ) {
    let pathEnd =
      destination.firstIndex { character in character == "#" || character == "?" }
      ?? destination.endIndex
    let path = String(destination[..<pathEnd])
    let fragment: String?
    if let hash = destination.firstIndex(of: "#") {
      fragment = String(destination[destination.index(after: hash)...])
    } else {
      fragment = nil
    }
    return (path.isEmpty ? "." : path, fragment)
  }
}

internal struct MarkdownLinkInfo {
  var line: Int
  var kind: String
  var label: String?
  var referenceLabel: String?
  var destination: String?
  var title: String?
  var raw: String
  var isImage: Bool
  var target: MarkdownLinkTargetInfo?

  var json: JSONValue {
    .object([
      "line": .integer(Int64(line)),
      "kind": .string(kind),
      "label": label.map(JSONValue.string) ?? .null,
      "reference_label": referenceLabel.map(JSONValue.string) ?? .null,
      "destination": destination.map(JSONValue.string) ?? .null,
      "title": title.map(JSONValue.string) ?? .null,
      "raw": .string(raw),
      "is_image": .bool(isImage),
      "target": target?.json ?? .null,
    ])
  }
}

private struct MarkdownLinkInventory {
  var url: URL
  var info: FileInfo
  var bytesScanned: Int
  var fileTruncated: Bool
  var links: [MarkdownLinkInfo]
}

internal struct MarkdownTableInfo {
  var startLine: Int
  var endLine: Int
  var headerLine: Int
  var delimiterLine: Int
  var headers: [String]
  var alignments: [String]
  var rows: [MarkdownTableRowInfo]
  var raw: String

  func json(maxRowsPerTable: Int) -> JSONValue {
    let returnedRows = Array(rows.prefix(maxRowsPerTable))
    return .object([
      "start_line": .integer(Int64(startLine)),
      "end_line": .integer(Int64(endLine)),
      "header_line": .integer(Int64(headerLine)),
      "delimiter_line": .integer(Int64(delimiterLine)),
      "column_count": .integer(Int64(headers.count)),
      "headers": .array(headers.map(JSONValue.string)),
      "alignments": .array(alignments.map(JSONValue.string)),
      "row_count": .integer(Int64(rows.count)),
      "returned_row_count": .integer(Int64(returnedRows.count)),
      "row_result_truncated": .bool(rows.count > returnedRows.count),
      "raw": .string(raw),
      "raw_bytes": .integer(Int64(Data(raw.utf8).count)),
      "rows": .array(returnedRows.map { $0.json(columnCount: headers.count) }),
    ])
  }
}

internal struct MarkdownTableRowInfo {
  var line: Int
  var cells: [String]

  func json(columnCount: Int) -> JSONValue {
    let returnedCells = Array(cells.prefix(columnCount))
    let missingCount = max(0, columnCount - returnedCells.count)
    let normalizedCells = returnedCells + Array(repeating: "", count: missingCount)
    let extraCells = cells.count > columnCount ? Array(cells.dropFirst(columnCount)) : []
    return .object([
      "line": .integer(Int64(line)),
      "cell_count": .integer(Int64(cells.count)),
      "cells": .array(normalizedCells.map(JSONValue.string)),
      "raw_cells": .array(cells.map(JSONValue.string)),
      "missing_cell_count": .integer(Int64(missingCount)),
      "extra_cells": .array(extraCells.map(JSONValue.string)),
    ])
  }
}

private struct MarkdownLinkCheckResult {
  var link: MarkdownLinkInfo
  var resolvedDestination: String?
  var resolvedViaReferenceDefinition: Bool
  var referenceDefinitionLine: Int?
  var status: String
  var category: String
  var issue: String?
  var target: MarkdownLinkTargetInfo?
  var targetExists: Bool?
  var targetIsDirectory: Bool?
  var isLocal = false
  var isExternal = false
  var hasFragment = false
  var fragmentChecked: Bool?
  var fragmentFound: Bool?
  var targetBytesScanned: Int?
  var targetTruncated = false

  var json: JSONValue {
    var targetObject = target?.json.objectValue ?? [:]
    targetObject["exists"] = targetExists.map(JSONValue.bool) ?? .null
    targetObject["is_directory"] = targetIsDirectory.map(JSONValue.bool) ?? .null
    targetObject["fragment_checked"] = fragmentChecked.map(JSONValue.bool) ?? .null
    targetObject["fragment_found"] = fragmentFound.map(JSONValue.bool) ?? .null
    targetObject["target_bytes_scanned"] =
      targetBytesScanned.map { .integer(Int64($0)) } ?? .null
    targetObject["target_truncated"] = .bool(targetTruncated)

    return .object([
      "line": .integer(Int64(link.line)),
      "kind": .string(link.kind),
      "label": link.label.map(JSONValue.string) ?? .null,
      "reference_label": link.referenceLabel.map(JSONValue.string) ?? .null,
      "destination": link.destination.map(JSONValue.string) ?? .null,
      "resolved_destination": resolvedDestination.map(JSONValue.string) ?? .null,
      "resolved_via_reference_definition": .bool(resolvedViaReferenceDefinition),
      "reference_definition_line": referenceDefinitionLine.map { .integer(Int64($0)) } ?? .null,
      "title": link.title.map(JSONValue.string) ?? .null,
      "raw": .string(link.raw),
      "is_image": .bool(link.isImage),
      "status": .string(status),
      "category": .string(category),
      "issue": issue.map(JSONValue.string) ?? .null,
      "is_local": .bool(isLocal),
      "is_external": .bool(isExternal),
      "has_fragment": .bool(hasFragment),
      "target": target == nil ? .null : .object(targetObject),
    ])
  }
}

internal struct MarkdownLinkTargetInfo {
  var kind: String
  var scheme: String? = nil
  var fragment: String? = nil
  var targetPath: String? = nil
  var targetWorkspaceRelativePath: String? = nil
  var targetWorkspaceContained: Bool? = nil

  var json: JSONValue {
    .object([
      "kind": .string(kind),
      "scheme": scheme.map(JSONValue.string) ?? .null,
      "fragment": fragment.map(JSONValue.string) ?? .null,
      "target_path": targetPath.map(JSONValue.string) ?? .null,
      "target_workspace_relative_path": targetWorkspaceRelativePath.map(JSONValue.string) ?? .null,
      "target_workspace_contained": targetWorkspaceContained.map(JSONValue.bool) ?? .null,
    ])
  }
}

internal struct MarkdownAnchorScanResult {
  var anchors: Set<String>
  var bytesScanned: Int
  var truncated: Bool
}
