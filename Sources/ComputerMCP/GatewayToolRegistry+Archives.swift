import Foundation

extension GatewayToolRegistry {
  internal func listArchive(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let maxEntries = optionalInt("max_entries", in: object) ?? 1_000
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
    let archive = try archiveListCommand(for: url)
    let result = try commandRunner.run(
      executable: archive.executable,
      arguments: archive.arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    let allEntries = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    let entries = allEntries.prefix(maxEntries).map { entry -> JSONValue in
      .object([
        "path": .string(entry),
        "is_directory": .bool(entry.hasSuffix("/")),
      ])
    }

    return .object([
      "operation": .string("archive.list"),
      "archive": .object([
        "path": .string(url.path),
        "workspace_relative_path": .string(info.workspaceRelativePath),
        "format": .string(archive.format),
      ]),
      "argv": .array(archive.arguments.map(JSONValue.string)),
      "max_entries": .integer(Int64(maxEntries)),
      "entry_count": .integer(Int64(entries.count)),
      "truncated": .bool(result.stdoutTruncated || allEntries.count > entries.count),
      "entries": .array(Array(entries)),
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

  internal func readArchiveFile(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let entry = try requiredString("entry", in: object)
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let encoding = try optionalString("encoding", in: object) ?? "utf8"
    guard encoding == "utf8" || encoding == "base64" || encoding == "auto" else {
      throw GatewayToolError.invalidArguments("encoding must be utf8, base64, or auto.")
    }
    try validateBoundedPositive(maxBytes, name: "max_bytes", upperBound: 20_971_520)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)

    let archiveURL = try resolvedWorkspaceURL(path)
    let archiveInfo = try fileInfo(url: archiveURL)
    guard archiveInfo.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }

    let normalizedEntry = try normalizedReadableArchiveEntryPath(entry)
    let archive = try archiveListCommand(for: archiveURL)
    let readCommand = try archiveReadFileCommand(
      archive: archive,
      archiveURL: archiveURL,
      entry: normalizedEntry
    )
    let result = try commandRunner.runData(
      executable: readCommand.executable,
      arguments: readCommand.arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxBytes
    )
    try requireSuccessfulArchiveRead(result)
    let validUTF8 = String(data: result.stdout, encoding: .utf8) != nil
    let resolvedEncoding: String
    let content: String
    switch encoding {
    case "utf8":
      guard let text = String(data: result.stdout, encoding: .utf8) else {
        throw GatewayToolError.invalidArguments(
          "archive.read_file member is not valid UTF-8; use encoding=base64 or encoding=auto.")
      }
      resolvedEncoding = "utf8"
      content = text
    case "base64":
      resolvedEncoding = "base64"
      content = result.stdout.base64EncodedString()
    case "auto":
      if let text = String(data: result.stdout, encoding: .utf8) {
        resolvedEncoding = "utf8"
        content = text
      } else {
        resolvedEncoding = "base64"
        content = result.stdout.base64EncodedString()
      }
    default:
      throw GatewayToolError.invalidArguments("encoding must be utf8, base64, or auto.")
    }

    return .object([
      "operation": .string("archive.read_file"),
      "archive": .object([
        "path": .string(archiveURL.path),
        "workspace_relative_path": .string(archiveInfo.workspaceRelativePath),
        "format": .string(archive.format),
      ]),
      "entry": .object([
        "requested_path": .string(entry),
        "normalized_path": .string(normalizedEntry),
      ]),
      "argv": .array(readCommand.arguments.map(JSONValue.string)),
      "requested_encoding": .string(encoding),
      "encoding": .string(resolvedEncoding),
      "valid_utf8": .bool(validUTF8),
      "content": .string(content),
      "bytes_read": .integer(Int64(result.stdout.count)),
      "max_bytes": .integer(Int64(maxBytes)),
      "content_truncated": .bool(result.stdoutTruncated),
      "truncated": .bool(result.stdoutTruncated),
      "result": .object([
        "executable": .string(result.executable),
        "arguments": .array(result.arguments.map(JSONValue.string)),
        "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
        "timed_out": .bool(result.timedOut),
        "stderr": .string(result.stderrString),
        "stderr_truncated": .bool(result.stderrTruncated),
        "stdout_truncated": .bool(result.stdoutTruncated),
      ]),
    ])
  }

  internal func extractArchive(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let destinationPath = try requiredString("destination", in: object)
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmExtract = try optionalBool("confirm_extract", in: object) ?? false
    guard dryRun || confirmExtract else {
      throw GatewayToolError.invalidArguments(
        "archive.extract requires confirm_extract=true when dry_run is false.")
    }

    let maxEntries = optionalInt("max_entries", in: object) ?? 100_000
    let maxPreviewEntries = optionalInt("max_preview_entries", in: object) ?? 100
    let timeout = optionalInt("timeout_ms", in: object) ?? 30_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 100_000)
    try validateBoundedNonNegative(
      maxPreviewEntries,
      name: "max_preview_entries",
      upperBound: 5_000
    )
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let archiveURL = try resolvedWorkspaceURL(path)
    let archiveInfo = try fileInfo(url: archiveURL)
    guard archiveInfo.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    let destinationURL = try resolvedWorkspaceURL(destinationPath)
    let fileManager = FileManager.default
    var destinationIsDirectory = ObjCBool(false)
    let destinationExists = fileManager.fileExists(
      atPath: destinationURL.path,
      isDirectory: &destinationIsDirectory
    )
    if destinationExists {
      guard destinationIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments(
          "Destination exists and is not a directory: \(destinationPath)")
      }
    } else if !createDirectories {
      throw GatewayToolError.invalidArguments(
        "Destination directory does not exist; set create_directories=true to create it.")
    }

    let archive = try archiveListCommand(for: archiveURL)
    let listResult = try commandRunner.run(
      executable: archive.executable,
      arguments: archive.arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    try requireSuccessfulArchivePreflight(listResult, operation: "archive list")
    let rawEntries = listResult.stdout.split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    guard rawEntries.count <= maxEntries else {
      throw GatewayToolError.invalidArguments(
        "archive contains more than max_entries entries; increase max_entries to validate extraction."
      )
    }
    let linkEntries = try archiveLinkEntries(
      archiveURL: archiveURL,
      archive: archive,
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
    guard linkEntries.isEmpty else {
      throw GatewayToolError.invalidArguments(
        "archive.extract refuses archives containing link entries: \(linkEntries.prefix(5).joined(separator: ", "))"
      )
    }

    let entries = try validateArchiveEntries(
      rawEntries,
      destination: destinationURL,
      overwrite: overwrite
    )
    let previewEntries = entries.prefix(maxPreviewEntries).map(\.json)
    let extractCommand = try archiveExtractCommand(
      archive: archive,
      archiveURL: archiveURL,
      destinationURL: destinationURL,
      overwrite: overwrite
    )

    var result: JSONValue = .null
    if !dryRun {
      if !destinationExists {
        try fileManager.createDirectory(
          at: destinationURL,
          withIntermediateDirectories: true
        )
      }
      let commandResult = try commandRunner.run(
        executable: extractCommand.executable,
        arguments: extractCommand.arguments,
        workingDirectory: configuration.workspaceDirectory,
        environment: [:],
        timeoutMilliseconds: timeout,
        maxOutputBytes: maxOutputBytes
      )
      result = commandResult.json
    }

    return .object([
      "operation": .string("archive.extract"),
      "archive": .object([
        "path": .string(archiveURL.path),
        "workspace_relative_path": .string(archiveInfo.workspaceRelativePath),
        "format": .string(archive.format),
      ]),
      "destination": .object([
        "path": .string(destinationURL.path),
        "workspace_relative_path": .string(workspaceRelativePath(destinationURL)),
        "exists": .bool(destinationExists),
        "would_create": .bool(!destinationExists && createDirectories),
      ]),
      "argv": .array(extractCommand.arguments.map(JSONValue.string)),
      "confirm_extract": .bool(confirmExtract),
      "create_directories": .bool(createDirectories),
      "dry_run": .bool(dryRun),
      "entry_count": .integer(Int64(entries.count)),
      "entries": .array(Array(previewEntries)),
      "entries_truncated": .bool(entries.count > previewEntries.count),
      "format": .string(archive.format),
      "link_entry_count": .integer(Int64(linkEntries.count)),
      "max_entries": .integer(Int64(maxEntries)),
      "max_preview_entries": .integer(Int64(maxPreviewEntries)),
      "overwrite": .bool(overwrite),
      "result": result,
      "would_extract": .bool(true),
    ])
  }

  internal func createArchive(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try requiredString("path", in: object)
    let sourcePaths = try requiredStringArray("sources", in: object)
    guard !sourcePaths.isEmpty else {
      throw GatewayToolError.invalidArguments("sources must not be empty.")
    }
    let requestedFormat = try optionalString("format", in: object)
    let createDirectories = try optionalBool("create_directories", in: object) ?? false
    let overwrite = try optionalBool("overwrite", in: object) ?? false
    let dryRun = try optionalBool("dry_run", in: object) ?? true
    let confirmCreate = try optionalBool("confirm_create", in: object) ?? false
    guard dryRun || confirmCreate else {
      throw GatewayToolError.invalidArguments(
        "archive.create requires confirm_create=true when dry_run is false.")
    }

    let maxEntries = optionalInt("max_entries", in: object) ?? 100_000
    let maxPreviewEntries = optionalInt("max_preview_entries", in: object) ?? 100
    let timeout = optionalInt("timeout_ms", in: object) ?? 30_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 100_000)
    try validateBoundedNonNegative(
      maxPreviewEntries,
      name: "max_preview_entries",
      upperBound: 5_000
    )
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let archiveURL = try resolvedWorkspaceURLPreservingFinalSymlink(path)
    let archiveParentURL = archiveURL.deletingLastPathComponent()
    let fileManager = FileManager.default
    var parentIsDirectory = ObjCBool(false)
    let parentExists = fileManager.fileExists(
      atPath: archiveParentURL.path,
      isDirectory: &parentIsDirectory
    )
    if parentExists {
      guard parentIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Archive parent is not a directory: \(path)")
      }
    } else if !createDirectories {
      throw GatewayToolError.invalidArguments(
        "Archive parent directory does not exist; set create_directories=true to create it.")
    }

    var archiveIsDirectory = ObjCBool(false)
    let archiveExists = fileManager.fileExists(
      atPath: archiveURL.path,
      isDirectory: &archiveIsDirectory
    )
    if archiveExists {
      let archiveInfo = try fileInfo(url: archiveURL)
      guard !archiveInfo.isSymlink else {
        throw GatewayToolError.invalidArguments("Archive output path is a symlink: \(path)")
      }
      guard !archiveIsDirectory.boolValue else {
        throw GatewayToolError.invalidArguments("Archive output path is a directory: \(path)")
      }
      guard overwrite else {
        throw GatewayToolError.invalidArguments(
          "Archive output already exists; set overwrite=true to replace it.")
      }
    }

    let sourceSnapshot = try validateArchiveCreateSources(
      sourcePaths,
      archiveURL: archiveURL,
      maxEntries: maxEntries,
      maxPreviewEntries: maxPreviewEntries
    )
    let createCommand = try archiveCreateCommand(
      for: archiveURL,
      requestedFormat: requestedFormat,
      sourcePaths: sourceSnapshot.argvSourcePaths
    )

    var result: JSONValue = .null
    if !dryRun {
      if !parentExists {
        try fileManager.createDirectory(
          at: archiveParentURL,
          withIntermediateDirectories: true
        )
      }
      if archiveExists && overwrite {
        try fileManager.removeItem(at: archiveURL)
      }
      let commandResult = try commandRunner.run(
        executable: createCommand.executable,
        arguments: createCommand.arguments,
        workingDirectory: configuration.workspaceDirectory,
        environment: [:],
        timeoutMilliseconds: timeout,
        maxOutputBytes: maxOutputBytes
      )
      result = commandResult.json
    }

    return .object([
      "operation": .string("archive.create"),
      "archive": .object([
        "path": .string(archiveURL.path),
        "workspace_relative_path": .string(workspaceRelativePathPreservingSymlinks(archiveURL)),
        "format": .string(createCommand.format),
        "exists": .bool(archiveExists),
        "would_create_parent_directories": .bool(!parentExists && createDirectories),
        "would_overwrite": .bool(archiveExists && overwrite),
      ]),
      "argv": .array(createCommand.arguments.map(JSONValue.string)),
      "confirm_create": .bool(confirmCreate),
      "create_directories": .bool(createDirectories),
      "dry_run": .bool(dryRun),
      "entry_count": .integer(Int64(sourceSnapshot.entryCount)),
      "entries": .array(sourceSnapshot.previewEntries.map(\.json)),
      "entries_truncated": .bool(sourceSnapshot.entryCount > sourceSnapshot.previewEntries.count),
      "format": .string(createCommand.format),
      "max_entries": .integer(Int64(maxEntries)),
      "max_preview_entries": .integer(Int64(maxPreviewEntries)),
      "overwrite": .bool(overwrite),
      "result": result,
      "source_count": .integer(Int64(sourceSnapshot.sources.count)),
      "sources": .array(sourceSnapshot.sources.map(\.json)),
      "would_create": .bool(true),
    ])
  }

