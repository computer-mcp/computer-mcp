import AppKit
import CryptoKit
import Darwin
import Foundation

extension GatewayToolRegistry {
  internal func fileExists(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let url = try resolvedWorkspaceURL(path)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "exists": .bool(exists),
      "is_directory": exists ? .bool(isDirectory.boolValue) : .null,
      "is_file": exists ? .bool(!isDirectory.boolValue) : .null,
    ])
  }

  internal func listFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let requestedPath = try optionalStringAllowingEmpty("path", in: object)
    let path =
      requestedPath.flatMap { value in
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
      } ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let recursiveDepth = optionalInt("recursive_depth", in: object) ?? 0
    let maxEntries = optionalInt("max_entries", in: object) ?? 200

    guard recursiveDepth >= 0 else {
      throw GatewayToolError.invalidArguments("recursive_depth must be zero or greater.")
    }
    guard maxEntries > 0 else {
      throw GatewayToolError.invalidArguments("max_entries must be greater than zero.")
    }
    guard maxEntries <= 10_000 else {
      throw GatewayToolError.invalidArguments("max_entries must be less than or equal to 10000.")
    }

    let directory = try resolvedWorkspaceURL(path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Directory does not exist: \(path)")
    }
    guard isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Path is not a directory: \(path)")
    }

    var entries: [ListedFile] = []
    var truncated = false
    try collectDirectoryEntries(
      directory: directory,
      currentDepth: 0,
      maxDepth: recursiveDepth,
      includeHidden: includeHidden,
      maxEntries: maxEntries,
      entries: &entries,
      truncated: &truncated
    )
    entries.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }

    return .object([
      "path": .string(directory.path),
      "workspace_relative_path": .string(workspaceRelativePath(directory)),
      "recursive_depth": .integer(Int64(recursiveDepth)),
      "include_hidden": .bool(includeHidden),
      "max_entries": .integer(Int64(maxEntries)),
      "entry_count": .integer(Int64(entries.count)),
      "truncated": .bool(truncated),
      "entries": .array(entries.map(\.json)),
    ])
  }

  internal func treeFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 2
    let maxEntries = optionalInt("max_entries", in: object) ?? 500
    let directoriesOnly = try optionalBool("directories_only", in: object) ?? false

    try validateBoundedNonNegative(maxDepth, name: "max_depth", upperBound: 20)
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 50_000)

    let root = try resolvedWorkspaceURL(path)
    try requireDirectory(root, originalPath: path)

    var emitted = 0
    var truncated = false
    let tree = try fileTreeNode(
      url: root,
      depth: 0,
      maxDepth: maxDepth,
      includeHidden: includeHidden,
      directoriesOnly: directoriesOnly,
      maxEntries: maxEntries,
      emitted: &emitted,
      truncated: &truncated
    )

    return .object([
      "path": .string(root.path),
      "workspace_relative_path": .string(workspaceRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_entries": .integer(Int64(maxEntries)),
      "directories_only": .bool(directoriesOnly),
      "entry_count": .integer(Int64(emitted)),
      "truncated": .bool(truncated),
      "tree": tree,
    ])
  }

  internal func statFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let url = try resolvedWorkspaceURL(path)
    return try fileInfo(url: url).json
  }

  internal func filePermissions(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
    let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.intValue
    let groupID = (attributes[.groupOwnerAccountID] as? NSNumber)?.intValue
    let ownerName = attributes[.ownerAccountName] as? String
    let groupName = attributes[.groupOwnerAccountName] as? String
    let immutable = (attributes[.immutable] as? NSNumber)?.boolValue
    let appendOnly = (attributes[.appendOnly] as? NSNumber)?.boolValue
    let extensionHidden = (attributes[.extensionHidden] as? NSNumber)?.boolValue

    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "type": .string(info.type),
      "mode": mode.map { .integer(Int64($0)) } ?? .null,
      "mode_octal": mode.map { .string(String(format: "%04o", $0 & 0o7777)) } ?? .null,
      "owner_account_id": ownerID.map { .integer(Int64($0)) } ?? .null,
      "owner_account_name": ownerName.map(JSONValue.string) ?? .null,
      "group_owner_account_id": groupID.map { .integer(Int64($0)) } ?? .null,
      "group_owner_account_name": groupName.map(JSONValue.string) ?? .null,
      "permissions": mode.map(permissionSummary) ?? .null,
      "current_process_access": .object([
        "readable": .bool(info.isReadable),
        "writable": .bool(info.isWritable),
        "executable": .bool(info.isExecutable),
      ]),
      "flags": .object([
        "immutable": immutable.map(JSONValue.bool) ?? .null,
        "append_only": appendOnly.map(JSONValue.bool) ?? .null,
        "extension_hidden": extensionHidden.map(JSONValue.bool) ?? .null,
      ]),
    ])
  }

  internal func chmodFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let mode = try parsePOSIXMode(try requiredString("mode", in: object), name: "mode")
    let expectedCurrentMode = try optionalString("expected_current_mode", in: object)
      .map { try parsePOSIXMode($0, name: "expected_current_mode") }
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let url = try resolvedWorkspaceURL(path)

    guard FileManager.default.fileExists(atPath: url.path) else {
      throw GatewayToolError.invalidArguments("Path does not exist: \(path)")
    }

    let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)
    let modeBefore = (attributesBefore[.posixPermissions] as? NSNumber)?.intValue
    if let expectedCurrentMode, modeBefore.map({ $0 & 0o7777 }) != expectedCurrentMode {
      throw GatewayToolError.invalidArguments("expected_current_mode does not match current mode.")
    }

    if !dryRun {
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)
    let modeAfter = (attributesAfter[.posixPermissions] as? NSNumber)?.intValue
    let normalizedModeBefore = modeBefore.map { $0 & 0o7777 }
    let normalizedModeAfter = modeAfter.map { $0 & 0o7777 }

    return .object([
      "operation": .string("file.chmod"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "dry_run": .bool(dryRun),
      "mode_before": normalizedModeBefore.map { .integer(Int64($0)) } ?? .null,
      "mode_before_octal": normalizedModeBefore.map { .string(String(format: "%04o", $0)) }
        ?? .null,
      "mode_after": normalizedModeAfter.map { .integer(Int64($0)) } ?? .null,
      "mode_after_octal": normalizedModeAfter.map { .string(String(format: "%04o", $0)) }
        ?? .null,
      "requested_mode": .integer(Int64(mode)),
      "requested_mode_octal": .string(String(format: "%04o", mode)),
      "would_mode_after": .integer(Int64(mode)),
      "would_mode_after_octal": .string(String(format: "%04o", mode)),
      "would_change": normalizedModeBefore.map { $0 != mode }.map(JSONValue.bool) ?? .null,
      "changed": .bool(!dryRun && normalizedModeBefore.map { $0 != mode } == true),
      "result": dryRun ? .null : try fileInfo(url: url).json,
    ])
  }

  internal func typeFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let result = try commandRunner.run(
      executable: "/usr/bin/file",
      arguments: ["-b", "--mime", url.path],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
    let mimeType = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    var charset: String?
    if parts.count > 1 {
      for parameter in parts[1].split(separator: ";") {
        let trimmed = String(parameter).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("charset=") {
          charset = String(trimmed.dropFirst("charset=".count))
          break
        }
      }
    }

    return .object([
      "operation": .string("file.type"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "mime_type": mimeType.isEmpty ? .null : .string(mimeType),
      "charset": charset.map(JSONValue.string) ?? .null,
      "raw": .string(raw),
      "result": result.json,
    ])
  }

  internal func countFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let result = try commandRunner.run(
      executable: "/usr/bin/wc",
      arguments: ["-l", "-w", "-c", url.path],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let tokens = result.stdout.split { $0 == " " || $0 == "\t" || $0 == "\n" }
    let lineCount = tokens.count >= 1 ? Int(tokens[0]) : nil
    let wordCount = tokens.count >= 2 ? Int(tokens[1]) : nil
    let byteCount = tokens.count >= 3 ? Int(tokens[2]) : nil

    return .object([
      "operation": .string("file.count"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "line_count": lineCount.map { .integer(Int64($0)) } ?? .null,
      "word_count": wordCount.map { .integer(Int64($0)) } ?? .null,
      "byte_count": byteCount.map { .integer(Int64($0)) } ?? .null,
      "result": result.json,
    ])
  }

  internal func diskUsage(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let timeout = optionalInt("timeout_ms", in: object) ?? 30_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    let result = try commandRunner.run(
      executable: "/usr/bin/du",
      arguments: ["-sk", url.path],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let tokens = result.stdout.split { $0 == " " || $0 == "\t" || $0 == "\n" }
    let usageKiB = tokens.first.flatMap { Int64($0) }

    return .object([
      "operation": .string("file.disk_usage"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "type": .string(info.type),
      "apparent_size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "disk_usage_kib": usageKiB.map { .integer(Int64($0)) } ?? .null,
      "disk_usage_bytes": try usageKiB.map {
        let (bytes, overflow) = $0.multipliedReportingOverflow(by: 1_024)
        guard !overflow else {
          throw GatewayToolError.executionFailed(
            "Disk usage exceeds the supported signed 64-bit byte range.")
        }
        return JSONValue.integer(bytes)
      } ?? .null,
      "result": result.json,
    ])
  }

  internal func fileVolumeInfo(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    let keys = Set(volumeResourceKeys())
    let values = try url.resourceValues(forKeys: keys)
    let volumeURL = values.volume ?? url

    return .object([
      "operation": .string("file.volume_info"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "type": .string(info.type),
      "volume": volumeInfo(url: volumeURL, keys: keys),
    ])
  }

  internal func findFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let query = try requiredString("query", in: object)
    let matchMode = try fileNameMatchMode(try optionalString("match", in: object) ?? "contains")
    let caseSensitive = try optionalBool("case_sensitive", in: object) ?? false
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxVisited = optionalInt("max_visited", in: object) ?? 20_000

    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxVisited, name: "max_visited", upperBound: 200_000)

    let directory = try resolvedWorkspaceURL(path)
    try requireDirectory(directory, originalPath: path)

    var results: [FileInfo] = []
    var visited = 0
    var truncated = false
    try collectFindResults(
      directory: directory,
      currentDepth: 0,
      maxDepth: maxDepth,
      query: query,
      matchMode: matchMode,
      caseSensitive: caseSensitive,
      includeHidden: includeHidden,
      maxResults: maxResults,
      maxVisited: maxVisited,
      visited: &visited,
      results: &results,
      truncated: &truncated
    )
    results.sort {
      $0.workspaceRelativePath.localizedStandardCompare($1.workspaceRelativePath)
        == .orderedAscending
    }

    return .object([
      "path": .string(directory.path),
      "workspace_relative_path": .string(workspaceRelativePath(directory)),
      "query": .string(query),
      "match": .string(matchMode.rawValue),
      "case_sensitive": .bool(caseSensitive),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_visited": .integer(Int64(maxVisited)),
      "visited_entries": .integer(Int64(visited)),
      "result_count": .integer(Int64(results.count)),
      "truncated": .bool(truncated),
      "results": .array(results.map(\.json)),
    ])
  }

  internal func searchFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let query = try requiredString("query", in: object)
    let caseSensitive = try optionalBool("case_sensitive", in: object) ?? false
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxFiles = optionalInt("max_files", in: object) ?? 500
    let maxMatches = optionalInt("max_matches", in: object) ?? 100
    let maxBytesPerFile = optionalInt("max_bytes_per_file", in: object) ?? 1_048_576

    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxFiles, name: "max_files", upperBound: 50_000)
    try validateBoundedPositive(maxMatches, name: "max_matches", upperBound: 10_000)
    try validateBoundedPositive(maxBytesPerFile, name: "max_bytes_per_file", upperBound: 20_971_520)

    let root = try resolvedWorkspaceURL(path)
    var matches: [FileSearchMatch] = []
    var filesScanned = 0
    var filesSkipped = 0
    var bytesScanned = 0
    var truncatedFiles = 0
    var truncated = false

    let rootInfo = try fileInfo(url: root)
    if rootInfo.type == "directory" {
      try collectSearchMatches(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        query: query,
        caseSensitive: caseSensitive,
        includeHidden: includeHidden,
        maxFiles: maxFiles,
        maxMatches: maxMatches,
        maxBytesPerFile: maxBytesPerFile,
        filesScanned: &filesScanned,
        filesSkipped: &filesSkipped,
        bytesScanned: &bytesScanned,
        truncatedFiles: &truncatedFiles,
        matches: &matches,
        truncated: &truncated
      )
    } else {
      try searchFileIfAllowed(
        url: root,
        info: rootInfo,
        query: query,
        caseSensitive: caseSensitive,
        maxFiles: maxFiles,
        maxMatches: maxMatches,
        maxBytesPerFile: maxBytesPerFile,
        filesScanned: &filesScanned,
        filesSkipped: &filesSkipped,
        bytesScanned: &bytesScanned,
        truncatedFiles: &truncatedFiles,
        matches: &matches,
        truncated: &truncated
      )
    }

    return .object([
      "path": .string(root.path),
      "workspace_relative_path": .string(workspaceRelativePath(root)),
      "query": .string(query),
      "case_sensitive": .bool(caseSensitive),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_files": .integer(Int64(maxFiles)),
      "max_matches": .integer(Int64(maxMatches)),
      "max_bytes_per_file": .integer(Int64(maxBytesPerFile)),
      "files_scanned": .integer(Int64(filesScanned)),
      "files_skipped": .integer(Int64(filesSkipped)),
      "bytes_scanned": .integer(Int64(bytesScanned)),
      "truncated_files": .integer(Int64(truncatedFiles)),
      "match_count": .integer(Int64(matches.count)),
      "truncated": .bool(truncated),
      "matches": .array(matches.map(\.json)),
    ])
  }

  internal func fileTimeline(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    let sort = try fileTimelineSort(try optionalString("sort", in: object) ?? "modified_desc")
    let modifiedAfter = try optionalISO8601Date("modified_after", in: object)
    let modifiedBefore = try optionalISO8601Date("modified_before", in: object)
    if let modifiedAfter, let modifiedBefore, modifiedAfter > modifiedBefore {
      throw GatewayToolError.invalidArguments(
        "modified_after must be earlier than or equal to modified_before.")
    }

    try validateBoundedNonNegative(maxDepth, name: "max_depth", upperBound: 50)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let directory = try resolvedWorkspaceURL(path)
    try requireDirectory(directory, originalPath: path)

    var scannedEntries = 0
    var scannedFileCount = 0
    var skippedMissingModifiedDateCount = 0
    var scanTruncated = false
    var entries: [TimelineFileEntry] = []
    try collectTimelineFiles(
      directory: directory,
      currentDepth: 0,
      maxDepth: maxDepth,
      includeHidden: includeHidden,
      modifiedAfter: modifiedAfter,
      modifiedBefore: modifiedBefore,
      maxScanEntries: maxScanEntries,
      scannedEntries: &scannedEntries,
      scannedFileCount: &scannedFileCount,
      skippedMissingModifiedDateCount: &skippedMissingModifiedDateCount,
      scanTruncated: &scanTruncated,
      entries: &entries
    )

    let sortedEntries = entries.sorted { lhs, rhs in
      switch sort {
      case .modifiedDesc:
        if lhs.modifiedAt != rhs.modifiedAt {
          return lhs.modifiedAt > rhs.modifiedAt
        }
      case .modifiedAsc:
        if lhs.modifiedAt != rhs.modifiedAt {
          return lhs.modifiedAt < rhs.modifiedAt
        }
      case .path:
        break
      }
      return lhs.workspaceRelativePath.localizedStandardCompare(rhs.workspaceRelativePath)
        == .orderedAscending
    }
    let resultTruncated = sortedEntries.count > maxResults
    let returned = resultTruncated ? Array(sortedEntries.prefix(maxResults)) : sortedEntries

    return .object([
      "operation": .string("file.timeline"),
      "path": .string(directory.path),
      "workspace_relative_path": .string(workspaceRelativePath(directory)),
      "include_hidden": .bool(includeHidden),
      "modified_after": modifiedAfter.map { .string(iso8601String($0)) } ?? .null,
      "modified_before": modifiedBefore.map { .string(iso8601String($0)) } ?? .null,
      "sort": .string(sort.rawValue),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "scanned_file_count": .integer(Int64(scannedFileCount)),
      "matched_file_count": .integer(Int64(sortedEntries.count)),
      "returned_count": .integer(Int64(returned.count)),
      "skipped_missing_modified_date_count": .integer(Int64(skippedMissingModifiedDateCount)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(returned.map(\.json)),
    ])
  }

  internal func readFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    guard maxBytes > 0 else {
      throw GatewayToolError.invalidArguments("max_bytes must be greater than zero.")
    }

    let url = try resolvedWorkspaceURL(path)
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }

    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let truncated = data.count > maxBytes
    let contentData = truncated ? Data(data.prefix(maxBytes)) : data

    return .object([
      "path": .string(url.path),
      "encoding": .string("utf-8"),
      "content": .string(String(decoding: contentData, as: UTF8.self)),
      "bytes_read": .integer(Int64(contentData.count)),
      "truncated": .bool(truncated),
    ])
  }

  internal func readFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let paths = try requiredStringArray("paths", in: object)
    let maxBytes =
      optionalInt("max_bytes_per_file", in: object)
      ?? configuration.policy.maxOutputBytes
    let encoding = try optionalString("encoding", in: object) ?? "utf8"
    guard !paths.isEmpty else {
      throw GatewayToolError.invalidArguments("paths must not be empty.")
    }
    guard paths.count <= 50 else {
      throw GatewayToolError.invalidArguments("paths must contain at most 50 values.")
    }
    try validateBoundedPositive(maxBytes, name: "max_bytes_per_file", upperBound: 20_971_520)
    guard encoding == "utf8" || encoding == "base64" else {
      throw GatewayToolError.invalidArguments("encoding must be utf8 or base64.")
    }

    var files: [JSONValue] = []
    var totalBytesRead = 0
    var truncatedCount = 0
    for path in paths {
      let file = try readWorkspaceFileEntry(
        path: path,
        maxBytes: maxBytes,
        encoding: encoding
      )
      totalBytesRead += file.bytesRead
      if file.truncated {
        truncatedCount += 1
      }
      files.append(file.json)
    }

    return .object([
      "operation": .string("file.read_files"),
      "encoding": .string(encoding),
      "max_bytes_per_file": .integer(Int64(maxBytes)),
      "requested_count": .integer(Int64(paths.count)),
      "file_count": .integer(Int64(files.count)),
      "total_bytes_read": .integer(Int64(totalBytesRead)),
      "truncated_file_count": .integer(Int64(truncatedCount)),
      "files": .array(files),
    ])
  }

  private func readWorkspaceFileEntry(
    path: String,
    maxBytes: Int,
    encoding: String
  ) throws -> FileReadEntry {
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
    let truncated = data.count > maxBytes
    let contentData = truncated ? Data(data.prefix(maxBytes)) : data
    let validUTF8 = String(data: contentData, encoding: .utf8) != nil
    let content =
      encoding == "base64"
      ? contentData.base64EncodedString()
      : String(decoding: contentData, as: UTF8.self)

    return FileReadEntry(
      info: info,
      encoding: encoding,
      content: content,
      bytesRead: contentData.count,
      truncated: truncated,
      validUTF8: validUTF8
    )
  }

  internal func readFileWindow(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let offset = optionalInt("offset_bytes", in: object) ?? 0
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedNonNegative(offset, name: "offset_bytes", upperBound: 9_007_199_254_740_991)
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

    let fileSize = try handle.seekToEnd()
    let offsetValue = UInt64(offset)
    let data: Data
    if offsetValue >= fileSize {
      data = Data()
    } else {
      try handle.seek(toOffset: offsetValue)
      data = try handle.read(upToCount: maxBytes) ?? Data()
    }
    let nextOffset = offsetValue + UInt64(data.count)
    let validUTF8 = String(data: data, encoding: .utf8) != nil

    return .object([
      "operation": .string("file.read_window"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "encoding": .string("utf-8"),
      "offset_bytes": .integer(Int64(offset)),
      "max_bytes": .integer(Int64(maxBytes)),
      "file_size_bytes": .integer(Int64(fileSize)),
      "bytes_read": .integer(Int64(data.count)),
      "next_offset_bytes": .integer(Int64(nextOffset)),
      "eof": .bool(nextOffset >= fileSize),
      "truncated": .bool(nextOffset < fileSize),
      "valid_utf8": .bool(validUTF8),
      "content": .string(String(decoding: data, as: UTF8.self)),
    ])
  }

  internal func readFileLines(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let startLine = optionalInt("start_line", in: object) ?? 1
    let maxLines = optionalInt("max_lines", in: object) ?? 200
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(startLine, name: "start_line", upperBound: 10_000_000)
    try validateBoundedPositive(maxLines, name: "max_lines", upperBound: 10_000)
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
    let content = String(decoding: contentData, as: UTF8.self)
    let allLines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let selected = allLines.enumerated().compactMap { index, line -> JSONValue? in
      let lineNumber = index + 1
      guard lineNumber >= startLine, lineNumber < startLine + maxLines else {
        return nil
      }
      return .object([
        "line": .integer(Int64(lineNumber)),
        "text": .string(String(line)),
      ])
    }
    let returnedCount = selected.count

    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "encoding": .string("utf-8"),
      "start_line": .integer(Int64(startLine)),
      "max_lines": .integer(Int64(maxLines)),
      "max_bytes": .integer(Int64(maxBytes)),
      "bytes_scanned": .integer(Int64(contentData.count)),
      "file_truncated": .bool(fileTruncated),
      "line_count": .integer(Int64(returnedCount)),
      "lines": .array(selected),
    ])
  }

  internal func readFileContext(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let line = optionalInt("line", in: object) ?? 0
    let before = optionalInt("before", in: object) ?? 5
    let after = optionalInt("after", in: object) ?? 5
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(line, name: "line", upperBound: 10_000_000)
    try validateBoundedNonNegative(before, name: "before", upperBound: 10_000)
    try validateBoundedNonNegative(after, name: "after", upperBound: 10_000)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)

    let startLine = max(1, line - before)
    let endLine = line + after

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
    let content = String(decoding: contentData, as: UTF8.self)
    let allLines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let selected = allLines.enumerated().compactMap { index, text -> JSONValue? in
      let lineNumber = index + 1
      guard lineNumber >= startLine, lineNumber <= endLine else {
        return nil
      }
      return .object([
        "line": .integer(Int64(lineNumber)),
        "relative_line": .integer(Int64(lineNumber - line)),
        "is_target": .bool(lineNumber == line),
        "text": .string(String(text)),
      ])
    }
    let targetLineReturned = selected.contains { value in
      value.objectValue?["is_target"]?.boolValue == true
    }
    let rangeMayBeTruncated = fileTruncated && allLines.count < endLine

    return .object([
      "operation": .string("file.read_context"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "encoding": .string("utf-8"),
      "line": .integer(Int64(line)),
      "before": .integer(Int64(before)),
      "after": .integer(Int64(after)),
      "start_line": .integer(Int64(startLine)),
      "end_line": .integer(Int64(endLine)),
      "start_clamped": .bool(line - before < 1),
      "max_bytes": .integer(Int64(maxBytes)),
      "bytes_scanned": .integer(Int64(contentData.count)),
      "file_truncated": .bool(fileTruncated),
      "range_may_be_truncated": .bool(rangeMayBeTruncated),
      "target_line_returned": .bool(targetLineReturned),
      "line_count": .integer(Int64(selected.count)),
      "lines": .array(selected),
    ])
  }

  internal func headFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxLines = optionalInt("max_lines", in: object) ?? 200
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxLines, name: "max_lines", upperBound: 10_000)
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

    let fileSize = try handle.seekToEnd()
    try handle.seek(toOffset: 0)
    let bytesToRead = Int(min(UInt64(maxBytes), fileSize))
    let data = try handle.read(upToCount: bytesToRead) ?? Data()
    let fileTruncated = fileSize > UInt64(data.count)
    var content = String(decoding: data, as: UTF8.self)
    let byteWindowEndsMidLine = fileTruncated && !content.isEmpty && !content.hasSuffix("\n")
    if content.hasSuffix("\n") {
      content.removeLast()
    }

    let allLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let selectedLines = Array(allLines.prefix(maxLines))
    let resultTruncated = allLines.count > selectedLines.count
    let lastReturnedLineTruncated =
      byteWindowEndsMidLine && selectedLines.count == allLines.count && !selectedLines.isEmpty
    let selected = selectedLines.enumerated().map { index, line in
      JSONValue.object([
        "line": .integer(Int64(index + 1)),
        "head_index": .integer(Int64(index + 1)),
        "text": .string(line),
        "line_truncated": .bool(lastReturnedLineTruncated && index == selectedLines.count - 1),
      ])
    }

    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "encoding": .string("utf-8"),
      "max_lines": .integer(Int64(maxLines)),
      "max_bytes": .integer(Int64(maxBytes)),
      "file_size_bytes": .integer(Int64(fileSize)),
      "bytes_read": .integer(Int64(data.count)),
      "file_truncated": .bool(fileTruncated),
      "result_truncated": .bool(resultTruncated),
      "last_line_truncated": .bool(lastReturnedLineTruncated),
      "line_count": .integer(Int64(selected.count)),
      "truncated": .bool(fileTruncated || resultTruncated),
      "lines": .array(selected),
    ])
  }

  internal func outlineFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let includeImports = try optionalBool("include_imports", in: object) ?? false
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)

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
      throw GatewayToolError.invalidArguments("File is not valid UTF-8: \(path)")
    }

    let language = outlineLanguage(for: url)
    let allItems = outlineItems(
      in: content,
      language: language,
      includeImports: includeImports
    )
    let returnedItems = Array(allItems.prefix(maxResults))
    let resultTruncated = allItems.count > returnedItems.count

    return .object([
      "operation": .string("file.outline"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
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
    ])
  }

  internal func outlineItems(
    in content: String,
    language: String?,
    includeImports: Bool
  ) -> [FileOutlineItem] {
    var allItems: [FileOutlineItem] = []
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var insideMarkdownFence = false
    for (index, line) in lines.enumerated() {
      if language == "markdown" {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
          insideMarkdownFence.toggle()
          continue
        }
        if insideMarkdownFence {
          continue
        }
      }
      guard
        let item = outlineItem(line: String(line), lineNumber: index + 1, language: language)
      else {
        continue
      }
      if item.kind == "import" && !includeImports {
        continue
      }
      allItems.append(item)
    }
    return allItems
  }

  internal func outlineLanguage(for url: URL) -> String? {
    let name = url.lastPathComponent.lowercased()
    let ext = url.pathExtension.lowercased()
    if ["md", "markdown", "mdown"].contains(ext) {
      return "markdown"
    }
    if ext == "swift" {
      return "swift"
    }
    if ["js", "jsx", "mjs", "cjs"].contains(ext) {
      return "javascript"
    }
    if ["ts", "tsx", "mts", "cts"].contains(ext) {
      return "typescript"
    }
    if ext == "py" {
      return "python"
    }
    if ext == "go" {
      return "go"
    }
    if ext == "rs" {
      return "rust"
    }
    if ext == "java" {
      return "java"
    }
    if ["kt", "kts"].contains(ext) {
      return "kotlin"
    }
    if ["c", "h", "cc", "cpp", "cxx", "hpp"].contains(ext) {
      return "c-family"
    }
    if name == "makefile" || ext == "mk" {
      return "make"
    }
    return nil
  }

  private func outlineItem(line: String, lineNumber: Int, language: String?) -> FileOutlineItem? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      return nil
    }

    if language == "markdown", let heading = markdownHeading(trimmed, lineNumber: lineNumber) {
      return heading
    }

    var tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard !tokens.isEmpty else {
      return nil
    }

    let modifiers = Set([
      "public", "private", "internal", "fileprivate", "open", "static", "final", "override",
      "mutating", "nonmutating", "lazy", "async", "throws", "rethrows", "export", "default",
      "pub", "abstract", "sealed", "data", "inline", "extern", "virtual",
    ])
    while let first = tokens.first, modifiers.contains(first) {
      tokens.removeFirst()
    }
    guard !tokens.isEmpty else {
      return nil
    }

    if tokens.count >= 2, tokens[0] == "async", tokens[1] == "def" {
      return declarationOutlineItem(
        kind: "function",
        rawName: tokens.dropFirst(2).first,
        line: line,
        lineNumber: lineNumber
      )
    }

    let keyword = tokens[0]
    let rawName = tokens.dropFirst().first
    let kind: String
    switch keyword {
    case "class":
      kind = "class"
    case "struct":
      kind = "struct"
    case "enum":
      kind = "enum"
    case "protocol", "interface", "trait":
      kind = "interface"
    case "actor":
      kind = "actor"
    case "extension", "impl":
      kind = "extension"
    case "func", "function", "def", "fn":
      kind = "function"
    case "init", "deinit", "constructor":
      kind = "function"
    case "var", "let", "const":
      kind = "variable"
    case "typealias", "type":
      kind = "type"
    case "import", "package", "mod", "use":
      kind = "import"
    default:
      if language == "make", trimmed.hasSuffix(":"), !trimmed.hasPrefix("\t"),
        !trimmed.contains("=")
      {
        let target = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
          return nil
        }
        return FileOutlineItem(
          line: lineNumber,
          kind: "target",
          level: nil,
          name: target,
          text: line
        )
      }
      return nil
    }

    return declarationOutlineItem(kind: kind, rawName: rawName, line: line, lineNumber: lineNumber)
  }

  internal func markdownHeading(_ trimmed: String, lineNumber: Int) -> FileOutlineItem? {
    var level = 0
    for scalar in trimmed.unicodeScalars {
      if scalar == "#" {
        level += 1
        continue
      }
      break
    }
    guard level > 0, level <= 6 else {
      return nil
    }
    let index = trimmed.index(trimmed.startIndex, offsetBy: level)
    guard index < trimmed.endIndex, trimmed[index].isWhitespace else {
      return nil
    }
    let name = trimmed[index...].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else {
      return nil
    }
    return FileOutlineItem(
      line: lineNumber, kind: "heading", level: level, name: name, text: trimmed)
  }

  private func declarationOutlineItem(
    kind: String,
    rawName: String?,
    line: String,
    lineNumber: Int
  ) -> FileOutlineItem? {
    guard let rawName else {
      return nil
    }
    let name = cleanedOutlineName(rawName)
    guard !name.isEmpty else {
      return nil
    }
    return FileOutlineItem(
      line: lineNumber,
      kind: kind,
      level: nil,
      name: name,
      text: line.trimmingCharacters(in: .whitespaces)
    )
  }

  private func cleanedOutlineName(_ raw: String) -> String {
    let delimiters = CharacterSet(charactersIn: "({[:=<,")
    let scalarView = raw.unicodeScalars
    if let delimiter = scalarView.firstIndex(where: { delimiters.contains($0) }) {
      return String(String.UnicodeScalarView(scalarView[..<delimiter]))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t({[:=<,"))
  }

  internal func tailFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxLines = optionalInt("max_lines", in: object) ?? 200
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxLines, name: "max_lines", upperBound: 10_000)
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

    let fileSize = try handle.seekToEnd()
    let bytesToRead = min(UInt64(maxBytes), fileSize)
    let startOffset = fileSize - bytesToRead
    try handle.seek(toOffset: startOffset)
    let data = try handle.read(upToCount: Int(bytesToRead)) ?? Data()
    let fileTruncated = startOffset > 0

    var content = String(decoding: data, as: UTF8.self)
    var droppedPartialFirstLine = false
    if fileTruncated, let newline = content.firstIndex(of: "\n") {
      content.removeSubrange(content.startIndex...newline)
      droppedPartialFirstLine = true
    }

    var allLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if content.hasSuffix("\n"), !allLines.isEmpty {
      allLines.removeLast()
    }
    let selectedLines = Array(allLines.suffix(maxLines))
    let lineNumbersKnown = !fileTruncated
    let firstLineNumber = allLines.count - selectedLines.count + 1
    let selected = selectedLines.enumerated().map { index, line in
      JSONValue.object([
        "line": lineNumbersKnown ? .integer(Int64(firstLineNumber + index)) : .null,
        "tail_index": .integer(Int64(index + 1)),
        "text": .string(line),
      ])
    }

    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "encoding": .string("utf-8"),
      "max_lines": .integer(Int64(maxLines)),
      "max_bytes": .integer(Int64(maxBytes)),
      "file_size_bytes": .integer(Int64(fileSize)),
      "start_offset_bytes": .integer(Int64(startOffset)),
      "bytes_read": .integer(Int64(data.count)),
      "file_truncated": .bool(fileTruncated),
      "dropped_partial_first_line": .bool(droppedPartialFirstLine),
      "line_numbers_known": .bool(lineNumbersKnown),
      "line_count": .integer(Int64(selected.count)),
      "lines": .array(selected),
    ])
  }

  internal func hexdumpFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let offset = optionalInt("offset_bytes", in: object) ?? 0
    let maxBytes = optionalInt("max_bytes", in: object) ?? 256
    try validateBoundedNonNegative(offset, name: "offset_bytes", upperBound: 9_007_199_254_740_991)
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 65_536)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }

    let fileSize = try handle.seekToEnd()
    let offsetValue = UInt64(offset)
    let data: Data
    if offsetValue >= fileSize {
      data = Data()
    } else {
      try handle.seek(toOffset: offsetValue)
      data = try handle.read(upToCount: maxBytes) ?? Data()
    }

    let bytes = [UInt8](data)
    let lines = stride(from: 0, to: bytes.count, by: 16).map { start -> JSONValue in
      let lineBytes = Array(bytes[start..<min(start + 16, bytes.count)])
      return .object([
        "offset_bytes": .integer(Int64(offset + start)),
        "hex": .string(lineBytes.map { String(format: "%02x", $0) }.joined(separator: " ")),
        "ascii": .string(hexdumpASCII(lineBytes)),
        "byte_count": .integer(Int64(lineBytes.count)),
      ])
    }
    let nextOffset = offsetValue + UInt64(bytes.count)

    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "offset_bytes": .integer(Int64(offset)),
      "max_bytes": .integer(Int64(maxBytes)),
      "file_size_bytes": .integer(Int64(fileSize)),
      "bytes_read": .integer(Int64(bytes.count)),
      "next_offset_bytes": .integer(Int64(nextOffset)),
      "eof": .bool(nextOffset >= fileSize),
      "truncated": .bool(nextOffset < fileSize),
      "lines": .array(lines),
    ])
  }

  internal func extendedAttributes(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let includeValues = try optionalBool("include_values", in: object) ?? false
    let maxValueBytes = optionalInt("max_value_bytes", in: object) ?? 1_024
    try validateBoundedPositive(maxValueBytes, name: "max_value_bytes", upperBound: 65_536)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    let names = try extendedAttributeNames(url: url).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }

    let attributes = try names.map { name -> JSONValue in
      let size = try extendedAttributeSize(url: url, name: name)
      var object: [String: JSONValue] = [
        "name": .string(name),
        "size_bytes": .integer(Int64(size)),
      ]

      if includeValues {
        if size > maxValueBytes {
          object["value_bytes_read"] = .number(0)
          object["value_truncated"] = .bool(true)
          object["value_base64"] = .null
          object["value_utf8"] = .null
          object["value_omitted_reason"] = .string("attribute exceeds max_value_bytes")
        } else {
          let value = try extendedAttributeValue(
            url: url,
            name: name,
            size: size,
            maxBytes: maxValueBytes
          )
          object["value_bytes_read"] = .integer(Int64(value.count))
          object["value_truncated"] = .bool(false)
          object["value_base64"] = .string(value.base64EncodedString())
          object["value_utf8"] = String(data: value, encoding: .utf8).map(JSONValue.string) ?? .null
        }
      }

      return .object(object)
    }

    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "type": .string(info.type),
      "include_values": .bool(includeValues),
      "max_value_bytes": .integer(Int64(maxValueBytes)),
      "attribute_count": .integer(Int64(attributes.count)),
      "attributes": .array(attributes),
    ])
  }

  internal func removeExtendedAttribute(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let name = try requiredString("name", in: object)
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    try validateExtendedAttributeName(name)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    let namesBefore = try extendedAttributeNames(url: url).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
    guard namesBefore.contains(name) else {
      throw GatewayToolError.invalidArguments("Extended attribute does not exist: \(name)")
    }

    if !dryRun {
      try removeExtendedAttribute(url: url, name: name)
    }
    let namesAfter = try extendedAttributeNames(url: url).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
    let wouldNamesAfter = namesBefore.filter { $0 != name }

    return .object([
      "operation": .string("file.remove_xattr"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "type": .string(info.type),
      "dry_run": .bool(dryRun),
      "name": .string(name),
      "removed": .bool(!dryRun),
      "would_remove": .bool(true),
      "attributes_before": .array(namesBefore.map(JSONValue.string)),
      "attributes_after": .array(namesAfter.map(JSONValue.string)),
      "would_attributes_after": .array(wouldNamesAfter.map(JSONValue.string)),
    ])
  }

  internal func fileMetadata(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let attributes = try optionalStringArray("attributes", in: object)
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    for attribute in attributes {
      try validateMetadataAttributeName(attribute)
    }

    let arguments = ["-plist", "-", url.path]

    let result = try commandRunner.run(
      executable: "/usr/bin/mdls",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let parsed = metadataPayload(from: result)
    let metadata = filteredMetadata(parsed.metadata, attributes: attributes)

    return .object([
      "operation": .string("file.metadata"),
      "path": .string(url.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "type": .string(info.type),
      "requested_attributes": .array(attributes.map(JSONValue.string)),
      "metadata": metadata,
      "metadata_parse_error": parsed.error.map(JSONValue.string) ?? .null,
      "metadata_omitted_reason": parsed.omittedReason.map(JSONValue.string) ?? .null,
      "result": .object([
        "executable": .string(result.executable),
        "arguments": .array(result.arguments.map(JSONValue.string)),
        "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
        "timed_out": .bool(result.timedOut),
        "stderr": .string(result.stderr),
        "stderr_truncated": .bool(result.stderrTruncated),
        "stdout_truncated": .bool(result.stdoutTruncated),
      ]),
    ])
  }

  internal func readSymbolicLink(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let url = try resolvedWorkspaceURLPreservingFinalSymlink(path)

    let destination: String
    do {
      destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    } catch {
      throw GatewayToolError.invalidArguments("Path is not a symbolic link: \(path)")
    }

    let destinationURL =
      destination.hasPrefix("/")
      ? URL(fileURLWithPath: destination)
      : url.deletingLastPathComponent().appendingPathComponent(destination)
    let resolvedDestination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    let destinationContained = isWorkspaceContained(resolvedDestination)
    let destinationExists = FileManager.default.fileExists(atPath: resolvedDestination.path)

    return .object([
      "operation": .string("file.readlink"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePathPreservingSymlinks(url)),
      "destination": .string(destination),
      "destination_is_absolute": .bool(destination.hasPrefix("/")),
      "destination_workspace_contained": .bool(destinationContained),
      "destination_exists": .bool(destinationExists),
      "resolved_destination_path": .string(resolvedDestination.path),
      "destination_workspace_relative_path": destinationContained
        ? .string(workspaceRelativePath(resolvedDestination)) : .null,
    ])
  }

  internal func resolveFilePath(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let lexicalURL = try resolvedWorkspaceURLPreservingFinalSymlink(path)
    let exists = FileManager.default.fileExists(atPath: lexicalURL.path)
    let symlinkDestination = try? FileManager.default.destinationOfSymbolicLink(
      atPath: lexicalURL.path)
    let resolvedURL = exists ? lexicalURL.resolvingSymlinksInPath() : lexicalURL
    let resolvedContained = isWorkspaceContained(resolvedURL)

    return .object([
      "operation": .string("file.resolve"),
      "input_path": .string(path),
      "path": .string(lexicalURL.path),
      "workspace_relative_path": .string(workspaceRelativePathPreservingSymlinks(lexicalURL)),
      "exists": .bool(exists),
      "is_symlink": .bool(symlinkDestination != nil),
      "symlink_destination": symlinkDestination.map(JSONValue.string) ?? .null,
      "resolved_path": .string(resolvedURL.path),
      "resolved_workspace_contained": .bool(resolvedContained),
      "resolved_workspace_relative_path": resolvedContained
        ? .string(workspaceRelativePath(resolvedURL)) : .null,
    ])
  }

  internal func hashFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let algorithm = try optionalString("algorithm", in: object) ?? "sha256"
    guard algorithm == "sha256" else {
      throw GatewayToolError.invalidArguments("algorithm must be sha256.")
    }

    let url = try resolvedWorkspaceURL(path)
    let info = try fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let digest = try sha256Hex(url: url)
    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "algorithm": .string(algorithm),
      "hex": .string(digest.hex),
      "bytes_read": .integer(Int64(digest.bytesRead)),
    ])
  }

  private func sha256Hex(url: URL) throws -> (hex: String, bytesRead: Int) {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    var hasher = SHA256()
    var bytesRead = 0
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      guard !data.isEmpty else {
        break
      }
      hasher.update(data: data)
      bytesRead += data.count
    }
    return (hexString(hasher.finalize()), bytesRead)
  }

  internal func diffFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let sourcePath = try requiredString("source", in: object)
    let targetPath = try requiredString("target", in: object)
    let contextLines = optionalInt("context_lines", in: object) ?? 3
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedNonNegative(contextLines, name: "context_lines", upperBound: 1_000)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let source = try resolvedWorkspaceURL(sourcePath)
    let target = try resolvedWorkspaceURL(targetPath)
    let sourceInfo = try fileInfo(url: source)
    let targetInfo = try fileInfo(url: target)
    guard sourceInfo.type == "file" else {
      throw GatewayToolError.invalidArguments("Source is not a file: \(sourcePath)")
    }
    guard targetInfo.type == "file" else {
      throw GatewayToolError.invalidArguments("Target is not a file: \(targetPath)")
    }

    let result = try commandRunner.run(
      executable: "/usr/bin/diff",
      arguments: ["-U", "\(contextLines)", source.path, target.path],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    return .object([
      "operation": .string("file.diff"),
      "source": .object([
        "path": .string(source.path),
        "workspace_relative_path": .string(workspaceRelativePath(source)),
      ]),
      "target": .object([
        "path": .string(target.path),
        "workspace_relative_path": .string(workspaceRelativePath(target)),
      ]),
      "context_lines": .integer(Int64(contextLines)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "result": result.json,
    ])
  }

  internal func compareFileTrees(arguments object: [String: JSONValue]) throws -> JSONValue {
    let leftPath = try requiredString("left", in: object)
    let rightPath = try requiredString("right", in: object)
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let compareHashes = try optionalBool("compare_hashes", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxEntries = optionalInt("max_entries", in: object) ?? 20_000
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxHashFiles = optionalInt("max_hash_files", in: object) ?? 1_000
    let maxHashFileBytes = optionalInt("max_hash_file_bytes", in: object) ?? 10_485_760

    try validateBoundedNonNegative(maxDepth, name: "max_depth", upperBound: 50)
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 200_000)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxHashFiles, name: "max_hash_files", upperBound: 20_000)
    try validateBoundedPositive(
      maxHashFileBytes,
      name: "max_hash_file_bytes",
      upperBound: 1_073_741_824
    )

    let left = try resolvedWorkspaceURL(leftPath)
    let right = try resolvedWorkspaceURL(rightPath)
    try requireDirectory(left, originalPath: leftPath)
    try requireDirectory(right, originalPath: rightPath)

    var leftScanned = 0
    var rightScanned = 0
    var leftTruncated = false
    var rightTruncated = false
    let leftEntries = try collectTreeCompareEntries(
      root: left,
      includeHidden: includeHidden,
      maxDepth: maxDepth,
      maxEntries: maxEntries,
      scannedEntries: &leftScanned,
      truncated: &leftTruncated
    )
    let rightEntries = try collectTreeCompareEntries(
      root: right,
      includeHidden: includeHidden,
      maxDepth: maxDepth,
      maxEntries: maxEntries,
      scannedEntries: &rightScanned,
      truncated: &rightTruncated
    )

    var differenceCounts: [String: Int] = [:]
    var differences: [TreeCompareDifference] = []
    var resultTruncated = false
    var metadataMatchCount = 0
    var hashMatchCount = 0
    var hashSkippedCount = 0
    var hashFilesCompared = 0
    var hashBytesRead = 0
    let allRelativePaths = Set(leftEntries.keys).union(rightEntries.keys).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }

    for relativePath in allRelativePaths {
      guard let leftEntry = leftEntries[relativePath] else {
        recordTreeCompareDifference(
          kind: "right_only",
          relativePath: relativePath,
          left: nil,
          right: rightEntries[relativePath],
          detail: "Entry exists only under right.",
          differenceCounts: &differenceCounts,
          differences: &differences,
          maxResults: maxResults,
          resultTruncated: &resultTruncated
        )
        continue
      }
      guard let rightEntry = rightEntries[relativePath] else {
        recordTreeCompareDifference(
          kind: "left_only",
          relativePath: relativePath,
          left: leftEntry,
          right: nil,
          detail: "Entry exists only under left.",
          differenceCounts: &differenceCounts,
          differences: &differences,
          maxResults: maxResults,
          resultTruncated: &resultTruncated
        )
        continue
      }

      if leftEntry.type != rightEntry.type {
        recordTreeCompareDifference(
          kind: "type_mismatch",
          relativePath: relativePath,
          left: leftEntry,
          right: rightEntry,
          detail: "Entry types differ.",
          differenceCounts: &differenceCounts,
          differences: &differences,
          maxResults: maxResults,
          resultTruncated: &resultTruncated
        )
        continue
      }

      if leftEntry.isSymlink || rightEntry.isSymlink {
        if leftEntry.symlinkDestination == rightEntry.symlinkDestination {
          metadataMatchCount += 1
        } else {
          recordTreeCompareDifference(
            kind: "symlink_mismatch",
            relativePath: relativePath,
            left: leftEntry,
            right: rightEntry,
            detail: "Symlink destinations differ.",
            differenceCounts: &differenceCounts,
            differences: &differences,
            maxResults: maxResults,
            resultTruncated: &resultTruncated
          )
        }
        continue
      }

      guard leftEntry.type == "file" else {
        metadataMatchCount += 1
        continue
      }

      if leftEntry.sizeBytes != rightEntry.sizeBytes {
        recordTreeCompareDifference(
          kind: "size_mismatch",
          relativePath: relativePath,
          left: leftEntry,
          right: rightEntry,
          detail: "File sizes differ.",
          differenceCounts: &differenceCounts,
          differences: &differences,
          maxResults: maxResults,
          resultTruncated: &resultTruncated
        )
        continue
      }

      if compareHashes {
        guard
          let leftSize = leftEntry.sizeBytes,
          leftSize <= Int64(maxHashFileBytes),
          hashFilesCompared + 2 <= maxHashFiles
        else {
          metadataMatchCount += 1
          hashSkippedCount += 1
          continue
        }

        var hashedLeftEntry = leftEntry
        var hashedRightEntry = rightEntry
        let leftHash = try sha256Hex(url: leftEntry.url)
        let rightHash = try sha256Hex(url: rightEntry.url)
        hashedLeftEntry.sha256 = leftHash.hex
        hashedRightEntry.sha256 = rightHash.hex
        hashFilesCompared += 2
        hashBytesRead += leftHash.bytesRead + rightHash.bytesRead

        if leftHash.hex == rightHash.hex {
          hashMatchCount += 1
        } else {
          recordTreeCompareDifference(
            kind: "hash_mismatch",
            relativePath: relativePath,
            left: hashedLeftEntry,
            right: hashedRightEntry,
            detail: "SHA-256 hashes differ.",
            differenceCounts: &differenceCounts,
            differences: &differences,
            maxResults: maxResults,
            resultTruncated: &resultTruncated
          )
        }
      } else {
        metadataMatchCount += 1
      }
    }

    let differenceCount = differenceCounts.values.reduce(0, +)
    return .object([
      "operation": .string("file.compare_trees"),
      "left": .object([
        "path": .string(left.path),
        "workspace_relative_path": .string(workspaceRelativePath(left)),
        "scanned_entries": .integer(Int64(leftScanned)),
        "truncated": .bool(leftTruncated),
      ]),
      "right": .object([
        "path": .string(right.path),
        "workspace_relative_path": .string(workspaceRelativePath(right)),
        "scanned_entries": .integer(Int64(rightScanned)),
        "truncated": .bool(rightTruncated),
      ]),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_entries": .integer(Int64(maxEntries)),
      "max_results": .integer(Int64(maxResults)),
      "compare_hashes": .bool(compareHashes),
      "max_hash_files": .integer(Int64(maxHashFiles)),
      "max_hash_file_bytes": .integer(Int64(maxHashFileBytes)),
      "left_entry_count": .integer(Int64(leftEntries.count)),
      "right_entry_count": .integer(Int64(rightEntries.count)),
      "metadata_match_count": .integer(Int64(metadataMatchCount)),
      "hash_match_count": .integer(Int64(hashMatchCount)),
      "hash_skipped_count": .integer(Int64(hashSkippedCount)),
      "hash_files_compared": .integer(Int64(hashFilesCompared)),
      "hash_bytes_read": .integer(Int64(hashBytesRead)),
      "difference_count": .integer(Int64(differenceCount)),
      "difference_counts": .object(
        differenceCounts
          .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
          .reduce(into: [String: JSONValue]()) { result, pair in
            result[pair.key] = .integer(Int64(pair.value))
          }),
      "result_count": .integer(Int64(differences.count)),
      "result_truncated": .bool(resultTruncated),
      "scan_truncated": .bool(leftTruncated || rightTruncated),
      "differences": .array(differences.map(\.json)),
    ])
  }

  internal func findDuplicateFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let minSizeBytes = optionalInt("min_size_bytes", in: object) ?? 1
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxEntries = optionalInt("max_entries", in: object) ?? 20_000
    let maxHashFiles = optionalInt("max_hash_files", in: object) ?? 5_000
    let maxHashFileBytes = optionalInt("max_hash_file_bytes", in: object) ?? 10_485_760
    let maxGroups = optionalInt("max_groups", in: object) ?? 100
    let maxFilesPerGroup = optionalInt("max_files_per_group", in: object) ?? 20

    try validateBoundedNonNegative(
      minSizeBytes,
      name: "min_size_bytes",
      upperBound: 1_099_511_627_776
    )
    try validateBoundedNonNegative(maxDepth, name: "max_depth", upperBound: 50)
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 200_000)
    try validateBoundedPositive(maxHashFiles, name: "max_hash_files", upperBound: 200_000)
    try validateBoundedPositive(
      maxHashFileBytes,
      name: "max_hash_file_bytes",
      upperBound: 1_073_741_824
    )
    try validateBoundedPositive(maxGroups, name: "max_groups", upperBound: 10_000)
    try validateBoundedPositive(maxFilesPerGroup, name: "max_files_per_group", upperBound: 1_000)

    let root = try resolvedWorkspaceURL(path)
    try requireDirectory(root, originalPath: path)

    var scannedEntries = 0
    var scannedFileCount = 0
    var skippedSmallFileCount = 0
    var skippedLargeFileCount = 0
    var scanTruncated = false
    var candidates: [DuplicateFileCandidate] = []
    try collectDuplicateFileCandidates(
      directory: root,
      currentDepth: 0,
      maxDepth: maxDepth,
      includeHidden: includeHidden,
      minSizeBytes: Int64(minSizeBytes),
      maxHashFileBytes: Int64(maxHashFileBytes),
      maxEntries: maxEntries,
      scannedEntries: &scannedEntries,
      scannedFileCount: &scannedFileCount,
      skippedSmallFileCount: &skippedSmallFileCount,
      skippedLargeFileCount: &skippedLargeFileCount,
      scanTruncated: &scanTruncated,
      candidates: &candidates
    )

    let sizeBuckets = Dictionary(grouping: candidates, by: \.sizeBytes)
      .filter { $0.value.count > 1 }
    var hashBuckets: [DuplicateHashBucket] = []
    var hashedFileCount = 0
    var hashedSizeBucketCount = 0
    var hashBytesRead = 0
    var hashSkippedFileCount = 0
    var hashSkippedSizeBucketCount = 0

    for size in sizeBuckets.keys.sorted() {
      let bucket = (sizeBuckets[size] ?? []).sorted()
      guard hashedFileCount + bucket.count <= maxHashFiles else {
        hashSkippedFileCount += bucket.count
        hashSkippedSizeBucketCount += 1
        continue
      }

      hashedSizeBucketCount += 1
      var hashedByDigest: [String: [DuplicateFileCandidate]] = [:]
      for candidate in bucket {
        let digest = try sha256Hex(url: candidate.url)
        hashBytesRead += digest.bytesRead
        hashedFileCount += 1
        var hashedCandidate = candidate
        hashedCandidate.sha256 = digest.hex
        hashedByDigest[digest.hex, default: []].append(hashedCandidate)
      }

      for digest in hashedByDigest.keys.sorted() {
        guard let files = hashedByDigest[digest], files.count > 1 else {
          continue
        }
        hashBuckets.append(
          DuplicateHashBucket(
            sha256: digest,
            sizeBytes: size,
            files: files.sorted()
          ))
      }
    }

    let sortedGroups = hashBuckets.sorted()
    let duplicateGroupCount = sortedGroups.count
    let duplicateFileCount = sortedGroups.reduce(0) { $0 + $1.files.count }
    let duplicateBytes = sortedGroups.reduce(Int64(0)) {
      $0 + $1.sizeBytes * Int64($1.files.count)
    }
    let redundantBytes = sortedGroups.reduce(Int64(0)) {
      $0 + $1.sizeBytes * Int64(max($1.files.count - 1, 0))
    }
    var returnedDuplicateFileCount = 0
    var resultTruncated = sortedGroups.count > maxGroups
    let returnedGroups = sortedGroups.prefix(maxGroups).map { group -> JSONValue in
      let returnedFiles = Array(group.files.prefix(maxFilesPerGroup))
      if returnedFiles.count < group.files.count {
        resultTruncated = true
      }
      returnedDuplicateFileCount += returnedFiles.count
      return group.json(maxFiles: maxFilesPerGroup)
    }

    return .object([
      "operation": .string("file.duplicates"),
      "path": .string(root.path),
      "workspace_relative_path": .string(workspaceRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "min_size_bytes": .integer(Int64(minSizeBytes)),
      "max_depth": .integer(Int64(maxDepth)),
      "max_entries": .integer(Int64(maxEntries)),
      "max_hash_files": .integer(Int64(maxHashFiles)),
      "max_hash_file_bytes": .integer(Int64(maxHashFileBytes)),
      "max_groups": .integer(Int64(maxGroups)),
      "max_files_per_group": .integer(Int64(maxFilesPerGroup)),
      "scanned_entries": .integer(Int64(scannedEntries)),
      "scanned_file_count": .integer(Int64(scannedFileCount)),
      "candidate_file_count": .integer(Int64(candidates.count)),
      "candidate_size_bucket_count": .integer(Int64(sizeBuckets.count)),
      "skipped_small_file_count": .integer(Int64(skippedSmallFileCount)),
      "skipped_large_file_count": .integer(Int64(skippedLargeFileCount)),
      "hashed_file_count": .integer(Int64(hashedFileCount)),
      "hashed_size_bucket_count": .integer(Int64(hashedSizeBucketCount)),
      "hash_bytes_read": .integer(Int64(hashBytesRead)),
      "hash_skipped_file_count": .integer(Int64(hashSkippedFileCount)),
      "hash_skipped_size_bucket_count": .integer(Int64(hashSkippedSizeBucketCount)),
      "duplicate_group_count": .integer(Int64(duplicateGroupCount)),
      "returned_group_count": .integer(Int64(returnedGroups.count)),
      "duplicate_file_count": .integer(Int64(duplicateFileCount)),
      "returned_duplicate_file_count": .integer(Int64(returnedDuplicateFileCount)),
      "duplicate_bytes": .integer(Int64(duplicateBytes)),
      "redundant_bytes_if_one_kept_per_group": .integer(Int64(redundantBytes)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "groups": .array(returnedGroups),
    ])
  }

  internal func downloadFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let urlString = try requiredString("url", in: object)
    let path = try requiredString("path", in: object)
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmDownload = try optionalBool("confirm_download", in: object) ?? false
    guard dryRun || confirmDownload else {
      throw GatewayToolError.invalidArguments(
        "file.download requires confirm_download=true when dry_run is false.")
    }

    let followRedirects = try optionalBool("follow_redirects", in: object) ?? false
    let maxRedirects = optionalInt("max_redirects", in: object) ?? 5
    let connectTimeoutSeconds = optionalInt("connect_timeout_seconds", in: object) ?? 5
    let timeout = optionalInt("timeout_ms", in: object) ?? 30_000
    let maxDownloadBytes = optionalInt("max_download_bytes", in: object) ?? 10_485_760
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? min(configuration.policy.maxOutputBytes, 16_384)
    let validatedURL = try validateHTTPCheckURL(urlString)
    try validateBoundedPositive(maxRedirects, name: "max_redirects", upperBound: 20)
    try validateBoundedPositive(
      connectTimeoutSeconds, name: "connect_timeout_seconds", upperBound: 60)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(
      maxDownloadBytes, name: "max_download_bytes", upperBound: 104_857_600)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let destinationURL = try resolvedWorkspaceURLPreservingFinalSymlink(path)
    let parentURL = destinationURL.deletingLastPathComponent()
    let fileManager = FileManager.default
    var parentIsDirectory = ObjCBool(false)
    let parentExists = fileManager.fileExists(
      atPath: parentURL.path, isDirectory: &parentIsDirectory)
    if parentExists {
      guard parentIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Download parent is not a directory: \(path)")
      }
    } else if !createDirectories {
      throw GatewayToolError.invalidArguments(
        "Download parent directory does not exist; set create_directories=true to create it.")
    }

    var destinationIsDirectory = ObjCBool(false)
    let destinationExists = fileManager.fileExists(
      atPath: destinationURL.path,
      isDirectory: &destinationIsDirectory
    )
    if destinationExists {
      let destinationInfo = try fileInfo(url: destinationURL)
      guard !destinationInfo.isSymlink else {
        throw GatewayToolError.invalidArguments("Download destination is a symlink: \(path)")
      }
      guard !destinationIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Download destination is a directory: \(path)")
      }
      guard overwrite else {
        throw GatewayToolError.invalidArguments(
          "Download destination already exists; set overwrite=true to replace it.")
      }
    }

    let tempURL = parentURL.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).computer-mcp-download.tmp"
    )
    if fileManager.fileExists(atPath: tempURL.path) {
      throw GatewayToolError.invalidArguments(
        "Temporary download path already exists: \(workspaceRelativePathPreservingSymlinks(tempURL))"
      )
    }

    let marker = "__COMPUTER_MCP_FILE_DOWNLOAD_META__"
    var arguments = [
      "--fail",
      "--silent",
      "--show-error",
      "--max-time",
      "\(max(1, timeout / 1000))",
      "--connect-timeout",
      "\(connectTimeoutSeconds)",
      "--max-filesize",
      "\(maxDownloadBytes)",
    ]
    if followRedirects {
      arguments += ["--location", "--max-redirs", "\(maxRedirects)"]
    }
    arguments += [
      "--output",
      tempURL.path,
      "--write-out",
      "\n\(marker)\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nredirect_url=%{redirect_url}\ntime_total=%{time_total}\nsize_download=%{size_download}\n",
      validatedURL.absoluteString,
    ]

    var result: JSONValue = .null
    var http: HTTPCheckOutput?
    var downloaded = false
    var downloadedFile: JSONValue = .null
    var downloadedSizeBytes: Int64?

    if !dryRun {
      if !parentExists {
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
      }
      let commandResult = try commandRunner.run(
        executable: "/usr/bin/curl",
        arguments: arguments,
        workingDirectory: configuration.workspaceDirectory,
        environment: [:],
        timeoutMilliseconds: timeout,
        maxOutputBytes: maxOutputBytes
      )
      result = networkCommandSummary(commandResult)
      let parsed = parseHTTPCheckOutput(
        commandResult.stdout,
        marker: marker,
        includeBody: false,
        maxBodyBytes: 0,
        stdoutTruncated: commandResult.stdoutTruncated
      )
      http = parsed

      if commandResult.exitCode == 0 && !commandResult.timedOut {
        do {
          let tempInfo = try fileInfo(url: tempURL)
          guard !tempInfo.isSymlink, tempInfo.type == "file" else {
            try? fileManager.removeItem(at: tempURL)
            throw GatewayToolError.executionFailed("Download temp path is not a regular file.")
          }
          let size = tempInfo.size ?? 0
          guard size <= Int64(maxDownloadBytes) else {
            try? fileManager.removeItem(at: tempURL)
            throw GatewayToolError.executionFailed(
              "Downloaded file exceeds max_download_bytes.")
          }
          if destinationExists && overwrite {
            try fileManager.removeItem(at: destinationURL)
          }
          try fileManager.moveItem(at: tempURL, to: destinationURL)
          let finalInfo = try fileInfo(url: destinationURL)
          downloaded = true
          downloadedSizeBytes = finalInfo.size
          downloadedFile = finalInfo.json
        } catch {
          try? fileManager.removeItem(at: tempURL)
          throw error
        }
      } else {
        try? fileManager.removeItem(at: tempURL)
      }
    }

    return .object([
      "operation": .string("file.download"),
      "url": .string(validatedURL.absoluteString),
      "scheme": .string(validatedURL.scheme ?? ""),
      "host": .string(validatedURL.host ?? ""),
      "destination": .object([
        "path": .string(destinationURL.path),
        "workspace_relative_path": .string(workspaceRelativePathPreservingSymlinks(destinationURL)),
        "exists": .bool(destinationExists),
        "would_create_parent_directories": .bool(!parentExists && createDirectories),
        "would_overwrite": .bool(destinationExists && overwrite),
      ]),
      "temporary_path": .string(tempURL.path),
      "temporary_workspace_relative_path": .string(
        workspaceRelativePathPreservingSymlinks(tempURL)),
      "argv": .array(arguments.map(JSONValue.string)),
      "confirm_download": .bool(confirmDownload),
      "create_directories": .bool(createDirectories),
      "downloaded": .bool(downloaded),
      "downloaded_file": downloadedFile,
      "downloaded_size_bytes": downloadedSizeBytes.map { .integer(Int64($0)) } ?? .null,
      "dry_run": .bool(dryRun),
      "follow_redirects": .bool(followRedirects),
      "http_code": http?.httpCode.map { .integer(Int64($0)) } ?? .null,
      "url_effective": http?.urlEffective.map(JSONValue.string) ?? .null,
      "content_type": http?.contentType.map(JSONValue.string) ?? .null,
      "redirect_url": http?.redirectURL.map(JSONValue.string) ?? .null,
      "time_total_seconds": http?.timeTotal.map { .number($0) } ?? .null,
      "size_download_bytes": http?.sizeDownload.map { .number($0) } ?? .null,
      "max_download_bytes": .integer(Int64(maxDownloadBytes)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "max_redirects": .integer(Int64(maxRedirects)),
      "overwrite": .bool(overwrite),
      "result": result,
      "would_download": .bool(true),
    ])
  }

  internal func writeFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let content = try requiredString("content", in: object)
    let overwrite = try optionalBool("overwrite", in: object) ?? true
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let includePreview = try optionalBool("include_preview", in: object) ?? dryRun
    let previewMaxBytes = optionalInt("preview_max_bytes", in: object) ?? 8_192
    try validateBoundedPositive(previewMaxBytes, name: "preview_max_bytes", upperBound: 1_048_576)
    let url = try resolvedWorkspaceURL(path)
    let parent = url.deletingLastPathComponent()
    let fileManager = FileManager.default

    var parentIsDirectory: ObjCBool = false
    let parentExists = fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory)
    if parentExists {
      guard parentIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Parent path is not a directory: \(path)")
      }
    } else {
      guard createDirectories else {
        throw GatewayToolError.invalidArguments("Parent directory does not exist: \(path)")
      }
    }

    if createDirectories && !dryRun {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }

    var isDirectory: ObjCBool = false
    let existed = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if existed {
      guard !isDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Path is a directory: \(path)")
      }
    }

    if !overwrite && existed {
      throw GatewayToolError.invalidArguments("Refusing to overwrite existing file: \(path)")
    }

    let data = Data(content.utf8)
    let existingSizeBytes = try existingFileSizeBytes(url: url, existed: existed)
    if !dryRun {
      try data.write(to: url, options: .atomic)
    }

    var payload: [String: JSONValue] = [
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "dry_run": .bool(dryRun),
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
      let contentPreview = utf8Preview(content, maxBytes: previewMaxBytes)
      payload["preview"] = .object([
        "preview_max_bytes": .integer(Int64(previewMaxBytes)),
        "content": .string(contentPreview.text),
        "content_truncated": .bool(contentPreview.truncated),
      ])
    }

    return .object(payload)
  }

  internal func writeFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let entries = try requiredObjectArray("files", in: object)
    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmWrite = try optionalBool("confirm_write", in: object) ?? false
    let includePreview = try optionalBool("include_preview", in: object) ?? dryRun
    let previewMaxBytes = optionalInt("preview_max_bytes", in: object) ?? 8_192
    try validateBoundedPositive(previewMaxBytes, name: "preview_max_bytes", upperBound: 1_048_576)
    guard dryRun || confirmWrite else {
      throw GatewayToolError.invalidArguments(
        "file.write_files requires confirm_write=true when dry_run is false.")
    }
    guard !entries.isEmpty else {
      throw GatewayToolError.invalidArguments("files must not be empty.")
    }
    guard entries.count <= 50 else {
      throw GatewayToolError.invalidArguments("files must contain at most 50 entries.")
    }

    let fileManager = FileManager.default
    var seenPaths = Set<String>()
    var plans: [FileWritePlan] = []
    var totalBytesToWrite = 0

    for (index, entry) in entries.enumerated() {
      let path = try requiredString("path", in: entry)
      let content = try requiredStringAllowingEmpty("content", in: entry)
      let data = Data(content.utf8)
      guard data.count <= configuration.policy.maxOutputBytes else {
        throw GatewayToolError.invalidArguments(
          "files[\(index)].content exceeds policy.max_output_bytes (\(configuration.policy.maxOutputBytes))."
        )
      }
      let url = try resolvedWorkspaceURL(path)
      guard seenPaths.insert(url.path).inserted else {
        throw GatewayToolError.invalidArguments("Duplicate output path: \(path)")
      }
      let parent = url.deletingLastPathComponent()

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
        throw GatewayToolError.invalidArguments(
          "Refusing to overwrite existing file: \(path)")
      }

      let existingSizeBytes = try existingFileSizeBytes(url: url, existed: existed)
      totalBytesToWrite += data.count
      plans.append(
        FileWritePlan(
          requestedPath: path,
          url: url,
          workspaceRelativePath: workspaceRelativePath(url),
          parent: parent,
          parentExists: parentExists,
          existed: existed,
          existingSizeBytes: existingSizeBytes,
          data: data,
          preview: utf8Preview(content, maxBytes: previewMaxBytes)
        ))
    }

    if !dryRun {
      for plan in plans {
        if createDirectories && !plan.parentExists {
          try fileManager.createDirectory(
            at: plan.parent,
            withIntermediateDirectories: true
          )
        }
        try plan.data.write(to: plan.url, options: .atomic)
      }
    }

    return .object([
      "operation": .string("file.write_files"),
      "dry_run": .bool(dryRun),
      "confirm_write": .bool(confirmWrite),
      "overwrite": .bool(overwrite),
      "create_directories": .bool(createDirectories),
      "requested_count": .integer(Int64(entries.count)),
      "file_count": .integer(Int64(plans.count)),
      "total_bytes_to_write": .integer(Int64(totalBytesToWrite)),
      "total_bytes_written": .integer(Int64(dryRun ? 0 : totalBytesToWrite)),
      "written": .bool(!dryRun),
      "files": .array(
        plans.map {
          $0.json(
            dryRun: dryRun,
            overwrite: overwrite,
            createDirectories: createDirectories,
            includePreview: includePreview,
            previewMaxBytes: previewMaxBytes
          )
        }),
    ])
  }

  internal func appendFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let content = try requiredString("content", in: object)
    let createIfMissing = try optionalBool("create_if_missing", in: object) ?? true
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let appendNewline = try optionalBool("append_newline", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let includePreview = try optionalBool("include_preview", in: object) ?? dryRun
    let previewMaxBytes = optionalInt("preview_max_bytes", in: object) ?? 8_192
    try validateBoundedPositive(previewMaxBytes, name: "preview_max_bytes", upperBound: 1_048_576)
    let url = try resolvedWorkspaceURL(path)
    let parent = url.deletingLastPathComponent()
    let fileManager = FileManager.default

    let finalContent = appendNewline ? "\(content)\n" : content
    let data = Data(finalContent.utf8)
    guard data.count <= configuration.policy.maxOutputBytes else {
      throw GatewayToolError.invalidArguments(
        "content exceeds policy.max_output_bytes (\(configuration.policy.maxOutputBytes)).")
    }

    var parentIsDirectory: ObjCBool = false
    let parentExists = fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory)
    if parentExists {
      guard parentIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Parent path is not a directory: \(path)")
      }
    } else {
      guard createDirectories else {
        throw GatewayToolError.invalidArguments("Parent directory does not exist: \(path)")
      }
    }

    if createDirectories && !dryRun {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }

    var isDirectory: ObjCBool = false
    let existed = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if existed {
      guard !isDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Path is a directory: \(path)")
      }
    } else {
      guard createIfMissing else {
        throw GatewayToolError.invalidArguments("Path does not exist: \(path)")
      }
      if !dryRun {
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
          throw GatewayToolError.executionFailed("Failed to create file: \(path)")
        }
      }
    }

    let sizeBefore: UInt64
    if dryRun {
      sizeBefore = try existingFileSizeBytes(url: url, existed: existed)
    } else {
      let handle = try FileHandle(forWritingTo: url)
      defer {
        try? handle.close()
      }
      sizeBefore = try handle.seekToEnd()
      try handle.write(contentsOf: data)
    }
    let sizeAfter = sizeBefore + UInt64(data.count)

    var payload: [String: JSONValue] = [
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "dry_run": .bool(dryRun),
      "created": .bool(!dryRun && !existed),
      "would_create": .bool(!existed),
      "would_create_parent_directories": .bool(!parentExists && createDirectories),
      "append_newline": .bool(appendNewline),
      "bytes_to_append": .integer(Int64(data.count)),
      "bytes_appended": .integer(Int64(dryRun ? 0 : data.count)),
      "size_before_bytes": .integer(Int64(sizeBefore)),
      "size_after_bytes": .integer(Int64(sizeAfter)),
      "would_change": .bool(!data.isEmpty),
      "changed": .bool(!dryRun && !data.isEmpty),
    ]

    if includePreview {
      let contentPreview = utf8Preview(finalContent, maxBytes: previewMaxBytes)
      payload["preview"] = .object([
        "preview_max_bytes": .integer(Int64(previewMaxBytes)),
        "content": .string(contentPreview.text),
        "content_truncated": .bool(contentPreview.truncated),
      ])
    }

    return .object(payload)
  }

  internal func existingFileSizeBytes(url: URL, existed: Bool) throws -> UInt64 {
    guard existed else {
      return 0
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let number = attributes[.size] as? NSNumber else {
      return 0
    }
    return number.uint64Value
  }

  internal func replaceTextInFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let search = try requiredString("search", in: object)
    let replacement = try requiredStringAllowingEmpty("replacement", in: object)
    let replaceAll = try optionalBool("replace_all", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let includePreview = try optionalBool("include_preview", in: object) ?? dryRun
    let previewMaxBytes = optionalInt("preview_max_bytes", in: object) ?? 8_192
    try validateBoundedPositive(previewMaxBytes, name: "preview_max_bytes", upperBound: 1_048_576)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    let expectedReplacements = optionalInt("expected_replacements", in: object)
    if let expectedReplacements {
      try validateBoundedNonNegative(
        expectedReplacements,
        name: "expected_replacements",
        upperBound: 1_000_000
      )
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
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }
    guard let content = String(data: data, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("File is not valid UTF-8: \(path)")
    }

    let totalMatches = countOccurrences(of: search, in: content)
    let replacements = replaceAll ? totalMatches : min(totalMatches, 1)
    if let expectedReplacements, expectedReplacements != replacements {
      throw GatewayToolError.invalidArguments(
        "Expected \(expectedReplacements) replacements but would perform \(replacements).")
    }

    let updatedContent: String
    if replacements == 0 {
      updatedContent = content
    } else if replaceAll {
      updatedContent = content.replacingOccurrences(of: search, with: replacement)
    } else if let range = content.range(of: search) {
      var copy = content
      copy.replaceSubrange(range, with: replacement)
      updatedContent = copy
    } else {
      updatedContent = content
    }

    let updatedData = Data(updatedContent.utf8)
    let wouldChange = updatedContent != content
    if !dryRun && wouldChange {
      try updatedData.write(to: url, options: .atomic)
    }

    var payload: [String: JSONValue] = [
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "encoding": .string("utf-8"),
      "replace_all": .bool(replaceAll),
      "dry_run": .bool(dryRun),
      "total_matches": .integer(Int64(totalMatches)),
      "replacements": .integer(Int64(replacements)),
      "would_change": .bool(wouldChange),
      "changed": .bool(!dryRun && wouldChange),
      "bytes_before": .integer(Int64(data.count)),
      "bytes_after": .integer(Int64(updatedData.count)),
    ]

    if includePreview {
      let searchPreview = utf8Preview(search, maxBytes: previewMaxBytes)
      let replacementPreview = utf8Preview(replacement, maxBytes: previewMaxBytes)
      payload["preview"] = .object([
        "preview_max_bytes": .integer(Int64(previewMaxBytes)),
        "search": .string(searchPreview.text),
        "search_truncated": .bool(searchPreview.truncated),
        "replacement": .string(replacementPreview.text),
        "replacement_truncated": .bool(replacementPreview.truncated),
      ])
    }

    return .object(payload)
  }

  internal func insertTextInFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let line = optionalInt("line", in: object) ?? 1
    try validateBoundedPositive(line, name: "line", upperBound: 10_000_000)
    let contentToInsert = try requiredString("content", in: object)
    let position = try fileInsertPosition(try optionalString("position", in: object) ?? "before")
    let appendNewline = try optionalBool("append_newline", in: object) ?? true
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let includePreview = try optionalBool("include_preview", in: object) ?? dryRun
    let previewMaxBytes = optionalInt("preview_max_bytes", in: object) ?? 8_192
    try validateBoundedPositive(previewMaxBytes, name: "preview_max_bytes", upperBound: 1_048_576)
    let expectedLine = try optionalString("expected_line", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)

    let insertData = Data(contentToInsert.utf8)
    guard insertData.count <= configuration.policy.maxOutputBytes else {
      throw GatewayToolError.invalidArguments(
        "content exceeds policy.max_output_bytes (\(configuration.policy.maxOutputBytes)).")
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
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }
    guard let content = String(data: data, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("File is not valid UTF-8: \(path)")
    }

    let lineStarts = existingLineStarts(in: content)
    guard lineStarts.indices.contains(line - 1) else {
      throw GatewayToolError.invalidArguments(
        "line must be between 1 and \(max(lineStarts.count, 1)).")
    }
    let targetLine = lineText(at: line, starts: lineStarts, in: content)
    if let expectedLine, expectedLine != targetLine {
      throw GatewayToolError.invalidArguments("expected_line does not match target line.")
    }

    let insertionIndex: String.Index
    switch position {
    case .before:
      insertionIndex = lineStarts[line - 1]
    case .after:
      insertionIndex = line < lineStarts.count ? lineStarts[line] : content.endIndex
    }

    var insertion = contentToInsert
    if appendNewline, !insertion.hasSuffix("\n") {
      insertion += "\n"
    }
    if position == .after, line == lineStarts.count, !content.isEmpty, !content.hasSuffix("\n") {
      insertion = "\n\(insertion)"
    }

    var updatedContent = content
    updatedContent.insert(contentsOf: insertion, at: insertionIndex)
    let updatedData = Data(updatedContent.utf8)
    let wouldChange = updatedContent != content
    if !dryRun && wouldChange {
      try updatedData.write(to: url, options: .atomic)
    }

    var payload: [String: JSONValue] = [
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "encoding": .string("utf-8"),
      "line": .integer(Int64(line)),
      "position": .string(position.rawValue),
      "append_newline": .bool(appendNewline),
      "dry_run": .bool(dryRun),
      "line_count_before": .integer(Int64(lineStarts.count)),
      "bytes_inserted": .integer(Int64(Data(insertion.utf8).count)),
      "bytes_before": .integer(Int64(data.count)),
      "bytes_after": .integer(Int64(updatedData.count)),
      "would_change": .bool(wouldChange),
      "changed": .bool(!dryRun && wouldChange),
    ]

    if includePreview {
      let targetLinePreview = utf8Preview(targetLine, maxBytes: previewMaxBytes)
      let insertedContentPreview = utf8Preview(insertion, maxBytes: previewMaxBytes)
      payload["preview"] = .object([
        "preview_max_bytes": .integer(Int64(previewMaxBytes)),
        "target_line": .string(targetLinePreview.text),
        "target_line_truncated": .bool(targetLinePreview.truncated),
        "inserted_content": .string(insertedContentPreview.text),
        "inserted_content_truncated": .bool(insertedContentPreview.truncated),
      ])
    }

    return .object(payload)
  }

  internal func replaceLinesInFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    guard let startLine = optionalInt("start_line", in: object) else {
      throw GatewayToolError.invalidArguments("Missing required integer argument: start_line")
    }
    guard let endLine = optionalInt("end_line", in: object) else {
      throw GatewayToolError.invalidArguments("Missing required integer argument: end_line")
    }
    try validateBoundedPositive(startLine, name: "start_line", upperBound: 10_000_000)
    try validateBoundedPositive(endLine, name: "end_line", upperBound: 10_000_000)
    guard endLine >= startLine else {
      throw GatewayToolError.invalidArguments(
        "end_line must be greater than or equal to start_line.")
    }
    let replacementContent = try requiredStringAllowingEmpty("content", in: object)
    let appendNewline = try optionalBool("append_newline", in: object) ?? true
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let includePreview = try optionalBool("include_preview", in: object) ?? dryRun
    let previewMaxBytes = optionalInt("preview_max_bytes", in: object) ?? 8_192
    try validateBoundedPositive(previewMaxBytes, name: "preview_max_bytes", upperBound: 1_048_576)
    let expectedContent: String?
    if let expectedValue = object["expected_content"] {
      guard let value = expectedValue.stringValue else {
        throw GatewayToolError.invalidArguments("expected_content must be a string.")
      }
      expectedContent = value
    } else {
      expectedContent = nil
    }
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)

    let replacementData = Data(replacementContent.utf8)
    guard replacementData.count <= configuration.policy.maxOutputBytes else {
      throw GatewayToolError.invalidArguments(
        "content exceeds policy.max_output_bytes (\(configuration.policy.maxOutputBytes)).")
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
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }
    guard let content = String(data: data, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("File is not valid UTF-8: \(path)")
    }

    let lineStarts = existingLineStarts(in: content)
    guard !lineStarts.isEmpty else {
      throw GatewayToolError.invalidArguments("File has no replaceable lines: \(path)")
    }
    guard lineStarts.indices.contains(startLine - 1),
      lineStarts.indices.contains(endLine - 1)
    else {
      throw GatewayToolError.invalidArguments(
        "line range must be between 1 and \(lineStarts.count).")
    }

    let rangeStart = lineStarts[startLine - 1]
    let rangeEnd = endLine < lineStarts.count ? lineStarts[endLine] : content.endIndex
    let originalContent = String(content[rangeStart..<rangeEnd])
    if let expectedContent, expectedContent != originalContent {
      throw GatewayToolError.invalidArguments("expected_content does not match selected lines.")
    }

    var replacement = replacementContent
    if appendNewline, !replacement.isEmpty, !replacement.hasSuffix("\n") {
      replacement += "\n"
    }

    var updatedContent = content
    updatedContent.replaceSubrange(rangeStart..<rangeEnd, with: replacement)
    let updatedData = Data(updatedContent.utf8)
    let wouldChange = updatedContent != content
    if !dryRun && wouldChange {
      try updatedData.write(to: url, options: .atomic)
    }

    var payload: [String: JSONValue] = [
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "encoding": .string("utf-8"),
      "start_line": .integer(Int64(startLine)),
      "end_line": .integer(Int64(endLine)),
      "append_newline": .bool(appendNewline),
      "dry_run": .bool(dryRun),
      "line_count_before": .integer(Int64(lineStarts.count)),
      "deleted_line_count": .integer(Int64(endLine - startLine + 1)),
      "inserted_line_count": .integer(Int64(existingLineStarts(in: replacement).count)),
      "bytes_replaced": .integer(Int64(Data(originalContent.utf8).count)),
      "bytes_inserted": .integer(Int64(Data(replacement.utf8).count)),
      "bytes_before": .integer(Int64(data.count)),
      "bytes_after": .integer(Int64(updatedData.count)),
      "would_change": .bool(wouldChange),
      "changed": .bool(!dryRun && wouldChange),
    ]

    if includePreview {
      let selectedPreview = utf8Preview(originalContent, maxBytes: previewMaxBytes)
      let replacementPreview = utf8Preview(replacement, maxBytes: previewMaxBytes)
      payload["preview"] = .object([
        "preview_max_bytes": .integer(Int64(previewMaxBytes)),
        "selected_content": .string(selectedPreview.text),
        "selected_truncated": .bool(selectedPreview.truncated),
        "replacement_content": .string(replacementPreview.text),
        "replacement_truncated": .bool(replacementPreview.truncated),
      ])
    }

    return .object(payload)
  }

  internal func touchFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let createIfMissing = try optionalBool("create_if_missing", in: object) ?? true
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let url = try resolvedWorkspaceURL(path)
    let parent = url.deletingLastPathComponent()
    var parentIsDirectory: ObjCBool = false
    let parentExists = FileManager.default.fileExists(
      atPath: parent.path,
      isDirectory: &parentIsDirectory
    )

    if createDirectories {
      if parentExists && !parentIsDirectory.boolValue {
        throw GatewayToolError.invalidArguments("Parent path is not a directory: \(path)")
      }
      if !dryRun {
        try FileManager.default.createDirectory(
          at: parent,
          withIntermediateDirectories: true
        )
      }
    } else {
      guard parentExists && parentIsDirectory.boolValue
      else {
        throw GatewayToolError.invalidArguments("Parent directory does not exist: \(path)")
      }
    }

    let now = Date()
    var isDirectory: ObjCBool = false
    let existed = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if existed {
      guard !isDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Path is a directory: \(path)")
      }
      if !dryRun {
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
      }
    } else {
      guard createIfMissing else {
        throw GatewayToolError.invalidArguments("Path does not exist: \(path)")
      }
      if !dryRun {
        guard
          FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.modificationDate: now]
          )
        else {
          throw GatewayToolError.executionFailed("Failed to create file: \(path)")
        }
      }
    }

    var payload: [String: JSONValue] = [
      "operation": .string("file.touch"),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "dry_run": .bool(dryRun),
      "create_if_missing": .bool(createIfMissing),
      "create_directories": .bool(createDirectories),
      "existed": .bool(existed),
      "created": .bool(!dryRun && !existed),
      "modified": .bool(!dryRun),
      "would_create": .bool(!existed),
      "would_update_modification_time": .bool(existed),
      "would_create_parent_directories": .bool(createDirectories && !parentExists),
    ]
    payload["result"] = dryRun ? .null : try fileInfo(url: url).json
    return .object(payload)
  }

  internal func makeDirectory(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let intermediateDirectories = try optionalBool("intermediate_directories", in: object) ?? true
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let url = try resolvedWorkspaceURL(path)
    var isDirectory: ObjCBool = false

    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Path exists and is not a directory: \(path)")
      }
      return .object([
        "path": .string(url.path),
        "workspace_relative_path": .string(workspaceRelativePath(url)),
        "dry_run": .bool(dryRun),
        "intermediate_directories": .bool(intermediateDirectories),
        "created": .bool(false),
        "would_create": .bool(false),
        "would_create_parent_directories": .bool(false),
      ])
    }

    let parent = url.deletingLastPathComponent()
    var parentIsDirectory: ObjCBool = false
    let parentExists = FileManager.default.fileExists(
      atPath: parent.path,
      isDirectory: &parentIsDirectory
    )
    if parentExists {
      guard parentIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Parent path is not a directory: \(path)")
      }
    } else {
      guard intermediateDirectories else {
        throw GatewayToolError.invalidArguments("Parent directory does not exist: \(path)")
      }
    }

    if !dryRun {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: intermediateDirectories
      )
    }
    return .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath(url)),
      "dry_run": .bool(dryRun),
      "intermediate_directories": .bool(intermediateDirectories),
      "created": .bool(!dryRun),
      "would_create": .bool(true),
      "would_create_parent_directories": .bool(!parentExists),
    ])
  }

  internal func copyFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let sourcePath = try requiredString("source", in: object)
    let destinationPath = try requiredString("destination", in: object)
    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let source = try resolvedWorkspaceURL(sourcePath)
    let destination = try resolvedWorkspaceURL(destinationPath)

    guard FileManager.default.fileExists(atPath: source.path) else {
      throw GatewayToolError.invalidArguments("Source does not exist: \(sourcePath)")
    }
    let preparation = try inspectDestinationPreparation(
      destination,
      originalPath: destinationPath,
      overwrite: overwrite,
      createDirectories: createDirectories
    )
    if !dryRun {
      try prepareDestination(
        destination,
        originalPath: destinationPath,
        overwrite: overwrite,
        createDirectories: createDirectories
      )
      try FileManager.default.copyItem(at: source, to: destination)
    }
    return try organizationResult(
      operation: "file.copy",
      source: source,
      destination: destination,
      dryRun: dryRun,
      overwritten: !dryRun && preparation.destinationExists && overwrite,
      wouldOverwrite: preparation.destinationExists && overwrite,
      wouldCreateParentDirectories: preparation.wouldCreateParentDirectories,
      performedKey: "copied",
      wouldPerformKey: "would_copy"
    )
  }

  internal func moveFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let sourcePath = try requiredString("source", in: object)
    let destinationPath = try requiredString("destination", in: object)
    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let source = try resolvedWorkspaceURL(sourcePath)
    let destination = try resolvedWorkspaceURL(destinationPath)

    guard FileManager.default.fileExists(atPath: source.path) else {
      throw GatewayToolError.invalidArguments("Source does not exist: \(sourcePath)")
    }
    let preparation = try inspectDestinationPreparation(
      destination,
      originalPath: destinationPath,
      overwrite: overwrite,
      createDirectories: createDirectories
    )
    if !dryRun {
      try prepareDestination(
        destination,
        originalPath: destinationPath,
        overwrite: overwrite,
        createDirectories: createDirectories
      )
      try FileManager.default.moveItem(at: source, to: destination)
    }
    return try organizationResult(
      operation: "file.move",
      source: source,
      destination: destination,
      dryRun: dryRun,
      overwritten: !dryRun && preparation.destinationExists && overwrite,
      wouldOverwrite: preparation.destinationExists && overwrite,
      wouldCreateParentDirectories: preparation.wouldCreateParentDirectories,
      performedKey: "moved",
      wouldPerformKey: "would_move"
    )
  }

  internal func createSymbolicLink(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let destination = try requiredString("destination", in: object)
    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let allowExternalDestination =
      try optionalBool("allow_external_destination", in: object) ?? false
    try validateSymbolicLinkDestination(destination)

    let link = try resolvedWorkspaceURLPreservingFinalSymlink(path)
    let destinationURL =
      destination.hasPrefix("/")
      ? URL(fileURLWithPath: destination)
      : link.deletingLastPathComponent().appendingPathComponent(destination)
    let resolvedDestination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    let destinationContained = isWorkspaceContained(resolvedDestination)
    guard destinationContained || allowExternalDestination else {
      throw GatewayToolError.invalidArguments(
        "[policy.workspace_denied] destination resolves outside workspace; set allow_external_destination to true to allow it."
      )
    }

    let preparation = try inspectDestinationPreparation(
      link,
      originalPath: path,
      overwrite: overwrite,
      createDirectories: createDirectories,
      treatsBrokenSymlinkAsExisting: true
    )
    if !dryRun {
      try prepareSymlinkDestination(
        link,
        originalPath: path,
        overwrite: overwrite,
        createDirectories: createDirectories
      )
      try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: destination)
    }

    return .object([
      "operation": .string("file.symlink"),
      "path": .string(link.path),
      "workspace_relative_path": .string(workspaceRelativePathPreservingSymlinks(link)),
      "dry_run": .bool(dryRun),
      "destination": .string(destination),
      "destination_is_absolute": .bool(destination.hasPrefix("/")),
      "destination_workspace_contained": .bool(destinationContained),
      "allow_external_destination": .bool(allowExternalDestination),
      "destination_exists": .bool(FileManager.default.fileExists(atPath: resolvedDestination.path)),
      "resolved_destination_path": .string(resolvedDestination.path),
      "destination_workspace_relative_path": destinationContained
        ? .string(workspaceRelativePath(resolvedDestination)) : .null,
      "overwritten": .bool(!dryRun && preparation.destinationExists && overwrite),
      "would_overwrite": .bool(preparation.destinationExists && overwrite),
      "would_create_parent_directories": .bool(preparation.wouldCreateParentDirectories),
      "created": .bool(!dryRun),
      "would_create": .bool(true),
    ])
  }

  internal func trashFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let dryRun = try optionalBool("dry_run", in: object) ?? false
    let url = try resolvedWorkspaceURL(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw GatewayToolError.invalidArguments("Path does not exist: \(path)")
    }

    var resultingURL: NSURL?
    if !dryRun {
      try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }
    return .object([
      "operation": .string("file.trash"),
      "source": .string(url.path),
      "source_workspace_relative_path": .string(workspaceRelativePath(url)),
      "dry_run": .bool(dryRun),
      "trashed": .bool(!dryRun),
      "would_trash": .bool(true),
      "trashed_path": resultingURL.map { .string($0.path ?? "") } ?? .null,
    ])
  }

  private func collectDirectoryEntries(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxEntries: Int,
    entries: inout [ListedFile],
    truncated: inout Bool
  ) throws {
    guard !truncated else {
      return
    }

    let children = try sortedDirectoryChildren(directory, includeHidden: includeHidden)

    for child in children {
      if entries.count >= maxEntries {
        truncated = true
        return
      }

      let resolved = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
      let info = try fileInfo(url: resolved)
      entries.append(
        ListedFile(
          name: child.lastPathComponent,
          relativePath: info.workspaceRelativePath,
          info: info
        ))

      if currentDepth < maxDepth && info.type == "directory" && !info.isSymlink {
        try collectDirectoryEntries(
          directory: resolved,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxEntries: maxEntries,
          entries: &entries,
          truncated: &truncated
        )
      }
    }
  }

  private func fileTreeNode(
    url: URL,
    depth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    directoriesOnly: Bool,
    maxEntries: Int,
    emitted: inout Int,
    truncated: inout Bool
  ) throws -> JSONValue {
    let info = try fileInfo(url: url)
    emitted += 1

    var object: [String: JSONValue] = [
      "name": .string(url.lastPathComponent.isEmpty ? "." : url.lastPathComponent),
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "type": .string(info.type),
      "depth": .integer(Int64(depth)),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "is_symlink": .bool(info.isSymlink),
    ]

    if info.type == "directory", !info.isSymlink, depth < maxDepth, !truncated {
      var children: [JSONValue] = []
      for child in try sortedDirectoryChildren(url, includeHidden: includeHidden) {
        guard emitted < maxEntries else {
          truncated = true
          break
        }

        let resolved = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
        let childInfo = try fileInfo(url: resolved)
        if directoriesOnly && childInfo.type != "directory" {
          continue
        }

        children.append(
          try fileTreeNode(
            url: resolved,
            depth: depth + 1,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            directoriesOnly: directoriesOnly,
            maxEntries: maxEntries,
            emitted: &emitted,
            truncated: &truncated
          ))

        if truncated {
          break
        }
      }
      object["children"] = .array(children)
    }

    return .object(object)
  }

  private func collectTreeCompareEntries(
    root: URL,
    includeHidden: Bool,
    maxDepth: Int,
    maxEntries: Int,
    scannedEntries: inout Int,
    truncated: inout Bool
  ) throws -> [String: TreeCompareEntry] {
    var entries: [String: TreeCompareEntry] = [:]
    try collectTreeCompareEntries(
      directory: root,
      rootPath: root.standardizedFileURL.path,
      currentDepth: 0,
      maxDepth: maxDepth,
      includeHidden: includeHidden,
      maxEntries: maxEntries,
      scannedEntries: &scannedEntries,
      truncated: &truncated,
      entries: &entries
    )
    return entries
  }

  private func collectTreeCompareEntries(
    directory: URL,
    rootPath: String,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    maxEntries: Int,
    scannedEntries: inout Int,
    truncated: inout Bool,
    entries: inout [String: TreeCompareEntry]
  ) throws {
    guard !truncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: includeHidden) {
      guard scannedEntries < maxEntries else {
        truncated = true
        return
      }

      scannedEntries += 1
      let lexical = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
      let info = try fileInfo(url: lexical)
      let relativePath = relativePathPreservingSymlinks(fromDirectoryPath: rootPath, to: lexical)
      entries[relativePath] = TreeCompareEntry(
        url: lexical,
        relativePath: relativePath,
        workspaceRelativePath: workspaceRelativePathPreservingSymlinks(lexical),
        type: info.type,
        sizeBytes: info.size,
        modifiedAt: info.modifiedAt,
        isSymlink: info.isSymlink,
        symlinkDestination: info.symlinkDestination,
        sha256: nil
      )

      if currentDepth < maxDepth && info.type == "directory" && !info.isSymlink {
        try collectTreeCompareEntries(
          directory: lexical,
          rootPath: rootPath,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          maxEntries: maxEntries,
          scannedEntries: &scannedEntries,
          truncated: &truncated,
          entries: &entries
        )
      }
    }
  }

  private func relativePathPreservingSymlinks(fromDirectoryPath rootPath: String, to url: URL)
    -> String
  {
    let path = url.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
    guard path.hasPrefix(prefix) else {
      return url.lastPathComponent
    }
    return String(path.dropFirst(prefix.count))
  }

  private func recordTreeCompareDifference(
    kind: String,
    relativePath: String,
    left: TreeCompareEntry?,
    right: TreeCompareEntry?,
    detail: String,
    differenceCounts: inout [String: Int],
    differences: inout [TreeCompareDifference],
    maxResults: Int,
    resultTruncated: inout Bool
  ) {
    differenceCounts[kind, default: 0] += 1
    guard differences.count < maxResults else {
      resultTruncated = true
      return
    }
    differences.append(
      TreeCompareDifference(
        kind: kind,
        relativePath: relativePath,
        left: left,
        right: right,
        detail: detail
      ))
  }

  private func collectDuplicateFileCandidates(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    minSizeBytes: Int64,
    maxHashFileBytes: Int64,
    maxEntries: Int,
    scannedEntries: inout Int,
    scannedFileCount: inout Int,
    skippedSmallFileCount: inout Int,
    skippedLargeFileCount: inout Int,
    scanTruncated: inout Bool,
    candidates: inout [DuplicateFileCandidate]
  ) throws {
    guard !scanTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: includeHidden) {
      guard scannedEntries < maxEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let url = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
      let info = try fileInfo(url: url)

      if info.type == "directory", !info.isSymlink, currentDepth < maxDepth {
        try collectDuplicateFileCandidates(
          directory: url,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          minSizeBytes: minSizeBytes,
          maxHashFileBytes: maxHashFileBytes,
          maxEntries: maxEntries,
          scannedEntries: &scannedEntries,
          scannedFileCount: &scannedFileCount,
          skippedSmallFileCount: &skippedSmallFileCount,
          skippedLargeFileCount: &skippedLargeFileCount,
          scanTruncated: &scanTruncated,
          candidates: &candidates
        )
        continue
      }

      guard info.type == "file", !info.isSymlink else {
        continue
      }
      scannedFileCount += 1
      let size = info.size ?? 0
      guard size >= minSizeBytes else {
        skippedSmallFileCount += 1
        continue
      }
      guard size <= maxHashFileBytes else {
        skippedLargeFileCount += 1
        continue
      }
      candidates.append(
        DuplicateFileCandidate(
          url: url,
          workspaceRelativePath: workspaceRelativePathPreservingSymlinks(url),
          sizeBytes: size,
          modifiedAt: info.modifiedAt,
          sha256: nil
        ))
    }
  }

  private func collectFindResults(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    query: String,
    matchMode: FileNameMatchMode,
    caseSensitive: Bool,
    includeHidden: Bool,
    maxResults: Int,
    maxVisited: Int,
    visited: inout Int,
    results: inout [FileInfo],
    truncated: inout Bool
  ) throws {
    guard !truncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: includeHidden) {
      guard visited < maxVisited else {
        truncated = true
        return
      }
      visited += 1

      let resolved = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
      let info = try fileInfo(url: resolved)
      if fileName(
        child.lastPathComponent, matches: query, mode: matchMode, caseSensitive: caseSensitive)
      {
        guard results.count < maxResults else {
          truncated = true
          return
        }
        results.append(info)
      }

      if currentDepth < maxDepth && info.type == "directory" && !info.isSymlink {
        try collectFindResults(
          directory: resolved,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          query: query,
          matchMode: matchMode,
          caseSensitive: caseSensitive,
          includeHidden: includeHidden,
          maxResults: maxResults,
          maxVisited: maxVisited,
          visited: &visited,
          results: &results,
          truncated: &truncated
        )
      }
    }
  }

  private func collectTimelineFiles(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    includeHidden: Bool,
    modifiedAfter: Date?,
    modifiedBefore: Date?,
    maxScanEntries: Int,
    scannedEntries: inout Int,
    scannedFileCount: inout Int,
    skippedMissingModifiedDateCount: inout Int,
    scanTruncated: inout Bool,
    entries: inout [TimelineFileEntry]
  ) throws {
    guard !scanTruncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: includeHidden) {
      guard scannedEntries < maxScanEntries else {
        scanTruncated = true
        return
      }

      scannedEntries += 1
      let resolved = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
      let info = try fileInfo(url: resolved)

      if info.type == "directory", !info.isSymlink, currentDepth < maxDepth {
        try collectTimelineFiles(
          directory: resolved,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          includeHidden: includeHidden,
          modifiedAfter: modifiedAfter,
          modifiedBefore: modifiedBefore,
          maxScanEntries: maxScanEntries,
          scannedEntries: &scannedEntries,
          scannedFileCount: &scannedFileCount,
          skippedMissingModifiedDateCount: &skippedMissingModifiedDateCount,
          scanTruncated: &scanTruncated,
          entries: &entries
        )
        continue
      }

      guard info.type == "file", !info.isSymlink else {
        continue
      }
      scannedFileCount += 1
      guard let modifiedAt = info.modifiedAt else {
        skippedMissingModifiedDateCount += 1
        continue
      }
      if let modifiedAfter, modifiedAt < modifiedAfter {
        continue
      }
      if let modifiedBefore, modifiedAt > modifiedBefore {
        continue
      }
      entries.append(TimelineFileEntry(info: info, modifiedAt: modifiedAt))
    }
  }

  private func collectSearchMatches(
    directory: URL,
    currentDepth: Int,
    maxDepth: Int,
    query: String,
    caseSensitive: Bool,
    includeHidden: Bool,
    maxFiles: Int,
    maxMatches: Int,
    maxBytesPerFile: Int,
    filesScanned: inout Int,
    filesSkipped: inout Int,
    bytesScanned: inout Int,
    truncatedFiles: inout Int,
    matches: inout [FileSearchMatch],
    truncated: inout Bool
  ) throws {
    guard !truncated else {
      return
    }

    for child in try sortedDirectoryChildren(directory, includeHidden: includeHidden) {
      guard !truncated else {
        return
      }

      let resolved = try resolvedWorkspaceURLPreservingFinalSymlink(child.path)
      let info = try fileInfo(url: resolved)
      if info.type == "directory" && !info.isSymlink {
        if currentDepth < maxDepth {
          try collectSearchMatches(
            directory: resolved,
            currentDepth: currentDepth + 1,
            maxDepth: maxDepth,
            query: query,
            caseSensitive: caseSensitive,
            includeHidden: includeHidden,
            maxFiles: maxFiles,
            maxMatches: maxMatches,
            maxBytesPerFile: maxBytesPerFile,
            filesScanned: &filesScanned,
            filesSkipped: &filesSkipped,
            bytesScanned: &bytesScanned,
            truncatedFiles: &truncatedFiles,
            matches: &matches,
            truncated: &truncated
          )
        }
        continue
      }

      try searchFileIfAllowed(
        url: resolved,
        info: info,
        query: query,
        caseSensitive: caseSensitive,
        maxFiles: maxFiles,
        maxMatches: maxMatches,
        maxBytesPerFile: maxBytesPerFile,
        filesScanned: &filesScanned,
        filesSkipped: &filesSkipped,
        bytesScanned: &bytesScanned,
        truncatedFiles: &truncatedFiles,
        matches: &matches,
        truncated: &truncated
      )
    }
  }

  private func searchFileIfAllowed(
    url: URL,
    info: FileInfo,
    query: String,
    caseSensitive: Bool,
    maxFiles: Int,
    maxMatches: Int,
    maxBytesPerFile: Int,
    filesScanned: inout Int,
    filesSkipped: inout Int,
    bytesScanned: inout Int,
    truncatedFiles: inout Int,
    matches: inout [FileSearchMatch],
    truncated: inout Bool
  ) throws {
    guard !truncated else {
      return
    }
    guard info.type == "file" else {
      filesSkipped += 1
      return
    }
    guard filesScanned < maxFiles else {
      truncated = true
      return
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytesPerFile + 1) ?? Data()
    let limitedData: Data
    if data.count > maxBytesPerFile {
      limitedData = Data(data.prefix(maxBytesPerFile))
      truncatedFiles += 1
    } else {
      limitedData = data
    }
    bytesScanned += limitedData.count
    filesScanned += 1

    guard !limitedData.contains(0) else {
      filesSkipped += 1
      return
    }

    let content = String(decoding: limitedData, as: UTF8.self)
    try appendContentMatches(
      content: content,
      fileInfo: info,
      query: query,
      caseSensitive: caseSensitive,
      maxMatches: maxMatches,
      fileTruncated: data.count > maxBytesPerFile,
      matches: &matches,
      truncated: &truncated
    )
  }

  private func appendContentMatches(
    content: String,
    fileInfo: FileInfo,
    query: String,
    caseSensitive: Bool,
    maxMatches: Int,
    fileTruncated: Bool,
    matches: inout [FileSearchMatch],
    truncated: inout Bool
  ) throws {
    let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
    for (lineIndex, line) in content.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      guard let range = line.range(of: query, options: options) else {
        continue
      }
      guard matches.count < maxMatches else {
        truncated = true
        return
      }

      matches.append(
        FileSearchMatch(
          path: fileInfo.path,
          workspaceRelativePath: fileInfo.workspaceRelativePath,
          line: lineIndex + 1,
          column: line.distance(from: line.startIndex, to: range.lowerBound) + 1,
          preview: String(line.prefix(300)),
          fileTruncated: fileTruncated
        ))
    }
  }

  internal func sortedDirectoryChildren(_ directory: URL, includeHidden: Bool) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { includeHidden || !$0.hasPrefix(".") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { directory.appendingPathComponent($0) }
  }

  private func validateSymbolicLinkDestination(_ destination: String) throws {
    try validateUTF8ByteLimit(destination, name: "destination", maxBytes: 4_096)
    guard !destination.isEmpty else {
      throw GatewayToolError.invalidArguments("destination must not be empty.")
    }
    guard !destination.contains("\0") else {
      throw GatewayToolError.invalidArguments("destination must not contain null bytes.")
    }
  }

  private func validateMetadataAttributeName(_ name: String) throws {
    try validateUTF8ByteLimit(name, name: "attribute", maxBytes: 128)
    guard !name.isEmpty else {
      throw GatewayToolError.invalidArguments("attributes must not contain empty strings.")
    }
    guard !name.hasPrefix("-") else {
      throw GatewayToolError.invalidArguments("attribute must not be an option.")
    }
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.$")
    guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      throw GatewayToolError.invalidArguments(
        "attribute may contain only letters, digits, underscore, dot, or dollar sign.")
    }
  }

  private func validateExtendedAttributeName(_ name: String) throws {
    try validateUTF8ByteLimit(name, name: "name", maxBytes: 255)
    guard !name.isEmpty else {
      throw GatewayToolError.invalidArguments("name must not be empty.")
    }
    guard !name.contains("\0") else {
      throw GatewayToolError.invalidArguments("name must not contain null bytes.")
    }
    guard
      name.unicodeScalars.allSatisfy({ scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
      })
    else {
      throw GatewayToolError.invalidArguments("name must not contain control characters.")
    }
  }

  internal func readBoundedFileData(url: URL, path: String, maxBytes: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else {
      throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
    }
    return data
  }

  internal func fileInfo(url: URL) throws -> FileInfo {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let type = fileType(attributes[.type])
    let symlinkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    let relativePath =
      symlinkDestination == nil
      ? workspaceRelativePath(url) : workspaceRelativePathPreservingSymlinks(url)

    return FileInfo(
      path: url.path,
      workspaceRelativePath: relativePath,
      type: symlinkDestination == nil ? type : "symlink",
      size: (attributes[.size] as? NSNumber)?.int64Value,
      createdAt: attributes[.creationDate] as? Date,
      modifiedAt: attributes[.modificationDate] as? Date,
      isReadable: FileManager.default.isReadableFile(atPath: url.path),
      isWritable: FileManager.default.isWritableFile(atPath: url.path),
      isExecutable: FileManager.default.isExecutableFile(atPath: url.path),
      isSymlink: symlinkDestination != nil,
      symlinkDestination: symlinkDestination
    )
  }

  internal func fileType(_ attribute: Any?) -> String {
    guard let type = attribute as? FileAttributeType else {
      return "unknown"
    }
    switch type {
    case .typeDirectory:
      return "directory"
    case .typeRegular:
      return "file"
    case .typeSymbolicLink:
      return "symlink"
    case .typeSocket:
      return "socket"
    case .typeCharacterSpecial:
      return "character_special"
    case .typeBlockSpecial:
      return "block_special"
    default:
      return "unknown"
    }
  }

  internal func fileNameMatchMode(_ value: String) throws -> FileNameMatchMode {
    guard let mode = FileNameMatchMode(rawValue: value) else {
      throw GatewayToolError.invalidArguments(
        "match must be one of: contains, prefix, suffix, exact.")
    }
    return mode
  }

  private func fileTimelineSort(_ value: String) throws -> FileTimelineSort {
    guard let sort = FileTimelineSort(rawValue: value) else {
      throw GatewayToolError.invalidArguments(
        "sort must be one of: modified_desc, modified_asc, path.")
    }
    return sort
  }

  internal func fileName(
    _ name: String,
    matches query: String,
    mode: FileNameMatchMode,
    caseSensitive: Bool
  ) -> Bool {
    let candidate = caseSensitive ? name : name.lowercased()
    let needle = caseSensitive ? query : query.lowercased()

    switch mode {
    case .contains:
      return candidate.contains(needle)
    case .prefix:
      return candidate.hasPrefix(needle)
    case .suffix:
      return candidate.hasSuffix(needle)
    case .exact:
      return candidate == needle
    }
  }

  private func countOccurrences(of needle: String, in haystack: String) -> Int {
    var count = 0
    var searchStart = haystack.startIndex
    while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
      count += 1
      searchStart = range.upperBound
    }
    return count
  }

  private func fileInsertPosition(_ value: String) throws -> FileInsertPosition {
    guard let position = FileInsertPosition(rawValue: value) else {
      throw GatewayToolError.invalidArguments("position must be one of: before, after.")
    }
    return position
  }

  private func existingLineStarts(in content: String) -> [String.Index] {
    guard !content.isEmpty else {
      return []
    }
    var starts = [content.startIndex]
    var searchStart = content.startIndex
    while let newline = content[searchStart...].firstIndex(of: "\n") {
      let next = content.index(after: newline)
      if next < content.endIndex {
        starts.append(next)
      }
      searchStart = next
    }
    return starts
  }

  private func lineText(
    at line: Int,
    starts: [String.Index],
    in content: String
  ) -> String {
    let start = starts[line - 1]
    var end: String.Index
    if line < starts.count {
      let nextStart = starts[line]
      end = content.index(before: nextStart)
    } else {
      end = content.endIndex
      if end > start {
        let previous = content.index(before: end)
        if content[previous] == "\n" {
          end = previous
        }
      }
    }
    return String(content[start..<end])
  }

  internal func utf8Preview(_ value: String, maxBytes: Int) -> (text: String, truncated: Bool) {
    let data = Data(value.utf8)
    guard data.count > maxBytes else {
      return (value, false)
    }

    var index = value.startIndex
    var byteCount = 0
    while index < value.endIndex {
      let next = value.index(after: index)
      let characterByteCount = value[index..<next].utf8.count
      guard byteCount + characterByteCount <= maxBytes else {
        break
      }
      byteCount += characterByteCount
      index = next
    }

    return (String(value[..<index]), true)
  }

  internal func requireDirectory(_ url: URL, originalPath: String) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw GatewayToolError.invalidArguments("Directory does not exist: \(originalPath)")
    }
    guard isDirectory.boolValue else {
      throw GatewayToolError.invalidArguments("Path is not a directory: \(originalPath)")
    }
  }

  private func prepareDestination(
    _ url: URL,
    originalPath: String,
    overwrite: Bool,
    createDirectories: Bool
  ) throws {
    if createDirectories {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      return
    }
    guard overwrite else {
      throw GatewayToolError.invalidArguments("Destination already exists: \(originalPath)")
    }
    try FileManager.default.removeItem(at: url)
  }

  private struct DestinationPreparation {
    let destinationExists: Bool
    let wouldCreateParentDirectories: Bool
  }

  private func inspectDestinationPreparation(
    _ url: URL,
    originalPath: String,
    overwrite: Bool,
    createDirectories: Bool,
    treatsBrokenSymlinkAsExisting: Bool = false
  ) throws -> DestinationPreparation {
    let parent = url.deletingLastPathComponent()
    var parentIsDirectory: ObjCBool = false
    let parentExists = FileManager.default.fileExists(
      atPath: parent.path,
      isDirectory: &parentIsDirectory
    )
    if parentExists {
      guard parentIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Parent path is not a directory: \(originalPath)")
      }
    } else {
      guard createDirectories else {
        throw GatewayToolError.invalidArguments(
          "Parent directory does not exist: \(originalPath)"
        )
      }
    }

    let destinationExists =
      FileManager.default.fileExists(atPath: url.path)
      || (treatsBrokenSymlinkAsExisting
        && (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil)
    if destinationExists && !overwrite {
      throw GatewayToolError.invalidArguments("Destination already exists: \(originalPath)")
    }

    return DestinationPreparation(
      destinationExists: destinationExists,
      wouldCreateParentDirectories: !parentExists
    )
  }

  private func prepareSymlinkDestination(
    _ url: URL,
    originalPath: String,
    overwrite: Bool,
    createDirectories: Bool
  ) throws {
    if createDirectories {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }

    let exists =
      FileManager.default.fileExists(atPath: url.path)
      || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    guard exists else {
      return
    }
    guard overwrite else {
      throw GatewayToolError.invalidArguments("Destination already exists: \(originalPath)")
    }
    try FileManager.default.removeItem(at: url)
  }

  private func organizationResult(
    operation: String,
    source: URL,
    destination: URL,
    dryRun: Bool,
    overwritten: Bool,
    wouldOverwrite: Bool,
    wouldCreateParentDirectories: Bool,
    performedKey: String,
    wouldPerformKey: String
  ) throws -> JSONValue {
    var payload: [String: JSONValue] = [
      "operation": .string(operation),
      "source": .string(source.path),
      "source_workspace_relative_path": .string(workspaceRelativePath(source)),
      "destination": .string(destination.path),
      "destination_workspace_relative_path": .string(workspaceRelativePath(destination)),
      "dry_run": .bool(dryRun),
      "overwritten": .bool(overwritten),
      "would_overwrite": .bool(wouldOverwrite),
      "would_create_parent_directories": .bool(wouldCreateParentDirectories),
      performedKey: .bool(!dryRun),
      wouldPerformKey: .bool(true),
    ]
    if operation == "file.move" {
      payload["source_removed"] = .bool(!dryRun)
      payload["would_remove_source"] = .bool(true)
    }
    payload["result"] = dryRun ? .null : try fileInfo(url: destination).json
    return .object(payload)
  }

  private func extendedAttributeNames(url: URL) throws -> [String] {
    let size = url.withUnsafeFileSystemRepresentation { pathPointer -> Int in
      guard let pathPointer else {
        errno = EINVAL
        return -1
      }
      return listxattr(pathPointer, nil, 0, 0)
    }
    guard size >= 0 else {
      throw extendedAttributeError("listxattr", url: url, errno: errno)
    }
    guard size > 0 else {
      return []
    }

    var buffer = [CChar](repeating: 0, count: size)
    let bytesRead = url.withUnsafeFileSystemRepresentation { pathPointer -> Int in
      guard let pathPointer else {
        errno = EINVAL
        return -1
      }
      return buffer.withUnsafeMutableBufferPointer { pointer in
        listxattr(pathPointer, pointer.baseAddress, pointer.count, 0)
      }
    }
    guard bytesRead >= 0 else {
      throw extendedAttributeError("listxattr", url: url, errno: errno)
    }

    var names: [String] = []
    var start = 0
    for index in 0..<bytesRead where buffer[index] == 0 {
      if index > start {
        names.append(
          String(
            decoding: buffer[start..<index].map { UInt8(bitPattern: $0) },
            as: UTF8.self
          ))
      }
      start = index + 1
    }
    return names
  }

  private func extendedAttributeSize(url: URL, name: String) throws -> Int {
    let size = url.withUnsafeFileSystemRepresentation { pathPointer -> Int in
      guard let pathPointer else {
        errno = EINVAL
        return -1
      }
      return name.withCString { namePointer in
        getxattr(pathPointer, namePointer, nil, 0, 0, 0)
      }
    }
    guard size >= 0 else {
      throw extendedAttributeError("getxattr", url: url, errno: errno)
    }
    return size
  }

  private func extendedAttributeValue(
    url: URL,
    name: String,
    size: Int,
    maxBytes: Int
  ) throws -> Data {
    let bytesToRead = min(size, maxBytes)
    guard bytesToRead > 0 else {
      return Data()
    }

    var data = Data(count: bytesToRead)
    let bytesRead = data.withUnsafeMutableBytes { rawBuffer -> Int in
      url.withUnsafeFileSystemRepresentation { pathPointer -> Int in
        guard let pathPointer else {
          errno = EINVAL
          return -1
        }
        return name.withCString { namePointer in
          getxattr(pathPointer, namePointer, rawBuffer.baseAddress, bytesToRead, 0, 0)
        }
      }
    }
    guard bytesRead >= 0 else {
      throw extendedAttributeError("getxattr", url: url, errno: errno)
    }
    if bytesRead < data.count {
      data.removeSubrange(bytesRead..<data.count)
    }
    return data
  }

  internal func removeExtendedAttribute(url: URL, name: String) throws {
    let result = url.withUnsafeFileSystemRepresentation { pathPointer -> Int32 in
      guard let pathPointer else {
        errno = EINVAL
        return -1
      }
      return name.withCString { namePointer in
        removexattr(pathPointer, namePointer, 0)
      }
    }
    guard result == 0 else {
      throw extendedAttributeError("removexattr", url: url, errno: errno)
    }
  }

  private func extendedAttributeError(_ operation: String, url: URL, errno error: Int32)
    -> GatewayToolError
  {
    GatewayToolError.executionFailed(
      "\(operation) failed for \(url.path): \(String(cString: strerror(error)))"
    )
  }

  private func metadataPayload(from result: CommandResult) -> MetadataPayload {
    if result.timedOut {
      return MetadataPayload(
        metadata: .null,
        error: nil,
        omittedReason: "mdls timed out"
      )
    }
    if result.stdoutTruncated {
      return MetadataPayload(
        metadata: .null,
        error: nil,
        omittedReason: "stdout truncated"
      )
    }
    if result.exitCode != 0 {
      return MetadataPayload(
        metadata: .null,
        error: nil,
        omittedReason: "mdls exited nonzero"
      )
    }
    guard !result.stdout.isEmpty else {
      return MetadataPayload(
        metadata: .null,
        error: nil,
        omittedReason: "empty stdout"
      )
    }

    do {
      let plist = try PropertyListSerialization.propertyList(
        from: Data(result.stdout.utf8),
        options: [],
        format: nil
      )
      return MetadataPayload(
        metadata: try propertyListJSON(plist),
        error: nil,
        omittedReason: nil
      )
    } catch {
      return MetadataPayload(
        metadata: .null,
        error: error.localizedDescription,
        omittedReason: "plist parse failed"
      )
    }
  }

  private func propertyListJSON(_ value: Any) throws -> JSONValue {
    if let dictionary = value as? NSDictionary {
      var object: [String: JSONValue] = [:]
      for key in dictionary.allKeys {
        guard let stringKey = key as? String else {
          continue
        }
        object[stringKey] = try propertyListJSON(dictionary[stringKey] as Any)
      }
      return .object(object)
    }
    if let array = value as? NSArray {
      return .array(try array.map { try propertyListJSON($0) })
    }
    if let string = value as? String {
      return .string(string)
    }
    if let date = value as? Date {
      return .string(iso8601String(date))
    }
    if let data = value as? Data {
      return .string(data.base64EncodedString())
    }
    if let number = value as? NSNumber {
      return try JSONValue(foundationNumber: number)
    }
    return .null
  }

  private func filteredMetadata(_ metadata: JSONValue, attributes: [String]) -> JSONValue {
    guard !attributes.isEmpty else {
      return metadata
    }
    guard let object = metadata.objectValue else {
      return metadata
    }

    var filtered: [String: JSONValue] = [:]
    for attribute in attributes {
      filtered[attribute] = object[attribute] ?? .null
    }
    return .object(filtered)
  }

  private func permissionSummary(_ mode: Int) -> JSONValue {
    func triplet(read: Int, write: Int, execute: Int) -> JSONValue {
      .object([
        "read": .bool((mode & read) != 0),
        "write": .bool((mode & write) != 0),
        "execute": .bool((mode & execute) != 0),
      ])
    }

    return .object([
      "user": triplet(read: 0o400, write: 0o200, execute: 0o100),
      "group": triplet(read: 0o040, write: 0o020, execute: 0o010),
      "other": triplet(read: 0o004, write: 0o002, execute: 0o001),
      "setuid": .bool((mode & 0o4000) != 0),
      "setgid": .bool((mode & 0o2000) != 0),
      "sticky": .bool((mode & 0o1000) != 0),
    ])
  }

  private func parsePOSIXMode(_ raw: String, name: String) throws -> Int {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits: String
    if trimmed.hasPrefix("0o") {
      digits = String(trimmed.dropFirst(2))
    } else {
      digits = trimmed
    }

    guard digits.count == 3 || digits.count == 4, digits.allSatisfy({ $0 >= "0" && $0 <= "7" }),
      let mode = Int(digits, radix: 8), mode >= 0, mode <= 0o7777
    else {
      throw GatewayToolError.invalidArguments(
        "\(name) must be a 3- or 4-digit octal POSIX mode, for example 0644.")
    }
    return mode
  }
}

