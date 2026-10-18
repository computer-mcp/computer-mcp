import AppKit
import Foundation

extension GatewayToolRegistry {
  internal func macOSUserDirectories(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeMissing = try optionalBool("include_missing", in: object) ?? true
    let includeSystem = try optionalBool("include_system", in: object) ?? true
    let includeTemporary = try optionalBool("include_temporary", in: object) ?? true

    let directories = macOSUserDirectoryCatalog(
      includeSystem: includeSystem,
      includeTemporary: includeTemporary
    )
    let rows = directories.compactMap { entry -> MacOSUserDirectoryInfo? in
      let info = macOSUserDirectoryInfo(entry)
      if !includeMissing && !info.exists {
        return nil
      }
      return info
    }

    return .object([
      "operation": .string("macos.user_directories"),
      "include_missing": .bool(includeMissing),
      "include_system": .bool(includeSystem),
      "include_temporary": .bool(includeTemporary),
      "directory_count": .integer(Int64(rows.count)),
      "directories": .array(rows.map(\.json)),
    ])
  }

  private func macOSUserDirectoryCatalog(
    includeSystem: Bool,
    includeTemporary: Bool
  ) -> [MacOSUserDirectoryEntry] {
    let fileManager = FileManager.default
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    var entries: [MacOSUserDirectoryEntry] = [
      MacOSUserDirectoryEntry(
        id: "home",
        category: "home",
        path: home.path,
        description: "Current user's home directory."
      ),
      MacOSUserDirectoryEntry(
        id: "desktop",
        category: "user_content",
        path: fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
          ?? home.appendingPathComponent("Desktop", isDirectory: true).path,
        description: "Current user's Desktop directory."
      ),
      MacOSUserDirectoryEntry(
        id: "documents",
        category: "user_content",
        path: fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.path
          ?? home.appendingPathComponent("Documents", isDirectory: true).path,
        description: "Current user's Documents directory."
      ),
      MacOSUserDirectoryEntry(
        id: "downloads",
        category: "user_content",
        path: fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
          ?? home.appendingPathComponent("Downloads", isDirectory: true).path,
        description: "Current user's Downloads directory."
      ),
      MacOSUserDirectoryEntry(
        id: "movies",
        category: "user_content",
        path: fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first?.path
          ?? home.appendingPathComponent("Movies", isDirectory: true).path,
        description: "Current user's Movies directory."
      ),
      MacOSUserDirectoryEntry(
        id: "music",
        category: "user_content",
        path: fileManager.urls(for: .musicDirectory, in: .userDomainMask).first?.path
          ?? home.appendingPathComponent("Music", isDirectory: true).path,
        description: "Current user's Music directory."
      ),
      MacOSUserDirectoryEntry(
        id: "pictures",
        category: "user_content",
        path: fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first?.path
          ?? home.appendingPathComponent("Pictures", isDirectory: true).path,
        description: "Current user's Pictures directory."
      ),
      MacOSUserDirectoryEntry(
        id: "user_library",
        category: "user_library",
        path: fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?.path
          ?? home.appendingPathComponent("Library", isDirectory: true).path,
        description: "Current user's Library directory."
      ),
      MacOSUserDirectoryEntry(
        id: "user_applications",
        category: "applications",
        path: home.appendingPathComponent("Applications", isDirectory: true).path,
        description: "Current user's Applications directory."
      ),
    ]

    if includeSystem {
      entries.append(
        contentsOf: [
          MacOSUserDirectoryEntry(
            id: "local_applications",
            category: "applications",
            path: "/Applications",
            description: "Local system-wide Applications directory."
          ),
          MacOSUserDirectoryEntry(
            id: "system_applications",
            category: "applications",
            path: "/System/Applications",
            description: "Apple system Applications directory."
          ),
        ])
    }

    if includeTemporary {
      entries.append(
        MacOSUserDirectoryEntry(
          id: "temporary",
          category: "temporary",
          path: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).path,
          description: "Current process temporary directory."
        ))
    }

