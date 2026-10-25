import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPToolKit
import Foundation

extension FilesToolProvider {
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

    let url = try projectScope.resolvedProjectURL(path)
    let info = try projectScope.fileInfo(url: url)
    guard info.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    let archive = try archiveListCommand(for: url)
    let result = try commandRunner.run(
      executable: archive.executable,
      arguments: archive.arguments,
      workingDirectory: configuration.projectDirectory,
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
        "project_relative_path": .string(info.projectRelativePath),
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

    let archiveURL = try projectScope.resolvedProjectURL(path)
    let archiveInfo = try projectScope.fileInfo(url: archiveURL)
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
      workingDirectory: configuration.projectDirectory,
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
        "project_relative_path": .string(archiveInfo.projectRelativePath),
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
    let files = try ProjectFileAccess(
      project: projectScope.projectDirectory, environment: environment.environment,
      commands: environment.registeredCommands,
      mutationObserver: fileMutationObserver)
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

    let archiveURL = try projectScope.resolvedProjectURL(path)
    let archiveInfo = try projectScope.fileInfo(url: archiveURL)
    guard archiveInfo.type == "file" else {
      throw GatewayToolError.invalidArguments("Path is not a file: \(path)")
    }
    let destinationURL = try files.url(destinationPath)
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

    let format = try archiveFormat(for: archiveURL)
    let reader = try archiveReader(for: format)
    let listing = archiveVerboseListCommand(archiveURL: archiveURL, reader: reader)
    let listResult = try commandRunner.run(
      executable: listing.executable, arguments: listing.arguments,
      workingDirectory: configuration.projectDirectory, environment: ["LC_ALL": "C"],
      timeoutMilliseconds: timeout, maxOutputBytes: maxOutputBytes)
    try requireSuccessfulArchivePreflight(listResult, operation: "archive list")
    let listedEntries = try parseArchiveListing(listResult.stdout)
    guard listedEntries.count <= maxEntries else {
      throw GatewayToolError.invalidArguments(
        "archive contains more than max_entries entries; increase max_entries to validate extraction."
      )
    }
    let entries = try validateArchiveEntries(
      listedEntries, destination: destinationURL, overwrite: overwrite, files: files)
    let previewEntries = entries.prefix(maxPreviewEntries).map(\.json)
    var extractionResult: JSONValue = .null
    if !dryRun {
      let modificationTimes = try archiveModificationTimes(
        archiveURL, reader: reader, entries: entries, timeout: timeout,
        maxOutputBytes: maxOutputBytes)
      let createdDestination = try files.mkdir(destinationURL, recursive: createDirectories)
      extractionResult = try files.withStagingDirectory(
        in: destinationURL, destinationIdentity: createdDestination,
        preservingDestinationTimes: createdDestination == nil
      ) { staging, directory in
        let command = archiveExtractCommand(archiveURL: archiveURL, reader: reader)
        let result = try files.withTemporaryFile(in: staging) { contents in
          try fileMutationObserver?("archive.extract", staging, .willMutate)
          let result = try files.withReadDescriptor(archiveURL) { input in
            try commandRunner.runInDirectory(
              executable: command.executable, arguments: command.arguments,
              directoryDescriptor: directory, inputDescriptor: input, outputDescriptor: contents,
              environment: ["LC_ALL": "C"], timeoutMilliseconds: timeout,
              maxOutputBytes: maxOutputBytes)
          }
          try requireSuccessfulArchivePreflight(result, operation: "archive extract")
          // Only host-created inodes are eligible for cleanup. Tar streams contents rather
          // than replacing files whose identities could otherwise be learned only afterward.
          let stream = FileHandle(fileDescriptor: contents, closeOnDealloc: false)
          try stream.seek(toOffset: 0)
          for entry in entries where entry.normalizedPath != "." {
            let target = staging.appendingPathComponent(entry.normalizedPath)
            if entry.isDirectory {
              try files.mkdir(target, recursive: true, mode: entry.mode | 0o700)
            } else {
              try files.writeGenerated(
                to: target, overwrite: false, createDirectories: true, creationMode: entry.mode
              ) { output in
                let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
                var remaining = entry.byteCount
                while remaining > 0 {
                  guard let data = try stream.read(upToCount: Int(min(65_536, remaining))),
                    !data.isEmpty
                  else {
                    throw GatewayToolError.invalidArguments(
                      "Archive contents do not match the listing.")
                  }
                  try writer.write(contentsOf: data)
                  remaining -= Int64(data.count)
                }
              }
              let time = modificationTimes[entry.normalizedPath]!
              try files.setArchiveMetadata(
                target, seconds: time.seconds, nanoseconds: time.nanoseconds)
            }
          }
          guard try stream.read(upToCount: 1)?.isEmpty != false else {
            throw GatewayToolError.invalidArguments("Archive contents do not match the listing.")
          }
          return result
        }
        try fileMutationObserver?("archive.extract", staging, .didMutate)
        var expected: [String: Bool] = [:]
        for entry in entries where entry.normalizedPath != "." {
          let parts = entry.normalizedPath.split(separator: "/")
          for count in 1..<parts.count {
            expected[parts.prefix(count).joined(separator: "/")] = true
          }
          expected[entry.normalizedPath] = entry.isDirectory
        }
        guard try files.tree(staging) == expected else {
          throw GatewayToolError.invalidArguments(
            "Extracted tree does not match the archive listing.")
        }
        for (path, directory) in expected.sorted(by: { $0.key < $1.key }) {
          let target = destinationURL.appendingPathComponent(path)
          if directory {
            try files.mkdir(target, recursive: true)
          } else {
            try files.move(
              staging.appendingPathComponent(path), to: target,
              overwrite: overwrite, createDirectories: true)
          }
        }
        return result.json
      }
      // Keep directories writable until publication and staging cleanup finish.
      for entry in entries.filter(\.isDirectory).sorted(by: {
        $0.normalizedPath.split(separator: "/").count
          > $1.normalizedPath.split(separator: "/").count
      }) where entry.normalizedPath != "." {
        let time = modificationTimes[entry.normalizedPath]!
        try files.setArchiveMetadata(
          destinationURL.appendingPathComponent(entry.normalizedPath),
          mode: entry.mode, seconds: time.seconds, nanoseconds: time.nanoseconds)
      }
      if let createdDestination, let entry = entries.first(where: { $0.normalizedPath == "." }) {
        let time = modificationTimes["."]!
        try files.setArchiveMetadata(
          destinationURL, identity: createdDestination,
          mode: entry.mode, seconds: time.seconds, nanoseconds: time.nanoseconds)
      }
    }

    return .object([
      "operation": .string("archive.extract"),
      "archive": .object([
        "path": .string(archiveURL.path),
        "project_relative_path": .string(archiveInfo.projectRelativePath),
        "format": .string(format),
      ]),
      "destination": .object([
        "path": .string(destinationURL.path),
        "project_relative_path": .string(projectScope.projectRelativePath(destinationURL)),
        "exists": .bool(destinationExists),
        "would_create": .bool(!destinationExists && createDirectories),
      ]),

      "confirm_extract": .bool(confirmExtract),
      "create_directories": .bool(createDirectories),
      "dry_run": .bool(dryRun),
      "entry_count": .integer(Int64(entries.count)),
      "entries": .array(Array(previewEntries)),
      "entries_truncated": .bool(entries.count > previewEntries.count),
      "format": .string(format),
      "link_entry_count": .integer(0),
      "max_entries": .integer(Int64(maxEntries)),
      "max_preview_entries": .integer(Int64(maxPreviewEntries)),
      "overwrite": .bool(overwrite),
      "result": extractionResult,
      "would_extract": .bool(true),
    ])
  }

