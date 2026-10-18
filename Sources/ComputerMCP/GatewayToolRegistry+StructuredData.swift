import Foundation
import TOML
import Yams

extension GatewayToolRegistry {
  internal func readJSON(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    if let size = info.size, size > Int64(maxBytes) {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw GatewayToolError.invalidArguments("Unable to parse JSON: \(error.localizedDescription)")
    }

    return .object([
      "operation": .string("json.read"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "bytes_read": .integer(Int64(data.count)),
      "value": value,
    ])
  }

  internal func readJSONLines(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let startLine = optionalInt("start_line", in: object) ?? 1
    let maxRecords = optionalInt("max_records", in: object) ?? 100
    let maxErrors = optionalInt("max_errors", in: object) ?? 50
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let skipBlankLines = try optionalBool("skip_blank_lines", in: object) ?? true
    let includePartialLine = try optionalBool("include_partial_line", in: object) ?? false
    try validateBoundedPositive(startLine, name: "start_line", upperBound: 10_000_000)
    try validateBoundedPositive(maxRecords, name: "max_records", upperBound: 100_000)
    try validateBoundedNonNegative(maxErrors, name: "max_errors", upperBound: 100_000)
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
    let contentTruncated = data.count > maxBytes
    let boundedData = contentTruncated ? Data(data.prefix(maxBytes)) : data
    guard let text = String(data: boundedData, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("JSONL file is not valid UTF-8: \(path)")
    }

    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if text.hasSuffix("\n"), lines.last?.isEmpty == true {
      lines.removeLast()
    }
    let lastLineMayBePartial = contentTruncated && !text.hasSuffix("\n")
    let partialLineDropped = lastLineMayBePartial && !includePartialLine && !lines.isEmpty
    if partialLineDropped {
      lines.removeLast()
    }

    let decoder = JSONDecoder()
    var records: [JSONValue] = []
    var errors: [JSONValue] = []
    var parsedRecordCount = 0
    var parseErrorCount = 0
    var scannedLineCount = 0
    var skippedBlankLineCount = 0

    for (index, rawLine) in lines.enumerated() {
      let lineNumber = index + 1
      guard lineNumber >= startLine else {
        continue
      }
      scannedLineCount += 1
      var line = rawLine
      if line.hasSuffix("\r") {
        line.removeLast()
      }
      if skipBlankLines && line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        skippedBlankLineCount += 1
        continue
      }

      let lineData = Data(line.utf8)
      do {
        let value = try decoder.decode(JSONValue.self, from: lineData)
        parsedRecordCount += 1
        if records.count < maxRecords {
          records.append(
            .object([
              "line": .integer(Int64(lineNumber)),
              "byte_count": .integer(Int64(lineData.count)),
              "value": value,
            ]))
        }
      } catch {
        parseErrorCount += 1
        if errors.count < maxErrors {
          let preview = utf8Preview(line, maxBytes: 240)
          errors.append(
            .object([
              "line": .integer(Int64(lineNumber)),
              "byte_count": .integer(Int64(lineData.count)),
              "message": .string(error.localizedDescription),
              "raw_preview": .string(preview.text),
              "raw_preview_truncated": .bool(preview.truncated),
            ]))
        }
      }
    }

    let recordCountTruncated = parsedRecordCount > records.count
    let errorCountTruncated = parseErrorCount > errors.count

    return .object([
      "operation": .string("jsonl.read"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "encoding": .string("utf-8"),
      "start_line": .integer(Int64(startLine)),
      "max_records": .integer(Int64(maxRecords)),
      "max_errors": .integer(Int64(maxErrors)),
      "max_bytes": .integer(Int64(maxBytes)),
      "skip_blank_lines": .bool(skipBlankLines),
      "include_partial_line": .bool(includePartialLine),
      "bytes_read": .integer(Int64(boundedData.count)),
      "content_truncated": .bool(contentTruncated),
      "last_line_may_be_partial": .bool(lastLineMayBePartial),
      "partial_line_dropped": .bool(partialLineDropped),
      "scanned_line_count": .integer(Int64(scannedLineCount)),
      "skipped_blank_line_count": .integer(Int64(skippedBlankLineCount)),
      "record_count": .integer(Int64(parsedRecordCount)),
      "returned_record_count": .integer(Int64(records.count)),
      "record_count_truncated": .bool(recordCountTruncated),
      "error_count": .integer(Int64(parseErrorCount)),
      "returned_error_count": .integer(Int64(errors.count)),
      "error_count_truncated": .bool(errorCountTruncated),
      "parse_incomplete": .bool(lastLineMayBePartial),
      "truncated": .bool(
        contentTruncated || partialLineDropped || recordCountTruncated || errorCountTruncated),
      "records": .array(records),
      "errors": .array(errors),
    ])
  }

  internal func writeJSON(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    guard let value = object["value"] else {
      throw GatewayToolError.invalidArguments("Missing required JSON argument: value")
    }
    let pretty = try optionalBool("pretty", in: object) ?? true
    let sortedKeys = try optionalBool("sorted_keys", in: object) ?? true
    let appendNewline = try optionalBool("append_newline", in: object) ?? true
    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmWrite = try optionalBool("confirm_write", in: object) ?? false
    let includePreview = try optionalBool("include_preview", in: object) ?? dryRun
    let previewMaxBytes = optionalInt("preview_max_bytes", in: object) ?? 8_192
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(previewMaxBytes, name: "preview_max_bytes", upperBound: 1_048_576)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    guard dryRun || confirmWrite else {
      throw GatewayToolError.invalidArguments(
        "json.write requires confirm_write=true when dry_run is false.")
    }

    let encoder = JSONEncoder()
    var formatting: JSONEncoder.OutputFormatting = []
    if pretty {
      formatting.insert(.prettyPrinted)
    }
    if sortedKeys {
      formatting.insert(.sortedKeys)
    }
    encoder.outputFormatting = formatting
    var data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      throw GatewayToolError.invalidArguments(
        "Unable to encode JSON: \(error.localizedDescription)")
    }
    if appendNewline {
      data.append(0x0a)
    }
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("Encoded JSON exceeds max_bytes.")
    }