private struct ListedFile {
  var name: String
  var relativePath: String
  var info: FileInfo

  var json: JSONValue {
    .object([
      "name": .string(name),
      "path": .string(info.path),
      "workspace_relative_path": .string(relativePath),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_directory": .bool(info.type == "directory"),
      "is_symlink": .bool(info.isSymlink),
    ])
  }
}

internal struct FileOutlineItem {
  var line: Int
  var kind: String
  var level: Int?
  var name: String
  var text: String

  var json: JSONValue {
    .object([
      "line": .integer(Int64(line)),
      "kind": .string(kind),
      "level": level.map { .integer(Int64($0)) } ?? .null,
      "name": .string(name),
      "text": .string(text),
    ])
  }
}

internal enum FileNameMatchMode: String {
  case contains
  case prefix
  case suffix
  case exact
}

private enum FileTimelineSort: String {
  case modifiedDesc = "modified_desc"
  case modifiedAsc = "modified_asc"
  case path
}

private enum FileInsertPosition: String {
  case before
  case after
}

private struct MetadataPayload {
  var metadata: JSONValue
  var error: String?
  var omittedReason: String?
}

internal struct FileInfo {
  var path: String
  var workspaceRelativePath: String
  var type: String
  var size: Int64?
  var createdAt: Date?
  var modifiedAt: Date?
  var isReadable: Bool
  var isWritable: Bool
  var isExecutable: Bool
  var isSymlink: Bool
  var symlinkDestination: String?

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "type": .string(type),
      "size_bytes": size.map { .integer(Int64($0)) } ?? .null,
      "created_at": createdAt.map { .string(iso8601String($0)) } ?? .null,
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_readable": .bool(isReadable),
      "is_writable": .bool(isWritable),
      "is_executable": .bool(isExecutable),
      "is_symlink": .bool(isSymlink),
      "symlink_destination": symlinkDestination.map(JSONValue.string) ?? .null,
    ])
  }
}