    return entries
  }

  private func macOSUserDirectoryInfo(_ entry: MacOSUserDirectoryEntry)
    -> MacOSUserDirectoryInfo
  {
    let path = (entry.path as NSString).standardizingPath
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let symlinkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    let exists = attributes != nil
    let type =
      exists
      ? (symlinkDestination == nil ? fileType(attributes?[.type]) : "symlink")
      : "missing"
    let isDirectory = type == "directory"

    return MacOSUserDirectoryInfo(
      id: entry.id,
      category: entry.category,
      description: entry.description,
      path: path,
      exists: exists,
      type: type,
      size: (attributes?[.size] as? NSNumber)?.int64Value,
      createdAt: attributes?[.creationDate] as? Date,
      modifiedAt: attributes?[.modificationDate] as? Date,
      isReadable: exists && FileManager.default.isReadableFile(atPath: path),
      isWritable: exists && FileManager.default.isWritableFile(atPath: path),
      isTraversable: isDirectory && FileManager.default.isExecutableFile(atPath: path),
      isSymlink: symlinkDestination != nil,
      symlinkDestination: symlinkDestination
    )
  }

  internal func macOSDefaultApplication(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object)
    let urlString = try optionalString("url", in: object)
    let includeCandidates = try optionalBool("include_candidates", in: object) ?? false
    let maxCandidates = optionalInt("max_candidates", in: object) ?? 20
    try validateBoundedPositive(maxCandidates, name: "max_candidates", upperBound: 200)

    let targetCount = [path, urlString].compactMap { value in
      value?.isEmpty == false ? value : nil
    }.count
    guard targetCount == 1 else {
      throw GatewayToolError.invalidArguments("Provide exactly one of: path, url.")
    }

    let targetURL: URL
    let target: JSONValue
    if let path, !path.isEmpty {
      try validateUTF8ByteLimit(path, name: "path", maxBytes: 4_096)
      let fileURL = try resolvedWorkspaceURL(path)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw GatewayToolError.invalidArguments("Path does not exist: \(path)")
      }
      targetURL = fileURL
      target = .object([
        "type": .string("path"),
        "path": .string(fileURL.path),
        "workspace_relative_path": .string(workspaceRelativePath(fileURL)),
      ])
    } else {
      let urlString = urlString ?? ""
      try validateUTF8ByteLimit(urlString, name: "url", maxBytes: 4_096)
      guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
        throw GatewayToolError.invalidArguments("url must be an absolute URL.")
      }
      let allowedSchemes = Set(["http", "https", "mailto"])
      guard allowedSchemes.contains(scheme) else {
        throw GatewayToolError.invalidArguments(
          "url scheme must be one of: http, https, mailto.")
      }
      if ["http", "https"].contains(scheme), url.host?.isEmpty ?? true {
        throw GatewayToolError.invalidArguments("http and https URLs must include a host.")
      }
      targetURL = url
      target = .object([
        "type": .string("url"),
        "url": .string(urlString),
        "scheme": .string(scheme),
      ])
    }

    let defaultApplication = NSWorkspace.shared.urlForApplication(toOpen: targetURL)
    let candidates: [URL]
    if includeCandidates {
      var seen = Set<String>()
      candidates = NSWorkspace.shared.urlsForApplications(toOpen: targetURL).compactMap { url in
        let path = url.standardizedFileURL.path
        guard seen.insert(path).inserted else {
          return nil
        }
        return url
      }
    } else {
      candidates = []
    }
    let selectedCandidates = Array(candidates.prefix(maxCandidates))

    return .object([
      "operation": .string("macos.default_application"),
      "target": target,
      "include_candidates": .bool(includeCandidates),
      "max_candidates": .integer(Int64(maxCandidates)),
      "default_application_available": .bool(defaultApplication != nil),
      "default_application": defaultApplication.map { macOSApplicationInfo(url: $0).json } ?? .null,
      "candidate_count": .integer(Int64(candidates.count)),
      "candidate_applications": .array(
        selectedCandidates.map { macOSApplicationInfo(url: $0).json }),
      "truncated": .bool(candidates.count > selectedCandidates.count),
    ])
  }

  internal func macOSApplications(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeSystem = try optionalBool("include_system", in: object) ?? true
    let includeUser = try optionalBool("include_user", in: object) ?? true
    let maxResults = optionalInt("max_results", in: object) ?? 500
    let maxDepth = optionalInt("max_depth", in: object) ?? 3
    let maxVisited = optionalInt("max_visited", in: object) ?? 20_000
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 5_000)
    try validateBoundedNonNegative(maxDepth, name: "max_depth", upperBound: 8)
    try validateBoundedPositive(maxVisited, name: "max_visited", upperBound: 200_000)

    let roots = macOSApplicationRoots(includeSystem: includeSystem, includeUser: includeUser)
    var applications: [MacOSApplicationInfo] = []
    var visited = 0
    var truncated = false

    for root in roots where !truncated {
      try collectMacOSApplications(
        root: root,
        currentDepth: 0,
        maxDepth: maxDepth,
        maxResults: maxResults,
        maxVisited: maxVisited,
        applications: &applications,
        visited: &visited,
        truncated: &truncated
      )
    }

    applications.sort {
      if $0.name == $1.name {
        return $0.path.localizedStandardCompare($1.path) == .orderedAscending
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }

    return .object([
      "include_system": .bool(includeSystem),
      "include_user": .bool(includeUser),
      "roots": .array(roots.map { .string($0.path) }),
      "max_depth": .integer(Int64(maxDepth)),
      "max_visited": .integer(Int64(maxVisited)),
      "visited_entries": .integer(Int64(visited)),
      "application_count": .integer(Int64(applications.count)),
      "truncated": .bool(truncated),
      "applications": .array(applications.map(\.json)),
    ])
  }

  internal func macOSScreens() throws -> JSONValue {
    let screens = try NSScreen.screens.enumerated().map { index, screen in
      var deviceID: JSONValue = .null
      if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
      {
        deviceID = try JSONValue(foundationNumber: screenNumber)
      }

      return JSONValue.object([
        "index": .integer(Int64(index)),
        "localized_name": .string(screen.localizedName),
        "is_main": .bool(screen == NSScreen.main),
        "is_deepest": .bool(screen == NSScreen.deepest),
        "frame": rectJSON(screen.frame),
        "visible_frame": rectJSON(screen.visibleFrame),
        "backing_scale_factor": .number(Double(screen.backingScaleFactor)),
        "color_space": screen.colorSpace?.localizedName.map(JSONValue.string) ?? .null,
        "device_id": deviceID,
      ])
    }

    return .object([
      "screen_count": .integer(Int64(screens.count)),
      "screens": .array(screens),
    ])
  }

  internal func macOSSpotlightSearch(arguments object: [String: JSONValue]) throws -> JSONValue {
    let path = try optionalString("path", in: object) ?? "."
    let query = try requiredString("query", in: object)
    let maxResults = optionalInt("max_results", in: object) ?? 100
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    try validateUTF8ByteLimit(query, name: "query", maxBytes: 4_096)
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let directory = try resolvedWorkspaceURL(path)
    try requireDirectory(directory, originalPath: path)

    let result = try commandRunner.run(
      executable: "/usr/bin/mdfind",
      arguments: ["-onlyin", directory.path, query],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    let base = configuration.workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let basePath = base.path
    let basePrefix = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
    var matched: [FileInfo] = []
    var skippedEscaped = 0
    var skippedMissing = 0
    var totalReturnedPaths = 0

    for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
      totalReturnedPaths += 1
      let candidate = URL(fileURLWithPath: String(line))
        .standardizedFileURL
        .resolvingSymlinksInPath()
      guard candidate.path == basePath || candidate.path.hasPrefix(basePrefix) else {
        skippedEscaped += 1
        continue
      }

      guard FileManager.default.fileExists(atPath: candidate.path) else {
        skippedMissing += 1
        continue
      }

      if matched.count < maxResults {
        matched.append(try fileInfo(url: candidate))
      }
    }

    matched.sort {
      $0.workspaceRelativePath.localizedStandardCompare($1.workspaceRelativePath)
        == .orderedAscending
    }
    let containedPathCount = totalReturnedPaths - skippedEscaped - skippedMissing

    return .object([
      "operation": .string("macos.spotlight_search"),
      "path": .string(directory.path),
      "workspace_relative_path": .string(workspaceRelativePath(directory)),
      "query": .string(query),
      "max_results": .integer(Int64(maxResults)),
      "max_output_bytes": .integer(Int64(maxOutputBytes)),
      "returned_path_count": .integer(Int64(totalReturnedPaths)),
      "result_count": .integer(Int64(matched.count)),
      "truncated": .bool(result.stdoutTruncated || containedPathCount > matched.count),
      "skipped_escaped_results": .integer(Int64(skippedEscaped)),
      "skipped_missing_results": .integer(Int64(skippedMissing)),
      "results": .array(matched.map(\.json)),
      "command": result.json,
    ])
  }

  internal func macOSRunningApplications(arguments object: [String: JSONValue]) throws -> JSONValue
  {
    let includeBackground = try optionalBool("include_background", in: object) ?? false
    let query = try optionalString("query", in: object)
    let matchMode = try fileNameMatchMode(try optionalString("match", in: object) ?? "contains")
    let caseSensitive = try optionalBool("case_sensitive", in: object) ?? false
    let maxResults = optionalInt("max_results", in: object) ?? 200
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 2_000)

    let running = NSWorkspace.shared.runningApplications
      .filter { includeBackground || $0.activationPolicy == .regular }
      .filter { application in
        guard let query, !query.isEmpty else {
          return true
        }
        return macOSRunningApplication(
          application,
          matches: query,
          mode: matchMode,
          caseSensitive: caseSensitive
        )
      }
      .sorted { lhs, rhs in
        let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
        let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
        if lhsName == rhsName {
          return lhs.processIdentifier < rhs.processIdentifier
        }
        return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
      }

    let selected = Array(running.prefix(maxResults))
    return .object([
      "include_background": .bool(includeBackground),
      "query": query.map(JSONValue.string) ?? .null,
      "match": .string(matchMode.rawValue),
      "case_sensitive": .bool(caseSensitive),
      "max_results": .integer(Int64(maxResults)),
      "application_count": .integer(Int64(running.count)),
      "truncated": .bool(running.count > selected.count),
      "applications": .array(selected.map { macOSRunningApplicationInfo($0).json }),
    ])
  }

  internal func macOSFrontmostApplication() -> JSONValue {
    let application = NSWorkspace.shared.frontmostApplication
    return .object([
      "available": .bool(application != nil),
      "application": application.map { macOSRunningApplicationInfo($0).json } ?? .null,
    ])
  }

  private func macOSApplicationRoots(includeSystem: Bool, includeUser: Bool) -> [URL] {
    var roots: [URL] = []
    if includeSystem {
      roots.append(URL(fileURLWithPath: "/Applications", isDirectory: true))
      roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
    }
    if includeUser {
      roots.append(
        FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Applications", isDirectory: true))
    }
    var seen = Set<String>()
    return roots.filter { root in
      let path = root.standardizedFileURL.path
      guard seen.insert(path).inserted else {
        return false
      }
      return true
    }
  }

  private func collectMacOSApplications(
    root: URL,
    currentDepth: Int,
    maxDepth: Int,
    maxResults: Int,
    maxVisited: Int,
    applications: inout [MacOSApplicationInfo],
    visited: inout Int,
    truncated: inout Bool
  ) throws {
    guard !truncated else {
      return
    }
    guard applications.count < maxResults else {
      truncated = true
      return
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return
    }

    for url in try sortedDirectoryChildren(root, includeHidden: false) {
      guard !truncated else {
        return
      }
      guard visited < maxVisited else {
        truncated = true
        return
      }
      visited += 1
      if url.pathExtension == "app" {
        guard applications.count < maxResults else {
          truncated = true
          return
        }
        applications.append(macOSApplicationInfo(url: url))
        continue
      }

      if currentDepth < maxDepth {
        var childIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &childIsDirectory),
          childIsDirectory.boolValue
        else {
          continue
        }
        try collectMacOSApplications(
          root: url,
          currentDepth: currentDepth + 1,
          maxDepth: maxDepth,
          maxResults: maxResults,
          maxVisited: maxVisited,
          applications: &applications,
          visited: &visited,
          truncated: &truncated
        )
      }
    }
  }

  private func macOSApplicationInfo(url: URL) -> MacOSApplicationInfo {
    let bundle = Bundle(url: url)
    let resourceValues = try? url.resourceValues(forKeys: [.localizedNameKey])
    return MacOSApplicationInfo(
      name: resourceValues?.localizedName ?? url.deletingPathExtension().lastPathComponent,
      path: url.standardizedFileURL.path,
      bundleIdentifier: bundle?.bundleIdentifier,
      version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    )
  }

  private func rectJSON(_ rect: CGRect) -> JSONValue {
    .object([
      "x": .number(Double(rect.origin.x)),
      "y": .number(Double(rect.origin.y)),
      "width": .number(Double(rect.width)),
      "height": .number(Double(rect.height)),
    ])
  }

  private func macOSRunningApplicationInfo(
    _ application: NSRunningApplication
  ) -> MacOSRunningApplicationInfo {
    MacOSRunningApplicationInfo(
      name: application.localizedName,
      bundleIdentifier: application.bundleIdentifier,
      bundlePath: application.bundleURL?.standardizedFileURL.path,
      executablePath: application.executableURL?.standardizedFileURL.path,
      processIdentifier: Int(application.processIdentifier),
      activationPolicy: macOSActivationPolicyName(application.activationPolicy),
      isActive: application.isActive,
      isHidden: application.isHidden,
      isFinishedLaunching: application.isFinishedLaunching,
      launchDate: application.launchDate
    )
  }

  private func macOSRunningApplication(
    _ application: NSRunningApplication,
    matches query: String,
    mode: FileNameMatchMode,
    caseSensitive: Bool
  ) -> Bool {
    let candidates = [
      application.localizedName,
      application.bundleIdentifier,
      application.bundleURL?.path,
      application.executableURL?.path,
    ].compactMap { $0 }
    return candidates.contains {
      fileName($0, matches: query, mode: mode, caseSensitive: caseSensitive)
    }
  }

  private func macOSActivationPolicyName(
    _ policy: NSApplication.ActivationPolicy
  ) -> String {
    switch policy {
    case .regular:
      return "regular"
    case .accessory:
      return "accessory"
    case .prohibited:
      return "prohibited"
    @unknown default:
      return "unknown"
    }
  }
}