    let url = try resolvedWorkspaceURL(path)
    let parent = url.deletingLastPathComponent()
    let fileManager = FileManager.default
    var parentIsDirectory = ObjCBool(false)
    let parentExists = fileManager.fileExists(
      atPath: parent.path,
      isDirectory: &parentIsDirectory
    )
    if parentExists {
      guard parentIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Parent path is not a directory: \(path)")
      }
    } else {
      guard createDirectories else {
        throw GatewayToolError.invalidArguments("Parent directory does not exist: \(path)")
      }
    }

    var isDirectory = ObjCBool(false)
    let existed = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if existed {
      guard !isDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Path is a directory: \(path)")
      }
    }
    if existed && !overwrite {
      throw GatewayToolError.invalidArguments("Refusing to overwrite existing file: \(path)")
    }

    let existingSizeBytes = try existingFileSizeBytes(url: url, existed: existed)
    if !dryRun {
      if createDirectories && !parentExists {
        try fileManager.createDirectory(
          at: parent,
          withIntermediateDirectories: true
        )
      }
      try data.write(to: url, options: .atomic)
    }

    var payload: [String: JSONValue] = [
      "operation": .string("json.write"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "dry_run": .bool(dryRun),
      "confirm_write": .bool(confirmWrite),
      "overwrite": .bool(overwrite),
      "create_directories": .bool(createDirectories),
      "pretty": .bool(pretty),
      "sorted_keys": .bool(sortedKeys),
      "append_newline": .bool(appendNewline),
      "existed": .bool(existed),
      "would_create": .bool(!existed),
      "would_overwrite": .bool(existed),
      "would_create_parent_directories": .bool(!parentExists && createDirectories),
      "bytes_before": .integer(Int64(existingSizeBytes)),
      "bytes_after": .integer(Int64(data.count)),
      "bytes_to_write": .integer(Int64(data.count)),
      "bytes_written": .integer(Int64(dryRun ? 0 : data.count)),
      "written": .bool(!dryRun),
    ]

    if includePreview {
      let content = String(decoding: data, as: UTF8.self)
      let preview = utf8Preview(content, maxBytes: previewMaxBytes)
      payload["preview"] = .object([
        "preview_max_bytes": .integer(Int64(previewMaxBytes)),
        "content": .string(preview.text),
        "content_truncated": .bool(preview.truncated),
      ])
    }

    return .object(payload)
  }

  internal func readTOML(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    if let size = info.size, size > Int64(maxBytes) {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let decoder = TOMLDecoder()
    decoder.limits = TOMLDecoder.DecodingLimits(
      maxInputSize: maxBytes,
      maxDepth: 128,
      maxTableKeys: 10_000,
      maxArrayLength: 100_000,
      maxStringLength: min(maxBytes, 1_048_576)
    )

    let value: DecodedTOMLValue
    do {
      value = try decoder.decode(DecodedTOMLValue.self, from: data)
    } catch {
      throw GatewayToolError.invalidArguments("Unable to parse TOML: \(error.localizedDescription)")
    }

    return .object([
      "operation": .string("toml.read"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "bytes_read": .integer(Int64(data.count)),
      "value": tomlJSONValue(value),
    ])
  }

  internal func readYAML(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let maxDocuments = optionalInt("max_documents", in: object) ?? 50
    let maxDepth = optionalInt("max_depth", in: object) ?? 128
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxDocuments, name: "max_documents", upperBound: 1_000)
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 512)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    if let size = info.size, size > Int64(maxBytes) {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("YAML file is not valid UTF-8: \(path)")
    }

    var sequence: YamlSequence<Any>
    do {
      sequence = try Yams.load_all(yaml: text)
    } catch {
      throw GatewayToolError.invalidArguments("Unable to parse YAML: \(error.localizedDescription)")
    }

    var stats = YAMLConversionStats()
    var documents: [JSONValue] = []
    var values: [JSONValue] = []
    var parsedDocumentCount = 0
    while let document = sequence.next() {
      parsedDocumentCount += 1
      if documents.count < maxDocuments {
        let value = try yamlJSONValue(
          document,
          stats: &stats,
          depth: 0,
          maxDepth: maxDepth
        )
        values.append(value)
        documents.append(
          .object([
            "index": .integer(Int64(parsedDocumentCount - 1)),
            "value": value,
          ]))
      }
    }
    if let error = sequence.error {
      throw GatewayToolError.invalidArguments("Unable to parse YAML: \(error.localizedDescription)")
    }

    let documentCountTruncated = parsedDocumentCount > documents.count
    let topLevelValue: JSONValue
    switch values.count {
    case 0:
      topLevelValue = .null
    case 1:
      topLevelValue = values[0]
    default:
      topLevelValue = .array(values)
    }

    return .object([
      "operation": .string("yaml.read"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "encoding": .string("utf-8"),
      "bytes_read": .integer(Int64(data.count)),
      "max_bytes": .integer(Int64(maxBytes)),
      "max_documents": .integer(Int64(maxDocuments)),
      "max_depth": .integer(Int64(maxDepth)),
      "document_count": .integer(Int64(parsedDocumentCount)),
      "returned_document_count": .integer(Int64(documents.count)),
      "document_count_truncated": .bool(documentCountTruncated),
      "truncated": .bool(documentCountTruncated),
      "conversion": stats.json,
      "documents": .array(documents),
      "value": topLevelValue,
    ])
  }

  internal func readXML(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let maxNodes = optionalInt("max_nodes", in: object) ?? 10_000
    let maxDepth = optionalInt("max_depth", in: object) ?? 64
    let maxTextBytes = optionalInt("max_text_bytes", in: object) ?? 8_192
    let trimText = try optionalBool("trim_text", in: object) ?? true
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxNodes, name: "max_nodes", upperBound: 100_000)
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 512)
    try validateBoundedPositive(maxTextBytes, name: "max_text_bytes", upperBound: 1_048_576)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    if let size = info.size, size > Int64(maxBytes) {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let delegate = XMLTreeParserDelegate(
      maxNodes: maxNodes,
      maxDepth: maxDepth,
      maxTextBytes: maxTextBytes
    )
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldProcessNamespaces = false
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false

    guard parser.parse() else {
      let message = parser.parserError?.localizedDescription ?? "unknown parse error"
      throw GatewayToolError.invalidArguments(
        "Unable to parse XML at line \(parser.lineNumber), column \(parser.columnNumber): \(message)"
      )
    }

    let truncated = delegate.nodeCountTruncated || delegate.depthTruncated || delegate.textTruncated
    return .object([
      "operation": .string("xml.read"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "bytes_read": .integer(Int64(data.count)),
      "max_bytes": .integer(Int64(maxBytes)),
      "max_nodes": .integer(Int64(maxNodes)),
      "max_depth": .integer(Int64(maxDepth)),
      "max_text_bytes": .integer(Int64(maxTextBytes)),
      "trim_text": .bool(trimText),
      "element_count": .integer(Int64(delegate.elementCount)),
      "returned_element_count": .integer(Int64(delegate.returnedElementCount)),
      "max_depth_observed": .integer(Int64(delegate.maxDepthObserved)),
      "node_count_truncated": .bool(delegate.nodeCountTruncated),
      "depth_truncated": .bool(delegate.depthTruncated),
      "text_truncated": .bool(delegate.textTruncated),
      "truncated": .bool(truncated),
      "root": delegate.root?.json(trimText: trimText) ?? .null,
    ])
  }

  internal func readPropertyList(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    if let size = info.size, size > Int64(maxBytes) {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    var format = PropertyListSerialization.PropertyListFormat.xml
    let plist: Any
    do {
      plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
    } catch {
      throw GatewayToolError.invalidArguments(
        "Unable to parse property list: \(error.localizedDescription)")
    }

    return .object([
      "operation": .string("plist.read"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "format": .string(propertyListFormatName(format)),
      "bytes_read": .integer(Int64(data.count)),
      "value": try propertyListJSONValue(plist),
    ])
  }

  internal func getStructuredValue(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let format = try optionalString("format", in: object) ?? "auto"
    let queryPath = try requiredStructuredPath("query_path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let maxDocuments = optionalInt("max_documents", in: object) ?? 50
    let maxDepth = optionalInt("max_depth", in: object) ?? 128
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxDocuments, name: "max_documents", upperBound: 1_000)
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 512)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    if let size = info.size, size > Int64(maxBytes) {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }

    let data = try readBoundedFileData(url: url, path: path, maxBytes: maxBytes)
    let resolvedFormat = try structuredFormat(format, path: url.path)
    let document = try parseStructuredValue(
      data: data,
      format: resolvedFormat,
      path: path,
      maxBytes: maxBytes,
      maxDocuments: maxDocuments,
      maxDepth: maxDepth
    )
    let selection = selectStructuredValue(document.value, path: queryPath)

    return .object([
      "operation": .string("structured.get"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "format": .string(resolvedFormat),
      "requested_format": .string(format),
      "bytes_read": .integer(Int64(data.count)),
      "max_bytes": .integer(Int64(maxBytes)),
      "max_documents": .integer(Int64(maxDocuments)),
      "max_depth": .integer(Int64(maxDepth)),
      "query_path": .array(queryPath.map(\.json)),
      "query_pointer": .string(structuredPointer(queryPath)),
      "matched": .bool(selection.matched),
      "failure": selection.failure?.json ?? .null,
      "value_kind": .string(jsonValueKind(selection.value)),
      "value": selection.value,
      "document_metadata": document.metadata,
    ])
  }

  internal func writePropertyList(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    guard let value = object["value"] else {
      throw GatewayToolError.invalidArguments("Missing required property list argument: value")
    }
    let formatName = try optionalString("format", in: object) ?? "xml"
    let format: PropertyListSerialization.PropertyListFormat
    switch formatName {
    case "xml":
      format = .xml
    case "binary":
      format = .binary
    default:
      throw GatewayToolError.invalidArguments("format must be xml or binary.")
    }

    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmWrite = try optionalBool("confirm_write", in: object) ?? false
    let includePreview = try optionalBool("include_preview", in: object) ?? dryRun
    let previewMaxBytes = optionalInt("preview_max_bytes", in: object) ?? 8_192
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(previewMaxBytes, name: "preview_max_bytes", upperBound: 1_048_576)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    guard dryRun || confirmWrite else {
      throw GatewayToolError.invalidArguments(
        "plist.write requires confirm_write=true when dry_run is false.")
    }

    let plist = try propertyListObject(from: value)
    var data: Data
    do {
      data = try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: format,
        options: 0
      )
    } catch {
      throw GatewayToolError.invalidArguments(
        "Unable to encode property list: \(error.localizedDescription)")
    }
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("Encoded property list exceeds max_bytes.")
    }

    let url = try resolvedWorkspaceURL(path)
    let parent = url.deletingLastPathComponent()
    let fileManager = FileManager.default
    var parentIsDirectory = ObjCBool(false)
    let parentExists = fileManager.fileExists(
      atPath: parent.path,
      isDirectory: &parentIsDirectory
    )
    if parentExists {
      guard parentIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Parent path is not a directory: \(path)")
      }
    } else {
      guard createDirectories else {
        throw GatewayToolError.invalidArguments("Parent directory does not exist: \(path)")
      }
    }

    var isDirectory = ObjCBool(false)
    let existed = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if existed {
      guard !isDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Path is a directory: \(path)")
      }
    }
    if existed && !overwrite {
      throw GatewayToolError.invalidArguments("Refusing to overwrite existing file: \(path)")
    }

    let existingSizeBytes = try existingFileSizeBytes(url: url, existed: existed)
    if !dryRun {
      if createDirectories && !parentExists {
        try fileManager.createDirectory(
          at: parent,
          withIntermediateDirectories: true
        )
      }
      try data.write(to: url, options: .atomic)
    }

    var payload: [String: JSONValue] = [
      "operation": .string("plist.write"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "format": .string(formatName),
      "dry_run": .bool(dryRun),
      "confirm_write": .bool(confirmWrite),
      "overwrite": .bool(overwrite),
      "create_directories": .bool(createDirectories),
      "existed": .bool(existed),
      "would_create": .bool(!existed),
      "would_overwrite": .bool(existed),
      "would_create_parent_directories": .bool(!parentExists && createDirectories),
      "bytes_before": .integer(Int64(existingSizeBytes)),
      "bytes_after": .integer(Int64(data.count)),
      "bytes_to_write": .integer(Int64(data.count)),
      "bytes_written": .integer(Int64(dryRun ? 0 : data.count)),
      "written": .bool(!dryRun),
    ]

    if includePreview {
      payload["preview"] = propertyListPreview(
        data: data, format: format, maxBytes: previewMaxBytes)
    }

    return .object(payload)
  }

  internal func readCSV(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let delimiterInput = try optionalString("delimiter", in: object) ?? "auto"
    let hasHeader = try optionalBool("has_header", in: object) ?? true
    let maxRows = optionalInt("max_rows", in: object) ?? 100
    let maxColumns = optionalInt("max_columns", in: object) ?? 200
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxRows, name: "max_rows", upperBound: 100_000)
    try validateBoundedPositive(maxColumns, name: "max_columns", upperBound: 10_000)
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
    let contentTruncated = data.count > maxBytes
    let boundedData = contentTruncated ? Data(data.prefix(maxBytes)) : data
    guard let text = String(data: boundedData, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("CSV file is not valid UTF-8: \(path)")
    }

    let delimiter = try csvDelimiter(from: delimiterInput, sample: text)
    let requestedRecords = maxRows + (hasHeader ? 1 : 0)
    let parsed = parseDelimitedText(
      text,
      delimiter: delimiter.character,
      maxRecords: requestedRecords,
      maxColumns: maxColumns
    )
    let records = parsed.records
    let headers: [String]
    let rowRecords: ArraySlice<[String]>
    if hasHeader, let first = records.first {
      headers = first
      rowRecords = records.dropFirst()
    } else {
      headers = []
      rowRecords = records[...]
    }

    let rows: [JSONValue] = rowRecords.enumerated().map { index, cells in
      JSONValue.object([
        "record_number": .integer(Int64(index + (hasHeader ? 2 : 1))),
        "cells": .array(cells.map(JSONValue.string)),
      ])
    }
    let rowCountTruncated =
      parsed.recordsTruncated
      || (!hasHeader && records.count > maxRows)
      || (hasHeader && max(records.count - 1, 0) > maxRows)

    let payload: [String: JSONValue] = [
      "operation": .string("csv.read"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "delimiter": .string(delimiter.name),
      "delimiter_character": .string(String(delimiter.character)),
      "delimiter_source": .string(delimiter.source),
      "has_header": .bool(hasHeader),
      "headers": .array(headers.map(JSONValue.string)),
      "header_count": .integer(Int64(headers.count)),
      "rows": .array(rows),
      "returned_row_count": .integer(Int64(rows.count)),
      "max_rows": .integer(Int64(maxRows)),
      "max_columns": .integer(Int64(maxColumns)),
      "bytes_read": .integer(Int64(boundedData.count)),
      "content_truncated": .bool(contentTruncated),
      "row_count_truncated": .bool(rowCountTruncated),
      "column_count_truncated": .bool(parsed.columnsTruncated),
      "parse_incomplete": .bool(contentTruncated || parsed.openQuotedField),
      "truncated": .bool(contentTruncated || rowCountTruncated || parsed.columnsTruncated),
    ]
    return .object(payload)
  }

  private func csvDelimiter(from input: String, sample: String) throws -> CSVDelimiter {
    switch input {
    case "auto":
      let inferred = inferDelimitedTextDelimiter(sample)
      return CSVDelimiter(
        character: inferred.character,
        name: inferred.name,
        source: "auto"
      )
    case "comma", ",":
      return CSVDelimiter(character: ",", name: "comma", source: "configured")
    case "tab", "\\t", "\t":
      return CSVDelimiter(character: "\t", name: "tab", source: "configured")
    case "semicolon", ";":
      return CSVDelimiter(character: ";", name: "semicolon", source: "configured")
    case "pipe", "|":
      return CSVDelimiter(character: "|", name: "pipe", source: "configured")
    default:
      let characters = Array(input)
      guard characters.count == 1, characters[0] != "\n", characters[0] != "\r",
        characters[0] != "\""
      else {
        throw GatewayToolError.invalidArguments(
          "delimiter must be auto, comma, tab, semicolon, pipe, or one non-newline character.")
      }
      return CSVDelimiter(character: characters[0], name: input, source: "configured")
    }
  }

  private func inferDelimitedTextDelimiter(_ text: String) -> CSVDelimiter {
    let candidates: [(Character, String)] = [
      (",", "comma"),
      ("\t", "tab"),
      (";", "semicolon"),
      ("|", "pipe"),
    ]
    var counts = Dictionary(uniqueKeysWithValues: candidates.map { ($0.1, 0) })
    var inQuotes = false
    var index = text.startIndex
    var scannedBytes = 0
    while index < text.endIndex && scannedBytes < 8_192 {
      let character = text[index]
      scannedBytes += String(character).utf8.count
      if character == "\"" {
        let next = text.index(after: index)
        if inQuotes, next < text.endIndex, text[next] == "\"" {
          index = text.index(after: next)
          continue
        }
        inQuotes.toggle()
      } else if !inQuotes {
        for (candidate, name) in candidates where character == candidate {
          counts[name, default: 0] += 1
        }
      }
      index = text.index(after: index)
    }

    let best =
      candidates.max { lhs, rhs in
        counts[lhs.1, default: 0] < counts[rhs.1, default: 0]
      } ?? (",", "comma")
    if counts[best.1, default: 0] == 0 {
      return CSVDelimiter(character: ",", name: "comma", source: "auto")
    }
    return CSVDelimiter(character: best.0, name: best.1, source: "auto")
  }

  private func parseDelimitedText(
    _ text: String,
    delimiter: Character,
    maxRecords: Int,
    maxColumns: Int
  ) -> DelimitedTextParseResult {
    var records: [[String]] = []
    var currentRecord: [String] = []
    var currentField = ""
    var inQuotes = false
    var atFieldStart = true
    var pendingField = false
    var recordsTruncated = false
    var columnsTruncated = false

    func appendField() {
      if currentRecord.count < maxColumns {
        currentRecord.append(currentField)
      } else {
        columnsTruncated = true
      }
      currentField = ""
      atFieldStart = true
      pendingField = true
    }

    func appendRecord() {
      guard records.count < maxRecords else {
        recordsTruncated = true
        currentRecord.removeAll()
        currentField = ""
        pendingField = false
        return
      }
      records.append(currentRecord)
      currentRecord.removeAll()
      currentField = ""
      atFieldStart = true
      pendingField = false
    }

    var index = text.startIndex
    while index < text.endIndex {
      if recordsTruncated {
        break
      }
      let character = text[index]

      if inQuotes {
        if character == "\"" {
          let next = text.index(after: index)
          if next < text.endIndex, text[next] == "\"" {
            currentField.append("\"")
            pendingField = true
            atFieldStart = false
            index = text.index(after: next)
            continue
          }
          inQuotes = false
          atFieldStart = false
        } else {
          currentField.append(character)
          pendingField = true
          atFieldStart = false
        }
      } else if character == "\"" && atFieldStart {
        inQuotes = true
        pendingField = true
        atFieldStart = false
      } else if character == delimiter {
        appendField()
      } else if character == "\n" || character == "\r" {
        appendField()
        appendRecord()
        if character == "\r" {
          let next = text.index(after: index)
          if next < text.endIndex, text[next] == "\n" {
            index = next
          }
        }
      } else {
        currentField.append(character)
        pendingField = true
        atFieldStart = false
      }

      index = text.index(after: index)
    }

    if !recordsTruncated, pendingField || !currentRecord.isEmpty || !currentField.isEmpty {
      appendField()
      appendRecord()
    }

    return DelimitedTextParseResult(
      records: records,
      recordsTruncated: recordsTruncated,
      columnsTruncated: columnsTruncated,
      openQuotedField: inQuotes
    )
  }

  internal func sqliteSchema(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let includeViews = try optionalBool("include_views", in: object) ?? true
    let includeIndexes = try optionalBool("include_indexes", in: object) ?? true
    let includeTriggers = try optionalBool("include_triggers", in: object) ?? true
    let includeInternal = try optionalBool("include_internal", in: object) ?? false
    let includeSQL = try optionalBool("include_sql", in: object) ?? true
    let maxEntries = optionalInt("max_entries", in: object) ?? 500
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 100_000)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    var types = ["table"]
    if includeViews {
      types.append("view")
    }
    if includeIndexes {
      types.append("index")
    }
    if includeTriggers {
      types.append("trigger")
    }
    let typeList = types.map { "'\($0)'" }.joined(separator: ", ")
    var predicates = ["type IN (\(typeList))"]
    if !includeInternal {
      predicates.append("name NOT LIKE 'sqlite_%'")
    }
    let sqlColumn = includeSQL ? "sql" : "NULL AS sql"
    let sql = """
      SELECT type, name, tbl_name, \(sqlColumn)
      FROM sqlite_schema
      WHERE \(predicates.joined(separator: " AND "))
      ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2 \
      WHEN 'trigger' THEN 3 ELSE 4 END, name
      LIMIT \(maxEntries + 1);
      """

    let result = try commandRunner.run(
      executable: "/usr/bin/sqlite3",
      arguments: ["-batch", "-readonly", "-json", url.path, sql],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    guard !result.timedOut else {
      throw GatewayToolError.executionFailed("sqlite.schema timed out.")
    }
    guard result.exitCode == 0 else {
      throw GatewayToolError.executionFailed(
        "sqlite.schema failed with exit code \(result.exitCode.map(String.init) ?? "unknown"): \(result.stderr)"
      )
    }
    guard !result.stdoutTruncated else {
      throw GatewayToolError.executionFailed("sqlite.schema output exceeded max_output_bytes.")
    }

    let decoded: JSONValue
    do {
      decoded = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
    } catch {
      throw GatewayToolError.invalidArguments(
        "Unable to parse sqlite schema JSON: \(error.localizedDescription)")
    }
    guard let allEntries = decoded.arrayValue else {
      throw GatewayToolError.invalidArguments("Unable to parse sqlite schema JSON: expected array.")
    }

    let truncated = allEntries.count > maxEntries
    let entries = truncated ? Array(allEntries.prefix(maxEntries)) : allEntries

    return .object([
      "operation": .string("sqlite.schema"),
      "database": .object([
        "path": .string(url.path),
        "workspace_relative_path": .string(info.workspaceRelativePath),
        "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
        "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      ]),
      "include_views": .bool(includeViews),
      "include_indexes": .bool(includeIndexes),
      "include_triggers": .bool(includeTriggers),
      "include_internal": .bool(includeInternal),
      "include_sql": .bool(includeSQL),
      "max_entries": .integer(Int64(maxEntries)),
      "returned_count": .integer(Int64(entries.count)),
      "truncated": .bool(truncated),
      "sql": .string(sql),
      "argv": .array(result.arguments.map(JSONValue.string)),
      "entries": .array(entries),
      "result": .object([
        "executable": .string(result.executable),
        "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
        "timed_out": .bool(result.timedOut),
        "stdout_bytes": .integer(Int64(result.stdout.utf8.count)),
        "stdout_truncated": .bool(result.stdoutTruncated),
        "stderr": .string(result.stderr),
        "stderr_truncated": .bool(result.stderrTruncated),
      ]),
    ])
  }

  internal func sqliteQuery(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let query = try requiredString("query", in: object)
    let maxRows = optionalInt("max_rows", in: object) ?? 100
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxRows, name: "max_rows", upperBound: 100_000)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let readonlyQuery = try validatedReadonlySQLiteQuery(query)
    let executableSQL: String
    switch readonlyQuery.kind {
    case "select", "with":
      executableSQL = """
        SELECT *
        FROM (
        \(readonlyQuery.sql)
        )
        LIMIT \(maxRows + 1);
        """
    default:
      executableSQL = readonlyQuery.sql
    }

    let result = try commandRunner.run(
      executable: "/usr/bin/sqlite3",
      arguments: ["-batch", "-readonly", "-json", url.path, executableSQL],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    guard !result.timedOut else {
      throw GatewayToolError.executionFailed("sqlite.query timed out.")
    }
    guard result.exitCode == 0 else {
      throw GatewayToolError.executionFailed(
        "sqlite.query failed with exit code \(result.exitCode.map(String.init) ?? "unknown"): \(result.stderr)"
      )
    }
    guard !result.stdoutTruncated else {
      throw GatewayToolError.executionFailed("sqlite.query output exceeded max_output_bytes.")
    }

    let decoded: JSONValue
    do {
      decoded = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
    } catch {
      throw GatewayToolError.invalidArguments(
        "Unable to parse sqlite query JSON: \(error.localizedDescription)")
    }
    guard let allRows = decoded.arrayValue else {
      throw GatewayToolError.invalidArguments("Unable to parse sqlite query JSON: expected array.")
    }

    let truncated = allRows.count > maxRows
    let rows = truncated ? Array(allRows.prefix(maxRows)) : allRows

    return .object([
      "operation": .string("sqlite.query"),
      "database": .object([
        "path": .string(url.path),
        "workspace_relative_path": .string(info.workspaceRelativePath),
        "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
        "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      ]),
      "query_kind": .string(readonlyQuery.kind),
      "query": .string(readonlyQuery.sql),
      "executed_sql": .string(executableSQL),
      "max_rows": .integer(Int64(maxRows)),
      "returned_count": .integer(Int64(rows.count)),
      "truncated": .bool(truncated),
      "rows": .array(rows),
      "argv": .array(result.arguments.map(JSONValue.string)),
      "result": .object([
        "executable": .string(result.executable),
        "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
        "timed_out": .bool(result.timedOut),
        "stdout_bytes": .integer(Int64(result.stdout.utf8.count)),
        "stdout_truncated": .bool(result.stdoutTruncated),
        "stderr": .string(result.stderr),
        "stderr_truncated": .bool(result.stderrTruncated),
      ]),
    ])
  }

  private func validatedReadonlySQLiteQuery(_ sql: String) throws -> (sql: String, kind: String) {
    let withoutComments = try sqliteSQLWithoutComments(sql)
    let statement = try sqliteSingleStatement(withoutComments)
    guard !statement.isEmpty else {
      throw GatewayToolError.invalidArguments("query must not be empty.")
    }

    let tokens = sqliteTokensOutsideLiterals(statement)
    guard let first = tokens.first else {
      throw GatewayToolError.invalidArguments("query must contain a SQL statement.")
    }
    let allowedKinds = Set(["select", "with", "pragma"])
    guard allowedKinds.contains(first) else {
      throw GatewayToolError.invalidArguments(
        "sqlite.query only accepts read-only SELECT, WITH, or PRAGMA statements.")
    }

    let denied = Set([
      "alter", "analyze", "attach", "create", "delete", "detach", "drop", "insert",
      "reindex", "replace", "update", "vacuum",
    ])
    if let token = tokens.first(where: { denied.contains($0) }) {
      throw GatewayToolError.invalidArguments(
        "sqlite.query rejected non-read-only SQL token: \(token).")
    }
    if first == "pragma" {
      guard !sqliteContainsEqualsOutsideLiterals(statement) else {
        throw GatewayToolError.invalidArguments(
          "sqlite.query only accepts read-only PRAGMA statements without assignment.")
      }
      if tokens.contains("optimize") || tokens.contains("writable_schema") {
        throw GatewayToolError.invalidArguments("sqlite.query rejected unsafe PRAGMA statement.")
      }
    }

    return (statement, first)
  }

  private func sqliteSQLWithoutComments(_ sql: String) throws -> String {
    var output = ""
    var index = sql.startIndex
    var quote: Character?
    while index < sql.endIndex {
      let character = sql[index]
      let nextIndex = sql.index(after: index)
      let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil

      if let currentQuote = quote {
        output.append(character)
        if character == currentQuote {
          if next == currentQuote, currentQuote == "'" || currentQuote == "\"" {
            output.append(next!)
            index = sql.index(after: nextIndex)
            continue
          }
          quote = nil
        }
        index = nextIndex
        continue
      }

      if character == "'" || character == "\"" || character == "`" {
        quote = character
        output.append(character)
        index = nextIndex
      } else if character == "[", let closeIndex = sql[index...].firstIndex(of: "]") {
        output.append(contentsOf: sql[index...closeIndex])
        index = sql.index(after: closeIndex)
      } else if character == "-", next == "-" {
        var cursor = sql.index(after: nextIndex)
        while cursor < sql.endIndex, sql[cursor] != "\n" {
          cursor = sql.index(after: cursor)
        }
        output.append(" ")
        index = cursor
      } else if character == "/", next == "*" {
        var cursor = sql.index(after: nextIndex)
        var closed = false
        while cursor < sql.endIndex {
          let afterCursor = sql.index(after: cursor)
          if sql[cursor] == "*", afterCursor < sql.endIndex, sql[afterCursor] == "/" {
            cursor = sql.index(after: afterCursor)
            closed = true
            break
          }
          cursor = afterCursor
        }
        guard closed else {
          throw GatewayToolError.invalidArguments("query contains an unterminated block comment.")
        }
        output.append(" ")
        index = cursor
      } else {
        output.append(character)
        index = nextIndex
      }
    }

    guard quote == nil else {
      throw GatewayToolError.invalidArguments("query contains an unterminated quoted literal.")
    }
    return output
  }

  private func sqliteSingleStatement(_ sql: String) throws -> String {
    var semicolonIndex: String.Index?
    var index = sql.startIndex
    var quote: Character?
    while index < sql.endIndex {
      let character = sql[index]
      let nextIndex = sql.index(after: index)
      let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil

      if let currentQuote = quote {
        if character == currentQuote {
          if next == currentQuote, currentQuote == "'" || currentQuote == "\"" {
            index = sql.index(after: nextIndex)
            continue
          }
          quote = nil
        }
        index = nextIndex
        continue
      }

      if character == "'" || character == "\"" || character == "`" {
        quote = character
      } else if character == "[", let closeIndex = sql[index...].firstIndex(of: "]") {
        index = sql.index(after: closeIndex)
        continue
      } else if character == ";" {
        guard semicolonIndex == nil else {
          throw GatewayToolError.invalidArguments("sqlite.query accepts one SQL statement only.")
        }
        semicolonIndex = index
      }
      index = nextIndex
    }

    guard quote == nil else {
      throw GatewayToolError.invalidArguments("query contains an unterminated quoted literal.")
    }

    if let semicolonIndex {
      let rest = sql[sql.index(after: semicolonIndex)...]
      guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GatewayToolError.invalidArguments("sqlite.query accepts one SQL statement only.")
      }
      return String(sql[..<semicolonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return sql.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func sqliteTokensOutsideLiterals(_ sql: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var index = sql.startIndex
    var quote: Character?

    func flush() {
      if !current.isEmpty {
        tokens.append(current.lowercased())
        current.removeAll()
      }
    }

    while index < sql.endIndex {
      let character = sql[index]
      let nextIndex = sql.index(after: index)
      let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil

      if let currentQuote = quote {
        if character == currentQuote {
          if next == currentQuote, currentQuote == "'" || currentQuote == "\"" {
            index = sql.index(after: nextIndex)
            continue
          }
          quote = nil
        }
        index = nextIndex
        continue
      }

      if character == "'" || character == "\"" || character == "`" {
        flush()
        quote = character
      } else if character == "[", let closeIndex = sql[index...].firstIndex(of: "]") {
        flush()
        index = sql.index(after: closeIndex)
        continue
      } else if character.isLetter || character.isNumber || character == "_" {
        current.append(character)
      } else {
        flush()
      }
      index = nextIndex
    }
    flush()
    return tokens
  }

  private func sqliteContainsEqualsOutsideLiterals(_ sql: String) -> Bool {
    var index = sql.startIndex
    var quote: Character?
    while index < sql.endIndex {
      let character = sql[index]
      let nextIndex = sql.index(after: index)
      let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil

      if let currentQuote = quote {
        if character == currentQuote {
          if next == currentQuote, currentQuote == "'" || currentQuote == "\"" {
            index = sql.index(after: nextIndex)
            continue
          }
          quote = nil
        }
        index = nextIndex
        continue
      }

      if character == "'" || character == "\"" || character == "`" {
        quote = character
      } else if character == "[", let closeIndex = sql[index...].firstIndex(of: "]") {
        index = sql.index(after: closeIndex)
        continue
      } else if character == "=" {
        return true
      }
      index = nextIndex
    }
    return false
  }

  private func propertyListFormatName(_ format: PropertyListSerialization.PropertyListFormat)
    -> String
  {
    switch format {
    case .openStep:
      return "openstep"
    case .xml:
      return "xml"
    case .binary:
      return "binary"
    @unknown default:
      return "unknown"
    }
  }

  private func yamlJSONValue(
    _ value: Any,
    stats: inout YAMLConversionStats,
    depth: Int,
    maxDepth: Int
  ) throws -> JSONValue {
    guard depth <= maxDepth else {
      throw GatewayToolError.invalidArguments("YAML nesting exceeds max_depth.")
    }

    switch value {
    case _ as NSNull:
      return .null
    case let number as NSNumber:
      if !number.doubleValue.isFinite { return yamlJSONNumber(number.doubleValue, stats: &stats) }
      return try JSONValue(foundationNumber: number)
    case let string as String:
      return .string(string)
    case let date as Date:
      stats.dateCount += 1
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return .object([
        "type": .string("date"),
        "iso8601": .string(formatter.string(from: date)),
      ])
    case let array as [Any]:
      return .array(
        try array.map {
          try yamlJSONValue($0, stats: &stats, depth: depth + 1, maxDepth: maxDepth)
        })
    case let dictionary as [String: Any]:
      var object: [String: JSONValue] = [:]
      for key in dictionary.keys.sorted() {
        if let entry = dictionary[key] {
          object[key] = try yamlJSONValue(
            entry,
            stats: &stats,
            depth: depth + 1,
            maxDepth: maxDepth
          )
        }
      }
      return .object(object)
    case let dictionary as [AnyHashable: Any]:
      var object: [String: JSONValue] = [:]
      let pairs = dictionary.map { key, value in (yamlKeyString(key), value, key is String) }
        .sorted { lhs, rhs in lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending }
      for (key, entry, keyWasString) in pairs {
        if !keyWasString {
          stats.nonStringKeyCount += 1
        }
        if object[key] != nil {
          stats.keyCollisionCount += 1
        }
        object[key] = try yamlJSONValue(
          entry,
          stats: &stats,
          depth: depth + 1,
          maxDepth: maxDepth
        )
      }
      return .object(object)
    case let array as NSArray:
      return .array(
        try array.map {
          try yamlJSONValue($0, stats: &stats, depth: depth + 1, maxDepth: maxDepth)
        })
    case let dictionary as NSDictionary:
      var object: [String: JSONValue] = [:]
      let pairs = dictionary.map { key, value in
        (yamlKeyString(key), value, key is String)
      }
      .sorted { lhs, rhs in lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending }
      for (key, entry, keyWasString) in pairs {
        if !keyWasString {
          stats.nonStringKeyCount += 1
        }
        if object[key] != nil {
          stats.keyCollisionCount += 1
        }
        object[key] = try yamlJSONValue(
          entry,
          stats: &stats,
          depth: depth + 1,
          maxDepth: maxDepth
        )
      }
      return .object(object)
    default:
      stats.unsupportedValueCount += 1
      return .object([
        "type": .string("unsupported_yaml_value"),
        "swift_type": .string(String(describing: type(of: value))),
        "description": .string(String(describing: value)),
      ])
    }
  }

  private func yamlJSONNumber(_ value: Double, stats: inout YAMLConversionStats) -> JSONValue {
    guard value.isFinite else {
      stats.nonFiniteNumberCount += 1
      let representation: String
      if value.isNaN {
        representation = "nan"
      } else if value > 0 {
        representation = "inf"
      } else {
        representation = "-inf"
      }
      return .object([
        "type": .string("non_finite_number"),
        "value": .string(representation),
      ])
    }
    return .number(value)
  }

  private func yamlKeyString(_ key: Any) -> String {
    if let string = key as? String {
      return string
    }
    if key is NSNull {
      return "null"
    }
    return String(describing: key)
  }

  private func propertyListJSONValue(_ value: Any, depth: Int = 0) throws -> JSONValue {
    guard depth <= 100 else {
      throw GatewayToolError.invalidArguments("Property list nesting exceeds 100 levels.")
    }

    switch value {
    case let string as String:
      return .string(string)
    case let number as NSNumber:
      return try JSONValue(foundationNumber: number)
    case let date as Date:
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return .object([
        "type": .string("date"),
        "iso8601": .string(formatter.string(from: date)),
      ])
    case let data as Data:
      return .object([
        "type": .string("data"),
        "byte_count": .integer(Int64(data.count)),
        "base64": .string(data.base64EncodedString()),
      ])
    case let array as [Any]:
      return .array(try array.map { try propertyListJSONValue($0, depth: depth + 1) })
    case let dictionary as [String: Any]:
      var object: [String: JSONValue] = [:]
      for key in dictionary.keys.sorted() {
        if let entry = dictionary[key] {
          object[key] = try propertyListJSONValue(entry, depth: depth + 1)
        }
      }
      return .object(object)
    default:
      throw GatewayToolError.invalidArguments(
        "Unsupported property list value: \(String(describing: type(of: value)))")
    }
  }

  private func propertyListObject(from value: JSONValue, depth: Int = 0) throws -> Any {
    guard depth <= 100 else {
      throw GatewayToolError.invalidArguments("Property list nesting exceeds 100 levels.")
    }

    switch value {
    case .string(let string):
      return string
    case .bool(let bool):
      return bool
    case .integer(let integer):
      return integer
    case .number(let number):
      guard number.isFinite else {
        throw GatewayToolError.invalidArguments("Property list numbers must be finite.")
      }
      if let integer = Int64(exactly: number) { return integer }
      return number
    case .array(let array):
      return try array.map { try propertyListObject(from: $0, depth: depth + 1) }
    case .object(let object):
      if let typed = try typedPropertyListObject(from: object) {
        return typed
      }
      var dictionary: [String: Any] = [:]
      for key in object.keys.sorted() {
        if let entry = object[key] {
          dictionary[key] = try propertyListObject(from: entry, depth: depth + 1)
        }
      }
      return dictionary
    case .null:
      throw GatewayToolError.invalidArguments("Property lists do not support null values.")
    }
  }

  private func typedPropertyListObject(from object: [String: JSONValue]) throws -> Any? {
    guard let type = object["type"]?.stringValue else {
      return nil
    }
    switch type {
    case "date":
      guard let iso8601 = object["iso8601"]?.stringValue else {
        return nil
      }
      guard let date = propertyListDate(from: iso8601) else {
        throw GatewayToolError.invalidArguments("Invalid property list date iso8601 value.")
      }
      return date
    case "data":
      guard let base64 = object["base64"]?.stringValue else {
        return nil
      }
      guard let data = Data(base64Encoded: base64) else {
        throw GatewayToolError.invalidArguments("Invalid property list data base64 value.")
      }
      return data
    default:
      return nil
    }
  }

  private func propertyListDate(from string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
      return date
    }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: string)
  }

  private func propertyListPreview(
    data: Data,
    format: PropertyListSerialization.PropertyListFormat,
    maxBytes: Int
  ) -> JSONValue {
    let bounded = data.count > maxBytes ? Data(data.prefix(maxBytes)) : data
    let truncated = data.count > maxBytes
    if format == .xml, let text = String(data: bounded, encoding: .utf8) {
      return .object([
        "preview_max_bytes": .integer(Int64(maxBytes)),
        "encoding": .string("utf8"),
        "content": .string(text),
        "content_truncated": .bool(truncated),
      ])
    }
    return .object([
      "preview_max_bytes": .integer(Int64(maxBytes)),
      "encoding": .string("base64"),
      "content": .string(bounded.base64EncodedString()),
      "content_truncated": .bool(truncated),
    ])
  }

  private func tomlJSONValue(_ value: DecodedTOMLValue) -> JSONValue {
    switch value {
    case .string(let string):
      return .string(string)
    case .integer(let integer):
      return .integer(Int64(integer))
    case .float(let double):
      return .number(double)
    case .bool(let bool):
      return .bool(bool)
    case .offsetDateTime(let date):
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return .object([
        "type": .string("offset_datetime"),
        "iso8601": .string(formatter.string(from: date)),
      ])
    case .localDateTime(let dateTime):
      return .object([
        "type": .string("local_datetime"),
        "value": .string(formatTOMLLocalDateTime(dateTime)),
      ])
    case .localDate(let date):
      return .object([
        "type": .string("local_date"),
        "value": .string(formatTOMLLocalDate(date)),
      ])
    case .localTime(let time):
      return .object([
        "type": .string("local_time"),
        "value": .string(formatTOMLLocalTime(time)),
      ])
    case .array(let array):
      return .array(array.map(tomlJSONValue))
    case .table(let table):
      var object: [String: JSONValue] = [:]
      for key in table.keys.sorted() {
        if let value = table[key] {
          object[key] = tomlJSONValue(value)
        }
      }
      return .object(object)
    }
  }

  private func structuredFormat(_ requestedFormat: String, path: String) throws -> String {
    let normalized = requestedFormat.lowercased()
    let allowed = ["auto", "json", "yaml", "toml", "plist"]
    guard allowed.contains(normalized) else {
      throw GatewayToolError.invalidArguments(
        "format must be one of: auto, json, yaml, toml, plist.")
    }
    guard normalized == "auto" else {
      return normalized
    }
    let extensionName = URL(fileURLWithPath: path).pathExtension.lowercased()
    switch extensionName {
    case "json":
      return "json"
    case "yaml", "yml":
      return "yaml"
    case "toml":
      return "toml"
    case "plist":
      return "plist"
    default:
      throw GatewayToolError.invalidArguments(
        "Unable to infer structured format from file extension; pass format explicitly.")
    }
  }

  internal func parseStructuredValue(
    data: Data,
    format: String,
    path: String,
    maxBytes: Int,
    maxDocuments: Int,
    maxDepth: Int
  ) throws -> StructuredDocument {
    switch format {
    case "json":
      do {
        return StructuredDocument(
          value: try JSONDecoder().decode(JSONValue.self, from: data),
          metadata: .object(["kind": .string("json")])
        )
      } catch {
        throw GatewayToolError.invalidArguments(
          "Unable to parse JSON: \(error.localizedDescription)")
      }

    case "toml":
      let decoder = TOMLDecoder()
      decoder.limits = TOMLDecoder.DecodingLimits(
        maxInputSize: maxBytes,
        maxDepth: maxDepth,
        maxTableKeys: 10_000,
        maxArrayLength: 100_000,
        maxStringLength: min(maxBytes, 1_048_576)
      )
      do {
        let value = try decoder.decode(DecodedTOMLValue.self, from: data)
        return StructuredDocument(
          value: tomlJSONValue(value),
          metadata: .object(["kind": .string("toml")])
        )
      } catch {
        throw GatewayToolError.invalidArguments(
          "Unable to parse TOML: \(error.localizedDescription)")
      }

    case "yaml":
      guard let text = String(data: data, encoding: .utf8) else {
        throw GatewayToolError.invalidArguments("YAML file is not valid UTF-8: \(path)")
      }
      var sequence: YamlSequence<Any>
      do {
        sequence = try Yams.load_all(yaml: text)
      } catch {
        throw GatewayToolError.invalidArguments(
          "Unable to parse YAML: \(error.localizedDescription)")
      }
      var stats = YAMLConversionStats()
      var documents: [JSONValue] = []
      var parsedDocumentCount = 0
      while let document = sequence.next() {
        parsedDocumentCount += 1
        if documents.count < maxDocuments {
          documents.append(
            try yamlJSONValue(document, stats: &stats, depth: 0, maxDepth: maxDepth))
        }
      }
      if let error = sequence.error {
        throw GatewayToolError.invalidArguments(
          "Unable to parse YAML: \(error.localizedDescription)")
      }
      let value: JSONValue
      switch documents.count {
      case 0:
        value = .null
      case 1:
        value = documents[0]
      default:
        value = .array(documents)
      }
      return StructuredDocument(
        value: value,
        metadata: .object([
          "kind": .string("yaml"),
          "document_count": .integer(Int64(parsedDocumentCount)),
          "returned_document_count": .integer(Int64(documents.count)),
          "document_count_truncated": .bool(parsedDocumentCount > documents.count),
          "conversion": stats.json,
        ])
      )

    case "plist":
      var propertyListFormat = PropertyListSerialization.PropertyListFormat.xml
      let plist: Any
      do {
        plist = try PropertyListSerialization.propertyList(
          from: data,
          options: [],
          format: &propertyListFormat
        )
      } catch {
        throw GatewayToolError.invalidArguments(
          "Unable to parse property list: \(error.localizedDescription)")
      }
      return StructuredDocument(
        value: try propertyListJSONValue(plist),
        metadata: .object([
          "kind": .string("plist"),
          "property_list_format": .string(propertyListFormatName(propertyListFormat)),
        ])
      )

    default:
      throw GatewayToolError.invalidArguments("Unsupported structured format: \(format)")
    }
  }

  private func selectStructuredValue(_ root: JSONValue, path: [StructuredPathSegment])
    -> StructuredSelection
  {
    var current = root
    for (index, segment) in path.enumerated() {
      switch segment {
      case .key(let key):
        guard let object = current.objectValue else {
          return StructuredSelection(
            matched: false,
            value: .null,
            failure: StructuredSelectionFailure(
              index: index,
              segment: segment,
              reason: "not_object",
              actualKind: jsonValueKind(current)
            )
          )
        }
        guard let value = object[key] else {
          return StructuredSelection(
            matched: false,
            value: .null,
            failure: StructuredSelectionFailure(
              index: index,
              segment: segment,
              reason: "missing_key",
              actualKind: "object"
            )
          )
        }
        current = value

      case .index(let itemIndex):
        guard let array = current.arrayValue else {
          return StructuredSelection(
            matched: false,
            value: .null,
            failure: StructuredSelectionFailure(
              index: index,
              segment: segment,
              reason: "not_array",
              actualKind: jsonValueKind(current)
            )
          )
        }
        guard itemIndex < array.count else {
          return StructuredSelection(
            matched: false,
            value: .null,
            failure: StructuredSelectionFailure(
              index: index,
              segment: segment,
              reason: "index_out_of_range",
              actualKind: "array"
            )
          )
        }
        current = array[itemIndex]
      }
    }

    return StructuredSelection(matched: true, value: current, failure: nil)
  }

  private func structuredPointer(_ path: [StructuredPathSegment]) -> String {
    guard !path.isEmpty else {
      return ""
    }
    return path.map { segment in
      switch segment {
      case .key(let key):
        return "/"
          + key.replacingOccurrences(of: "~", with: "~0")
          .replacingOccurrences(of: "/", with: "~1")
      case .index(let index):
        return "/\(index)"
      }
    }.joined()
  }

  private func jsonValueKind(_ value: JSONValue) -> String {
    switch value {
    case .string:
      return "string"
    case .number, .integer:
      return "number"
    case .bool:
      return "bool"
    case .object:
      return "object"
    case .array:
      return "array"
    case .null:
      return "null"
    }
  }

  private func formatTOMLLocalDateTime(_ value: LocalDateTime) -> String {
    "\(formatTOMLLocalDate(LocalDate(year: value.year, month: value.month, day: value.day)))T\(formatTOMLLocalTime(LocalTime(hour: value.hour, minute: value.minute, second: value.second, nanosecond: value.nanosecond)))"
  }

  private func formatTOMLLocalDate(_ value: LocalDate) -> String {
    String(format: "%04d-%02d-%02d", value.year, value.month, value.day)
  }

  private func formatTOMLLocalTime(_ value: LocalTime) -> String {
    var time = String(format: "%02d:%02d:%02d", value.hour, value.minute, value.second)
    if value.nanosecond > 0 {
      var fractional = String(format: "%09d", value.nanosecond)
      while fractional.last == "0" {
        fractional.removeLast()
      }
      time += ".\(fractional)"
    }
    return time
  }
}

private enum DecodedTOMLValue: Decodable {
  case string(String)
  case integer(Int64)
  case float(Double)
  case bool(Bool)
  case offsetDateTime(Date)
  case localDateTime(LocalDateTime)
  case localDate(LocalDate)
  case localTime(LocalTime)
  case array([DecodedTOMLValue])
  case table([String: DecodedTOMLValue])

  init(from decoder: any Decoder) throws {
    if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
      var table: [String: DecodedTOMLValue] = [:]
      for key in keyed.allKeys {
        table[key.stringValue] = try keyed.decode(DecodedTOMLValue.self, forKey: key)
      }
      self = .table(table)
      return
    }

    if var unkeyed = try? decoder.unkeyedContainer() {
      var array: [DecodedTOMLValue] = []
      while !unkeyed.isAtEnd {
        array.append(try unkeyed.decode(DecodedTOMLValue.self))
      }
      self = .array(array)
      return
    }

    let single = try decoder.singleValueContainer()
    if let value = try? single.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? single.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? single.decode(Double.self) {
      self = .float(value)
    } else if let value = try? single.decode(LocalDateTime.self) {
      self = .localDateTime(value)
    } else if let value = try? single.decode(LocalDate.self) {
      self = .localDate(value)
    } else if let value = try? single.decode(LocalTime.self) {
      self = .localTime(value)
    } else if let value = try? single.decode(Date.self) {
      self = .offsetDateTime(value)
    } else if let value = try? single.decode(String.self) {
      self = .string(value)
    } else {
      throw DecodingError.typeMismatch(
        DecodedTOMLValue.self,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Unsupported TOML value"
        )
      )
    }
  }
}

private struct DynamicCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = "\(intValue)"
    self.intValue = intValue
  }
}