private struct TimelineFileEntry {
  var info: FileInfo
  var modifiedAt: Date

  var workspaceRelativePath: String {
    info.workspaceRelativePath
  }

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "type": .string(info.type),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "created_at": info.createdAt.map { .string(iso8601String($0)) } ?? .null,
      "modified_at": .string(iso8601String(modifiedAt)),
      "is_readable": .bool(info.isReadable),
      "is_writable": .bool(info.isWritable),
      "read_context": .object([
        "tool": .string("file.read"),
        "arguments": .object([
          "path": .string(info.workspaceRelativePath)
        ]),
      ]),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "arguments": .object([
          "path": .string(info.workspaceRelativePath)
        ]),
      ]),
      "open_context": .object([
        "tool": .string("workspace.open"),
        "arguments": .object([
          "path": .string(info.workspaceRelativePath)
        ]),
      ]),
      "reveal_context": .object([
        "tool": .string("workspace.reveal"),
        "arguments": .object([
          "path": .string(info.workspaceRelativePath)
        ]),
      ]),
    ])
  }
}

private struct FileReadEntry {
  var info: FileInfo
  var encoding: String
  var content: String
  var bytesRead: Int
  var truncated: Bool
  var validUTF8: Bool

  var json: JSONValue {
    .object([
      "path": .string(info.path),
      "workspace_relative_path": .string(info.workspaceRelativePath),
      "size_bytes": info.size.map { .integer(Int64($0)) } ?? .null,
      "modified_at": info.modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "encoding": .string(encoding),
      "content": .string(content),
      "bytes_read": .integer(Int64(bytesRead)),
      "truncated": .bool(truncated),
      "valid_utf8": .bool(validUTF8),
    ])
  }
}