  private func archiveListCommand(for url: URL) throws -> ArchiveListCommand {
    let name = url.lastPathComponent.lowercased()
    if name.hasSuffix(".zip") || name.hasSuffix(".jar") || name.hasSuffix(".war")
      || name.hasSuffix(".ear")
    {
      return ArchiveListCommand(
        format: "zip",
        executable: "/usr/bin/zipinfo",
        arguments: ["-1", url.path]
      )
    }

    let tarSuffixes = [
      ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz",
    ]
    if tarSuffixes.contains(where: { name.hasSuffix($0) }) {
      return ArchiveListCommand(
        format: "tar",
        executable: "/usr/bin/tar",
        arguments: ["-tf", url.path]
      )
    }

    throw GatewayToolError.invalidArguments(
      "Unsupported archive format. Supported suffixes: .zip, .jar, .war, .ear, .tar, .tar.gz, .tgz, .tar.bz2, .tbz, .tbz2, .tar.xz, .txz."
    )
  }

  private func archiveVerboseListCommand(
    archive: ArchiveListCommand,
    archiveURL: URL
  ) throws -> ArchiveListCommand {
    switch archive.format {
    case "zip":
      return ArchiveListCommand(
        format: archive.format,
        executable: "/usr/bin/zipinfo",
        arguments: ["-l", archiveURL.path]
      )
    case "tar":
      return ArchiveListCommand(
        format: archive.format,
        executable: "/usr/bin/tar",
        arguments: ["-tvf", archiveURL.path]
      )
    default:
      throw GatewayToolError.invalidArguments("Unsupported archive format: \(archive.format)")
    }
  }