internal enum StructuredPathSegment {
  case key(String)
  case index(Int)

  var json: JSONValue {
    switch self {
    case .key(let key):
      return .string(key)
    case .index(let index):
      return .integer(Int64(index))
    }
  }
}

internal struct StructuredDocument {
  var value: JSONValue
  var metadata: JSONValue
}

private struct StructuredSelection {
  var matched: Bool
  var value: JSONValue
  var failure: StructuredSelectionFailure?
}

private struct StructuredSelectionFailure {
  var index: Int
  var segment: StructuredPathSegment
  var reason: String
  var actualKind: String

  var json: JSONValue {
    .object([
      "index": .integer(Int64(index)),
      "segment": segment.json,
      "reason": .string(reason),
      "actual_kind": .string(actualKind),
    ])
  }
}

private struct YAMLConversionStats {
  var nonStringKeyCount = 0
  var keyCollisionCount = 0
  var nonFiniteNumberCount = 0
  var dateCount = 0
  var unsupportedValueCount = 0

  var json: JSONValue {
    .object([
      "non_string_key_count": .integer(Int64(nonStringKeyCount)),
      "key_collision_count": .integer(Int64(keyCollisionCount)),
      "non_finite_number_count": .integer(Int64(nonFiniteNumberCount)),
      "date_count": .integer(Int64(dateCount)),
      "unsupported_value_count": .integer(Int64(unsupportedValueCount)),
    ])
  }
}