private struct DuplicateFileCandidate: Comparable {
  var url: URL
  var workspaceRelativePath: String
  var sizeBytes: Int64
  var modifiedAt: Date?
  var sha256: String?

  static func == (lhs: DuplicateFileCandidate, rhs: DuplicateFileCandidate) -> Bool {
    lhs.workspaceRelativePath == rhs.workspaceRelativePath
  }

  static func < (lhs: DuplicateFileCandidate, rhs: DuplicateFileCandidate) -> Bool {
    lhs.workspaceRelativePath.localizedStandardCompare(rhs.workspaceRelativePath)
      == .orderedAscending
  }

  var json: JSONValue {
    .object([
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "size_bytes": .integer(Int64(sizeBytes)),
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "sha256": sha256.map(JSONValue.string) ?? .null,
      "read_context": .object([
        "tool": .string("file.read"),
        "arguments": .object([
          "path": .string(workspaceRelativePath)
        ]),
      ]),
      "stat_context": .object([
        "tool": .string("file.stat"),
        "arguments": .object([
          "path": .string(workspaceRelativePath)
        ]),
      ]),
      "hash_context": .object([
        "tool": .string("file.hash"),
        "arguments": .object([
          "path": .string(workspaceRelativePath)
        ]),
      ]),
    ])
  }
}

