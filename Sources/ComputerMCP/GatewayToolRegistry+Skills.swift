import Foundation
import Yams

extension GatewayToolRegistry {
  internal func requireSkillsEnabled() throws {
    guard configuration.skills.enabled else {
      throw GatewayToolError.disabled("skills tools are disabled by configuration.")
    }
  }

  internal func skillsRoots() throws -> JSONValue {
    let roots = configuration.skills.roots.map(skillRootStatus)
    return .object([
      "operation": .string("skills.roots"),
      "enabled": .bool(configuration.skills.enabled),
      "root_count": .integer(Int64(roots.count)),
      "max_bytes_per_skill": .integer(Int64(configuration.skills.maxBytesPerSkill)),
      "roots": .array(roots.map(\.json)),
    ])
  }

  internal func skillsList(arguments object: [String: JSONValue]) throws -> JSONValue {
    let rootID = try optionalString("root_id", in: object)
    let maxResults = optionalInt("max_results", in: object) ?? 500
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)

    let inventory = try scanSkills(rootID: rootID, maxResults: maxResults)
    return .object([
      "operation": .string("skills.list"),
      "root_id": rootID.map(JSONValue.string) ?? .null,
      "root_count": .integer(Int64(inventory.rootStatuses.count)),
      "skill_count": .integer(Int64(inventory.skills.count)),
      "returned_count": .integer(Int64(inventory.skills.count)),
      "max_results": .integer(Int64(maxResults)),
      "scan_truncated": .bool(inventory.scanTruncated),
      "result_truncated": .bool(inventory.resultTruncated),
      "truncated": .bool(inventory.scanTruncated || inventory.resultTruncated),
      "roots": .array(inventory.rootStatuses.map(\.json)),
      "skills": .array(inventory.skills.map(\.json)),
    ])
  }

  internal func skillsDescribe(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 32)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let skill = try resolveSkill(name: name, rootID: rootID)
    let result = try listSkillFiles(
      skill: skill,
      directory: skill.directoryURL,
      includeHidden: true,
      maxDepth: maxDepth,
      maxResults: 10_000,
      maxScanEntries: maxScanEntries
    )
    let resources = skillResourceSummaries(skill: skill, files: result.files)
    let fileCount = result.files.filter { $0.type == "file" }.count
    let directoryCount = result.files.filter { $0.type == "directory" }.count
    let symlinkCount = result.files.filter { $0.isSymlink }.count
    let otherCount = result.files.filter { $0.type == "other" }.count
    let totalSize = result.files.compactMap(\.sizeBytes).reduce(Int64(0), +)

    return .object([
      "operation": .string("skills.describe"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "description": skill.description.map(JSONValue.string) ?? .null,
      "path": .string(skill.fileURL.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "entrypoint": skillEntrypointJSON(skill),
      "resource_count": .integer(Int64(resources.count)),
      "resources": .array(resources.map(\.json)),
      "file_count": .integer(Int64(fileCount)),
      "directory_count": .integer(Int64(directoryCount)),
      "symlink_count": .integer(Int64(symlinkCount)),
      "other_count": .integer(Int64(otherCount)),
      "total_size_bytes": .integer(Int64(totalSize)),
      "max_depth": .integer(Int64(maxDepth)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_count": .integer(Int64(result.scannedCount)),
      "result_truncated": .bool(result.resultTruncated),
      "scan_truncated": .bool(result.scanTruncated),
      "truncated": .bool(result.resultTruncated || result.scanTruncated),
      "read_context": skillReadContext(skill),
      "files_context": skillFilesContext(skill),
      "read_package_context": skillReadPackageContext(skill),
    ])
  }

  internal func skillsValidate(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 32)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let content = try readSkillContent(skill.fileURL, maxBytes: maxBytes)
    let frontmatter = skillFrontmatterStatus(content.content)
    let result = try listSkillFiles(
      skill: skill,
      directory: skill.directoryURL,
      includeHidden: true,
      maxDepth: maxDepth,
      maxResults: 10_000,
      maxScanEntries: maxScanEntries
    )
    let resources = skillResourceSummaries(skill: skill, files: result.files)
    var issues: [SkillValidationIssue] = []

    if !content.validUTF8 {
      issues.append(
        SkillValidationIssue(
          severity: "error",
          code: "skill_md_not_utf8",
          message: "SKILL.md is not valid UTF-8.",
          path: "SKILL.md"
        ))
    }
    if content.truncated {
      issues.append(
        SkillValidationIssue(
          severity: "warning",
          code: "skill_md_truncated",
          message: "SKILL.md was truncated at max_bytes; validation is partial.",
          path: "SKILL.md"
        ))
    }
    if let lineCount = frontmatter.lineCount, lineCount > 500 {
      issues.append(
        SkillValidationIssue(
          severity: "warning",
          code: "skill_md_long",
          message: "SKILL.md is over 500 lines.",
          path: "SKILL.md"
        ))
    }
    if !frontmatter.hasOpening {
      issues.append(
        SkillValidationIssue(
          severity: "error",
          code: "missing_frontmatter",
          message: "SKILL.md must start with YAML frontmatter delimited by ---.",
          path: "SKILL.md"
        ))
    } else if !frontmatter.closed {
      issues.append(
        SkillValidationIssue(
          severity: "error",
          code: "unterminated_frontmatter",
          message: "SKILL.md frontmatter must close with ---.",
          path: "SKILL.md"
        ))
    }
    if let parseError = frontmatter.parseError {
      issues.append(
        SkillValidationIssue(
          severity: "error",
          code: "invalid_frontmatter_yaml",
          message: parseError,
          path: "SKILL.md"
        ))
    }
    if frontmatter.name == nil {
      issues.append(
        SkillValidationIssue(
          severity: "error",
          code: "missing_name",
          message: "SKILL.md frontmatter must include a non-empty name.",
          path: "SKILL.md"
        ))
    } else if let skillName = frontmatter.name, !isCanonicalSkillName(skillName) {
      issues.append(
        SkillValidationIssue(
          severity: "warning",
          code: "noncanonical_name",
          message: "Skill name should use lowercase letters, digits, and hyphens.",
          path: "SKILL.md"
        ))
    }
    if frontmatter.description == nil {
      issues.append(
        SkillValidationIssue(
          severity: "error",
          code: "missing_description",
          message: "SKILL.md frontmatter must include a non-empty description.",
          path: "SKILL.md"
        ))
    }
    if let skillName = frontmatter.name, skillName != skill.directoryName {
      issues.append(
        SkillValidationIssue(
          severity: "warning",
          code: "directory_name_mismatch",
          message: "Skill directory name should match the frontmatter name.",
          path: "."
        ))
    }

    for file in result.files {
      if file.isSymlink && !file.targetInsideSkill {
        issues.append(
          SkillValidationIssue(
            severity: "error",
            code: "symlink_escape",
            message: "Skill package contains a symlink whose target escapes the skill directory.",
            path: file.path
          ))
      } else if !file.isReadable {
        issues.append(
          SkillValidationIssue(
            severity: "warning",
            code: "unreadable_path",
            message: "Skill package contains an unreadable path.",
            path: file.path
          ))
      }
    }
    if result.scanTruncated || result.resultTruncated {
      issues.append(
        SkillValidationIssue(
          severity: "warning",
          code: "scan_truncated",
          message: "Skill package scan was truncated; validation is partial.",
          path: "."
        ))
    }

    let errorCount = issues.filter { $0.severity == "error" }.count
    let warningCount = issues.filter { $0.severity == "warning" }.count
    return .object([
      "operation": .string("skills.validate"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "valid": .bool(errorCount == 0),
      "error_count": .integer(Int64(errorCount)),
      "warning_count": .integer(Int64(warningCount)),
      "issue_count": .integer(Int64(issues.count)),
      "issues": .array(issues.map(\.json)),
      "frontmatter": frontmatter.json,
      "entrypoint": .object([
        "path": .string("SKILL.md"),
        "absolute_path": .string(skill.fileURL.path),
        "size_bytes": skill.sizeBytes.map { .integer(Int64($0)) } ?? .null,
        "modified_at": skill.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
        "content_bytes_read": .integer(Int64(content.bytesRead)),
        "content_truncated": .bool(content.truncated),
        "valid_utf8": .bool(content.validUTF8),
        "read_context": skillReadContext(skill),
      ]),
      "resources": .array(resources.map(\.json)),
      "max_depth": .integer(Int64(maxDepth)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_count": .integer(Int64(result.scannedCount)),
      "result_truncated": .bool(result.resultTruncated),
      "scan_truncated": .bool(result.scanTruncated),
      "truncated": .bool(result.resultTruncated || result.scanTruncated || content.truncated),
      "describe_context": skillDescribeContext(skill),
      "read_context": skillReadContext(skill),
      "files_context": skillFilesContext(skill),
      "read_package_context": skillReadPackageContext(skill),
    ])
  }

  internal func skillsFrontmatter(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let relativePath = requestedPath?.isEmpty == false ? requestedPath! : "SKILL.md"
    let requestedFormat = try optionalString("format", in: object) ?? "auto"
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    let maxDepth = optionalInt("max_depth", in: object) ?? 128
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 512)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }
    let formats = try markdownFrontmatterFormats(requestedFormat)

    let skill = try resolveSkill(name: name, rootID: rootID)
    let file = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Unknown skill file: \(relativePath)")
    }
    guard !isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Skill path is a directory: \(relativePath)")
    }

    let content = try readSkillContent(file, maxBytes: maxBytes)
    guard content.validUTF8, let text = content.content else {
      throw GatewayToolError.invalidArguments(
        "Skill Markdown file is not valid UTF-8: \(relativePath)")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
      let opening = markdownFrontmatterOpening(firstLine, allowedFormats: formats)
    else {
      return skillFrontmatterPayload(
        skill: skill,
        path: relativePath,
        absolutePath: file.path,
        requestedFormat: requestedFormat,
        format: nil,
        maxBytes: maxBytes,
        maxDepth: maxDepth,
        bytesScanned: content.bytesRead,
        fileTruncated: content.truncated,
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
      return skillFrontmatterPayload(
        skill: skill,
        path: relativePath,
        absolutePath: file.path,
        requestedFormat: requestedFormat,
        format: opening.format,
        maxBytes: maxBytes,
        maxDepth: maxDepth,
        bytesScanned: content.bytesRead,
        fileTruncated: content.truncated,
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
    if opening.format == "yaml" {
      let decoded = decodeSkillFrontmatterYAML(raw)
      parsedDocument = decoded.document
      parseError = decoded.parseError
    } else {
      do {
        parsedDocument = try parseStructuredValue(
          data: rawData,
          format: opening.format,
          path: relativePath,
          maxBytes: max(rawData.count, 1),
          maxDocuments: 1,
          maxDepth: maxDepth
        )
        parseError = nil
      } catch {
        parsedDocument = nil
        parseError = error.localizedDescription
      }
    }

    return skillFrontmatterPayload(
      skill: skill,
      path: relativePath,
      absolutePath: file.path,
      requestedFormat: requestedFormat,
      format: opening.format,
      maxBytes: maxBytes,
      maxDepth: maxDepth,
      bytesScanned: content.bytesRead,
      fileTruncated: content.truncated,
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

  internal func skillsRead(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let content = try readSkillContent(skill.fileURL, maxBytes: maxBytes)
    return .object([
      "operation": .string("skills.read"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "description": skill.description.map(JSONValue.string) ?? .null,
      "path": .string(skill.fileURL.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "size_bytes": skill.sizeBytes.map { .integer(Int64($0)) } ?? .null,
      "modified_at": skill.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "max_bytes": .integer(Int64(maxBytes)),
      "content": content.content.map(JSONValue.string) ?? .null,
      "content_bytes_read": .integer(Int64(content.bytesRead)),
      "content_truncated": .bool(content.truncated),
      "valid_utf8": .bool(content.validUTF8),
    ])
  }

  internal func skillsFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let relativePath = requestedPath?.isEmpty == false ? requestedPath! : "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxResults = optionalInt("max_results", in: object) ?? 500
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 32)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let skill = try resolveSkill(name: name, rootID: rootID)
    let directory = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw GatewayToolError.invalidArguments("Skill path is not a directory: \(relativePath)")
    }

    let result = try listSkillFiles(
      skill: skill,
      directory: directory,
      includeHidden: includeHidden,
      maxDepth: maxDepth,
      maxResults: maxResults,
      maxScanEntries: maxScanEntries
    )
    return .object([
      "operation": .string("skills.files"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(relativePath),
      "skill_directory_path": .string(skill.directoryURL.path),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "include_hidden": .bool(includeHidden),
      "file_count": .integer(Int64(result.files.count)),
      "returned_count": .integer(Int64(result.files.count)),
      "scanned_count": .integer(Int64(result.scannedCount)),
      "result_truncated": .bool(result.resultTruncated),
      "scan_truncated": .bool(result.scanTruncated),
      "truncated": .bool(result.resultTruncated || result.scanTruncated),
      "files": .array(result.files.map(\.json)),
    ])
  }

  internal func skillsReadFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let relativePath = try requiredString("path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    let encoding = try optionalString("encoding", in: object) ?? "utf8"
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }
    guard encoding == "utf8" || encoding == "base64" || encoding == "auto" else {
      throw GatewayToolError.invalidArguments("encoding must be utf8, base64, or auto.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let file = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Unknown skill file: \(relativePath)")
    }
    guard !isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Skill path is a directory: \(relativePath)")
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    let content = try readSkillFileContent(file, maxBytes: maxBytes, encoding: encoding)
    return .object([
      "operation": .string("skills.read_file"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(relativePath),
      "absolute_path": .string(file.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "size_bytes": (attributes?[.size] as? NSNumber).map { .integer($0.int64Value) } ?? .null,
      "modified_at": (attributes?[.modificationDate] as? Date).map { .string(iso8601String($0)) }
        ?? .null,
      "encoding": .string(content.encoding),
      "content": content.content.map(JSONValue.string) ?? .null,
      "content_bytes_read": .integer(Int64(content.bytesRead)),
      "content_truncated": .bool(content.truncated),
      "valid_utf8": .bool(content.validUTF8),
    ])
  }

  internal func skillsReadFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let paths = try requiredStringArray("paths", in: object)
    let maxBytes =
      optionalInt("max_bytes_per_file", in: object) ?? configuration.skills.maxBytesPerSkill
    let encoding = try optionalString("encoding", in: object) ?? "utf8"
    try validateBoundedPositive(maxBytes, name: "max_bytes_per_file", upperBound: 20_971_520)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes_per_file must be less than or equal to skills.max_bytes_per_skill.")
    }
    guard !paths.isEmpty else {
      throw GatewayToolError.invalidArguments("paths must not be empty.")
    }
    guard paths.count <= 50 else {
      throw GatewayToolError.invalidArguments("paths must contain at most 50 values.")
    }
    guard encoding == "utf8" || encoding == "base64" || encoding == "auto" else {
      throw GatewayToolError.invalidArguments("encoding must be utf8, base64, or auto.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    var entries: [JSONValue] = []
    var totalBytesRead = 0
    var truncatedCount = 0
    for relativePath in paths {
      let file = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
      var isDirectory = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
        throw GatewayToolError.invalidArguments("Unknown skill file: \(relativePath)")
      }
      guard !isDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Skill path is a directory: \(relativePath)")
      }

      let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
      let content = try readSkillFileContent(file, maxBytes: maxBytes, encoding: encoding)
      totalBytesRead += content.bytesRead
      if content.truncated {
        truncatedCount += 1
      }
      entries.append(
        .object([
          "path": .string(relativePath),
          "absolute_path": .string(file.path),
          "size_bytes": (attributes?[.size] as? NSNumber).map { .integer($0.int64Value) } ?? .null,
          "modified_at": (attributes?[.modificationDate] as? Date).map {
            .string(iso8601String($0))
          } ?? .null,
          "encoding": .string(content.encoding),
          "content": content.content.map(JSONValue.string) ?? .null,
          "content_bytes_read": .integer(Int64(content.bytesRead)),
          "content_truncated": .bool(content.truncated),
          "valid_utf8": .bool(content.validUTF8),
        ]))
    }

    return .object([
      "operation": .string("skills.read_files"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "skill_directory_path": .string(skill.directoryURL.path),
      "encoding": .string(encoding),
      "max_bytes_per_file": .integer(Int64(maxBytes)),
      "requested_count": .integer(Int64(paths.count)),
      "file_count": .integer(Int64(entries.count)),
      "total_content_bytes_read": .integer(Int64(totalBytesRead)),
      "truncated_file_count": .integer(Int64(truncatedCount)),
      "files": .array(entries),
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "files_context": skillFilesContext(skill),
      "read_package_context": skillReadPackageContext(skill),
    ])
  }

  internal func skillsReadPackage(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let relativePath = requestedPath?.isEmpty == false ? requestedPath! : "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxFiles = optionalInt("max_files", in: object) ?? 100
    let maxBytesPerFile =
      optionalInt("max_bytes_per_file", in: object) ?? configuration.skills.maxBytesPerSkill
    let maxTotalBytes =
      optionalInt("max_total_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    let encoding = try optionalString("encoding", in: object) ?? "utf8"
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 32)
    try validateBoundedPositive(maxFiles, name: "max_files", upperBound: 10_000)
    try validateBoundedPositive(
      maxBytesPerFile,
      name: "max_bytes_per_file",
      upperBound: 20_971_520
    )
    try validateBoundedPositive(maxTotalBytes, name: "max_total_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)
    guard maxBytesPerFile <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes_per_file must be less than or equal to skills.max_bytes_per_skill.")
    }
    guard maxTotalBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_total_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }
    guard encoding == "utf8" || encoding == "base64" || encoding == "auto" else {
      throw GatewayToolError.invalidArguments("encoding must be utf8, base64, or auto.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let directory = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw GatewayToolError.invalidArguments("Skill path is not a directory: \(relativePath)")
    }

    let result = try listSkillFiles(
      skill: skill,
      directory: directory,
      includeHidden: includeHidden,
      maxDepth: maxDepth,
      maxResults: 10_000,
      maxScanEntries: maxScanEntries
    )

    var files: [JSONValue] = []
    var skipped: [JSONValue] = []
    var totalBytesRead = 0
    var truncatedFileCount = 0
    var totalBytesTruncated = false
    var fileCountTruncated = false

    for fileInfo in result.files.sorted(by: skillPackageReadOrder) {
      guard fileInfo.type == "file" else {
        skipped.append(skillPackageSkippedFile(fileInfo, reason: "not_file"))
        continue
      }
      guard fileInfo.isReadable else {
        skipped.append(skillPackageSkippedFile(fileInfo, reason: "unreadable"))
        continue
      }
      guard fileInfo.targetInsideSkill else {
        skipped.append(skillPackageSkippedFile(fileInfo, reason: "target_outside_skill"))
        continue
      }
      guard !fileInfo.isSymlink else {
        skipped.append(skillPackageSkippedFile(fileInfo, reason: "symlink"))
        continue
      }
      guard files.count < maxFiles else {
        fileCountTruncated = true
        skipped.append(skillPackageSkippedFile(fileInfo, reason: "max_files_reached"))
        continue
      }
      let remainingBytes = maxTotalBytes - totalBytesRead
      guard remainingBytes > 0 else {
        totalBytesTruncated = true
        skipped.append(skillPackageSkippedFile(fileInfo, reason: "max_total_bytes_reached"))
        continue
      }

      let readLimit = min(maxBytesPerFile, remainingBytes)
      let content = try readSkillPackageFileContent(
        URL(fileURLWithPath: fileInfo.absolutePath),
        maxBytes: readLimit,
        encoding: encoding
      )
      totalBytesRead += content.bytesRead
      if content.truncated {
        truncatedFileCount += 1
      }
      if totalBytesRead >= maxTotalBytes {
        totalBytesTruncated = true
      }

      files.append(
        .object([
          "path": .string(fileInfo.path),
          "absolute_path": .string(fileInfo.absolutePath),
          "size_bytes": fileInfo.sizeBytes.map { .integer(Int64($0)) } ?? .null,
          "modified_at": fileInfo.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
          "encoding": .string(content.encoding),
          "content": content.content.map(JSONValue.string) ?? .null,
          "content_bytes_read": .integer(Int64(content.bytesRead)),
          "content_truncated": .bool(content.truncated),
          "valid_utf8": .bool(content.validUTF8),
        ]))
    }

    return .object([
      "operation": .string("skills.read_package"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(relativePath),
      "skill_directory_path": .string(skill.directoryURL.path),
      "encoding": .string(encoding),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_files": .integer(Int64(maxFiles)),
      "max_bytes_per_file": .integer(Int64(maxBytesPerFile)),
      "max_total_bytes": .integer(Int64(maxTotalBytes)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_count": .integer(Int64(result.scannedCount)),
      "discovered_entry_count": .integer(Int64(result.files.count)),
      "file_count": .integer(Int64(files.count)),
      "skipped_count": .integer(Int64(skipped.count)),
      "total_content_bytes_read": .integer(Int64(totalBytesRead)),
      "truncated_file_count": .integer(Int64(truncatedFileCount)),
      "scan_truncated": .bool(result.scanTruncated),
      "result_truncated": .bool(result.resultTruncated),
      "file_count_truncated": .bool(fileCountTruncated),
      "total_bytes_truncated": .bool(totalBytesTruncated),
      "truncated": .bool(
        result.scanTruncated || result.resultTruncated || fileCountTruncated
          || totalBytesTruncated || truncatedFileCount > 0
      ),
      "files": .array(files),
      "skipped": .array(skipped),
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "files_context": skillFilesContext(skill, path: relativePath),
    ])
  }

  internal func skillsOutline(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let relativePath = requestedPath?.isEmpty == false ? requestedPath! : "SKILL.md"
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let includeImports = try optionalBool("include_imports", in: object) ?? false
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let file = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Unknown skill file: \(relativePath)")
    }
    guard !isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Skill path is a directory: \(relativePath)")
    }

    let handle = try FileHandle(forReadingFrom: file)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let fileTruncated = data.count > maxBytes
    let contentData = fileTruncated ? Data(data.prefix(maxBytes)) : data
    guard let content = String(data: contentData, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("Skill file is not valid UTF-8: \(relativePath)")
    }

    let language = outlineLanguage(for: file)
    let allItems = outlineItems(
      in: content,
      language: language,
      includeImports: includeImports
    )
    let returnedItems = Array(allItems.prefix(maxResults))
    let resultTruncated = allItems.count > returnedItems.count
    let isMarkdown = language == "markdown"

    return .object([
      "operation": .string("skills.outline"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(relativePath),
      "absolute_path": .string(file.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "language": language.map(JSONValue.string) ?? .null,
      "encoding": .string("utf-8"),
      "include_imports": .bool(includeImports),
      "max_bytes": .integer(Int64(maxBytes)),
      "max_results": .integer(Int64(maxResults)),
      "bytes_scanned": .integer(Int64(contentData.count)),
      "file_truncated": .bool(fileTruncated),
      "outline_count": .integer(Int64(allItems.count)),
      "returned_count": .integer(Int64(returnedItems.count)),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(fileTruncated || resultTruncated),
      "items": .array(returnedItems.map(\.json)),
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "files_context": skillFilesContext(skill),
      "read_file_context": skillReadFileContext(skill, path: relativePath),
      "section_context": isMarkdown ? skillSectionContext(skill, path: relativePath) : .null,
      "tables_context": isMarkdown ? skillTablesContext(skill, path: relativePath) : .null,
      "links_context": isMarkdown ? skillLinksContext(skill, path: relativePath) : .null,
      "link_check_context": isMarkdown ? skillLinkCheckContext(skill, path: relativePath) : .null,
    ])
  }

  internal func skillsSection(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let relativePath = requestedPath?.isEmpty == false ? requestedPath! : "SKILL.md"
    let heading = try requiredString("heading", in: object)
    let level = optionalInt("level", in: object)
    let occurrence = optionalInt("occurrence", in: object) ?? 1
    let includeHeading = try optionalBool("include_heading", in: object) ?? true
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    let maxSectionBytes =
      optionalInt("max_section_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(
      maxSectionBytes, name: "max_section_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(occurrence, name: "occurrence", upperBound: 10_000)
    if let level {
      try validateBoundedPositive(level, name: "level", upperBound: 6)
    }
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }
    guard maxSectionBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_section_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let file = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Unknown skill file: \(relativePath)")
    }
    guard !isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Skill path is a directory: \(relativePath)")
    }

    let content = try readSkillContent(file, maxBytes: maxBytes)
    guard content.validUTF8, let text = content.content else {
      throw GatewayToolError.invalidArguments(
        "Skill Markdown file is not valid UTF-8: \(relativePath)")
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var insideFence = false
    var matchCount = 0
    var selectedHeading: FileOutlineItem?
    var selectedStartIndex: Int?
    var selectedEndIndex: Int?
    var followingHeading: FileOutlineItem?

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if markdownFenceToggleLine(trimmed) {
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
        "operation": .string("skills.section"),
        "root_id": .string(skill.root.id),
        "name": .string(skill.name),
        "directory_name": .string(skill.directoryName),
        "path": .string(relativePath),
        "absolute_path": .string(file.path),
        "skill_directory_path": .string(skill.directoryURL.path),
        "encoding": .string("utf-8"),
        "heading": .string(heading),
        "level": level.map { .integer(Int64($0)) } ?? .null,
        "occurrence": .integer(Int64(occurrence)),
        "include_heading": .bool(includeHeading),
        "max_bytes": .integer(Int64(maxBytes)),
        "max_section_bytes": .integer(Int64(maxSectionBytes)),
        "bytes_scanned": .integer(Int64(content.bytesRead)),
        "file_truncated": .bool(content.truncated),
        "match_count": .integer(Int64(matchCount)),
        "matched": .bool(false),
        "failure": .object([
          "reason": .string("missing_heading")
        ]),
        "section": .null,
        "describe_context": skillDescribeContext(skill),
        "validate_context": skillValidateContext(skill),
        "files_context": skillFilesContext(skill),
        "frontmatter_context": skillFrontmatterContext(skill, path: relativePath),
        "outline_context": skillOutlineContext(skill, path: relativePath),
        "read_file_context": skillReadFileContext(skill, path: relativePath),
        "tables_context": skillTablesContext(skill, path: relativePath),
        "links_context": skillLinksContext(skill, path: relativePath),
        "link_check_context": skillLinkCheckContext(skill, path: relativePath),
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
    let sectionMayBeTruncated = content.truncated && selectedEndIndex == nil
    let startLine = selectedLines.isEmpty ? selectedHeading.line : contentStartIndex + 1
    let endLine =
      selectedLines.isEmpty ? selectedHeading.line : contentStartIndex + selectedLines.count

    return .object([
      "operation": .string("skills.section"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(relativePath),
      "absolute_path": .string(file.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "encoding": .string("utf-8"),
      "heading": .string(heading),
      "level": level.map { .integer(Int64($0)) } ?? .null,
      "occurrence": .integer(Int64(occurrence)),
      "include_heading": .bool(includeHeading),
      "max_bytes": .integer(Int64(maxBytes)),
      "max_section_bytes": .integer(Int64(maxSectionBytes)),
      "bytes_scanned": .integer(Int64(content.bytesRead)),
      "file_truncated": .bool(content.truncated),
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
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "files_context": skillFilesContext(skill),
      "frontmatter_context": skillFrontmatterContext(skill, path: relativePath),
      "outline_context": skillOutlineContext(skill, path: relativePath),
      "read_file_context": skillReadFileContext(skill, path: relativePath),
      "tables_context": skillTablesContext(skill, path: relativePath),
      "links_context": skillLinksContext(skill, path: relativePath),
      "link_check_context": skillLinkCheckContext(skill, path: relativePath),
    ])
  }

  internal func skillsTables(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let relativePath = requestedPath?.isEmpty == false ? requestedPath! : "SKILL.md"
    let includeCodeBlocks = try optionalBool("include_code_blocks", in: object) ?? false
    let maxTables = optionalInt("max_tables", in: object) ?? 20
    let maxRowsPerTable = optionalInt("max_rows_per_table", in: object) ?? 100
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    try validateBoundedPositive(maxTables, name: "max_tables", upperBound: 10_000)
    try validateBoundedPositive(maxRowsPerTable, name: "max_rows_per_table", upperBound: 100_000)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let file = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Unknown skill file: \(relativePath)")
    }
    guard !isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Skill path is a directory: \(relativePath)")
    }

    let content = try readSkillContent(file, maxBytes: maxBytes)
    guard content.validUTF8, let text = content.content else {
      throw GatewayToolError.invalidArguments(
        "Skill Markdown file is not valid UTF-8: \(relativePath)")
    }

    let tables = markdownTablesInContent(text, includeCodeBlocks: includeCodeBlocks)
    let returnedTables = Array(tables.prefix(maxTables))
    let tableResultTruncated = tables.count > returnedTables.count
    let rowTruncatedCount = returnedTables.filter { $0.rows.count > maxRowsPerTable }.count

    return .object([
      "operation": .string("skills.tables"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(relativePath),
      "absolute_path": .string(file.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "encoding": .string("utf-8"),
      "include_code_blocks": .bool(includeCodeBlocks),
      "max_tables": .integer(Int64(maxTables)),
      "max_rows_per_table": .integer(Int64(maxRowsPerTable)),
      "max_bytes": .integer(Int64(maxBytes)),
      "bytes_scanned": .integer(Int64(content.bytesRead)),
      "file_truncated": .bool(content.truncated),
      "table_count": .integer(Int64(tables.count)),
      "returned_count": .integer(Int64(returnedTables.count)),
      "row_truncated_table_count": .integer(Int64(rowTruncatedCount)),
      "result_truncated": .bool(tableResultTruncated),
      "truncated": .bool(tableResultTruncated || rowTruncatedCount > 0 || content.truncated),
      "tables": .array(returnedTables.map { $0.json(maxRowsPerTable: maxRowsPerTable) }),
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "files_context": skillFilesContext(skill),
      "frontmatter_context": skillFrontmatterContext(skill, path: relativePath),
      "outline_context": skillOutlineContext(skill, path: relativePath),
      "section_context": skillSectionContext(skill, path: relativePath),
      "read_file_context": skillReadFileContext(skill, path: relativePath),
      "links_context": skillLinksContext(skill, path: relativePath),
      "link_check_context": skillLinkCheckContext(skill, path: relativePath),
    ])
  }

  internal func skillsLinks(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let relativePath = requestedPath?.isEmpty == false ? requestedPath! : "SKILL.md"
    let includeImages = try optionalBool("include_images", in: object) ?? true
    let includeReferenceDefinitions =
      try optionalBool("include_reference_definitions", in: object) ?? true
    let includeAutolinks = try optionalBool("include_autolinks", in: object) ?? true
    let includeCodeBlocks = try optionalBool("include_code_blocks", in: object) ?? false
    let maxLinks = optionalInt("max_links", in: object) ?? 200
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    try validateBoundedPositive(maxLinks, name: "max_links", upperBound: 100_000)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let file = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Unknown skill file: \(relativePath)")
    }
    guard !isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Skill path is a directory: \(relativePath)")
    }

    let content = try readSkillContent(file, maxBytes: maxBytes)
    guard content.validUTF8, let text = content.content else {
      throw GatewayToolError.invalidArguments(
        "Skill Markdown file is not valid UTF-8: \(relativePath)")
    }

    let links = markdownLinksInContent(
      text,
      sourceURL: file,
      includeImages: includeImages,
      includeReferenceDefinitions: includeReferenceDefinitions,
      includeAutolinks: includeAutolinks,
      includeCodeBlocks: includeCodeBlocks
    )
    let definitions = markdownReferenceDefinitions(links)
    let returnedLinks = Array(links.prefix(maxLinks))
    let resultTruncated = links.count > returnedLinks.count
    let skillLinks = returnedLinks.map {
      skillMarkdownLinkInventoryJSON(
        link: $0,
        sourceURL: file,
        sourceRelativePath: relativePath,
        skill: skill,
        definitions: definitions
      )
    }
    let localCount = links.filter { link in
      guard let destination = skillMarkdownResolvedDestination(link: link, definitions: definitions)
      else {
        return false
      }
      let target = skillMarkdownLinkTarget(destination: destination, sourceURL: file, skill: skill)
      return target.kind == "fragment" || target.kind == "relative_path"
        || target.kind == "absolute_path"
    }.count
    let externalCount = links.filter { link in
      guard let destination = skillMarkdownResolvedDestination(link: link, definitions: definitions)
      else {
        return false
      }
      let target = skillMarkdownLinkTarget(destination: destination, sourceURL: file, skill: skill)
      return target.kind == "url" || target.kind == "email"
    }.count
    let imageCount = links.filter(\.isImage).count
    let referenceDefinitionCount = definitions.count

    return .object([
      "operation": .string("skills.links"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(relativePath),
      "absolute_path": .string(file.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "encoding": .string("utf-8"),
      "include_images": .bool(includeImages),
      "include_reference_definitions": .bool(includeReferenceDefinitions),
      "include_autolinks": .bool(includeAutolinks),
      "include_code_blocks": .bool(includeCodeBlocks),
      "max_links": .integer(Int64(maxLinks)),
      "max_bytes": .integer(Int64(maxBytes)),
      "bytes_scanned": .integer(Int64(content.bytesRead)),
      "file_truncated": .bool(content.truncated),
      "link_count": .integer(Int64(links.count)),
      "returned_count": .integer(Int64(returnedLinks.count)),
      "local_count": .integer(Int64(localCount)),
      "external_count": .integer(Int64(externalCount)),
      "image_count": .integer(Int64(imageCount)),
      "reference_definition_count": .integer(Int64(referenceDefinitionCount)),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(content.truncated || resultTruncated),
      "links": .array(skillLinks),
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "files_context": skillFilesContext(skill),
      "frontmatter_context": skillFrontmatterContext(skill, path: relativePath),
      "outline_context": skillOutlineContext(skill, path: relativePath),
      "section_context": skillSectionContext(skill, path: relativePath),
      "read_file_context": skillReadFileContext(skill, path: relativePath),
      "tables_context": skillTablesContext(skill, path: relativePath),
      "links_context": skillLinksContext(skill, path: relativePath),
      "link_check_context": skillLinkCheckContext(skill, path: relativePath),
    ])
  }

  private func skillMarkdownResolvedDestination(
    link: MarkdownLinkInfo,
    definitions: [String: MarkdownLinkInfo]
  ) -> String? {
    if let destination = link.destination {
      return destination
    }
    guard link.kind == "reference_link" || link.kind == "reference_image" else {
      return nil
    }
    let key = markdownReferenceKey(link.referenceLabel ?? link.label ?? "")
    return definitions[key]?.destination
  }

  private func skillMarkdownLinkInventoryJSON(
    link: MarkdownLinkInfo,
    sourceURL: URL,
    sourceRelativePath: String,
    skill: SkillInfo,
    definitions: [String: MarkdownLinkInfo]
  ) -> JSONValue {
    let key = markdownReferenceKey(link.referenceLabel ?? link.label ?? "")
    let definition = definitions[key]
    let resolvedDestination = skillMarkdownResolvedDestination(link: link, definitions: definitions)
    let resolvedViaReferenceDefinition =
      link.destination == nil
      && (link.kind == "reference_link" || link.kind == "reference_image")
      && resolvedDestination != nil
    let target = resolvedDestination.map {
      skillMarkdownLinkTarget(destination: $0, sourceURL: sourceURL, skill: skill)
    }
    let isLocal =
      target?.kind == "fragment" || target?.kind == "relative_path"
      || target?.kind == "absolute_path"
    let isExternal = target?.kind == "url" || target?.kind == "email"
    return .object([
      "line": .integer(Int64(link.line)),
      "kind": .string(link.kind),
      "label": link.label.map(JSONValue.string) ?? .null,
      "reference_label": link.referenceLabel.map(JSONValue.string) ?? .null,
      "destination": link.destination.map(JSONValue.string) ?? .null,
      "resolved_destination": resolvedDestination.map(JSONValue.string) ?? .null,
      "resolved_via_reference_definition": .bool(resolvedViaReferenceDefinition),
      "reference_definition_line": definition.map { .integer(Int64($0.line)) } ?? .null,
      "title": link.title.map(JSONValue.string) ?? .null,
      "raw": .string(link.raw),
      "is_image": .bool(link.isImage),
      "is_local": .bool(isLocal),
      "is_external": .bool(isExternal),
      "has_fragment": .bool(target?.fragment != nil),
      "target": target?.json ?? .null,
      "target_context": skillMarkdownLinkTargetContext(target, skill: skill),
      "source_link_check_context": skillLinkCheckContext(skill, path: sourceRelativePath),
    ])
  }

  private func skillMarkdownLinkTargetContext(
    _ target: SkillMarkdownLinkTargetInfo?,
    skill: SkillInfo
  ) -> JSONValue {
    guard let target, target.targetInsideSkill == true,
      let path = target.targetSkillRelativePath
    else {
      return .null
    }
    let targetURL = URL(fileURLWithPath: target.targetPath ?? "")
    let language = target.targetPath == nil ? nil : outlineLanguage(for: targetURL)
    let isMarkdown = language == "markdown"
    return .object([
      "read_context": skillReadFileContext(skill, path: path),
      "outline_context": language == nil ? .null : skillOutlineContext(skill, path: path),
      "section_context": isMarkdown ? skillSectionContext(skill, path: path) : .null,
      "tables_context": isMarkdown ? skillTablesContext(skill, path: path) : .null,
      "links_context": isMarkdown ? skillLinksContext(skill, path: path) : .null,
      "link_check_context": isMarkdown ? skillLinkCheckContext(skill, path: path) : .null,
    ])
  }

  internal func skillsLinkCheck(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let relativePath = requestedPath?.isEmpty == false ? requestedPath! : "SKILL.md"
    let includeImages = try optionalBool("include_images", in: object) ?? true
    let includeReferenceDefinitions =
      try optionalBool("include_reference_definitions", in: object) ?? true
    let includeAutolinks = try optionalBool("include_autolinks", in: object) ?? true
    let includeCodeBlocks = try optionalBool("include_code_blocks", in: object) ?? false
    let checkFragments = try optionalBool("check_fragments", in: object) ?? true
    let maxLinks = optionalInt("max_links", in: object) ?? 200
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    let maxTargetBytes =
      optionalInt("max_target_bytes", in: object) ?? configuration.skills.maxBytesPerSkill
    try validateBoundedPositive(maxLinks, name: "max_links", upperBound: 100_000)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxTargetBytes, name: "max_target_bytes", upperBound: 20_971_520)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }
    guard maxTargetBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_target_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let file = try resolveSkillFilePath(skill: skill, relativePath: relativePath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Unknown skill file: \(relativePath)")
    }
    guard !isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Skill path is a directory: \(relativePath)")
    }

    let handle = try FileHandle(forReadingFrom: file)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let fileTruncated = data.count > maxBytes
    let contentData = fileTruncated ? Data(data.prefix(maxBytes)) : data
    guard let content = String(data: contentData, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments(
        "Skill Markdown file is not valid UTF-8: \(relativePath)")
    }

    let links = markdownLinksInContent(
      content,
      sourceURL: file,
      includeImages: includeImages,
      includeReferenceDefinitions: true,
      includeAutolinks: includeAutolinks,
      includeCodeBlocks: includeCodeBlocks
    )
    let definitions = markdownReferenceDefinitions(links)
    let linksToCheck = links.filter {
      includeReferenceDefinitions || $0.kind != "reference_definition"
    }

    var checks: [SkillMarkdownLinkCheckResult] = []
    var okCount = 0
    var brokenCount = 0
    var uncheckedCount = 0
    var localCount = 0
    var externalCount = 0
    var fragmentCount = 0
    var targetTruncatedCount = 0

    for link in linksToCheck {
      let result = skillMarkdownLinkCheckResult(
        link: link,
        sourceURL: file,
        skill: skill,
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
      "operation": .string("skills.link_check"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(relativePath),
      "absolute_path": .string(file.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "encoding": .string("utf-8"),
      "include_images": .bool(includeImages),
      "include_reference_definitions": .bool(includeReferenceDefinitions),
      "include_autolinks": .bool(includeAutolinks),
      "include_code_blocks": .bool(includeCodeBlocks),
      "check_fragments": .bool(checkFragments),
      "max_links": .integer(Int64(maxLinks)),
      "max_bytes": .integer(Int64(maxBytes)),
      "max_target_bytes": .integer(Int64(maxTargetBytes)),
      "bytes_scanned": .integer(Int64(contentData.count)),
      "file_truncated": .bool(fileTruncated),
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
      "truncated": .bool(fileTruncated || resultTruncated || targetTruncatedCount > 0),
      "checks": .array(returnedChecks.map(\.json)),
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "files_context": skillFilesContext(skill),
      "read_context": skillReadContext(skill),
      "frontmatter_context": skillFrontmatterContext(skill, path: relativePath),
      "outline_context": skillOutlineContext(skill, path: relativePath),
      "section_context": skillSectionContext(skill, path: relativePath),
      "tables_context": skillTablesContext(skill, path: relativePath),
      "links_context": skillLinksContext(skill, path: relativePath),
    ])
  }

  private func skillMarkdownLinkCheckResult(
    link: MarkdownLinkInfo,
    sourceURL: URL,
    skill: SkillInfo,
    definitions: [String: MarkdownLinkInfo],
    checkFragments: Bool,
    maxTargetBytes: Int
  ) -> SkillMarkdownLinkCheckResult {
    var resolvedDestination = link.destination
    var resolvedViaReferenceDefinition = false
    var referenceDefinitionLine: Int?

    if resolvedDestination == nil, link.kind == "reference_link" || link.kind == "reference_image" {
      let key = markdownReferenceKey(link.referenceLabel ?? link.label ?? "")
      if let definition = definitions[key] {
        resolvedDestination = definition.destination
        resolvedViaReferenceDefinition = true
        referenceDefinitionLine = definition.line
      } else {
        return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
        link: link,
        resolvedDestination: resolvedDestination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "empty_destination",
        category: "broken",
        issue: "Link destination is empty.",
        target: nil
      )
    }

    let target = skillMarkdownLinkTarget(
      destination: destination, sourceURL: sourceURL, skill: skill)
    switch target.kind {
    case "url", "email":
      return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
        link: link,
        resolvedDestination: destination,
        resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
        referenceDefinitionLine: referenceDefinitionLine,
        status: "empty_destination",
        category: "broken",
        issue: "Link destination is empty.",
        target: target
      )

    case "fragment", "relative_path", "absolute_path":
      guard target.targetInsideSkill == true, let targetPath = target.targetPath else {
        return SkillMarkdownLinkCheckResult(
          link: link,
          resolvedDestination: destination,
          resolvedViaReferenceDefinition: resolvedViaReferenceDefinition,
          referenceDefinitionLine: referenceDefinitionLine,
          status: "outside_skill",
          category: "broken",
          issue: "Local link target is outside the selected skill directory.",
          target: target,
          isLocal: true
        )
      }
      return skillMarkdownLocalLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
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

  private func skillMarkdownLocalLinkCheckResult(
    link: MarkdownLinkInfo,
    resolvedDestination: String,
    resolvedViaReferenceDefinition: Bool,
    referenceDefinitionLine: Int?,
    target: SkillMarkdownLinkTargetInfo,
    targetURL: URL,
    fragment: String?,
    checkFragments: Bool,
    maxTargetBytes: Int
  ) -> SkillMarkdownLinkCheckResult {
    var isDirectory = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
    guard exists else {
      return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
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
      return SkillMarkdownLinkCheckResult(
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

    return SkillMarkdownLinkCheckResult(
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

  private func skillMarkdownLinkTarget(
    destination: String,
    sourceURL: URL,
    skill: SkillInfo
  ) -> SkillMarkdownLinkTargetInfo {
    let normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      return SkillMarkdownLinkTargetInfo(kind: "empty")
    }
    if normalized.hasPrefix("#") {
      return SkillMarkdownLinkTargetInfo(
        kind: "fragment",
        fragment: String(normalized.dropFirst()),
        targetPath: sourceURL.standardizedFileURL.path,
        targetSkillRelativePath: skillRelativePath(sourceURL, in: skill),
        targetInsideSkill: true
      )
    }
    if let scheme = markdownDestinationScheme(normalized) {
      return SkillMarkdownLinkTargetInfo(kind: scheme == "mailto" ? "email" : "url", scheme: scheme)
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
    let contained = isSkillContained(targetURL, in: skill)
    return SkillMarkdownLinkTargetInfo(
      kind: kind,
      fragment: split.fragment,
      targetPath: targetURL.path,
      targetSkillRelativePath: contained ? skillRelativePath(targetURL, in: skill) : nil,
      targetInsideSkill: contained
    )
  }

  private func isSkillContained(_ url: URL, in skill: SkillInfo) -> Bool {
    let base = skill.directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
    let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path
    return path(candidatePath, isInside: base)
  }

  internal func skillsSearch(arguments object: [String: JSONValue]) throws -> JSONValue {
    let query = try requiredString("query", in: object)
    let rootID = try optionalString("root_id", in: object)
    let caseSensitive = try optionalBool("case_sensitive", in: object) ?? false
    let searchContent = try optionalBool("search_content", in: object) ?? false
    let maxResults = optionalInt("max_results", in: object) ?? 100
    let maxBytes =
      optionalInt("max_bytes_per_skill", in: object) ?? configuration.skills.maxBytesPerSkill
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxBytes, name: "max_bytes_per_skill", upperBound: 20_971_520)
    guard maxBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_bytes_per_skill must be less than or equal to skills.max_bytes_per_skill.")
    }

    let inventory = try scanSkills(rootID: rootID, maxResults: 10_000)
    var matches: [SkillSearchResult] = []
    var resultTruncated = false
    for skill in inventory.skills {
      let metadataMatches = skillMatchedFields(
        skill,
        query: query,
        caseSensitive: caseSensitive
      )
      var contentMatches: [SkillContentLineMatch] = []
      var contentTruncated = false
      var validUTF8 = true
      if searchContent {
        let content = try readSkillContent(skill.fileURL, maxBytes: maxBytes)
        contentTruncated = content.truncated
        validUTF8 = content.validUTF8
        if let text = content.content {
          contentMatches = skillContentLineMatches(
            text,
            query: query,
            caseSensitive: caseSensitive,
            maxMatches: 5
          )
        }
      }
      guard !metadataMatches.isEmpty || !contentMatches.isEmpty else {
        continue
      }
      guard matches.count < maxResults else {
        resultTruncated = true
        break
      }
      matches.append(
        SkillSearchResult(
          skill: skill,
          matchedFields: metadataMatches,
          contentMatches: contentMatches,
          contentSearched: searchContent,
          contentTruncated: contentTruncated,
          validUTF8: validUTF8
        ))
    }

    return .object([
      "operation": .string("skills.search"),
      "query": .string(query),
      "root_id": rootID.map(JSONValue.string) ?? .null,
      "case_sensitive": .bool(caseSensitive),
      "search_content": .bool(searchContent),
      "skill_count": .integer(Int64(inventory.skills.count)),
      "match_count": .integer(Int64(matches.count)),
      "max_results": .integer(Int64(maxResults)),
      "scan_truncated": .bool(inventory.scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(inventory.scanTruncated || resultTruncated),
      "matches": .array(matches.map(\.json)),
    ])
  }

  internal func skillsSearchFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let name = try requiredString("name", in: object)
    let rootID = try optionalString("root_id", in: object)
    let query = try requiredString("query", in: object)
    let caseSensitive = try optionalBool("case_sensitive", in: object) ?? false
    let searchContent = try optionalBool("search_content", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxResults = optionalInt("max_results", in: object) ?? 100
    let maxMatchesPerFile = optionalInt("max_matches_per_file", in: object) ?? 5
    let maxFileBytes = optionalInt("max_file_bytes", in: object) ?? 65_536
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateBoundedPositive(maxDepth, name: "max_depth", upperBound: 32)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxMatchesPerFile, name: "max_matches_per_file", upperBound: 100)
    try validateBoundedPositive(maxFileBytes, name: "max_file_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)
    guard maxFileBytes <= configuration.skills.maxBytesPerSkill else {
      throw GatewayToolError.invalidArguments(
        "max_file_bytes must be less than or equal to skills.max_bytes_per_skill.")
    }

    let skill = try resolveSkill(name: name, rootID: rootID)
    let result = try listSkillFiles(
      skill: skill,
      directory: skill.directoryURL,
      includeHidden: true,
      maxDepth: maxDepth,
      maxResults: 10_000,
      maxScanEntries: maxScanEntries
    )
    var matches: [SkillFileSearchResult] = []
    var resultTruncated = false

    for file in result.files {
      var matchedFields: [String] = []
      if string(file.path, contains: query, caseSensitive: caseSensitive) {
        matchedFields.append("path")
      }
      if string(file.type, contains: query, caseSensitive: caseSensitive) {
        matchedFields.append("type")
      }

      var contentMatches: [SkillContentLineMatch] = []
      var contentSearched = false
      var contentTruncated = false
      var validUTF8: Bool? = nil
      if searchContent, file.type == "file", file.isReadable, file.targetInsideSkill {
        contentSearched = true
        let content = try readSkillFileContent(
          URL(fileURLWithPath: file.absolutePath),
          maxBytes: maxFileBytes,
          encoding: "utf8"
        )
        contentTruncated = content.truncated
        validUTF8 = content.validUTF8
        if let text = content.content {
          contentMatches = skillContentLineMatches(
            text,
            query: query,
            caseSensitive: caseSensitive,
            maxMatches: maxMatchesPerFile
          )
        }
      }

      guard !matchedFields.isEmpty || !contentMatches.isEmpty else {
        continue
      }
      guard matches.count < maxResults else {
        resultTruncated = true
        break
      }
      matches.append(
        SkillFileSearchResult(
          file: file,
          matchedFields: matchedFields,
          contentSearched: contentSearched,
          contentMatches: contentMatches,
          contentTruncated: contentTruncated,
          validUTF8: validUTF8
        ))
    }

    return .object([
      "operation": .string("skills.search_files"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "query": .string(query),
      "case_sensitive": .bool(caseSensitive),
      "search_content": .bool(searchContent),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_matches_per_file": .integer(Int64(maxMatchesPerFile)),
      "max_file_bytes": .integer(Int64(maxFileBytes)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_count": .integer(Int64(result.scannedCount)),
      "match_count": .integer(Int64(matches.count)),
      "scan_truncated": .bool(result.scanTruncated),
      "result_truncated": .bool(resultTruncated || result.resultTruncated),
      "truncated": .bool(result.scanTruncated || resultTruncated || result.resultTruncated),
      "matches": .array(matches.map(\.json)),
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "files_context": skillFilesContext(skill),
    ])
  }

  private func scanSkills(rootID: String?, maxResults: Int) throws -> SkillInventory {
    let roots = try selectedSkillRoots(rootID: rootID)
    var statuses: [SkillRootStatus] = []
    var skills: [SkillInfo] = []
    var resultTruncated = false

    for root in roots {
      let status = skillRootStatus(root)
      statuses.append(status)
      guard status.exists, status.isDirectory, status.isReadable else {
        continue
      }
      skills.append(contentsOf: try skillInfos(in: root))
    }

    skills.sort { lhs, rhs in
      if lhs.name != rhs.name {
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
      return lhs.root.id.localizedStandardCompare(rhs.root.id) == .orderedAscending
    }
    if skills.count > maxResults {
      skills = Array(skills.prefix(maxResults))
      resultTruncated = true
    }

    return SkillInventory(
      rootStatuses: statuses,
      skills: skills,
      scanTruncated: false,
      resultTruncated: resultTruncated
    )
  }

  private func selectedSkillRoots(rootID: String?) throws -> [SkillRootConfig] {
    if let rootID {
      guard let root = configuration.skills.roots.first(where: { $0.id == rootID }) else {
        throw GatewayToolError.invalidArguments("Unknown skill root id: \(rootID)")
      }
      return [root]
    }
    return configuration.skills.roots
  }

  private func resolveSkill(name: String, rootID: String?) throws -> SkillInfo {
    let inventory = try scanSkills(rootID: rootID, maxResults: 10_000)
    let matches = inventory.skills.filter { $0.name == name || $0.directoryName == name }
    guard !matches.isEmpty else {
      throw GatewayToolError.invalidArguments("Unknown skill: \(name)")
    }
    guard matches.count == 1 else {
      let matchingRoots = matches.map(\.root.id).joined(separator: ", ")
      throw GatewayToolError.invalidArguments(
        "Skill name is ambiguous; pass root_id. Matching roots: \(matchingRoots)"
      )
    }
    return matches[0]
  }

  private func skillRootStatus(_ root: SkillRootConfig) -> SkillRootStatus {
    let url = URL(fileURLWithPath: root.path).standardizedFileURL
    var isDirectory = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return SkillRootStatus(
      root: root,
      exists: exists,
      isDirectory: exists && isDirectory.boolValue,
      isReadable: exists && FileManager.default.isReadableFile(atPath: url.path)
    )
  }

  private func skillInfos(in root: SkillRootConfig) throws -> [SkillInfo] {
    let rootURL = URL(fileURLWithPath: root.path).standardizedFileURL
    let canonicalRoot = rootURL.resolvingSymlinksInPath()
    var skills: [SkillInfo] = []

    if let rootSkill = try skillInfo(
      root: root,
      directoryURL: rootURL,
      canonicalRoot: canonicalRoot
    ) {
      skills.append(rootSkill)
    }

    let children = try FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for child in children.sorted(by: { lhs, rhs in
      lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }) {
      guard child.lastPathComponent != "SKILL.md" else {
        continue
      }
      let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
      guard values?.isDirectory == true else {
        continue
      }
      if let info = try skillInfo(root: root, directoryURL: child, canonicalRoot: canonicalRoot) {
        skills.append(info)
      }
    }
    return skills
  }

  private func skillInfo(
    root: SkillRootConfig,
    directoryURL: URL,
    canonicalRoot: URL
  ) throws -> SkillInfo? {
    let fileURL = directoryURL.appendingPathComponent("SKILL.md")
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return nil
    }

    let canonicalSkill = fileURL.standardizedFileURL.resolvingSymlinksInPath()
    guard path(canonicalSkill.path, isInside: canonicalRoot.path) else {
      return nil
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    let content = try? readSkillContent(fileURL, maxBytes: 65_536)
    let frontmatter = skillFrontmatterStatus(content?.content)
    let directoryName = directoryURL.lastPathComponent
    return SkillInfo(
      root: root,
      name: frontmatter.name ?? directoryName,
      directoryName: directoryName,
      description: frontmatter.description,
      directoryURL: directoryURL.standardizedFileURL,
      fileURL: fileURL.standardizedFileURL,
      sizeBytes: (attributes?[.size] as? NSNumber)?.int64Value,
      modifiedAt: attributes?[.modificationDate] as? Date
    )
  }

  internal func path(_ child: String, isInside parent: String) -> Bool {
    child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : "\(parent)/")
  }

  private func readSkillContent(_ url: URL, maxBytes: Int) throws -> SkillContent {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let truncated = data.count > maxBytes
    let bounded = truncated ? data.prefix(maxBytes) : data[...]
    let content = String(data: Data(bounded), encoding: .utf8)
    return SkillContent(
      content: content,
      bytesRead: bounded.count,
      truncated: truncated,
      validUTF8: content != nil
    )
  }

  private func readSkillFileContent(_ url: URL, maxBytes: Int, encoding: String) throws
    -> SkillFileContent
  {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let truncated = data.count > maxBytes
    let bounded = truncated ? Data(data.prefix(maxBytes)) : data
    let utf8Content = String(data: bounded, encoding: .utf8)
    let outputEncoding: String
    let content: String?
    if encoding == "auto" {
      if let utf8Content {
        outputEncoding = "utf8"
        content = utf8Content
      } else {
        outputEncoding = "base64"
        content = bounded.base64EncodedString()
      }
    } else if encoding == "base64" {
      outputEncoding = "base64"
      content = bounded.base64EncodedString()
    } else {
      outputEncoding = "utf8"
      content = utf8Content
    }
    return SkillFileContent(
      content: content,
      bytesRead: bounded.count,
      truncated: truncated,
      validUTF8: utf8Content != nil,
      encoding: outputEncoding
    )
  }

  private func readSkillPackageFileContent(_ url: URL, maxBytes: Int, encoding: String) throws
    -> SkillPackageFileContent
  {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let truncated = data.count > maxBytes
    let bounded = truncated ? Data(data.prefix(maxBytes)) : data
    let utf8Content = String(data: bounded, encoding: .utf8)
    let outputEncoding: String
    let content: String?
    switch encoding {
    case "auto":
      if let utf8Content {
        outputEncoding = "utf8"
        content = utf8Content
      } else {
        outputEncoding = "base64"
        content = bounded.base64EncodedString()
      }
    case "base64":
      outputEncoding = "base64"
      content = bounded.base64EncodedString()
    default:
      outputEncoding = "utf8"
      content = utf8Content
    }
    return SkillPackageFileContent(
      content: content,
      bytesRead: bounded.count,
      truncated: truncated,
      validUTF8: utf8Content != nil,
      encoding: outputEncoding
    )
  }

  private func resolveSkillFilePath(skill: SkillInfo, relativePath: String) throws -> URL {
    try validateSkillRelativePath(relativePath)
    let candidate =
      relativePath == "."
      ? skill.directoryURL.standardizedFileURL
      : skill.directoryURL.appendingPathComponent(relativePath).standardizedFileURL
    let canonicalSkill = skill.directoryURL.standardizedFileURL.resolvingSymlinksInPath()
    let canonicalCandidate = candidate.resolvingSymlinksInPath()
    guard path(canonicalCandidate.path, isInside: canonicalSkill.path) else {
      throw GatewayToolError.invalidArguments("Skill path escapes skill directory: \(relativePath)")
    }
    return candidate
  }

  private func validateSkillRelativePath(_ relativePath: String) throws {
    guard !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GatewayToolError.invalidArguments("path must not be empty.")
    }
    guard !relativePath.hasPrefix("/") else {
      throw GatewayToolError.invalidArguments("path must be relative to the skill directory.")
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    for component in components where component != "." {
      guard !component.isEmpty else {
        throw GatewayToolError.invalidArguments("path must not contain empty components.")
      }
      guard component != ".." else {
        throw GatewayToolError.invalidArguments("path must not escape skill directory.")
      }
    }
  }

  private func listSkillFiles(
    skill: SkillInfo,
    directory: URL,
    includeHidden: Bool,
    maxDepth: Int,
    maxResults: Int,
    maxScanEntries: Int
  ) throws -> SkillFileListResult {
    var files: [SkillFileInfo] = []
    var scannedCount = 0
    var scanTruncated = false
    var resultTruncated = false
    let canonicalSkill = skill.directoryURL.standardizedFileURL.resolvingSymlinksInPath()

    func walk(_ current: URL, depth: Int) throws {
      guard !scanTruncated else {
        return
      }
      let entries = try FileManager.default.contentsOfDirectory(
        at: current,
        includingPropertiesForKeys: [
          .isDirectoryKey,
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey,
          .contentModificationDateKey,
          .isReadableKey,
        ],
        options: []
      )
      for entry in entries.sorted(by: { lhs, rhs in
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
      }) {
        guard includeHidden || !entry.lastPathComponent.hasPrefix(".") else {
          continue
        }
        guard scannedCount < maxScanEntries else {
          scanTruncated = true
          return
        }
        scannedCount += 1
        guard
          let info = try skillFileInfo(
            skill: skill,
            fileURL: entry,
            canonicalSkill: canonicalSkill
          )
        else {
          continue
        }
        if files.count < maxResults {
          files.append(info)
        } else {
          resultTruncated = true
        }
        if info.type == "directory", depth < maxDepth {
          try walk(entry, depth: depth + 1)
        }
      }
    }

    try walk(directory, depth: 1)
    return SkillFileListResult(
      files: files,
      scannedCount: scannedCount,
      scanTruncated: scanTruncated,
      resultTruncated: resultTruncated
    )
  }

  private func skillFileInfo(
    skill: SkillInfo,
    fileURL: URL,
    canonicalSkill: URL
  ) throws -> SkillFileInfo? {
    let values = try fileURL.resourceValues(
      forKeys: [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
      ])
    let isSymlink = values.isSymbolicLink == true
    let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
    let targetInsideSkill = path(canonicalFile.path, isInside: canonicalSkill.path)
    guard targetInsideSkill || isSymlink else {
      return nil
    }
    let type: String
    if isSymlink {
      type = "symlink"
    } else if values.isDirectory == true {
      type = "directory"
    } else if values.isRegularFile == true {
      type = "file"
    } else {
      type = "other"
    }
    let relativePath = skillRelativePath(fileURL, in: skill)
    let detectedOutlineLanguage = outlineLanguage(for: fileURL)
    return SkillFileInfo(
      skill: skill,
      path: relativePath,
      absolutePath: fileURL.standardizedFileURL.path,
      type: type,
      sizeBytes: values.fileSize.map(Int64.init),
      modifiedAt: values.contentModificationDate,
      isReadable: values.isReadable == true,
      isSymlink: isSymlink,
      targetInsideSkill: targetInsideSkill,
      isMarkdown: detectedOutlineLanguage == "markdown",
      outlineLanguage: detectedOutlineLanguage
    )
  }

  private func skillRelativePath(_ url: URL, in skill: SkillInfo) -> String {
    let root = skill.directoryURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == root {
      return "."
    }
    return String(path.dropFirst(root.count + 1))
  }

  private func skillEntrypointJSON(_ skill: SkillInfo) -> JSONValue {
    .object([
      "path": .string("SKILL.md"),
      "absolute_path": .string(skill.fileURL.path),
      "size_bytes": skill.sizeBytes.map { .integer(Int64($0)) } ?? .null,
      "modified_at": skill.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "read_context": skillReadContext(skill),
    ])
  }

  private func skillReadContext(_ skill: SkillInfo) -> JSONValue {
    .object([
      "tool": .string("skills.read"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
      ]),
    ])
  }

  private func skillDescribeContext(_ skill: SkillInfo) -> JSONValue {
    .object([
      "tool": .string("skills.describe"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
      ]),
    ])
  }

  private func skillValidateContext(_ skill: SkillInfo) -> JSONValue {
    .object([
      "tool": .string("skills.validate"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
      ]),
    ])
  }

  private func skillFrontmatterContext(_ skill: SkillInfo, path: String = "SKILL.md") -> JSONValue {
    .object([
      "tool": .string("skills.frontmatter"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
        "path": .string(path),
      ]),
    ])
  }

  private func skillFilesContext(_ skill: SkillInfo, path: String? = nil) -> JSONValue {
    var arguments: [String: JSONValue] = [
      "name": .string(skill.name),
      "root_id": .string(skill.root.id),
    ]
    if let path {
      arguments["path"] = .string(path)
    }
    return .object([
      "tool": .string("skills.files"),
      "arguments": .object(arguments),
    ])
  }

  private func skillReadPackageContext(_ skill: SkillInfo, path: String? = nil) -> JSONValue {
    var arguments: [String: JSONValue] = [
      "name": .string(skill.name),
      "root_id": .string(skill.root.id),
    ]
    if let path {
      arguments["path"] = .string(path)
    }
    return .object([
      "tool": .string("skills.read_package"),
      "arguments": .object(arguments),
    ])
  }

  private func skillReadFileContext(_ skill: SkillInfo, path: String) -> JSONValue {
    .object([
      "tool": .string("skills.read_file"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
        "path": .string(path),
      ]),
    ])
  }

  private func skillOutlineContext(_ skill: SkillInfo, path: String) -> JSONValue {
    .object([
      "tool": .string("skills.outline"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
        "path": .string(path),
      ]),
    ])
  }

  private func skillSectionContext(_ skill: SkillInfo, path: String) -> JSONValue {
    .object([
      "tool": .string("skills.section"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
        "path": .string(path),
      ]),
      "required_arguments": .array([.string("heading")]),
    ])
  }

  private func skillTablesContext(_ skill: SkillInfo, path: String) -> JSONValue {
    .object([
      "tool": .string("skills.tables"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
        "path": .string(path),
      ]),
    ])
  }

  private func skillLinksContext(_ skill: SkillInfo, path: String) -> JSONValue {
    .object([
      "tool": .string("skills.links"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
        "path": .string(path),
      ]),
    ])
  }

  private func skillLinkCheckContext(_ skill: SkillInfo, path: String) -> JSONValue {
    .object([
      "tool": .string("skills.link_check"),
      "arguments": .object([
        "name": .string(skill.name),
        "root_id": .string(skill.root.id),
        "path": .string(path),
      ]),
    ])
  }

  private func skillFrontmatterPayload(
    skill: SkillInfo,
    path: String,
    absolutePath: String,
    requestedFormat: String,
    format: String?,
    maxBytes: Int,
    maxDepth: Int,
    bytesScanned: Int,
    fileTruncated: Bool,
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
      "operation": .string("skills.frontmatter"),
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "path": .string(path),
      "absolute_path": .string(absolutePath),
      "skill_directory_path": .string(skill.directoryURL.path),
      "encoding": .string("utf-8"),
      "requested_format": .string(requestedFormat),
      "format": format.map(JSONValue.string) ?? .null,
      "max_bytes": .integer(Int64(maxBytes)),
      "max_depth": .integer(Int64(maxDepth)),
      "bytes_scanned": .integer(Int64(bytesScanned)),
      "file_truncated": .bool(fileTruncated),
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
      "describe_context": skillDescribeContext(skill),
      "validate_context": skillValidateContext(skill),
      "read_file_context": skillReadFileContext(skill, path: path),
      "outline_context": skillOutlineContext(skill, path: path),
      "section_context": skillSectionContext(skill, path: path),
      "tables_context": skillTablesContext(skill, path: path),
      "links_context": skillLinksContext(skill, path: path),
      "link_check_context": skillLinkCheckContext(skill, path: path),
    ])
  }

  private func skillPackageSkippedFile(_ file: SkillFileInfo, reason: String) -> JSONValue {
    .object([
      "path": .string(file.path),
      "absolute_path": .string(file.absolutePath),
      "type": .string(file.type),
      "size_bytes": file.sizeBytes.map { .integer(Int64($0)) } ?? .null,
      "is_readable": .bool(file.isReadable),
      "is_symlink": .bool(file.isSymlink),
      "target_inside_skill": .bool(file.targetInsideSkill),
      "reason": .string(reason),
    ])
  }

  private func skillResourceSummaries(skill: SkillInfo, files: [SkillFileInfo])
    -> [SkillResourceSummary]
  {
    let knownKinds = ["agents", "references", "scripts", "assets"]
    var summaries = Dictionary(
      uniqueKeysWithValues: knownKinds.map {
        ($0, SkillResourceSummary(kind: $0, path: $0, skill: skill))
      })
    var other = SkillResourceSummary(kind: "other", path: nil, skill: skill)

    for file in files where file.path != "SKILL.md" {
      let kind = skillResourceKind(for: file.path)
      if knownKinds.contains(kind) {
        summaries[kind]?.add(file)
      } else {
        other.add(file)
      }
    }

    var ordered = knownKinds.compactMap { summaries[$0] }
    if other.exists || other.fileCount > 0 || other.directoryCount > 0 || other.symlinkCount > 0
      || other.otherCount > 0
    {
      ordered.append(other)
    }
    return ordered
  }

  private func skillResourceKind(for path: String) -> String {
    let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first
    switch first {
    case "agents":
      return "agents"
    case "references":
      return "references"
    case "scripts":
      return "scripts"
    case "assets":
      return "assets"
    default:
      return "other"
    }
  }

  private func skillPackageReadOrder(_ lhs: SkillFileInfo, _ rhs: SkillFileInfo) -> Bool {
    let lhsPriority = skillPackageReadPriority(lhs.path)
    let rhsPriority = skillPackageReadPriority(rhs.path)
    if lhsPriority != rhsPriority {
      return lhsPriority < rhsPriority
    }
    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
  }

  private func skillPackageReadPriority(_ path: String) -> Int {
    if path == "SKILL.md" {
      return 0
    }
    if path == "agents/openai.yaml" {
      return 1
    }
    if path.hasPrefix("references/") {
      return 2
    }
    if path.hasPrefix("agents/") {
      return 3
    }
    if path.hasPrefix("scripts/") {
      return 4
    }
    if path.hasPrefix("assets/") {
      return 5
    }
    return 6
  }

  private func skillFrontmatterStatus(_ content: String?) -> SkillFrontmatterStatus {
    guard let content else {
      return SkillFrontmatterStatus(
        hasOpening: false,
        closed: false,
        name: nil,
        description: nil,
        lineCount: nil
      )
    }
    let block = skillFrontmatterBlock(content)
    let decoded = block.raw.map(decodeSkillFrontmatterYAML)

    return SkillFrontmatterStatus(
      hasOpening: block.hasOpening,
      closed: block.closed,
      name: decoded?.metadata.name,
      description: decoded?.metadata.description,
      lineCount: block.lineCount,
      parseError: decoded?.parseError
    )
  }

  private func isCanonicalSkillName(_ name: String) -> Bool {
    guard !name.isEmpty else {
      return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
      let value = scalar.value
      return (value >= 48 && value <= 57)
        || (value >= 97 && value <= 122)
        || value == 45
    }
  }

  private func skillFrontmatterBlock(_ text: String) -> (
    hasOpening: Bool, closed: Bool, raw: String?, lineCount: Int
  ) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return (false, false, nil, lines.count)
    }
    guard
      let closingOffset = lines.dropFirst().enumerated().first(where: { _, line in
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
      })?.offset
    else {
      return (true, false, nil, lines.count)
    }
    let closingLineIndex = closingOffset + 1
    let rawLines = closingLineIndex > 1 ? Array(lines[1..<closingLineIndex]) : []
    return (true, true, rawLines.joined(separator: "\n"), lines.count)
  }

  private func decodeSkillFrontmatterYAML(_ raw: String) -> DecodedSkillFrontmatter {
    do {
      let document = try parseStructuredValue(
        data: Data(raw.utf8),
        format: "yaml",
        path: "SKILL.md",
        maxBytes: max(raw.utf8.count, 1),
        maxDocuments: 1,
        maxDepth: 128
      )
      guard let object = document.value.objectValue else {
        return DecodedSkillFrontmatter(
          metadata: SkillFrontmatter(),
          document: nil,
          parseError: "YAML frontmatter root must be an object."
        )
      }
      return DecodedSkillFrontmatter(
        metadata: SkillFrontmatter(
          name: object["name"]?.stringValue,
          description: object["description"]?.stringValue
        ),
        document: document,
        parseError: nil
      )
    } catch {
      return DecodedSkillFrontmatter(
        metadata: SkillFrontmatter(),
        document: nil,
        parseError: error.localizedDescription
      )
    }
  }

  private func skillMatchedFields(
    _ skill: SkillInfo,
    query: String,
    caseSensitive: Bool
  ) -> [String] {
    let fields: [(String, String)] = [
      ("name", skill.name),
      ("directory_name", skill.directoryName),
      ("description", skill.description ?? ""),
      ("root_id", skill.root.id),
      ("path", skill.fileURL.path),
    ]
    return fields.compactMap { field, value in
      string(value, contains: query, caseSensitive: caseSensitive) ? field : nil
    }
  }

  private func skillContentLineMatches(
    _ content: String,
    query: String,
    caseSensitive: Bool,
    maxMatches: Int
  ) -> [SkillContentLineMatch] {
    var matches: [SkillContentLineMatch] = []
    for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .enumerated()
    where string(line, contains: query, caseSensitive: caseSensitive) {
      matches.append(
        SkillContentLineMatch(line: index + 1, text: String(line.prefix(240)))
      )
      if matches.count >= maxMatches {
        break
      }
    }
    return matches
  }

  internal func string(_ value: String, contains query: String, caseSensitive: Bool) -> Bool {
    if caseSensitive {
      return value.contains(query)
    }
    return value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}

private struct SkillMarkdownLinkCheckResult {
  var link: MarkdownLinkInfo
  var resolvedDestination: String?
  var resolvedViaReferenceDefinition: Bool
  var referenceDefinitionLine: Int?
  var status: String
  var category: String
  var issue: String?
  var target: SkillMarkdownLinkTargetInfo?
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

private struct SkillMarkdownLinkTargetInfo {
  var kind: String
  var scheme: String? = nil
  var fragment: String? = nil
  var targetPath: String? = nil
  var targetSkillRelativePath: String? = nil
  var targetInsideSkill: Bool? = nil

  var json: JSONValue {
    .object([
      "kind": .string(kind),
      "scheme": scheme.map(JSONValue.string) ?? .null,
      "fragment": fragment.map(JSONValue.string) ?? .null,
      "target_path": targetPath.map(JSONValue.string) ?? .null,
      "target_skill_relative_path": targetSkillRelativePath.map(JSONValue.string) ?? .null,
      "target_inside_skill": targetInsideSkill.map(JSONValue.bool) ?? .null,
    ])
  }
}

private struct SkillRootStatus {
  var root: SkillRootConfig
  var exists: Bool
  var isDirectory: Bool
  var isReadable: Bool

  var json: JSONValue {
    .object([
      "id": .string(root.id),
      "path": .string(root.path),
      "description": root.description.map(JSONValue.string) ?? .null,
      "exists": .bool(exists),
      "is_directory": .bool(isDirectory),
      "is_readable": .bool(isReadable),
    ])
  }
}

private struct SkillInventory {
  var rootStatuses: [SkillRootStatus]
  var skills: [SkillInfo]
  var scanTruncated: Bool
  var resultTruncated: Bool
}

private struct SkillInfo {
  var root: SkillRootConfig
  var name: String
  var directoryName: String
  var description: String?
  var directoryURL: URL
  var fileURL: URL
  var sizeBytes: Int64?
  var modifiedAt: Date?

  var json: JSONValue {
    .object([
      "root_id": .string(root.id),
      "name": .string(name),
      "directory_name": .string(directoryName),
      "description": description.map(JSONValue.string) ?? .null,
      "path": .string(fileURL.path),
      "skill_directory_path": .string(directoryURL.path),
      "size_bytes": sizeBytes.map { .integer(Int64($0)) } ?? .null,
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "describe_context": .object([
        "tool": .string("skills.describe"),
        "arguments": .object([
          "name": .string(name),
          "root_id": .string(root.id),
        ]),
      ]),
      "validate_context": .object([
        "tool": .string("skills.validate"),
        "arguments": .object([
          "name": .string(name),
          "root_id": .string(root.id),
        ]),
      ]),
      "read_context": .object([
        "tool": .string("skills.read"),
        "arguments": .object([
          "name": .string(name),
          "root_id": .string(root.id),
        ]),
      ]),
      "files_context": .object([
        "tool": .string("skills.files"),
        "arguments": .object([
          "name": .string(name),
          "root_id": .string(root.id),
        ]),
      ]),
      "read_package_context": .object([
        "tool": .string("skills.read_package"),
        "arguments": .object([
          "name": .string(name),
          "root_id": .string(root.id),
        ]),
      ]),
    ])
  }
}

private struct SkillContent {
  var content: String?
  var bytesRead: Int
  var truncated: Bool
  var validUTF8: Bool
}

private struct SkillFileContent {
  var content: String?
  var bytesRead: Int
  var truncated: Bool
  var validUTF8: Bool
  var encoding: String
}

private struct SkillPackageFileContent {
  var content: String?
  var bytesRead: Int
  var truncated: Bool
  var validUTF8: Bool
  var encoding: String
}

private struct SkillFileListResult {
  var files: [SkillFileInfo]
  var scannedCount: Int
  var scanTruncated: Bool
  var resultTruncated: Bool
}

private struct SkillFileInfo {
  var skill: SkillInfo
  var path: String
  var absolutePath: String
  var type: String
  var sizeBytes: Int64?
  var modifiedAt: Date?
  var isReadable: Bool
  var isSymlink: Bool
  var targetInsideSkill: Bool
  var isMarkdown: Bool
  var outlineLanguage: String?

  var json: JSONValue {
    let canRead = type == "file" && isReadable && targetInsideSkill
    let canList = type == "directory" && isReadable && targetInsideSkill
    let canOutline = canRead && outlineLanguage != nil
    let canCheckLinks = canRead && isMarkdown
    let canReadFrontmatter = canRead && isMarkdown
    let canReadSection = canRead && isMarkdown
    let canReadTables = canRead && isMarkdown
    let canReadLinks = canRead && isMarkdown
    return .object([
      "path": .string(path),
      "absolute_path": .string(absolutePath),
      "type": .string(type),
      "outline_language": outlineLanguage.map(JSONValue.string) ?? .null,
      "size_bytes": sizeBytes.map { .integer(Int64($0)) } ?? .null,
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_readable": .bool(isReadable),
      "is_symlink": .bool(isSymlink),
      "target_inside_skill": .bool(targetInsideSkill),
      "read_context": canRead
        ? .object([
          "tool": .string("skills.read_file"),
          "arguments": .object([
            "name": .string(skill.name),
            "root_id": .string(skill.root.id),
            "path": .string(path),
          ]),
        ])
        : .null,
      "outline_context": canOutline
        ? .object([
          "tool": .string("skills.outline"),
          "arguments": .object([
            "name": .string(skill.name),
            "root_id": .string(skill.root.id),
            "path": .string(path),
          ]),
        ])
        : .null,
      "frontmatter_context": canReadFrontmatter
        ? .object([
          "tool": .string("skills.frontmatter"),
          "arguments": .object([
            "name": .string(skill.name),
            "root_id": .string(skill.root.id),
            "path": .string(path),
          ]),
        ])
        : .null,
      "section_context": canReadSection
        ? .object([
          "tool": .string("skills.section"),
          "arguments": .object([
            "name": .string(skill.name),
            "root_id": .string(skill.root.id),
            "path": .string(path),
          ]),
          "required_arguments": .array([.string("heading")]),
        ])
        : .null,
      "tables_context": canReadTables
        ? .object([
          "tool": .string("skills.tables"),
          "arguments": .object([
            "name": .string(skill.name),
            "root_id": .string(skill.root.id),
            "path": .string(path),
          ]),
        ])
        : .null,
      "links_context": canReadLinks
        ? .object([
          "tool": .string("skills.links"),
          "arguments": .object([
            "name": .string(skill.name),
            "root_id": .string(skill.root.id),
            "path": .string(path),
          ]),
        ])
        : .null,
      "link_check_context": canCheckLinks
        ? .object([
          "tool": .string("skills.link_check"),
          "arguments": .object([
            "name": .string(skill.name),
            "root_id": .string(skill.root.id),
            "path": .string(path),
          ]),
        ])
        : .null,
      "list_context": canList
        ? .object([
          "tool": .string("skills.files"),
          "arguments": .object([
            "name": .string(skill.name),
            "root_id": .string(skill.root.id),
            "path": .string(path),
          ]),
        ])
        : .null,
    ])
  }
}

private struct SkillFileSearchResult {
  var file: SkillFileInfo
  var matchedFields: [String]
  var contentSearched: Bool
  var contentMatches: [SkillContentLineMatch]
  var contentTruncated: Bool
  var validUTF8: Bool?

  var json: JSONValue {
    let canRead = file.type == "file" && file.isReadable && file.targetInsideSkill
    let canList = file.type == "directory" && file.isReadable && file.targetInsideSkill
    return .object([
      "path": .string(file.path),
      "absolute_path": .string(file.absolutePath),
      "type": .string(file.type),
      "size_bytes": file.sizeBytes.map { .integer(Int64($0)) } ?? .null,
      "modified_at": file.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_readable": .bool(file.isReadable),
      "is_symlink": .bool(file.isSymlink),
      "target_inside_skill": .bool(file.targetInsideSkill),
      "matched_fields": .array(matchedFields.map(JSONValue.string)),
      "content_searched": .bool(contentSearched),
      "content_match_count": .integer(Int64(contentMatches.count)),
      "content_matches": .array(contentMatches.map(\.json)),
      "content_truncated": .bool(contentTruncated),
      "valid_utf8": validUTF8.map(JSONValue.bool) ?? .null,
      "read_context": canRead
        ? .object([
          "tool": .string("skills.read_file"),
          "arguments": .object([
            "name": .string(file.skill.name),
            "root_id": .string(file.skill.root.id),
            "path": .string(file.path),
          ]),
        ])
        : .null,
      "list_context": canList
        ? .object([
          "tool": .string("skills.files"),
          "arguments": .object([
            "name": .string(file.skill.name),
            "root_id": .string(file.skill.root.id),
            "path": .string(file.path),
          ]),
        ])
        : .null,
    ])
  }
}

private struct SkillResourceSummary {
  var kind: String
  var path: String?
  var skill: SkillInfo
  var exists = false
  var fileCount = 0
  var directoryCount = 0
  var symlinkCount = 0
  var otherCount = 0
  var totalSizeBytes: Int64 = 0
  var isReadable = false
  var isDirectory = false
  var targetInsideSkill = false

  mutating func add(_ file: SkillFileInfo) {
    exists = true
    if file.path == path {
      isReadable = file.isReadable
      isDirectory = file.type == "directory"
      targetInsideSkill = file.targetInsideSkill
    }
    switch file.type {
    case "file":
      fileCount += 1
    case "directory":
      directoryCount += 1
    default:
      otherCount += 1
    }
    if file.isSymlink {
      symlinkCount += 1
    }
    if let sizeBytes = file.sizeBytes {
      totalSizeBytes += sizeBytes
    }
  }

  var json: JSONValue {
    let listContext: JSONValue
    if let path, exists, isDirectory, isReadable, targetInsideSkill {
      listContext = .object([
        "tool": .string("skills.files"),
        "arguments": .object([
          "name": .string(skill.name),
          "root_id": .string(skill.root.id),
          "path": .string(path),
        ]),
      ])
    } else {
      listContext = .null
    }

    return .object([
      "kind": .string(kind),
      "path": path.map(JSONValue.string) ?? .null,
      "exists": .bool(exists),
      "file_count": .integer(Int64(fileCount)),
      "directory_count": .integer(Int64(directoryCount)),
      "symlink_count": .integer(Int64(symlinkCount)),
      "other_count": .integer(Int64(otherCount)),
      "total_size_bytes": .integer(Int64(totalSizeBytes)),
      "list_context": listContext,
    ])
  }
}

private struct SkillFrontmatterStatus {
  var hasOpening: Bool
  var closed: Bool
  var name: String?
  var description: String?
  var lineCount: Int?
  var parseError: String? = nil

  var json: JSONValue {
    .object([
      "has_opening_delimiter": .bool(hasOpening),
      "has_closing_delimiter": .bool(closed),
      "name": name.map(JSONValue.string) ?? .null,
      "description": description.map(JSONValue.string) ?? .null,
      "line_count": lineCount.map { .integer(Int64($0)) } ?? .null,
      "parse_error": parseError.map(JSONValue.string) ?? .null,
    ])
  }
}

private struct SkillValidationIssue {
  var severity: String
  var code: String
  var message: String
  var path: String

  var json: JSONValue {
    .object([
      "severity": .string(severity),
      "code": .string(code),
      "message": .string(message),
      "path": .string(path),
    ])
  }
}

private struct SkillFrontmatter {
  var name: String? = nil
  var description: String? = nil
}

private struct DecodedSkillFrontmatter {
  var metadata: SkillFrontmatter
  var document: StructuredDocument?
  var parseError: String?
}

private struct SkillContentLineMatch {
  var line: Int
  var text: String

  var json: JSONValue {
    .object([
      "line": .integer(Int64(line)),
      "text": .string(text),
    ])
  }
}

private struct SkillSearchResult {
  var skill: SkillInfo
  var matchedFields: [String]
  var contentMatches: [SkillContentLineMatch]
  var contentSearched: Bool
  var contentTruncated: Bool
  var validUTF8: Bool

  var json: JSONValue {
    .object([
      "root_id": .string(skill.root.id),
      "name": .string(skill.name),
      "directory_name": .string(skill.directoryName),
      "description": skill.description.map(JSONValue.string) ?? .null,
      "path": .string(skill.fileURL.path),
      "skill_directory_path": .string(skill.directoryURL.path),
      "matched_fields": .array(matchedFields.map(JSONValue.string)),
      "content_searched": .bool(contentSearched),
      "content_match_count": .integer(Int64(contentMatches.count)),
      "content_matches": .array(contentMatches.map(\.json)),
      "content_truncated": .bool(contentTruncated),
      "valid_utf8": .bool(validUTF8),
      "read_context": .object([
        "tool": .string("skills.read"),
        "arguments": .object([
          "name": .string(skill.name),
          "root_id": .string(skill.root.id),
        ]),
      ]),
      "files_context": .object([
        "tool": .string("skills.files"),
        "arguments": .object([
          "name": .string(skill.name),
          "root_id": .string(skill.root.id),
        ]),
      ]),
    ])
  }
}