  private func archiveExtractCommand(
    archive: ArchiveListCommand,
    archiveURL: URL,
    destinationURL: URL,
    overwrite: Bool
  ) throws -> ArchiveListCommand {
    switch archive.format {
    case "zip":
      return ArchiveListCommand(
        format: archive.format,
        executable: "/usr/bin/unzip",
        arguments: ["-q", overwrite ? "-o" : "-n", archiveURL.path, "-d", destinationURL.path]
      )
    case "tar":
      let args =
        overwrite
        ? ["-xf", archiveURL.path, "-C", destinationURL.path]
        : ["-xkf", archiveURL.path, "-C", destinationURL.path]
      return ArchiveListCommand(
        format: archive.format,
        executable: "/usr/bin/tar",
        arguments: args
      )
    default:
      throw GatewayToolError.invalidArguments("Unsupported archive format: \(archive.format)")
    }
  }

  private func archiveReadFileCommand(
    archive: ArchiveListCommand,
    archiveURL: URL,
    entry: String
  ) throws -> ArchiveListCommand {
    switch archive.format {
    case "zip":
      return ArchiveListCommand(
        format: archive.format,
        executable: "/usr/bin/unzip",
        arguments: ["-p", archiveURL.path, entry]
      )
    case "tar":
      return ArchiveListCommand(
        format: archive.format,
        executable: "/usr/bin/tar",
        arguments: ["-xOf", archiveURL.path, entry]
      )
    default:
      throw GatewayToolError.invalidArguments("Unsupported archive format: \(archive.format)")
    }
  }