private final class XMLTreeParserDelegate: NSObject, XMLParserDelegate {
  let maxNodes: Int
  let maxDepth: Int
  let maxTextBytes: Int
  var root: XMLNodeBuilder?
  var elementCount = 0
  var returnedElementCount = 0
  var maxDepthObserved = 0
  var nodeCountTruncated = false
  var depthTruncated = false
  var textTruncated = false

  private var stack: [XMLNodeBuilder] = []
  private var currentDepth = 0
  private var skippingDepth = 0

  init(maxNodes: Int, maxDepth: Int, maxTextBytes: Int) {
    self.maxNodes = maxNodes
    self.maxDepth = maxDepth
    self.maxTextBytes = maxTextBytes
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    elementCount += 1
    currentDepth += 1
    maxDepthObserved = max(maxDepthObserved, currentDepth)

    if skippingDepth > 0 {
      skippingDepth += 1
      return
    }

    if let parent = stack.last {
      parent.childCount += 1
    }

    guard currentDepth <= maxDepth else {
      depthTruncated = true
      skippingDepth = 1
      return
    }
    guard returnedElementCount < maxNodes else {
      nodeCountTruncated = true
      skippingDepth = 1
      return
    }

    let node = XMLNodeBuilder(
      name: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict,
      maxTextBytes: maxTextBytes
    )
    returnedElementCount += 1
    if let parent = stack.last {
      parent.children.append(node)
    } else {
      root = node
    }
    stack.append(node)
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if skippingDepth > 0 {
      skippingDepth -= 1
    } else if !stack.isEmpty {
      _ = stack.removeLast()
    }
    currentDepth = max(0, currentDepth - 1)
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard skippingDepth == 0, let node = stack.last else {
      return
    }
    if node.appendText(string) {
      textTruncated = true
    }
  }