  internal func createArchive(arguments object: [String: JSONValue]) throws -> JSONValue {
    let files = try ProjectFileAccess(
      project: projectScope.projectDirectory, environment: environment.environment,
      commands: environment.registeredCommands,
      mutationObserver: fileMutationObserver)
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

    let archiveURL = try files.url(path)
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
      let archiveInfo = try projectScope.fileInfo(url: archiveURL)
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
      let commandResult = try files.writeGenerated(
        to: archiveURL, overwrite: overwrite, createDirectories: createDirectories
      ) { fd in
        let result = try commandRunner.runToFile(
          executable: createCommand.executable, arguments: createCommand.arguments,
          workingDirectory: configuration.projectDirectory, environment: [:],
          timeoutMilliseconds: timeout, maxOutputBytes: maxOutputBytes, outputDescriptor: fd)
        try requireSuccessfulArchivePreflight(result, operation: "archive create")
        return result
      }
      result = commandResult.json
    }

    return .object([
      "operation": .string("archive.create"),
      "archive": .object([
        "path": .string(archiveURL.path),
        "project_relative_path": .string(
          projectScope.projectRelativePathPreservingSymlinks(archiveURL)),
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
    let format = try archiveFormat(for: url)
    return ArchiveListCommand(
      format: format,
      executable: try registeredCommands.builtinExecutable(format == "zip" ? "zipinfo" : "tar"),
      arguments: [format == "zip" ? "-1" : "-tf", url.path])
  }

  private func archiveFormat(for url: URL) throws -> String {
    let name = url.lastPathComponent.lowercased()
    if name.hasSuffix(".zip") || name.hasSuffix(".jar") || name.hasSuffix(".war")
      || name.hasSuffix(".ear")
    {
      return "zip"
    }

    let tarSuffixes = [
      ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz",
    ]
    if tarSuffixes.contains(where: { name.hasSuffix($0) }) {
      return "tar"
    }

    throw GatewayToolError.invalidArguments(
      "Unsupported archive format. Supported suffixes: .zip, .jar, .war, .ear, .tar, .tar.gz, .tgz, .tar.bz2, .tbz, .tbz2, .tar.xz, .txz."
    )
  }

  private func archiveReader(for format: String) throws -> ArchiveReader {
    #if canImport(Darwin)
      return ArchiveReader(
        executable: try registeredCommands.builtinExecutable("tar"), implementation: .bsd)
    #else
      return ArchiveReader(
        executable: try registeredCommands.builtinExecutable(format == "zip" ? "bsdtar" : "tar"),
        implementation: format == "zip" ? .bsd : .gnu)
    #endif
  }

  private func archiveVerboseListCommand(archiveURL: URL, reader: ArchiveReader)
    -> ArchiveListCommand
  {
    // ZIP central directory order may differ from local headers; both passes use tar's reader.
    ArchiveListCommand(
      format: "tar", executable: reader.executable,
      arguments: ["--numeric-owner", "-tvf", archiveURL.path])
  }

  private func archiveReadFileCommand(
    archive: ArchiveListCommand,
    archiveURL: URL,
    entry: String
  ) throws -> ArchiveListCommand {
    guard !entry.hasPrefix("-"), !entry.contains("\0"),
      entry.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]")) == nil
    else {
      throw GatewayToolError.invalidArguments("Archive member must be a literal file path.")
    }
    switch archive.format {
    case "zip":
      return ArchiveListCommand(
        format: archive.format,
        executable: try registeredCommands.builtinExecutable("unzip"),
        arguments: ["-p", archiveURL.path, entry]
      )
    case "tar":
      return ArchiveListCommand(
        format: archive.format,
        executable: try registeredCommands.builtinExecutable("tar"),
        arguments: ["-xOf", archiveURL.path, "--", entry]
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
        executable: try registeredCommands.builtinExecutable("zip"),
        arguments: ["-qry", "-", "--"] + sourcePaths
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
        executable: try registeredCommands.builtinExecutable("tar"),
        arguments: [tarFlag, "-", "--"] + sourcePaths
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
            projectRelativePath: projectScope.projectRelativePathPreservingSymlinks(url),
            type: type
          ))
      }
    }

    for rawSourcePath in rawSourcePaths {
      let lexicalSourceURL = try projectScope.lexicalProjectURL(rawSourcePath)
      let resolvedSourceURL = try projectScope.resolvedProjectURL(rawSourcePath)
      let sourceInfo = try projectScope.fileInfo(url: lexicalSourceURL)
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
              "archive.create refuses symbolic link entries: \(projectScope.projectRelativePathPreservingSymlinks(itemURL))"
            )
          }
          let type =
            values.isDirectory == true
            ? "directory"
            : (values.isRegularFile == true ? "file" : "other")
          guard type == "file" || type == "directory" else {
            throw GatewayToolError.invalidArguments(
              "archive.create source contains unsupported file type: \(projectScope.projectRelativePathPreservingSymlinks(itemURL))"
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
      let argvSourcePath = projectScope.projectRelativePathPreservingSymlinks(lexicalSourceURL)
      argvSourcePaths.append(argvSourcePath)
      sources.append(
        ArchiveCreateSource(
          path: lexicalSourceURL.path,
          projectRelativePath: argvSourcePath,
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

  private func archiveExtractCommand(archiveURL: URL, reader: ArchiveReader) -> ArchiveListCommand {
    var options = ["--no-same-owner", "--no-same-permissions", "--no-acls", "--no-xattrs"]
    if reader.implementation == .bsd {
      options.append("--no-fflags")
    } else {
      // GNU tar cannot autodetect compressed archives on standard input.
      let name = archiveURL.lastPathComponent.lowercased()
      if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
        options.append("--gzip")
      } else if [".tar.bz2", ".tbz", ".tbz2"].contains(where: name.hasSuffix) {
        options.append("--bzip2")
      } else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") {
        options.append("--xz")
      }
    }
    return ArchiveListCommand(
      format: "tar", executable: reader.executable,
      arguments: ["-xOf", "-"] + options)
  }

  private func archiveModificationTimes(
    _ archive: URL, reader: ArchiveReader, entries: [ArchiveValidatedEntry], timeout: Int,
    maxOutputBytes: Int
  ) throws -> [String: ArchiveModificationTime] {
    let arguments: [String]
    let metadataEnvironment: [String: String]
    if reader.implementation == .bsd {
      // BSD tar's verbose listing omits seconds and nanoseconds. Mtree carries
      // both, but sorts names, so it supplies metadata rather than content order.
      // -P preserves leading backslashes during this read-only format conversion.
      arguments = [
        "-cf", "-", "--format=mtree", "--options=!all,type,time", "-P", "--", "@" + archive.path,
      ]
      // ZIP DOS timestamps use local time, as they do during ordinary extraction.
      metadataEnvironment = ["LC_ALL": "C"]
    } else {
      arguments = ["--numeric-owner", "--full-time", "-tvf", archive.path]
      metadataEnvironment = ["LC_ALL": "C", "TZ": "UTC"]
    }
    let result = try commandRunner.run(
      executable: reader.executable, arguments: arguments,
      workingDirectory: configuration.projectDirectory, environment: metadataEnvironment,
      timeoutMilliseconds: timeout, maxOutputBytes: maxOutputBytes)
    try requireSuccessfulArchivePreflight(result, operation: "archive timestamp metadata")
    var times: [String: ArchiveModificationTime] = [:]
    var directories: [String: Bool] = [:]
    if reader.implementation == .bsd {
      for line in result.stdout.split(separator: "\n") where !line.hasPrefix("#") {
        let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard columns.count == 3,
          let timeColumn = columns.first(where: { $0.hasPrefix("time=") }),
          let type = columns.first(where: { $0.hasPrefix("type=") }),
          type == "type=dir" || type == "type=file"
        else { throw GatewayToolError.invalidArguments("Cannot parse archive timestamp metadata.") }
        let name = try decodedArchiveListingPath(columns[0])
        let path = try normalizedArchiveEntryPath(name == "/." ? "." : name)
        let parts = timeColumn.dropFirst(5).split(separator: ".", omittingEmptySubsequences: false)
        // Mtree writes seconds and a nanosecond integer, without decimal padding.
        guard parts.count == 2, let seconds = Int64(parts[0]), let nanoseconds = Int(parts[1]),
          (0..<1_000_000_000).contains(nanoseconds), times[path] == nil
        else {
          throw GatewayToolError.invalidArguments("Cannot parse archive modification time: \(name)")
        }
        times[path] = .init(seconds: seconds, nanoseconds: nanoseconds)
        directories[path] = type == "type=dir"
      }
    } else {
      for entry in try parseArchiveListing(result.stdout, includingTimes: true) {
        let path = try normalizedArchiveEntryPath(entry.path)
        guard let time = entry.modificationTime, times[path] == nil else {
          throw GatewayToolError.invalidArguments(
            "Cannot parse archive modification time: \(entry.path)")
        }
        times[path] = time
        directories[path] = entry.isDirectory
      }
    }
    guard times.count == entries.count,
      entries.allSatisfy({
        times[$0.normalizedPath] != nil && directories[$0.normalizedPath] == $0.isDirectory
      })
    else {
      throw GatewayToolError.invalidArguments(
        "Archive timestamp metadata does not match the listing.")
    }
    return times
  }

  private func parseArchiveListing(_ output: String, includingTimes: Bool = false) throws
    -> [ArchiveListedEntry]
  {
    var entries: [ArchiveListedEntry] = []
    var gnuDateWidth = 16
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let kind = line.first else { continue }
      guard kind == "-" || kind == "d" else {
        throw GatewayToolError.invalidArguments(
          kind == "l" || kind == "h"
            ? "archive.extract refuses archives containing link entries."
            : "archive.extract refuses special file entries.")
      }
      // BSD tar has separate owner/group columns; GNU tar prints owner/group together.
      let prefix = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      let fields = prefix.count > 1 && prefix[1].contains("/") ? 5 : 8
      var cursor = line.startIndex
      var columns: [Substring] = []
      for _ in 0..<fields {
        while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
          cursor = line.index(after: cursor)
        }
        let start = cursor
        while cursor < line.endIndex, line[cursor] != " " && line[cursor] != "\t" {
          cursor = line.index(after: cursor)
        }
        columns.append(line[start..<cursor])
      }
      // GNU tar pads dates to the widest timestamp seen so far. That padding
      // is distinct from leading spaces in the member name.
      var separatorCount = 1
      if fields == 5 {
        let dateWidth = columns[3].count + 1 + columns[4].count
        gnuDateWidth = max(gnuDateWidth, dateWidth)
        separatorCount += gnuDateWidth - dateWidth
      }
      guard let nameStart = line.index(cursor, offsetBy: separatorCount, limitedBy: line.endIndex),
        line[cursor..<nameStart].allSatisfy({ $0 == " " }), nameStart < line.endIndex
      else {
        throw GatewayToolError.invalidArguments("Cannot parse archive entry listing.")
      }
      let path = try decodedArchiveListingPath(line[nameStart...])
      let sizeIndex = fields == 5 ? 2 : 4
      guard let byteCount = Int64(columns[sizeIndex]), byteCount >= 0,
        columns[0].count >= 10
      else { throw GatewayToolError.invalidArguments("Cannot parse archive entry size or mode.") }
      var mode: UInt16 = 0
      for (index, bit) in Array(columns[0].dropFirst().prefix(9)).enumerated() {
        if "rwxst".contains(bit) { mode |= 1 << (8 - index) }
      }
      entries.append(
        .init(
          path: path, isDirectory: kind == "d", byteCount: byteCount, mode: mode,
          modificationTime: includingTimes
            ? try archiveFullModificationTime(date: columns[3], time: columns[4]) : nil)
      )
    }
    return entries
  }