private struct MacOSUserDirectoryEntry {
  var id: String
  var category: String
  var path: String
  var description: String
}

private struct MacOSUserDirectoryInfo {
  var id: String
  var category: String
  var description: String
  var path: String
  var exists: Bool
  var type: String
  var size: Int64?
  var createdAt: Date?
  var modifiedAt: Date?
  var isReadable: Bool
  var isWritable: Bool
  var isTraversable: Bool
  var isSymlink: Bool
  var symlinkDestination: String?

  var json: JSONValue {
    .object([
      "id": .string(id),
      "category": .string(category),
      "description": .string(description),
      "path": .string(path),
      "exists": .bool(exists),
      "type": .string(type),
      "size_bytes": size.map { .integer(Int64($0)) } ?? .null,
      "created_at": createdAt.map { .string(iso8601String($0)) } ?? .null,
      "modified_at": modifiedAt.map { .string(iso8601String($0)) } ?? .null,
      "is_readable": .bool(isReadable),
      "is_writable": .bool(isWritable),
      "is_traversable": .bool(isTraversable),
      "is_symlink": .bool(isSymlink),
      "symlink_destination": symlinkDestination.map(JSONValue.string) ?? .null,
    ])
  }
}

private struct MacOSApplicationInfo {
  var name: String
  var path: String
  var bundleIdentifier: String?
  var version: String?