private struct DuplicateHashBucket: Comparable {
  var sha256: String
  var sizeBytes: Int64
  var files: [DuplicateFileCandidate]

  var redundantBytes: Int64 {
    sizeBytes * Int64(max(files.count - 1, 0))
  }

  static func == (lhs: DuplicateHashBucket, rhs: DuplicateHashBucket) -> Bool {
    lhs.sha256 == rhs.sha256 && lhs.sizeBytes == rhs.sizeBytes
  }

  static func < (lhs: DuplicateHashBucket, rhs: DuplicateHashBucket) -> Bool {
    if lhs.redundantBytes != rhs.redundantBytes {
      return lhs.redundantBytes > rhs.redundantBytes
    }
    if lhs.sizeBytes != rhs.sizeBytes {
      return lhs.sizeBytes > rhs.sizeBytes
    }
    return lhs.sha256.localizedStandardCompare(rhs.sha256) == .orderedAscending
  }

  func json(maxFiles: Int) -> JSONValue {
    let returnedFiles = Array(files.prefix(maxFiles))
    return .object([
      "sha256": .string(sha256),
      "size_bytes": .integer(Int64(sizeBytes)),
      "file_count": .integer(Int64(files.count)),
      "returned_file_count": .integer(Int64(returnedFiles.count)),
      "file_list_truncated": .bool(returnedFiles.count < files.count),
      "duplicate_bytes": .integer(Int64(sizeBytes * Int64(files.count))),
      "redundant_bytes_if_one_kept": .integer(Int64(redundantBytes)),
      "files": .array(returnedFiles.map(\.json)),
    ])
  }
}