  func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
    guard skippingDepth == 0, let node = stack.last else {
      return
    }
    let text = String(decoding: cdataBlock, as: UTF8.self)
    if node.appendText(text) {
      textTruncated = true
    }
  }

  func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?)
    -> Data?
  {
    nil
  }
}

private final class XMLNodeBuilder {
  let name: String
  let namespaceURI: String?
  let qualifiedName: String?
  let attributes: [String: String]
  let maxTextBytes: Int
  var children: [XMLNodeBuilder] = []
  var childCount = 0
  private var text = ""
  private var textByteCount = 0
  private var textTruncated = false

  init(
    name: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String],
    maxTextBytes: Int
  ) {
    self.name = name
    self.namespaceURI = namespaceURI
    self.qualifiedName = qualifiedName
    self.attributes = attributes
    self.maxTextBytes = maxTextBytes
  }

  func appendText(_ value: String) -> Bool {
    guard textByteCount < maxTextBytes else {
      textTruncated = true
      return true
    }
    var didTruncate = false
    for scalar in value.unicodeScalars {
      let fragment = String(scalar)
      let bytes = fragment.utf8.count
      guard textByteCount + bytes <= maxTextBytes else {
        didTruncate = true
        break
      }
      text.append(fragment)
      textByteCount += bytes
    }
    if didTruncate {
      textTruncated = true
    }
    return didTruncate
  }

  func json(trimText: Bool) -> JSONValue {
    var attributeObject: [String: JSONValue] = [:]
    for key in attributes.keys.sorted() {
      attributeObject[key] = .string(attributes[key] ?? "")
    }

    let displayText =
      trimText
      ? text.trimmingCharacters(in: .whitespacesAndNewlines)
      : text

    return .object([
      "name": .string(name),
      "qualified_name": normalizedOptionalString(qualifiedName),
      "namespace_uri": normalizedOptionalString(namespaceURI),
      "attribute_count": .integer(Int64(attributes.count)),
      "attributes": .object(attributeObject),
      "text": displayText.isEmpty ? .null : .string(displayText),
      "text_truncated": .bool(textTruncated),
      "child_count": .integer(Int64(childCount)),
      "returned_child_count": .integer(Int64(children.count)),
      "children": .array(children.map { $0.json(trimText: trimText) }),
    ])
  }

  private func normalizedOptionalString(_ value: String?) -> JSONValue {
    guard let value, !value.isEmpty else {
      return .null
    }
    return .string(value)
  }
}

private struct CSVDelimiter {
  var character: Character
  var name: String
  var source: String
}

private struct DelimitedTextParseResult {
  var records: [[String]]
  var recordsTruncated: Bool
  var columnsTruncated: Bool
  var openQuotedField: Bool
}