  var json: JSONValue {
    .object([
      "name": .string(name),
      "path": .string(path),
      "bundle_identifier": bundleIdentifier.map(JSONValue.string) ?? .null,
      "version": version.map(JSONValue.string) ?? .null,
    ])
  }
}

private struct MacOSRunningApplicationInfo {
  var name: String?
  var bundleIdentifier: String?
  var bundlePath: String?
  var executablePath: String?
  var processIdentifier: Int
  var activationPolicy: String
  var isActive: Bool
  var isHidden: Bool
  var isFinishedLaunching: Bool
  var launchDate: Date?

  var json: JSONValue {
    .object([
      "name": name.map(JSONValue.string) ?? .null,
      "bundle_identifier": bundleIdentifier.map(JSONValue.string) ?? .null,
      "bundle_path": bundlePath.map(JSONValue.string) ?? .null,
      "executable_path": executablePath.map(JSONValue.string) ?? .null,
      "process_id": .integer(Int64(processIdentifier)),
      "activation_policy": .string(activationPolicy),
      "is_active": .bool(isActive),
      "is_hidden": .bool(isHidden),
      "is_finished_launching": .bool(isFinishedLaunching),
      "launch_date": launchDate.map { .string(iso8601String($0)) } ?? .null,
    ])
  }
}