private struct TreeCompareEntry {
  var url: URL
  var relativePath: String
  var workspaceRelativePath: String
  var type: String
  var sizeBytes: Int64?
  var modifiedAt: Date?
  var isSymlink: Bool
  var symlinkDestination: String?
  var sha256: String?

  var json: JSONValue {
    .object([
      "path": .string(url.path),
      "relative_path": .string(relativePath),
      "workspace_relative_path": .string(workspaceRelativePath),
      "type": .string(type),
      "size_bytes": sizeBytes.map { .integer(Int64($0)) } ?? .null,
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_symlink": .bool(isSymlink),
      "symlink_destination": symlinkDestination.map(JSONValue.string) ?? .null,
      "sha256": sha256.map(JSONValue.string) ?? .null,
    ])
  }
}

private struct TreeCompareDifference {
  var kind: String
  var relativePath: String
  var left: TreeCompareEntry?
  var right: TreeCompareEntry?
  var detail: String

  var json: JSONValue {
    .object([
      "kind": .string(kind),
      "relative_path": .string(relativePath),
      "detail": .string(detail),
      "left": left.map(\.json) ?? .null,
      "right": right.map(\.json) ?? .null,
    ])
  }
}

private struct FileWritePlan {
  var requestedPath: String
  var url: URL
  var workspaceRelativePath: String
  var parent: URL
  var parentExists: Bool
  var existed: Bool
  var existingSizeBytes: UInt64
  var data: Data
  var preview: (text: String, truncated: Bool)