  private func archiveCreateCommand(
    for archiveURL: URL,
    requestedFormat: String?,
    sourcePaths: [String]
  ) throws -> ArchiveListCommand {
    let name = archiveURL.lastPathComponent.lowercased()
    let normalizedFormat = requestedFormat?.lowercased()
    if let normalizedFormat, normalizedFormat != "zip" && normalizedFormat != "tar" {
      throw GatewayToolError.invalidArguments("format must be one of: zip, tar.")
    }

    if name.hasSuffix(".zip") || name.hasSuffix(".jar") || name.hasSuffix(".war")
      || name.hasSuffix(".ear")
    {
      if normalizedFormat == "tar" {
        throw GatewayToolError.invalidArguments("format=tar does not match archive path suffix.")
      }
      return ArchiveListCommand(
        format: "zip",
        executable: "/usr/bin/zip",
        arguments: ["-qry", archiveURL.path] + sourcePaths
      )
    }

    let tarFlag: String?
    if name.hasSuffix(".tar") {
      tarFlag = "-cf"
    } else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
      tarFlag = "-czf"
    } else if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") || name.hasSuffix(".tbz2") {
      tarFlag = "-cjf"
    } else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") {
      tarFlag = "-cJf"
    } else {
      tarFlag = nil
    }
    if let tarFlag {
      if normalizedFormat == "zip" {
        throw GatewayToolError.invalidArguments("format=zip does not match archive path suffix.")
      }
      return ArchiveListCommand(
        format: "tar",
        executable: "/usr/bin/tar",
        arguments: [tarFlag, archiveURL.path] + sourcePaths
      )
    }

    throw GatewayToolError.invalidArguments(
      "Unsupported archive format. Supported suffixes: .zip, .jar, .war, .ear, .tar, .tar.gz, .tgz, .tar.bz2, .tbz, .tbz2, .tar.xz, .txz."
    )
  }

  private func validateArchiveCreateSources(
    _ rawSourcePaths: [String],
    archiveURL: URL,
    maxEntries: Int,
    maxPreviewEntries: Int
  ) throws -> ArchiveCreateSourceSnapshot {
    let fileManager = FileManager.default
    let archivePath = archiveURL.standardizedFileURL.path
    var sources: [ArchiveCreateSource] = []
    var previewEntries: [ArchiveCreateEntry] = []
    var entryCount = 0
    var argvSourcePaths: [String] = []

    func appendEntry(url: URL, type: String) throws {
      entryCount += 1
      guard entryCount <= maxEntries else {
        throw GatewayToolError.invalidArguments(
          "sources contain more than max_entries entries; increase max_entries to validate archive creation."
        )
      }
      if previewEntries.count < maxPreviewEntries {
        previewEntries.append(
          ArchiveCreateEntry(
            workspaceRelativePath: workspaceRelativePathPreservingSymlinks(url),
            type: type
          ))
      }
    }

    for rawSourcePath in rawSourcePaths {
      let lexicalSourceURL = try lexicalWorkspaceURL(rawSourcePath)
      let resolvedSourceURL = try resolvedWorkspaceURL(rawSourcePath)
      let sourceInfo = try fileInfo(url: lexicalSourceURL)
      guard !sourceInfo.isSymlink else {
        throw GatewayToolError.invalidArguments(
          "archive.create refuses symbolic link sources: \(rawSourcePath)")
      }
      guard sourceInfo.type == "file" || sourceInfo.type == "directory" else {
        throw GatewayToolError.invalidArguments(
          "archive.create source must be a file or directory: \(rawSourcePath)")
      }

      let sourcePath = resolvedSourceURL.standardizedFileURL.path
      let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : "\(sourcePath)/"
      guard archivePath != sourcePath && !archivePath.hasPrefix(sourcePrefix) else {
        throw GatewayToolError.invalidArguments(
          "Archive output must not be inside a source path: \(rawSourcePath)")
      }

      let sourceEntryStart = entryCount
      try appendEntry(url: lexicalSourceURL, type: sourceInfo.type)

      if sourceInfo.type == "directory" {
        var enumerationError: Error?
        guard
          let enumerator = fileManager.enumerator(
            at: lexicalSourceURL,
            includingPropertiesForKeys: [
              .isDirectoryKey,
              .isRegularFileKey,
              .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, error in
              enumerationError = error
              return false
            }
          )
        else {
          throw GatewayToolError.invalidArguments(
            "Unable to enumerate source directory: \(rawSourcePath)")
        }

        for case let itemURL as URL in enumerator {
          let values = try itemURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
          ])
          if values.isSymbolicLink == true {
            throw GatewayToolError.invalidArguments(
              "archive.create refuses symbolic link entries: \(workspaceRelativePathPreservingSymlinks(itemURL))"
            )
          }
          let type =
            values.isDirectory == true
            ? "directory"
            : (values.isRegularFile == true ? "file" : "other")
          guard type == "file" || type == "directory" else {
            throw GatewayToolError.invalidArguments(
              "archive.create source contains unsupported file type: \(workspaceRelativePathPreservingSymlinks(itemURL))"
            )
          }
          try appendEntry(url: itemURL, type: type)
        }

        if let enumerationError {
          throw GatewayToolError.invalidArguments(
            "Unable to enumerate source directory \(rawSourcePath): \(enumerationError.localizedDescription)"
          )
        }
      }

      let sourceEntryCount = entryCount - sourceEntryStart
      let argvSourcePath = workspaceRelativePathPreservingSymlinks(lexicalSourceURL)
      argvSourcePaths.append(argvSourcePath)
      sources.append(
        ArchiveCreateSource(
          path: lexicalSourceURL.path,
          workspaceRelativePath: argvSourcePath,
          type: sourceInfo.type,
          entryCount: sourceEntryCount
        ))
    }

    return ArchiveCreateSourceSnapshot(
      sources: sources,
      argvSourcePaths: argvSourcePaths,
      entryCount: entryCount,
      previewEntries: previewEntries
    )
  }

  private func requireSuccessfulArchivePreflight(
    _ result: CommandResult,
    operation: String
  ) throws {
    guard !result.timedOut else {
      throw GatewayToolError.invalidArguments("\(operation) timed out.")
    }
    guard result.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "\(operation) failed with exit code \(result.exitCode.map(String.init) ?? "unknown").")
    }
    guard !result.stdoutTruncated else {
      throw GatewayToolError.invalidArguments(
        "\(operation) output was truncated; increase max_output_bytes to validate extraction.")
    }
  }

  private func requireSuccessfulArchiveRead(_ result: CommandDataResult) throws {
    guard !result.timedOut else {
      throw GatewayToolError.invalidArguments("archive.read_file timed out.")
    }
    guard result.exitCode == 0 else {
      throw GatewayToolError.invalidArguments(
        "archive.read_file failed with exit code \(result.exitCode.map(String.init) ?? "unknown").")
    }
  }

  private func archiveLinkEntries(
    archiveURL: URL,
    archive: ArchiveListCommand,
    timeout: Int,
    maxOutputBytes: Int
  ) throws -> [String] {
    let verboseCommand = try archiveVerboseListCommand(archive: archive, archiveURL: archiveURL)
    let result = try commandRunner.run(
      executable: verboseCommand.executable,
      arguments: verboseCommand.arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    try requireSuccessfulArchivePreflight(result, operation: "archive verbose list")
    return result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { line in
        guard let first = line.first else {
          return false
        }
        return first == "l" || first == "h"
      }
  }

  private func validateArchiveEntries(
    _ rawEntries: [String],
    destination: URL,
    overwrite: Bool
  ) throws -> [ArchiveValidatedEntry] {
    let fileManager = FileManager.default
    let destinationBase = destination.standardizedFileURL.resolvingSymlinksInPath()
    let destinationBasePath = destinationBase.path
    let destinationBasePrefix =
      destinationBasePath.hasSuffix("/") ? destinationBasePath : "\(destinationBasePath)/"
    var entries: [ArchiveValidatedEntry] = []

    for rawEntry in rawEntries {
      let normalizedPath = try normalizedArchiveEntryPath(rawEntry)
      let isDirectory = rawEntry.hasSuffix("/") || normalizedPath == "."
      let targetURL = destination.appendingPathComponent(normalizedPath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      guard targetURL.path == destinationBasePath || targetURL.path.hasPrefix(destinationBasePrefix)
      else {
        throw GatewayToolError.invalidArguments(
          "archive entry escapes destination: \(rawEntry)")
      }

      let targetExists: Bool
      var targetIsDirectory = ObjCBool(false)
      if normalizedPath == "." {
        targetExists = true
        targetIsDirectory = true
      } else {
        targetExists = fileManager.fileExists(
          atPath: targetURL.path,
          isDirectory: &targetIsDirectory
        )
      }
      if targetExists {
        if isDirectory {
          guard targetIsDirectory.boolValue else {
            throw GatewayToolError.invalidArguments(
              "archive entry would replace a non-directory path: \(normalizedPath)")
          }
        } else if !overwrite {
          throw GatewayToolError.invalidArguments(
            "archive entry would overwrite existing path: \(normalizedPath)")
        }
      }

      let parent = targetURL.deletingLastPathComponent()
      var parentIsDirectory = ObjCBool(false)
      if fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) {
        guard parentIsDirectory.boolValue else {
          throw GatewayToolError.invalidArguments(
            "archive entry parent is not a directory: \(normalizedPath)")
        }
      }

      entries.append(
        ArchiveValidatedEntry(
          originalPath: rawEntry,
          normalizedPath: normalizedPath,
          isDirectory: isDirectory,
          destinationWorkspaceRelativePath: workspaceRelativePath(targetURL),
          wouldOverwrite: targetExists && !isDirectory
        ))
    }

    return entries
  }

  private func normalizedReadableArchiveEntryPath(_ entry: String) throws -> String {
    guard !entry.hasSuffix("/") else {
      throw GatewayToolError.invalidArguments(
        "archive.read_file entry must be a file, not a directory.")
    }
    let normalizedPath = try normalizedArchiveEntryPath(entry)
    guard normalizedPath != "." else {
      throw GatewayToolError.invalidArguments("archive.read_file entry must be a file path.")
    }
    guard !normalizedPath.hasPrefix("-") else {
      throw GatewayToolError.invalidArguments(
        "archive.read_file entry must not start with '-'.")
    }
    let wildcardCharacters = CharacterSet(charactersIn: "*?[]")
    guard normalizedPath.rangeOfCharacter(from: wildcardCharacters) == nil else {
      throw GatewayToolError.invalidArguments(
        "archive.read_file entry must not contain archive wildcard characters.")
    }
    return normalizedPath
  }

  private func normalizedArchiveEntryPath(_ entry: String) throws -> String {
    guard !entry.isEmpty else {
      throw GatewayToolError.invalidArguments("archive contains an empty entry path.")
    }
    guard !entry.hasPrefix("/") else {
      throw GatewayToolError.invalidArguments("archive contains an absolute entry path: \(entry)")
    }
    let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
    var normalized: [String] = []
    for part in parts {
      if part.isEmpty || part == "." {
        continue
      }
      guard part != ".." else {
        throw GatewayToolError.invalidArguments("archive entry escapes destination: \(entry)")
      }
      normalized.append(String(part))
    }
    return normalized.isEmpty ? "." : normalized.joined(separator: "/")
  }
}