  private func archiveFullModificationTime(date: Substring, time: Substring) throws
    -> ArchiveModificationTime
  {
    let parts = time.split(separator: ".", omittingEmptySubsequences: false)
    let formatter = ISO8601DateFormatter()
    guard let clock = parts.first, parts.count <= 2,
      let value = formatter.date(from: "\(date)T\(clock)Z"),
      let seconds = Int64(exactly: value.timeIntervalSince1970)
    else { throw GatewayToolError.invalidArguments("Cannot parse archive modification time.") }
    let fraction = parts.count == 2 ? String(parts[1]) : ""
    guard fraction.count <= 9, fraction.utf8.allSatisfy({ (48...57).contains($0) }),
      let nanoseconds = Int(fraction + String(repeating: "0", count: 9 - fraction.count))
    else { throw GatewayToolError.invalidArguments("Cannot parse archive modification time.") }
    return .init(seconds: seconds, nanoseconds: nanoseconds)
  }

  private func decodedArchiveListingPath(_ path: Substring) throws -> String {
    let bytes = Array(path.utf8)
    var decoded: [UInt8] = []
    var index = 0
    let escapes: [UInt8: UInt8] = [
      97: 7, 98: 8, 102: 12, 110: 10, 114: 13, 116: 9, 118: 11, 92: 92,
    ]
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if byte != 92 {
        decoded.append(byte)
        continue
      }
      guard index < bytes.count else {
        throw GatewayToolError.invalidArguments("Invalid escape in archive listing.")
      }
      if let value = escapes[bytes[index]] {
        decoded.append(value)
        index += 1
      } else {
        guard index + 3 <= bytes.count,
          bytes[index..<index + 3].allSatisfy({ (48...55).contains($0) }),
          let value = UInt8(String(decoding: bytes[index..<index + 3], as: UTF8.self), radix: 8)
        else { throw GatewayToolError.invalidArguments("Invalid escape in archive listing.") }
        decoded.append(value)
        index += 3
      }
    }
    guard let name = String(bytes: decoded, encoding: .utf8) else {
      throw GatewayToolError.invalidArguments("Archive member names must be valid UTF-8.")
    }
    return name
  }

  private func validateArchiveEntries(
    _ rawEntries: [ArchiveListedEntry],
    destination: URL,
    overwrite: Bool,
    files: ProjectFileAccess
  ) throws -> [ArchiveValidatedEntry] {
    let fileManager = FileManager.default
    let destinationBase = destination.standardizedFileURL
    let destinationBasePath = destinationBase.path
    let destinationBasePrefix =
      destinationBasePath.hasSuffix("/") ? destinationBasePath : "\(destinationBasePath)/"
    var entries: [ArchiveValidatedEntry] = []

    var kinds: [String: Bool] = [:]
    for raw in rawEntries {
      let rawEntry = raw.path
      let isDirectory = raw.isDirectory
      let normalizedPath = try normalizedArchiveEntryPath(rawEntry)
      guard kinds[normalizedPath] == nil, normalizedPath != "." || isDirectory else {
        throw GatewayToolError.invalidArguments(
          "Archive contains duplicate or conflicting entries.")
      }
      kinds[normalizedPath] = isDirectory
      let targetURL = destination.appendingPathComponent(normalizedPath)
        .standardizedFileURL
      try files.validate(targetURL)
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
          byteCount: raw.byteCount,
          mode: raw.mode,
          destinationProjectRelativePath: projectScope.projectRelativePath(targetURL),
          wouldOverwrite: targetExists && !isDirectory
        ))
    }

    for path in kinds.keys {
      let parts = path.split(separator: "/")
      for count in 1..<parts.count where kinds[parts.prefix(count).joined(separator: "/")] == false
      {
        throw GatewayToolError.invalidArguments("Archive entry parent is not a directory.")
      }
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
    guard !entry.isEmpty, !entry.contains("\0") else {
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

private struct ArchiveReader {
  enum Implementation {
    case bsd, gnu
  }

  var executable: String
  var implementation: Implementation
}

private struct ArchiveValidatedEntry {
  var originalPath: String
  var normalizedPath: String
  var isDirectory: Bool
  var byteCount: Int64
  var mode: UInt16
  var destinationProjectRelativePath: String
  var wouldOverwrite: Bool

  var json: JSONValue {
    .object([
      "path": .string(originalPath),
      "normalized_path": .string(normalizedPath),
      "is_directory": .bool(isDirectory),
      "destination_project_relative_path": .string(destinationProjectRelativePath),
      "would_overwrite": .bool(wouldOverwrite),
    ])
  }
}

private struct ArchiveListedEntry {
  var path: String
  var isDirectory: Bool
  var byteCount: Int64
  var mode: UInt16
  var modificationTime: ArchiveModificationTime?
}

private struct ArchiveModificationTime {
  var seconds: Int64
  var nanoseconds: Int
}

private struct ArchiveCreateSourceSnapshot {
  var sources: [ArchiveCreateSource]
  var argvSourcePaths: [String]
  var entryCount: Int
  var previewEntries: [ArchiveCreateEntry]
}

private struct ArchiveCreateSource {
  var path: String
  var projectRelativePath: String
  var type: String
  var entryCount: Int

  var json: JSONValue {
    .object([
      "path": .string(path),
      "project_relative_path": .string(projectRelativePath),
      "type": .string(type),
      "entry_count": .integer(Int64(entryCount)),
    ])
  }
}

private struct ArchiveCreateEntry {
  var projectRelativePath: String
  var type: String

  var json: JSONValue {
    .object([
      "project_relative_path": .string(projectRelativePath),
      "type": .string(type),
    ])
  }
}