  func json(
    dryRun: Bool,
    overwrite: Bool,
    createDirectories: Bool,
    includePreview: Bool,
    previewMaxBytes: Int
  ) -> JSONValue {
    var object: [String: JSONValue] = [
      "requested_path": .string(requestedPath),
      "path": .string(url.path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "dry_run": .bool(dryRun),
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
      object["preview"] = .object([
        "preview_max_bytes": .integer(Int64(previewMaxBytes)),
        "content": .string(preview.text),
        "content_truncated": .bool(preview.truncated),
      ])
    }

    return .object(object)
  }
}

private struct FileSearchMatch {
  var path: String
  var workspaceRelativePath: String
  var line: Int
  var column: Int
  var preview: String
  var fileTruncated: Bool

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "line": .integer(Int64(line)),
      "column": .integer(Int64(column)),
      "preview": .string(preview),
      "file_truncated": .bool(fileTruncated),
    ])
  }
}

private func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
  bytes.map { String(format: "%02x", $0) }.joined()
}

private func hexdumpASCII(_ bytes: [UInt8]) -> String {
  let scalars = bytes.map { byte -> UnicodeScalar in
    if byte >= 0x20 && byte <= 0x7e {
      return UnicodeScalar(Int(byte)) ?? "."
    }
    return "."
  }
  return String(String.UnicodeScalarView(scalars))
}
