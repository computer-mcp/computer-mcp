import ComputerMCPCore
import ComputerMCPToolKit
import Foundation

extension ProjectToolProvider {
  internal func projectInfo() throws -> JSONValue {
    .object([
      "server": .object([
        "name": .string(configuration.server.name),
        "http": .object([
          "host": .string(configuration.server.http.host),
          "port": .integer(Int64(configuration.server.http.port)),
          "path": .string(configuration.server.http.path),
          "health_path": .string(configuration.server.http.healthPath),
          "public_base_url": configuration.server.http.publicBaseURL.map(JSONValue.string) ?? .null,
          "auth": .string(httpAuthMode(configuration: configuration)),
          "access_token_env": configuration.server.http.accessTokenEnv.map(JSONValue.string)
            ?? .null,
        ]),
      ]),
      "project": .object([
        "root": .string(configuration.projectDirectory.standardizedFileURL.path)
      ]),
      "policy": .object([
        "default_timeout_ms": .integer(Int64(configuration.policy.defaultTimeoutMs)),
        "max_output_bytes": .integer(Int64(configuration.policy.maxOutputBytes)),
        "shell_enabled": .bool(configuration.policy.shellEnabled),
      ]),
      "builtin": .object([
        "enabled": .array(configuration.builtin.enabled.sorted().map { .string($0) })
      ]),
      "cli": .object([
        "ids": .array(configuration.cli.commands.map(\.id).sorted().map { .string($0) })
      ]),
      "mcp": .object([
        "server_ids": .array(configuration.mcp.servers.map(\.id).sorted().map { .string($0) })
      ]),
      "tools": .object([
        "configured": .array(configuration.tools.map(\.name).sorted().map { .string($0) }),
        "tool_meta": projectScope.toolMeta ?? .null,
      ]),
    ])
  }

  internal func projectStatus(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxEntries = optionalInt("max_entries", in: object) ?? 5_000
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 100_000)

    let fileManager = FileManager.default
    let root = configuration.projectDirectory.standardizedFileURL
    var isDirectory = ObjCBool(false)
    let exists = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
    let readable = exists && fileManager.isReadableFile(atPath: root.path)
    let writable = exists && fileManager.isWritableFile(atPath: root.path)

    var fileCount = 0
    var directoryCount = 0
    var symlinkCount = 0
    var otherCount = 0
    var scannedCount = 0
    var truncated = false
    var scanError: String?

    if exists && isDirectory.boolValue && readable {
      let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ]
      var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
      if !includeHidden {
        options.insert(.skipsHiddenFiles)
      }