private struct ArchiveListCommand {
  var format: String
  var executable: String
  var arguments: [String]
}

private struct ArchiveValidatedEntry {
  var originalPath: String
  var normalizedPath: String
  var isDirectory: Bool
  var destinationWorkspaceRelativePath: String
  var wouldOverwrite: Bool

  var json: JSONValue {
    .object([
      "path": .string(originalPath),
      "normalized_path": .string(normalizedPath),
      "is_directory": .bool(isDirectory),
      "destination_workspace_relative_path": .string(destinationWorkspaceRelativePath),
      "would_overwrite": .bool(wouldOverwrite),
    ])
  }
}

private struct ArchiveCreateSourceSnapshot {
  var sources: [ArchiveCreateSource]
  var argvSourcePaths: [String]
  var entryCount: Int
  var previewEntries: [ArchiveCreateEntry]
}

private struct ArchiveCreateSource {
  var path: String
  var workspaceRelativePath: String
  var type: String
  var entryCount: Int

  var json: JSONValue {
    .object([
      "path": .string(path),
      "workspace_relative_path": .string(workspaceRelativePath),
      "type": .string(type),
      "entry_count": .integer(Int64(entryCount)),
    ])
  }
}

private struct ArchiveCreateEntry {
  var workspaceRelativePath: String
  var type: String

  var json: JSONValue {
    .object([
      "workspace_relative_path": .string(workspaceRelativePath),
      "type": .string(type),
    ])
  }
}