      if let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: options,
        errorHandler: { url, error in
          scanError = "\(url.path): \(error.localizedDescription)"
          return false
        }
      ) {
        for case let url as URL in enumerator {
          if scannedCount >= maxEntries {
            truncated = true
            break
          }
          scannedCount += 1
          let values = try? url.resourceValues(forKeys: Set(keys))
          if values?.isSymbolicLink == true {
            symlinkCount += 1
          } else if values?.isDirectory == true {
            directoryCount += 1
          } else if values?.isRegularFile == true {
            fileCount += 1
          } else {
            otherCount += 1
          }
        }
      }
    }

    let gitMetadata = root.appendingPathComponent(".git")
    var gitMetadataIsDirectory = ObjCBool(false)
    let gitMetadataExists = fileManager.fileExists(
      atPath: gitMetadata.path, isDirectory: &gitMetadataIsDirectory)

    return .object([
      "operation": .string("project.status"),
      "project": .object([
        "root": .string(root.path),
        "exists": .bool(exists),
        "is_directory": .bool(exists && isDirectory.boolValue),
        "is_readable": .bool(readable),
        "is_writable": .bool(writable),
      ]),
      "top_level": .object([
        "include_hidden": .bool(includeHidden),
        "max_entries": .integer(Int64(maxEntries)),
        "scanned_entry_count": .integer(Int64(scannedCount)),
        "file_count": .integer(Int64(fileCount)),
        "directory_count": .integer(Int64(directoryCount)),
        "symlink_count": .integer(Int64(symlinkCount)),
        "other_count": .integer(Int64(otherCount)),
        "truncated": .bool(truncated),
        "scan_error": scanError.map(JSONValue.string) ?? .null,
      ]),
      "vcs": .object([
        "git_metadata_at_root": .object([
          "exists": .bool(gitMetadataExists),
          "type": gitMetadataExists
            ? .string(gitMetadataIsDirectory.boolValue ? "directory" : "file")
            : .null,
        ])
      ]),
    ])
  }

  internal func projectManifests(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeMissing = try optionalBool("include_missing", in: object) ?? false
    let maxResults =
      optionalInt("max_results", in: object) ?? Self.projectManifestCandidates.count
    try validateBoundedPositive(
      maxResults,
      name: "max_results",
      upperBound: Self.projectManifestCandidates.count
    )

    let root = configuration.projectDirectory.standardizedFileURL
    var returned: [JSONValue] = []
    var includedCount = 0

    for path in Self.projectManifestCandidates {
      guard
        let entry = projectManifestEntry(path: path, root: root, includeMissing: includeMissing)
      else {
        continue
      }

      includedCount += 1
      if returned.count < maxResults {
        returned.append(entry)
      }
    }

    return .object([
      "operation": .string("project.manifests"),
      "project": .object([
        "root": .string(root.path)
      ]),
      "include_missing": .bool(includeMissing),
      "catalog_count": .integer(Int64(Self.projectManifestCandidates.count)),
      "included_count": .integer(Int64(includedCount)),
      "returned_count": .integer(Int64(returned.count)),
      "max_results": .integer(Int64(maxResults)),
      "truncated": .bool(includedCount > returned.count),
      "manifests": .array(returned),
    ])
  }

  private func projectManifestEntry(
    path: String,
    root: URL,
    includeMissing: Bool
  ) -> JSONValue? {
    let url = root.appendingPathComponent(path)
    var isDirectory = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

    guard exists || includeMissing else {
      return nil
    }

    let values =
      exists
      ? try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      : nil
    let isSymlink = values?.isSymbolicLink == true
    let isFile = values?.isRegularFile == true
    let directory = exists && isDirectory.boolValue
    let kind: String

    if !exists {
      kind = "missing"
    } else if isSymlink {
      kind = "symlink"
    } else if directory {
      kind = "directory"
    } else if isFile {
      kind = "file"
    } else {
      kind = "other"
    }

    return .object([
      "path": .string(path),
      "project_relative_path": .string(path),
      "exists": .bool(exists),
      "kind": .string(kind),
      "is_file": .bool(exists && isFile),
      "is_directory": .bool(directory),
      "is_symlink": .bool(exists && isSymlink),
    ])
  }

  internal func projectRecentFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxResults = optionalInt("max_results", in: object) ?? 25
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 10_000
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 500)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 100_000)

    let root = configuration.projectDirectory.standardizedFileURL
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
    ]
    var options: FileManager.DirectoryEnumerationOptions = []
    if !includeHidden {
      options.insert(.skipsHiddenFiles)
    }

    var scannedCount = 0
    var scanTruncated = false
    var scanError: String?
    var files: [FileInfo] = []

    if let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: options,
      errorHandler: { url, error in
        if scanError == nil {
          scanError = "\(url.path): \(error.localizedDescription)"
        }
        return true
      }
    ) {
      for case let url as URL in enumerator {
        if scannedCount >= maxScanEntries {
          scanTruncated = true
          break
        }

        scannedCount += 1
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
          continue
        }

        let resolved = try projectScope.resolvedProjectURL(url.path)
        let info = try projectScope.fileInfo(url: resolved)
        if info.type == "file" {
          files.append(info)
        }
      }
    }

    files.sort { lhs, rhs in
      let lhsDate = lhs.modifiedAt ?? .distantPast
      let rhsDate = rhs.modifiedAt ?? .distantPast
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }
      return lhs.projectRelativePath.localizedStandardCompare(rhs.projectRelativePath)
        == .orderedAscending
    }

    let returned = files.prefix(maxResults).map(\.json)
    let resultTruncated = files.count > returned.count

    return .object([
      "operation": .string("project.recent_files"),
      "project": .object([
        "root": .string(root.path)
      ]),
      "include_hidden": .bool(includeHidden),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedCount)),
      "matched_file_count": .integer(Int64(files.count)),
      "returned_count": .integer(Int64(returned.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "scan_error": scanError.map(JSONValue.string) ?? .null,
      "files": .array(Array(returned)),
    ])
  }

  internal func projectDirectoryStats(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 4
    let maxResults = optionalInt("max_results", in: object) ?? 100
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    try requireDirectory(root, originalPath: path)
    let rootProjectRelativePath = projectScope.projectRelativePath(root)
    let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]

    var scannedCount = 0
    var scanTruncated = false
    var scanError: String?
    var hiddenSkippedCount = 0
    var skippedSubtreeCount = 0
    var groups: [String: ProjectDirectoryStatInfo] = [:]

    if let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [],
      errorHandler: { url, error in
        if scanError == nil {
          scanError = "\(url.path): \(error.localizedDescription)"
        }
        return true
      }
    ) {
      for case let url as URL in enumerator {
        if scannedCount >= maxScanEntries {
          scanTruncated = true
          break
        }

        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDirectory = values?.isDirectory == true
        if name.hasPrefix("."), !includeHidden {
          hiddenSkippedCount += 1
          if isDirectory {
            enumerator.skipDescendants()
          }
          continue
        }

        let relativeToRoot = relativePath(fromDirectoryPath: rootPath, to: url)
        let depth = directoryStatsDepth(relativeToRoot)
        if depth > maxDepth {
          if isDirectory {
            enumerator.skipDescendants()
          }
          continue
        }

        scannedCount += 1
        let resolved = try projectScope.resolvedProjectURLPreservingFinalSymlink(url.path)
        let info = try projectScope.fileInfo(url: resolved)
        let groupPath = directoryStatsGroupPath(
          rootProjectRelativePath: rootProjectRelativePath,
          relativeToRoot: relativeToRoot
        )
        groups[
          groupPath,
          default: ProjectDirectoryStatInfo(
            projectRelativePath: groupPath,
            name: directoryStatsGroupName(
              groupPath, rootProjectRelativePath: rootProjectRelativePath)
          )
        ].record(info: info)

        if info.type == "file", !info.isSymlink {
          if sourceFileDescriptor(for: info.projectRelativePath) != nil {
            groups[groupPath]?.sourceFileCount += 1
          }
          if testFileDescriptor(for: info.projectRelativePath) != nil {
            groups[groupPath]?.testFileCount += 1
          }
          if dependencyFileDescriptor(for: name) != nil {
            groups[groupPath]?.dependencyFileCount += 1
          }
          if documentationDescriptor(for: info.projectRelativePath) != nil {
            groups[groupPath]?.documentationFileCount += 1
          }
          if ciFileDescriptor(for: info.projectRelativePath) != nil {
            groups[groupPath]?.ciFileCount += 1
          }
          if configFileDescriptor(for: info.projectRelativePath) != nil {
            groups[groupPath]?.configFileCount += 1
          }
          if info.isExecutable {
            groups[groupPath]?.executableFileCount += 1
          }
        }

        if isDirectory, Self.sourceSkippedDirectoryNames.contains(name.lowercased()) {
          groups[groupPath]?.skippedSubtreeCount += 1
          skippedSubtreeCount += 1
          enumerator.skipDescendants()
        }
      }
    }

    let sortedGroups = groups.values.sorted {
      $0.projectRelativePath.localizedStandardCompare($1.projectRelativePath)
        == .orderedAscending
    }
    let resultTruncated = sortedGroups.count > maxResults
    let returnedGroups = resultTruncated ? Array(sortedGroups.prefix(maxResults)) : sortedGroups

    return .object([
      "operation": .string("project.directory_stats"),
      "path": .string(root.path),
      "project_relative_path": .string(rootProjectRelativePath),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedCount)),
      "group_count": .integer(Int64(sortedGroups.count)),
      "returned_count": .integer(Int64(returnedGroups.count)),
      "hidden_skipped_count": .integer(Int64(hiddenSkippedCount)),
      "skipped_subtree_count": .integer(Int64(skippedSubtreeCount)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "scan_error": scanError.map(JSONValue.string) ?? .null,
      "groups": .array(returnedGroups.map(\.json)),
    ])
  }

  internal func projectArtifactDirectories(arguments object: [String: JSONValue]) throws
    -> JSONValue
  {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? true
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateBoundedNonNegative(maxDepth, name: "max_depth", upperBound: 50)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    try requireDirectory(root, originalPath: path)
    var artifactDirectories: [ProjectArtifactDirectoryInfo] = []
    var scannedEntries = 0
    var hiddenSkippedCount = 0
    var scanTruncated = false
    var resultTruncated = false

    try collectProjectArtifactDirectories(
      directory: root,
      currentDepth: 0,
      maxDepth: maxDepth,
      includeHidden: includeHidden,
      maxResults: maxResults,
      maxScanEntries: maxScanEntries,
      scannedEntries: &scannedEntries,
      hiddenSkippedCount: &hiddenSkippedCount,
      artifactDirectories: &artifactDirectories,
      scanTruncated: &scanTruncated,
      resultTruncated: &resultTruncated
    )

    artifactDirectories.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.artifact_directories"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "artifact_directory_count": .integer(Int64(artifactDirectories.count)),
      "returned_count": .integer(Int64(artifactDirectories.count)),
      "hidden_skipped_count": .integer(Int64(hiddenSkippedCount)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "directories": .array(artifactDirectories.map(\.json)),
    ])
  }

  internal func projectEmptyDirectories(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    try requireDirectory(root, originalPath: path)
    var emptyDirectories: [ProjectEmptyDirectoryInfo] = []
    var scannedEntries = 0
    var scannedDirectoryCount = 0
    var hiddenSkippedCount = 0
    var scanTruncated = false

    try collectProjectEmptyDirectories(
      directory: root,
      currentDepth: 0,
      maxDepth: maxDepth,
      includeHidden: includeHidden,
      maxScanEntries: maxScanEntries,
      scannedEntries: &scannedEntries,
      scannedDirectoryCount: &scannedDirectoryCount,
      hiddenSkippedCount: &hiddenSkippedCount,
      emptyDirectories: &emptyDirectories,
      scanTruncated: &scanTruncated
    )

    emptyDirectories.sort {
      $0.projectRelativePath.localizedStandardCompare($1.projectRelativePath)
        == .orderedAscending
    }
    let resultTruncated = emptyDirectories.count > maxResults
    let returnedDirectories =
      resultTruncated ? Array(emptyDirectories.prefix(maxResults)) : emptyDirectories

    return .object([
      "operation": .string("project.empty_directories"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "scanned_directory_count": .integer(Int64(scannedDirectoryCount)),
      "empty_directory_count": .integer(Int64(emptyDirectories.count)),
      "returned_count": .integer(Int64(returnedDirectories.count)),
      "hidden_skipped_count": .integer(Int64(hiddenSkippedCount)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "directories": .array(returnedDirectories.map(\.json)),
    ])
  }

  internal func projectGitChanges(arguments object: [String: JSONValue]) throws -> JSONValue {
    let maxResults = optionalInt("max_results", in: object) ?? 200
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    let paths = try optionalGitPaths(in: object)
    let command = try registeredCommands.gitCLICommand()

    var arguments = ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
    if !paths.isEmpty {
      arguments.append("--")
      arguments.append(contentsOf: paths)
    }

    let result = try registeredCommands.runHostGit(
      command: command,
      args: arguments,
      timeout: optionalInt("timeout_ms", in: object)
    )
    let changes = parseGitStatusPorcelainZ(result.stdout)
    let returnedChanges = Array(changes.prefix(maxResults))
    var statusCounts: [String: Int] = [:]
    for change in changes {
      statusCounts[change.status, default: 0] += 1
    }

    let resultTruncated = changes.count > returnedChanges.count
    let statusCountJSON = Dictionary(
      uniqueKeysWithValues: statusCounts.keys.sorted().map { key in
        (key, JSONValue.integer(Int64(statusCounts[key] ?? 0)))
      })

    return .object([
      "operation": .string("project.git_changes"),
      "provider": .string(command.id),
      "argv": .array(arguments.map { .string($0) }),
      "paths": .array(paths.map { .string($0) }),
      "max_results": .integer(Int64(maxResults)),
      "change_count": .integer(Int64(changes.count)),
      "returned_count": .integer(Int64(returnedChanges.count)),
      "result_truncated": .bool(resultTruncated),
      "stdout_truncated": .bool(result.stdoutTruncated),
      "parse_incomplete": .bool(result.stdoutTruncated),
      "truncated": .bool(resultTruncated || result.stdoutTruncated),
      "status_legend": .object([
        " ": .string("unchanged"),
        "M": .string("modified"),
        "A": .string("added"),
        "D": .string("deleted"),
        "R": .string("renamed"),
        "C": .string("copied"),
        "U": .string("unmerged"),
        "?": .string("untracked"),
        "!": .string("ignored"),
      ]),
      "status_counts": .object(statusCountJSON),
      "changes": .array(returnedChanges.map(\.json)),
      "result": .object([
        "executable": .string(result.executable),
        "arguments": .array(result.arguments.map { .string($0) }),
        "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
        "timed_out": .bool(result.timedOut),
        "stderr": .string(result.stderr),
        "stdout_bytes": .integer(Int64(result.stdout.utf8.count)),
        "stdout_truncated": .bool(result.stdoutTruncated),
        "stderr_truncated": .bool(result.stderrTruncated),
      ]),
    ])
  }

  private func parseGitStatusPorcelainZ(_ stdout: String) -> [ProjectGitChange] {
    let records = stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var changes: [ProjectGitChange] = []
    var index = 0
    while index < records.count {
      let record = records[index]
      guard record.count >= 3 else {
        index += 1
        continue
      }

      let indexStatusIndex = record.startIndex
      let worktreeStatusIndex = record.index(after: indexStatusIndex)
      let pathStart =
        record.index(record.startIndex, offsetBy: 3, limitedBy: record.endIndex)
        ?? record.endIndex
      let indexStatus = String(record[indexStatusIndex])
      let worktreeStatus = String(record[worktreeStatusIndex])
      var originalPath: String?
      if indexStatus == "R" || indexStatus == "C" || worktreeStatus == "R" || worktreeStatus == "C"
      {
        let originalPathIndex = index + 1
        if originalPathIndex < records.count {
          originalPath = records[originalPathIndex]
          index += 1
        }
      }

      changes.append(
        ProjectGitChange(
          indexStatus: indexStatus,
          worktreeStatus: worktreeStatus,
          path: String(record[pathStart...]),
          originalPath: originalPath
        ))
      index += 1
    }
    return changes
  }

  internal func projectFileTypes(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxGroups = optionalInt("max_groups", in: object) ?? 50
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 10_000
    try validateBoundedPositive(maxGroups, name: "max_groups", upperBound: 500)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 100_000)

    let root = configuration.projectDirectory.standardizedFileURL
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    var options: FileManager.DirectoryEnumerationOptions = []
    if !includeHidden {
      options.insert(.skipsHiddenFiles)
    }

    var scannedCount = 0
    var regularFileCount = 0
    var totalSizeBytes: Int64 = 0
    var scanTruncated = false
    var scanError: String?
    var groups: [String: ProjectFileTypeSummary] = [:]

    if let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: options,
      errorHandler: { url, error in
        if scanError == nil {
          scanError = "\(url.path): \(error.localizedDescription)"
        }
        return true
      }
    ) {
      for case let url as URL in enumerator {
        if scannedCount >= maxScanEntries {
          scanTruncated = true
          break
        }

        scannedCount += 1
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
          continue
        }

        let extensionName = url.pathExtension.lowercased()
        let sizeBytes = Int64(values?.fileSize ?? 0)
        totalSizeBytes += sizeBytes
        regularFileCount += 1

        var summary =
          groups[extensionName]
          ?? ProjectFileTypeSummary(
            extensionName: extensionName,
            displayName: extensionName.isEmpty ? "[none]" : ".\(extensionName)",
            fileCount: 0,
            sizeBytes: 0
          )
        summary.fileCount += 1
        summary.sizeBytes += sizeBytes
        groups[extensionName] = summary
      }
    }

    let summaries = groups.values.sorted { lhs, rhs in
      if lhs.fileCount != rhs.fileCount {
        return lhs.fileCount > rhs.fileCount
      }
      if lhs.sizeBytes != rhs.sizeBytes {
        return lhs.sizeBytes > rhs.sizeBytes
      }
      return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
    let returned = summaries.prefix(maxGroups).map(\.json)
    let resultTruncated = summaries.count > returned.count

    return .object([
      "operation": .string("project.file_types"),
      "project": .object([
        "root": .string(root.path)
      ]),
      "include_hidden": .bool(includeHidden),
      "max_groups": .integer(Int64(maxGroups)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedCount)),
      "regular_file_count": .integer(Int64(regularFileCount)),
      "total_size_bytes": .integer(Int64(totalSizeBytes)),
      "distinct_extension_count": .integer(Int64(summaries.count)),
      "returned_group_count": .integer(Int64(returned.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "scan_error": scanError.map(JSONValue.string) ?? .null,
      "file_types": .array(Array(returned)),
    ])
  }

  internal func projectLargeFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxResults = optionalInt("max_results", in: object) ?? 25
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 10_000
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 500)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 100_000)

    let root = configuration.projectDirectory.standardizedFileURL
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    var options: FileManager.DirectoryEnumerationOptions = []
    if !includeHidden {
      options.insert(.skipsHiddenFiles)
    }

    var scannedCount = 0
    var regularFileCount = 0
    var totalSizeBytes: Int64 = 0
    var scanTruncated = false
    var scanError: String?
    var files: [FileInfo] = []

    if let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: options,
      errorHandler: { url, error in
        if scanError == nil {
          scanError = "\(url.path): \(error.localizedDescription)"
        }
        return true
      }
    ) {
      for case let url as URL in enumerator {
        if scannedCount >= maxScanEntries {
          scanTruncated = true
          break
        }

        scannedCount += 1
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
          continue
        }

        let resolved = try projectScope.resolvedProjectURL(url.path)
        let info = try projectScope.fileInfo(url: resolved)
        if info.type == "file" {
          regularFileCount += 1
          totalSizeBytes += info.size ?? 0
          files.append(info)
        }
      }
    }

    files.sort { lhs, rhs in
      let lhsSize = lhs.size ?? 0
      let rhsSize = rhs.size ?? 0
      if lhsSize != rhsSize {
        return lhsSize > rhsSize
      }
      return lhs.projectRelativePath.localizedStandardCompare(rhs.projectRelativePath)
        == .orderedAscending
    }

    let returned = files.prefix(maxResults).map(\.json)
    let resultTruncated = files.count > returned.count

    return .object([
      "operation": .string("project.large_files"),
      "project": .object([
        "root": .string(root.path)
      ]),
      "include_hidden": .bool(includeHidden),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedCount)),
      "regular_file_count": .integer(Int64(regularFileCount)),
      "total_size_bytes": .integer(Int64(totalSizeBytes)),
      "returned_count": .integer(Int64(returned.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "scan_error": scanError.map(JSONValue.string) ?? .null,
      "files": .array(Array(returned)),
    ])
  }

  internal func projectSymlinks(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxResults = optionalInt("max_results", in: object) ?? 100
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 10_000
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 1_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 100_000)

    let root = configuration.projectDirectory.standardizedFileURL
    let keys: [URLResourceKey] = [.isSymbolicLinkKey]
    var options: FileManager.DirectoryEnumerationOptions = []
    if !includeHidden {
      options.insert(.skipsHiddenFiles)
    }

    var scannedCount = 0
    var scanTruncated = false
    var scanError: String?
    var symlinks: [ProjectSymlinkInfo] = []

    if let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: options,
      errorHandler: { url, error in
        if scanError == nil {
          scanError = "\(url.path): \(error.localizedDescription)"
        }
        return true
      }
    ) {
      for case let url as URL in enumerator {
        if scannedCount >= maxScanEntries {
          scanTruncated = true
          break
        }

        scannedCount += 1
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isSymbolicLink == true else {
          continue
        }

        let linkURL = try projectScope.resolvedProjectURLPreservingFinalSymlink(url.path)
        let destination =
          (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) ?? ""
        let targetURL =
          destination.hasPrefix("/")
          ? URL(fileURLWithPath: destination)
          : linkURL.deletingLastPathComponent().appendingPathComponent(destination)
        var targetIsDirectory = ObjCBool(false)
        let targetExists = FileManager.default.fileExists(
          atPath: targetURL.path,
          isDirectory: &targetIsDirectory
        )

        symlinks.append(
          ProjectSymlinkInfo(
            path: linkURL.path,
            projectRelativePath: projectScope.projectRelativePathPreservingSymlinks(linkURL),
            destination: destination,
            targetAbsolutePath: targetURL.standardizedFileURL.path,
            targetExists: targetExists,
            targetIsDirectory: targetExists && targetIsDirectory.boolValue,
            targetProjectContained: projectScope.isProjectContained(targetURL)
          ))
      }
    }

    symlinks.sort {
      $0.projectRelativePath.localizedStandardCompare($1.projectRelativePath)
        == .orderedAscending
    }

    let returned = symlinks.prefix(maxResults).map(\.json)
    let resultTruncated = symlinks.count > returned.count

    return .object([
      "operation": .string("project.symlinks"),
      "project": .object([
        "root": .string(root.path)
      ]),
      "include_hidden": .bool(includeHidden),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedCount)),
      "symlink_count": .integer(Int64(symlinks.count)),
      "returned_count": .integer(Int64(returned.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "scan_error": scanError.map(JSONValue.string) ?? .null,
      "symlinks": .array(Array(returned)),
    ])
  }

  internal func projectExecutableFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxResults = optionalInt("max_results", in: object) ?? 100
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 10_000
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 1_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 100_000)

    let root = configuration.projectDirectory.standardizedFileURL
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    var options: FileManager.DirectoryEnumerationOptions = []
    if !includeHidden {
      options.insert(.skipsHiddenFiles)
    }

    var scannedCount = 0
    var executableFiles: [FileInfo] = []
    var scanTruncated = false
    var scanError: String?

    if let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: options,
      errorHandler: { url, error in
        if scanError == nil {
          scanError = "\(url.path): \(error.localizedDescription)"
        }
        return true
      }
    ) {
      for case let url as URL in enumerator {
        if scannedCount >= maxScanEntries {
          scanTruncated = true
          break
        }

        scannedCount += 1
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
          continue
        }

        let resolved = try projectScope.resolvedProjectURL(url.path)
        let info = try projectScope.fileInfo(url: resolved)
        if info.type == "file" && info.isExecutable {
          executableFiles.append(info)
        }
      }
    }

    executableFiles.sort {
      $0.projectRelativePath.localizedStandardCompare($1.projectRelativePath)
        == .orderedAscending
    }

    let returned = executableFiles.prefix(maxResults).map(\.json)
    let resultTruncated = executableFiles.count > returned.count

    return .object([
      "operation": .string("project.executable_files"),
      "project": .object([
        "root": .string(root.path)
      ]),
      "include_hidden": .bool(includeHidden),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedCount)),
      "executable_file_count": .integer(Int64(executableFiles.count)),
      "returned_count": .integer(Int64(returned.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "scan_error": scanError.map(JSONValue.string) ?? .null,
      "files": .array(Array(returned)),
    ])
  }

  internal func projectTodos(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let configuredMarkers = try optionalStringArray("markers", in: object)
    let markers = configuredMarkers.isEmpty ? Self.defaultTodoMarkers : configuredMarkers
    let caseSensitive = try optionalBool("case_sensitive", in: object) ?? false
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxFiles = optionalInt("max_files", in: object) ?? 500
    let maxMatches = optionalInt("max_matches", in: object) ?? 100
    let maxBytesPerFile = optionalInt("max_bytes_per_file", in: object) ?? 1_048_576

    try validateTodoMarkers(markers)
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxFiles, name: "max_files", upperBound: 50_000)
    try validateBoundedPositive(maxMatches, name: "max_matches", upperBound: 10_000)
    try validateBoundedPositive(maxBytesPerFile, name: "max_bytes_per_file", upperBound: 20_971_520)

    let root = try projectScope.resolvedProjectURL(path)
    var matches: [ProjectTodoMatch] = []
    var filesScanned = 0
    var filesSkipped = 0
    var bytesScanned = 0
    var truncatedFiles = 0
    var truncated = false

    let rootInfo = try projectScope.fileInfo(url: root)
    if rootInfo.type == "directory" {
      try collectTodoMatches(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        markers: markers,
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
      try scanTodoFileIfAllowed(
        url: root,
        info: rootInfo,
        markers: markers,
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
      "operation": .string("project.todos"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "markers": .array(markers.map(JSONValue.string)),
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

  internal func projectEnvFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHiddenDirectories =
      try optionalBool("include_hidden_directories", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxFiles = optionalInt("max_files", in: object) ?? 100
    let maxKeysPerFile = optionalInt("max_keys_per_file", in: object) ?? 200
    let maxBytesPerFile = optionalInt("max_bytes_per_file", in: object) ?? 262_144
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000

    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxFiles, name: "max_files", upperBound: 1_000)
    try validateBoundedPositive(maxKeysPerFile, name: "max_keys_per_file", upperBound: 10_000)
    try validateBoundedPositive(maxBytesPerFile, name: "max_bytes_per_file", upperBound: 1_048_576)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 100_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var envFiles: [ProjectEnvFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectEnvFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHiddenDirectories: includeHiddenDirectories,
        maxFiles: maxFiles,
        maxKeysPerFile: maxKeysPerFile,
        maxBytesPerFile: maxBytesPerFile,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        envFiles: &envFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file", isEnvFileName(root.lastPathComponent) {
      envFiles.append(
        try parseProjectEnvFile(
          url: root,
          info: rootInfo,
          maxKeysPerFile: maxKeysPerFile,
          maxBytesPerFile: maxBytesPerFile
        ))
    }

    envFiles.sort {
      $0.projectRelativePath.localizedStandardCompare($1.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.env_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden_directories": .bool(includeHiddenDirectories),
      "max_depth": .integer(Int64(maxDepth)),
      "max_files": .integer(Int64(maxFiles)),
      "max_keys_per_file": .integer(Int64(maxKeysPerFile)),
      "max_bytes_per_file": .integer(Int64(maxBytesPerFile)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "env_file_count": .integer(Int64(envFiles.count)),
      "returned_count": .integer(Int64(envFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(
        scanTruncated || resultTruncated || envFiles.contains { $0.keysTruncated }),
      "values_redacted": .bool(true),
      "env_files": .array(envFiles.map(\.json)),
    ])
  }

  internal func projectDependencyFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var dependencyFiles: [ProjectDependencyFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectDependencyFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        dependencyFiles: &dependencyFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if let descriptor = dependencyFileDescriptor(for: root.lastPathComponent) {
      dependencyFiles.append(
        ProjectDependencyFileInfo(
          info: rootInfo,
          ecosystem: descriptor.ecosystem,
          role: descriptor.role
        ))
    }

    dependencyFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.dependency_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "dependency_file_count": .integer(Int64(dependencyFiles.count)),
      "returned_count": .integer(Int64(dependencyFiles.count)),
      "catalog_count": .integer(Int64(Self.dependencyFileDescriptors.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(dependencyFiles.map(\.json)),
    ])
  }

  internal func projectRoots(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var dependencyFiles: [ProjectDependencyFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var dependencyResultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectRootDependencyFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults * 10,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        dependencyFiles: &dependencyFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &dependencyResultTruncated
      )
    } else if let descriptor = dependencyFileDescriptor(for: root.lastPathComponent) {
      dependencyFiles.append(
        ProjectDependencyFileInfo(
          info: rootInfo,
          ecosystem: descriptor.ecosystem,
          role: descriptor.role
        ))
    }

    let projectRoots = groupedProjectRoots(from: dependencyFiles)
    let resultTruncated = projectRoots.count > maxResults
    let returnedRoots = resultTruncated ? Array(projectRoots.prefix(maxResults)) : projectRoots

    return .object([
      "operation": .string("project.project_roots"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "dependency_file_count": .integer(Int64(dependencyFiles.count)),
      "project_root_count": .integer(Int64(projectRoots.count)),
      "returned_count": .integer(Int64(returnedRoots.count)),
      "scan_truncated": .bool(scanTruncated),
      "dependency_result_truncated": .bool(dependencyResultTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || dependencyResultTruncated || resultTruncated),
      "project_roots": .array(returnedRoots.map(\.json)),
    ])
  }

  internal func projectDocumentationFiles(arguments object: [String: JSONValue]) throws
    -> JSONValue
  {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 6
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var documentationFiles: [ProjectDocumentationFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectDocumentationFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        documentationFiles: &documentationFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if let descriptor = documentationDescriptor(for: rootInfo.projectRelativePath) {
      documentationFiles.append(
        ProjectDocumentationFileInfo(
          info: rootInfo,
          category: descriptor.category,
          source: descriptor.source
        ))
    }

    documentationFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.documentation_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "documentation_file_count": .integer(Int64(documentationFiles.count)),
      "returned_count": .integer(Int64(documentationFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(documentationFiles.map(\.json)),
    ])
  }

  internal func projectAgentFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? true
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 100
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var agentFiles: [ProjectAgentFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectAgentFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        agentFiles: &agentFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if let descriptor = agentFileDescriptor(for: rootInfo.projectRelativePath) {
      agentFiles.append(
        ProjectAgentFileInfo(
          info: rootInfo,
          kind: descriptor.kind,
          source: descriptor.source
        ))
    }

    agentFiles.sort {
      if $0.scopeProjectRelativePath != $1.scopeProjectRelativePath {
        return $0.scopeProjectRelativePath.localizedStandardCompare($1.scopeProjectRelativePath)
          == .orderedAscending
      }
      return $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.agent_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "agent_file_count": .integer(Int64(agentFiles.count)),
      "returned_count": .integer(Int64(agentFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(agentFiles.map(\.json)),
    ])
  }

  internal func projectInstructions(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let pathIsDirectory = try optionalBool("path_is_directory", in: object)
    let includeContent = try optionalBool("include_content", in: object) ?? true
    let maxBytesPerFile = optionalInt("max_bytes_per_file", in: object) ?? 65_536
    let maxResults = optionalInt("max_results", in: object) ?? 50
    try validateBoundedPositive(maxBytesPerFile, name: "max_bytes_per_file", upperBound: 1_048_576)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 200)

    let targetURL = try projectScope.lexicalProjectURL(path)
    let targetExists = FileManager.default.fileExists(atPath: targetURL.path)
    let scopeURL = try projectScope.projectInstructionScopeURL(
      targetURL: targetURL,
      originalPath: path,
      pathIsDirectory: pathIsDirectory,
      targetExists: targetExists
    )
    let scopeDirectories = projectScope.projectInstructionScopeDirectories(scopeURL: scopeURL)
    var files: [ProjectInstructionFileInfo] = []
    var seenPaths = Set<String>()
    var resultTruncated = false
    var applyOrder = 0

    for directory in scopeDirectories {
      guard !resultTruncated else {
        break
      }
      let scopeProjectRelativePath = projectScope.projectRelativePath(directory)
      try collectProjectInstructionFiles(
        directory: directory,
        scopeProjectRelativePath: scopeProjectRelativePath,
        includeContent: includeContent,
        maxBytesPerFile: maxBytesPerFile,
        maxResults: maxResults,
        seenPaths: &seenPaths,
        files: &files,
        resultTruncated: &resultTruncated,
        applyOrder: &applyOrder
      )
    }

    return .object([
      "operation": .string("project.instructions"),
      "path": .string(targetURL.path),
      "project_relative_path": .string(projectScope.projectRelativePath(targetURL)),
      "target_exists": .bool(targetExists),
      "path_is_directory": pathIsDirectory.map(JSONValue.bool) ?? .null,
      "scope_project_relative_path": .string(projectScope.projectRelativePath(scopeURL)),
      "include_content": .bool(includeContent),
      "max_bytes_per_file": .integer(Int64(maxBytesPerFile)),
      "max_results": .integer(Int64(maxResults)),
      "scope_directory_count": .integer(Int64(scopeDirectories.count)),
      "instruction_file_count": .integer(Int64(files.count)),
      "returned_count": .integer(Int64(files.count)),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(resultTruncated),
      "files": .array(files.map(\.json)),
    ])
  }

  internal func projectTestFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var testFiles: [ProjectTestFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectTestFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        testFiles: &testFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = testFileDescriptor(for: rootInfo.projectRelativePath)
    {
      testFiles.append(
        ProjectTestFileInfo(
          info: rootInfo,
          language: descriptor.language,
          matchSource: descriptor.matchSource,
          style: descriptor.style
        ))
    }

    testFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.test_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "test_file_count": .integer(Int64(testFiles.count)),
      "returned_count": .integer(Int64(testFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(testFiles.map(\.json)),
    ])
  }

  internal func projectCIFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? true
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var ciFiles: [ProjectCIFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectCIFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        ciFiles: &ciFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = ciFileDescriptor(for: rootInfo.projectRelativePath)
    {
      ciFiles.append(
        ProjectCIFileInfo(
          info: rootInfo,
          provider: descriptor.provider,
          category: descriptor.category,
          matchSource: descriptor.matchSource
        ))
    }

    ciFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.ci_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "ci_file_count": .integer(Int64(ciFiles.count)),
      "returned_count": .integer(Int64(ciFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(ciFiles.map(\.json)),
    ])
  }

  internal func projectInfraFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var infraFiles: [ProjectInfraFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectInfraFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        infraFiles: &infraFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = infraFileDescriptor(for: rootInfo.projectRelativePath)
    {
      infraFiles.append(
        ProjectInfraFileInfo(
          info: rootInfo,
          category: descriptor.category,
          provider: descriptor.provider,
          kind: descriptor.kind,
          format: descriptor.format,
          matchSource: descriptor.matchSource,
          jsonReadable: descriptor.jsonReadable,
          tomlReadable: descriptor.tomlReadable,
          fileExtension: descriptor.fileExtension
        ))
    }

    infraFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.infra_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "infra_file_count": .integer(Int64(infraFiles.count)),
      "returned_count": .integer(Int64(infraFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(infraFiles.map(\.json)),
    ])
  }

  internal func projectConfigFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? true
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var configFiles: [ProjectConfigFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectConfigFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        configFiles: &configFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = configFileDescriptor(for: rootInfo.projectRelativePath)
    {
      configFiles.append(
        ProjectConfigFileInfo(
          info: rootInfo,
          tool: descriptor.tool,
          category: descriptor.category,
          matchSource: descriptor.matchSource
        ))
    }

    configFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.config_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "config_file_count": .integer(Int64(configFiles.count)),
      "returned_count": .integer(Int64(configFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(configFiles.map(\.json)),
    ])
  }

  internal func projectIgnoreFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? true
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var ignoreFiles: [ProjectIgnoreFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectIgnoreFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        ignoreFiles: &ignoreFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = ignoreFileDescriptor(for: rootInfo.projectRelativePath)
    {
      ignoreFiles.append(
        ProjectIgnoreFileInfo(
          info: rootInfo,
          provider: descriptor.provider,
          category: descriptor.category,
          matchSource: descriptor.matchSource
        ))
    }

    ignoreFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.ignore_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "ignore_file_count": .integer(Int64(ignoreFiles.count)),
      "returned_count": .integer(Int64(ignoreFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(ignoreFiles.map(\.json)),
    ])
  }

  internal func projectAssetFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 500
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var assetFiles: [ProjectAssetFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectAssetFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        assetFiles: &assetFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = assetFileDescriptor(for: rootInfo.projectRelativePath)
    {
      assetFiles.append(
        ProjectAssetFileInfo(
          info: rootInfo,
          category: descriptor.category,
          subtype: descriptor.subtype,
          fileExtension: descriptor.fileExtension
        ))
    }

    assetFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.asset_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "asset_file_count": .integer(Int64(assetFiles.count)),
      "returned_count": .integer(Int64(assetFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(assetFiles.map(\.json)),
    ])
  }

  internal func projectArchiveFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 500
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var archiveFiles: [ProjectArchiveFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectArchiveFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        archiveFiles: &archiveFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = archiveFileDescriptor(for: rootInfo.projectRelativePath)
    {
      archiveFiles.append(
        ProjectArchiveFileInfo(
          info: rootInfo,
          category: descriptor.category,
          format: descriptor.format,
          fileExtension: descriptor.fileExtension,
          listSupported: descriptor.listSupported
        ))
    }

    archiveFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.archive_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "archive_file_count": .integer(Int64(archiveFiles.count)),
      "returned_count": .integer(Int64(archiveFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(archiveFiles.map(\.json)),
    ])
  }

  internal func projectLogFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 500
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var logFiles: [ProjectLogFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectLogFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        logFiles: &logFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = logFileDescriptor(for: rootInfo.projectRelativePath)
    {
      logFiles.append(
        ProjectLogFileInfo(
          info: rootInfo,
          category: descriptor.category,
          kind: descriptor.kind,
          matchSource: descriptor.matchSource,
          fileExtension: descriptor.fileExtension
        ))
    }

    logFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.log_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "log_file_count": .integer(Int64(logFiles.count)),
      "returned_count": .integer(Int64(logFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(logFiles.map(\.json)),
    ])
  }

  internal func projectDataFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 500
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var dataFiles: [ProjectDataFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectDataFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        dataFiles: &dataFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = dataFileDescriptor(for: rootInfo.projectRelativePath)
    {
      dataFiles.append(
        ProjectDataFileInfo(
          info: rootInfo,
          category: descriptor.category,
          format: descriptor.format,
          matchSource: descriptor.matchSource,
          textReadable: descriptor.textReadable,
          jsonReadable: descriptor.jsonReadable,
          jsonLinesReadable: descriptor.jsonLinesReadable,
          fileExtension: descriptor.fileExtension
        ))
    }

    dataFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.data_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "data_file_count": .integer(Int64(dataFiles.count)),
      "returned_count": .integer(Int64(dataFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(dataFiles.map(\.json)),
    ])
  }

  internal func projectSchemaFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 500
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var schemaFiles: [ProjectSchemaFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectSchemaFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        schemaFiles: &schemaFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = schemaFileDescriptor(for: rootInfo.projectRelativePath)
    {
      schemaFiles.append(
        ProjectSchemaFileInfo(
          info: rootInfo,
          category: descriptor.category,
          schemaKind: descriptor.schemaKind,
          format: descriptor.format,
          matchSource: descriptor.matchSource,
          jsonReadable: descriptor.jsonReadable,
          fileExtension: descriptor.fileExtension
        ))
    }

    schemaFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.schema_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "schema_file_count": .integer(Int64(schemaFiles.count)),
      "returned_count": .integer(Int64(schemaFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(schemaFiles.map(\.json)),
    ])
  }

  internal func projectSourceFiles(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let includeTests = try optionalBool("include_tests", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxResults = optionalInt("max_results", in: object) ?? 500
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var sourceFiles: [ProjectSourceFileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectSourceFiles(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        includeTests: includeTests,
        maxResults: maxResults,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        sourceFiles: &sourceFiles,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file",
      let descriptor = sourceFileDescriptor(for: rootInfo.projectRelativePath),
      includeTests || testFileDescriptor(for: rootInfo.projectRelativePath) == nil
    {
      sourceFiles.append(
        ProjectSourceFileInfo(
          info: rootInfo,
          language: descriptor.language,
          kind: descriptor.kind,
          matchSource: descriptor.matchSource
        ))
    }

    sourceFiles.sort {
      $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.source_files"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "include_tests": .bool(includeTests),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "source_file_count": .integer(Int64(sourceFiles.count)),
      "returned_count": .integer(Int64(sourceFiles.count)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated),
      "files": .array(sourceFiles.map(\.json)),
    ])
  }

  internal func projectOutline(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let includeTests = try optionalBool("include_tests", in: object) ?? false
    let includeImports = try optionalBool("include_imports", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 8
    let maxFiles = optionalInt("max_files", in: object) ?? 200
    let maxItems = optionalInt("max_items", in: object) ?? 1_000
    let maxBytesPerFile = optionalInt("max_bytes_per_file", in: object) ?? 262_144
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    try validateBoundedNonNegative(maxDepth, name: "max_depth", upperBound: 50)
    try validateBoundedPositive(maxFiles, name: "max_files", upperBound: 10_000)
    try validateBoundedPositive(maxItems, name: "max_items", upperBound: 50_000)
    try validateBoundedPositive(
      maxBytesPerFile, name: "max_bytes_per_file", upperBound: 20_971_520)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var items: [ProjectOutlineItem] = []
    var scannedEntries = 0
    var outlineFileCount = 0
    var bytesScanned = 0
    var fileTruncatedCount = 0
    var invalidUTF8FileCount = 0
    var scanTruncated = false
    var resultTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectOutlineItems(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        includeTests: includeTests,
        includeImports: includeImports,
        maxFiles: maxFiles,
        maxItems: maxItems,
        maxBytesPerFile: maxBytesPerFile,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        outlineFileCount: &outlineFileCount,
        bytesScanned: &bytesScanned,
        fileTruncatedCount: &fileTruncatedCount,
        invalidUTF8FileCount: &invalidUTF8FileCount,
        items: &items,
        scanTruncated: &scanTruncated,
        resultTruncated: &resultTruncated
      )
    } else if rootInfo.type == "file" {
      try appendProjectOutlineItems(
        url: root,
        info: rootInfo,
        includeTests: includeTests,
        includeImports: includeImports,
        maxFiles: maxFiles,
        maxItems: maxItems,
        maxBytesPerFile: maxBytesPerFile,
        outlineFileCount: &outlineFileCount,
        bytesScanned: &bytesScanned,
        fileTruncatedCount: &fileTruncatedCount,
        invalidUTF8FileCount: &invalidUTF8FileCount,
        items: &items,
        resultTruncated: &resultTruncated
      )
    } else {
      throw GatewayToolError.invalidArguments("Path is not a file or directory: \(path)")
    }

    items.sort {
      if $0.info.projectRelativePath == $1.info.projectRelativePath {
        return $0.item.line < $1.item.line
      }
      return $0.info.projectRelativePath.localizedStandardCompare($1.info.projectRelativePath)
        == .orderedAscending
    }

    return .object([
      "operation": .string("project.outline"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "include_tests": .bool(includeTests),
      "include_imports": .bool(includeImports),
      "max_depth": .integer(Int64(maxDepth)),
      "max_files": .integer(Int64(maxFiles)),
      "max_items": .integer(Int64(maxItems)),
      "max_bytes_per_file": .integer(Int64(maxBytesPerFile)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "outline_file_count": .integer(Int64(outlineFileCount)),
      "outline_item_count": .integer(Int64(items.count)),
      "returned_count": .integer(Int64(items.count)),
      "bytes_scanned": .integer(Int64(bytesScanned)),
      "file_truncated_count": .integer(Int64(fileTruncatedCount)),
      "invalid_utf8_file_count": .integer(Int64(invalidUTF8FileCount)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated || fileTruncatedCount > 0),
      "items": .array(items.map(\.json)),
    ])
  }

  internal func projectCommands(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let maxDepth = optionalInt("max_depth", in: object) ?? 4
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let maxScanEntries = optionalInt("max_scan_entries", in: object) ?? 20_000
    let maxBytesPerFile = optionalInt("max_bytes_per_file", in: object) ?? 262_144
    try validateNonNegative(maxDepth, name: "max_depth")
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedPositive(maxScanEntries, name: "max_scan_entries", upperBound: 200_000)
    try validateBoundedPositive(maxBytesPerFile, name: "max_bytes_per_file", upperBound: 2_097_152)

    let root = try projectScope.resolvedProjectURL(path)
    let rootInfo = try projectScope.fileInfo(url: root)
    var manifests: [FileInfo] = []
    var scannedEntries = 0
    var scanTruncated = false

    if rootInfo.type == "directory" {
      try collectProjectCommandManifests(
        directory: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        includeHidden: includeHidden,
        maxScanEntries: maxScanEntries,
        scannedEntries: &scannedEntries,
        manifests: &manifests,
        scanTruncated: &scanTruncated
      )
    } else if rootInfo.type == "file",
      Self.commandManifestNames.contains(root.lastPathComponent)
    {
      manifests.append(rootInfo)
    }

    manifests.sort {
      $0.projectRelativePath.localizedStandardCompare($1.projectRelativePath)
        == .orderedAscending
    }

    var commands: [ProjectCommandInfo] = []
    var parseErrors: [ProjectCommandParseError] = []
    var fileTruncatedCount = 0

    for manifest in manifests {
      let parsed = parseProjectCommandManifest(info: manifest, maxBytesPerFile: maxBytesPerFile)
      commands.append(contentsOf: parsed.commands)
      parseErrors.append(contentsOf: parsed.errors)
      if parsed.fileTruncated {
        fileTruncatedCount += 1
      }
    }

    commands.sort {
      if $0.sourceProjectRelativePath != $1.sourceProjectRelativePath {
        return $0.sourceProjectRelativePath.localizedStandardCompare(
          $1.sourceProjectRelativePath)
          == .orderedAscending
      }
      if $0.ecosystem != $1.ecosystem {
        return $0.ecosystem.localizedStandardCompare($1.ecosystem) == .orderedAscending
      }
      if $0.kind != $1.kind {
        return $0.kind.localizedStandardCompare($1.kind) == .orderedAscending
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }

    let commandCount = commands.count
    let resultTruncated = commands.count > maxResults
    if resultTruncated {
      commands = Array(commands.prefix(maxResults))
    }

    return .object([
      "operation": .string("project.commands"),
      "path": .string(root.path),
      "project_relative_path": .string(projectScope.projectRelativePath(root)),
      "include_hidden": .bool(includeHidden),
      "max_depth": .integer(Int64(maxDepth)),
      "max_results": .integer(Int64(maxResults)),
      "max_scan_entries": .integer(Int64(maxScanEntries)),
      "max_bytes_per_file": .integer(Int64(maxBytesPerFile)),
      "scanned_entry_count": .integer(Int64(scannedEntries)),
      "manifest_count": .integer(Int64(manifests.count)),
      "command_count": .integer(Int64(commandCount)),
      "returned_count": .integer(Int64(commands.count)),
      "file_truncated_count": .integer(Int64(fileTruncatedCount)),
      "scan_truncated": .bool(scanTruncated),
      "result_truncated": .bool(resultTruncated),
      "truncated": .bool(scanTruncated || resultTruncated || fileTruncatedCount > 0),
      "commands": .array(commands.map(\.json)),
      "parse_errors": .array(parseErrors.map(\.json)),
    ])
  }

  internal func openProject(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let application = try optionalString("application", in: object)
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let url = try projectScope.resolvedProjectURL(path)
    guard let opener = environment.projectOpener else {
      throw GatewayToolError.disabled("Project opening is unavailable on this platform.")
    }
    return try opener.open(
      url, application: application,
      workingDirectory: configuration.projectDirectory,
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes
    ).json
  }

  internal func revealProjectPath(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let url = try projectScope.resolvedProjectURL(path)

    guard let opener = environment.projectOpener else {
      throw GatewayToolError.disabled("Project opening is unavailable on this platform.")
    }
    return try opener.reveal(
      url,
      workingDirectory: configuration.projectDirectory,
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes
    ).json
  }
}
