import Darwin
import Foundation

extension GatewayToolRegistry {
  internal func systemInfo() throws -> JSONValue {
    let processInfo = ProcessInfo.processInfo
    return .object([
      "operating_system": .object([
        "name": .string("macOS"),
        "version": .string(processInfo.operatingSystemVersionString),
      ]),
      "host": .object([
        "name": .string(processInfo.hostName)
      ]),
      "hardware": .object([
        "processor_count": .integer(Int64(processInfo.processorCount)),
        "active_processor_count": .integer(Int64(processInfo.activeProcessorCount)),
        "physical_memory_bytes": try .integer(exactly: processInfo.physicalMemory),
      ]),
      "process": .object([
        "id": .integer(Int64(processInfo.processIdentifier)),
        "name": .string(processInfo.processName),
      ]),
    ])
  }

  internal func systemKernel() throws -> JSONValue {
    var info = utsname()
    guard uname(&info) == 0 else {
      throw GatewayToolError.executionFailed(
        "uname failed: \(String(cString: strerror(errno)))")
    }

    let processInfo = ProcessInfo.processInfo
    return .object([
      "operation": .string("system.kernel"),
      "source": .string("uname"),
      "operating_system": .object([
        "name": .string("macOS"),
        "version": .string(processInfo.operatingSystemVersionString),
      ]),
      "kernel": .object([
        "name": .string(fixedCString(info.sysname)),
        "release": .string(fixedCString(info.release)),
        "version": .string(fixedCString(info.version)),
      ]),
      "hardware": .object([
        "machine": .string(fixedCString(info.machine)),
        "processor_count": .integer(Int64(processInfo.processorCount)),
        "active_processor_count": .integer(Int64(processInfo.activeProcessorCount)),
      ]),
    ])
  }

  internal func systemSoftware(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)

    let result = try commandRunner.run(
      executable: "/usr/bin/sw_vers",
      arguments: [],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes
    )
    let fields = parseSWVers(stdout: result.stdout)
    let version = ProcessInfo.processInfo.operatingSystemVersion

    return .object([
      "operation": .string("system.software"),
      "source": .string("/usr/bin/sw_vers"),
      "product": .object([
        "name": fields["ProductName"].map(JSONValue.string) ?? .null,
        "version": fields["ProductVersion"].map(JSONValue.string) ?? .null,
        "build_version": fields["BuildVersion"].map(JSONValue.string) ?? .null,
      ]),
      "process_info": .object([
        "operating_system_version_string": .string(
          ProcessInfo.processInfo.operatingSystemVersionString),
        "major_version": .integer(Int64(version.majorVersion)),
        "minor_version": .integer(Int64(version.minorVersion)),
        "patch_version": .integer(Int64(version.patchVersion)),
      ]),
      "result": result.json,
    ])
  }

  private func parseSWVers(stdout: String) -> [String: String] {
    var fields: [String: String] = [:]
    for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else {
        continue
      }
      let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else {
        continue
      }
      fields[key] = value
    }
    return fields
  }

  internal func systemLocale() throws -> JSONValue {
    let locale = Locale.current
    let nsLocale = NSLocale(localeIdentifier: locale.identifier)
    let calendar = Calendar.current
    let timeZone = TimeZone.current
    let now = Date()
    let languageCode = locale.language.languageCode?.identifier
    let regionCode = locale.region?.identifier
    let scriptCode = locale.language.script?.identifier
    let currencyCode = locale.currency?.identifier
    let measurementSystem = nsLocale.object(forKey: NSLocale.Key.measurementSystem) as? String

    let localePayload: [String: JSONValue] = [
      "identifier": .string(locale.identifier),
      "language_code": languageCode.map(JSONValue.string) ?? .null,
      "region_code": regionCode.map(JSONValue.string) ?? .null,
      "script_code": scriptCode.map(JSONValue.string) ?? .null,
      "currency_code": currencyCode.map(JSONValue.string) ?? .null,
      "measurement_system": measurementSystem.map(JSONValue.string) ?? .null,
    ]
    let calendarPayload: [String: JSONValue] = [
      "identifier": .string(String(describing: calendar.identifier)),
      "first_weekday": .integer(Int64(calendar.firstWeekday)),
      "minimum_days_in_first_week": .integer(Int64(calendar.minimumDaysInFirstWeek)),
    ]
    let timeZonePayload: [String: JSONValue] = [
      "identifier": .string(timeZone.identifier),
      "abbreviation": timeZone.abbreviation(for: now).map(JSONValue.string) ?? .null,
      "seconds_from_gmt": .integer(Int64(timeZone.secondsFromGMT(for: now))),
    ]

    return .object([
      "operation": .string("system.locale"),
      "source": .string("Foundation.Locale"),
      "locale": .object(localePayload),
      "preferred_languages": .array(Locale.preferredLanguages.map(JSONValue.string)),
      "calendar": .object(calendarPayload),
      "time_zone": .object(timeZonePayload),
    ])
  }

  internal func systemMemory() throws -> JSONValue {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      throw GatewayToolError.executionFailed(
        "host_statistics64 failed: \(String(cString: mach_error_string(result)))")
    }

    var rawPageSize: vm_size_t = 0
    let pageSizeResult = host_page_size(mach_host_self(), &rawPageSize)
    guard pageSizeResult == KERN_SUCCESS else {
      throw GatewayToolError.executionFailed(
        "host_page_size failed: \(String(cString: mach_error_string(pageSizeResult)))")
    }
    let pageSize = UInt64(rawPageSize)
    let freePages = UInt64(stats.free_count)
    let activePages = UInt64(stats.active_count)
    let inactivePages = UInt64(stats.inactive_count)
    let wiredPages = UInt64(stats.wire_count)
    let speculativePages = UInt64(stats.speculative_count)
    let compressedPages = UInt64(stats.compressor_page_count)
    let purgeablePages = UInt64(stats.purgeable_count)
    let internalPages = UInt64(stats.internal_page_count)
    let externalPages = UInt64(stats.external_page_count)

    return .object([
      "operation": .string("system.memory"),
      "source": .string("host_statistics64"),
      "physical_memory_bytes": try .integer(exactly: ProcessInfo.processInfo.physicalMemory),
      "page_size_bytes": try .integer(exactly: pageSize),
      "pages": .object([
        "free": try .integer(exactly: freePages),
        "active": try .integer(exactly: activePages),
        "inactive": try .integer(exactly: inactivePages),
        "wired": try .integer(exactly: wiredPages),
        "speculative": try .integer(exactly: speculativePages),
        "compressed": try .integer(exactly: compressedPages),
        "purgeable": try .integer(exactly: purgeablePages),
        "internal": try .integer(exactly: internalPages),
        "external": try .integer(exactly: externalPages),
      ]),
      "bytes": .object([
        "free": try .integer(exactly: freePages * pageSize),
        "active": try .integer(exactly: activePages * pageSize),
        "inactive": try .integer(exactly: inactivePages * pageSize),
        "wired": try .integer(exactly: wiredPages * pageSize),
        "speculative": try .integer(exactly: speculativePages * pageSize),
        "compressed": try .integer(exactly: compressedPages * pageSize),
        "purgeable": try .integer(exactly: purgeablePages * pageSize),
        "internal": try .integer(exactly: internalPages * pageSize),
        "external": try .integer(exactly: externalPages * pageSize),
      ]),
      "events": .object([
        "pageins": try .integer(exactly: stats.pageins),
        "pageouts": try .integer(exactly: stats.pageouts),
        "faults": try .integer(exactly: stats.faults),
        "copy_on_write_faults": try .integer(exactly: stats.cow_faults),
        "compressions": try .integer(exactly: stats.compressions),
        "decompressions": try .integer(exactly: stats.decompressions),
        "swapins": try .integer(exactly: stats.swapins),
        "swapouts": try .integer(exactly: stats.swapouts),
      ]),
    ])
  }

  internal func systemLoad() throws -> JSONValue {
    var loads = [Double](repeating: 0, count: 3)
    let sampleCount = loads.withUnsafeMutableBufferPointer { buffer in
      getloadavg(buffer.baseAddress, Int32(buffer.count))
    }
    guard sampleCount >= 0 else {
      throw GatewayToolError.executionFailed("getloadavg failed.")
    }

    let processInfo = ProcessInfo.processInfo
    let activeProcessorCount = max(1, processInfo.activeProcessorCount)
    let oneMinute = sampleCount > 0 ? loads[0] : nil
    let fiveMinutes = sampleCount > 1 ? loads[1] : nil
    let fifteenMinutes = sampleCount > 2 ? loads[2] : nil

    func loadValue(_ value: Double?) -> JSONValue {
      value.map(JSONValue.number) ?? .null
    }

    func normalizedLoadValue(_ value: Double?) -> JSONValue {
      value.map { .number($0 / Double(activeProcessorCount)) } ?? .null
    }

    return .object([
      "operation": .string("system.load"),
      "source": .string("getloadavg"),
      "sample_count": .integer(Int64(sampleCount)),
      "processor_count": .integer(Int64(processInfo.processorCount)),
      "active_processor_count": .integer(Int64(activeProcessorCount)),
      "load_average": .object([
        "one_minute": loadValue(oneMinute),
        "five_minutes": loadValue(fiveMinutes),
        "fifteen_minutes": loadValue(fifteenMinutes),
      ]),
      "load_per_active_processor": .object([
        "one_minute": normalizedLoadValue(oneMinute),
        "five_minutes": normalizedLoadValue(fiveMinutes),
        "fifteen_minutes": normalizedLoadValue(fifteenMinutes),
      ]),
    ])
  }

  internal func systemCPU() throws -> JSONValue {
    let processInfo = ProcessInfo.processInfo
    var unameInfo = utsname()
    let machine =
      uname(&unameInfo) == 0
      ? JSONValue.string(fixedCString(unameInfo.machine))
      : .null

    return .object([
      "operation": .string("system.cpu"),
      "source": .array([
        .string("ProcessInfo"),
        .string("sysctlbyname"),
        .string("uname"),
      ]),
      "process_info": .object([
        "processor_count": .integer(Int64(processInfo.processorCount)),
        "active_processor_count": .integer(Int64(processInfo.activeProcessorCount)),
      ]),
      "hardware": .object([
        "machine": machine,
        "model_identifier": sysctlString("hw.model").map(JSONValue.string) ?? .null,
        "brand_string": sysctlString("machdep.cpu.brand_string").map(JSONValue.string) ?? .null,
        "physical_cpu_count": sysctlInteger("hw.physicalcpu").map { .integer(Int64($0)) } ?? .null,
        "logical_cpu_count": sysctlInteger("hw.logicalcpu").map { .integer(Int64($0)) } ?? .null,
        "physical_cpu_max": sysctlInteger("hw.physicalcpu_max").map { .integer(Int64($0)) }
          ?? .null,
        "logical_cpu_max": sysctlInteger("hw.logicalcpu_max").map { .integer(Int64($0)) } ?? .null,
        "cpu_frequency_hz": sysctlInteger("hw.cpufrequency").map { .integer(Int64($0)) } ?? .null,
        "cpu_frequency_min_hz": sysctlInteger("hw.cpufrequency_min").map { .integer(Int64($0)) }
          ?? .null,
        "cpu_frequency_max_hz": sysctlInteger("hw.cpufrequency_max").map { .integer(Int64($0)) }
          ?? .null,
        "arm64_supported": sysctlInteger("hw.optional.arm64").map { .bool($0 != 0) } ?? .null,
      ]),
    ])
  }

  internal func systemThermal() throws -> JSONValue {
    let processInfo = ProcessInfo.processInfo
    let thermalState = processInfo.thermalState

    return .object([
      "operation": .string("system.thermal"),
      "source": .string("ProcessInfo"),
      "thermal_state": .string(thermalStateName(thermalState)),
      "thermal_state_rank": .integer(Int64(thermalStateRank(thermalState))),
      "low_power_mode_enabled": .bool(processInfo.isLowPowerModeEnabled),
      "processor_count": .integer(Int64(processInfo.processorCount)),
      "active_processor_count": .integer(Int64(processInfo.activeProcessorCount)),
    ])
  }

  internal func systemTime() throws -> JSONValue {
    let now = Date()
    let timeZone = TimeZone.current
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    return .object([
      "now": .object([
        "iso8601": .string(formatter.string(from: now)),
        "unix_time": .number(now.timeIntervalSince1970),
      ]),
      "time_zone": .object([
        "identifier": .string(timeZone.identifier),
        "abbreviation": timeZone.abbreviation().map(JSONValue.string) ?? .null,
        "seconds_from_gmt": .integer(Int64(timeZone.secondsFromGMT(for: now))),
      ]),
      "system": .object([
        "uptime_seconds": .number(ProcessInfo.processInfo.systemUptime)
      ]),
    ])
  }

  internal func systemUptime() throws -> JSONValue {
    let now = Date()
    let uptime = ProcessInfo.processInfo.systemUptime
    let bootTime = now.addingTimeInterval(-uptime)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    return .object([
      "operation": .string("system.uptime"),
      "source": .array([
        .string("ProcessInfo.systemUptime"),
        .string("Date"),
      ]),
      "uptime_seconds": .number(uptime),
      "boot_time": .object([
        "iso8601": .string(formatter.string(from: bootTime)),
        "unix_time": .number(bootTime.timeIntervalSince1970),
      ]),
      "now": .object([
        "iso8601": .string(formatter.string(from: now)),
        "unix_time": .number(now.timeIntervalSince1970),
      ]),
    ])
  }

  internal func systemUser() throws -> JSONValue {
    let realUID = getuid()
    let effectiveUID = geteuid()
    let realGID = getgid()
    let effectiveGID = getegid()

    return .object([
      "operation": .string("system.user"),
      "source": .array([
        .string("getuid"),
        .string("geteuid"),
        .string("getgid"),
        .string("getegid"),
        .string("getpwuid"),
        .string("getgrgid"),
      ]),
      "ids": .object([
        "uid": .integer(Int64(realUID)),
        "effective_uid": .integer(Int64(effectiveUID)),
        "gid": .integer(Int64(realGID)),
        "effective_gid": .integer(Int64(effectiveGID)),
      ]),
      "user": passwdJSON(for: realUID),
      "effective_user": passwdJSON(for: effectiveUID),
      "group": groupJSON(for: realGID),
      "effective_group": groupJSON(for: effectiveGID),
    ])
  }

  internal func systemGroups() throws -> JSONValue {
    let count = getgroups(0, nil)
    guard count >= 0 else {
      throw GatewayToolError.executionFailed(
        "getgroups failed: \(String(cString: strerror(errno)))")
    }

    var groups = [gid_t](repeating: 0, count: Int(count))
    let returnedCount =
      groups.isEmpty
      ? 0
      : groups.withUnsafeMutableBufferPointer { buffer in
        getgroups(Int32(buffer.count), buffer.baseAddress)
      }
    guard returnedCount >= 0 else {
      throw GatewayToolError.executionFailed(
        "getgroups failed: \(String(cString: strerror(errno)))")
    }

    if returnedCount < groups.count {
      groups.removeSubrange(Int(returnedCount)..<groups.count)
    }

    return .object([
      "operation": .string("system.groups"),
      "source": .array([
        .string("getgroups"),
        .string("getgid"),
        .string("getegid"),
        .string("getgrgid"),
      ]),
      "primary_gid": .integer(Int64(getgid())),
      "effective_gid": .integer(Int64(getegid())),
      "supplementary_group_count": .integer(Int64(groups.count)),
      "supplementary_groups": .array(
        groups.map { gid in
          .object([
            "gid": .integer(Int64(gid)),
            "group": groupJSON(for: gid),
          ])
        }
      ),
    ])
  }

  internal func systemPower(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)

    let result = try commandRunner.run(
      executable: "/usr/bin/pmset",
      arguments: ["-g", "batt"],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes
    )

    return .object([
      "operation": .string("system.power"),
      "result": result.json,
    ])
  }

  internal func systemVolumes(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeHidden = try optionalBool("include_hidden", in: object) ?? false
    let keys = volumeResourceKeys()
    let options: FileManager.VolumeEnumerationOptions = includeHidden ? [] : [.skipHiddenVolumes]
    let volumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys,
        options: options
      ) ?? []
    let sortedVolumes = volumes.sorted {
      $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }

    return .object([
      "include_hidden": .bool(includeHidden),
      "volume_count": .integer(Int64(sortedVolumes.count)),
      "volumes": .array(sortedVolumes.map { volumeInfo(url: $0, keys: Set(keys)) }),
    ])
  }

  internal func systemProcesses(arguments object: [String: JSONValue]) throws -> JSONValue {
    let query = try optionalString("query", in: object)
    let maxResults = optionalInt("max_results", in: object) ?? 200
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes
    if let query {
      try validateUTF8ByteLimit(query, name: "query", maxBytes: 512)
    }
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 10_000)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let arguments = [
      "-axo",
      "pid=,ppid=,user=,stat=,pcpu=,pmem=,etime=,comm=",
    ]
    let result = try commandRunner.run(
      executable: "/bin/ps",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    var matched: [JSONValue] = []
    var matchedBeforeLimit = 0
    let normalizedQuery = query?.lowercased()
    for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(
      String.init)
    {
      let process = systemProcess(line: line)
      guard systemProcess(process, matches: normalizedQuery) else {
        continue
      }
      matchedBeforeLimit += 1
      if matched.count < maxResults {
        matched.append(process)
      }
    }

    return .object([
      "operation": .string("system.processes"),
      "argv": .array(arguments.map(JSONValue.string)),
      "query": query.map(JSONValue.string) ?? .null,
      "max_results": .integer(Int64(maxResults)),
      "process_count": .integer(Int64(matched.count)),
      "truncated": .bool(result.stdoutTruncated || matchedBeforeLimit > matched.count),
      "processes": .array(matched),
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

  internal func systemWhich(arguments object: [String: JSONValue]) throws -> JSONValue {
    let executable = try requiredString("name", in: object)
    let allMatches = try optionalBool("all_matches", in: object) ?? false
    try validateExecutableLookupName(executable)

    let paths = pathExecutables(executable, allMatches: allMatches)

    return .object([
      "operation": .string("system.which"),
      "name": .string(executable),
      "found": .bool(!paths.isEmpty),
      "resolved_path": paths.first.map(JSONValue.string) ?? .null,
      "paths": .array(paths.map(JSONValue.string)),
      "match_count": .integer(Int64(paths.count)),
      "all_matches": .bool(allMatches),
      "path_entry_count": .integer(Int64(pathSearchDirectories().count)),
    ])
  }

  internal func systemPath(arguments object: [String: JSONValue]) throws -> JSONValue {
    let includeMissing = try optionalBool("include_missing", in: object) ?? true
    let maxEntries = optionalInt("max_entries", in: object) ?? 200
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 1_000)

    let directories = pathSearchDirectories()
    let hasProcessPath = environment["PATH"] != nil
    var entries: [JSONValue] = []
    var omittedCount = 0
    var seenStandardizedPaths: [String: Int] = [:]
    let fileManager = FileManager.default

    for (index, path) in directories.enumerated() {
      var isDirectory = ObjCBool(false)
      let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
      if !includeMissing && !exists {
        continue
      }
      if entries.count >= maxEntries {
        omittedCount += directories.count - index
        break
      }

      let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
      let duplicateIndex = seenStandardizedPaths[standardizedPath]
      if duplicateIndex == nil {
        seenStandardizedPaths[standardizedPath] = index
      }

      entries.append(
        .object([
          "index": .integer(Int64(index)),
          "path": .string(path),
          "standardized_path": .string(standardizedPath),
          "is_absolute": .bool(path.hasPrefix("/")),
          "exists": .bool(exists),
          "is_directory": .bool(exists && isDirectory.boolValue),
          "is_readable": .bool(exists && fileManager.isReadableFile(atPath: path)),
          "is_writable": .bool(exists && fileManager.isWritableFile(atPath: path)),
          "is_executable": .bool(exists && fileManager.isExecutableFile(atPath: path)),
          "duplicate_of_index": duplicateIndex.map { .integer(Int64($0)) } ?? .null,
        ]))
    }

    return .object([
      "operation": .string("system.path"),
      "source": .string(hasProcessPath ? "process_environment" : "default_fallback"),
      "include_missing": .bool(includeMissing),
      "path_entry_count": .integer(Int64(directories.count)),
      "returned_count": .integer(Int64(entries.count)),
      "max_entries": .integer(Int64(maxEntries)),
      "truncated": .bool(omittedCount > 0),
      "omitted_entry_count": .integer(Int64(omittedCount)),
      "entries": .array(entries),
    ])
  }

  internal func logsQuery(arguments object: [String: JSONValue]) throws -> JSONValue {
    guard let lastSeconds = optionalInt("last_seconds", in: object) else {
      throw GatewayToolError.invalidArguments(
        "Missing required integer argument: last_seconds")
    }
    guard let maxEntries = optionalInt("max_entries", in: object) else {
      throw GatewayToolError.invalidArguments(
        "Missing required integer argument: max_entries")
    }
    let predicate = try optionalString("predicate", in: object)
    let includeInfo = try optionalBool("include_info", in: object) ?? false
    let includeDebug = try optionalBool("include_debug", in: object) ?? false
    let timeout = optionalInt("timeout_ms", in: object) ?? 30_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes

    try validateBoundedPositive(lastSeconds, name: "last_seconds", upperBound: 604_800)
    try validateBoundedPositive(maxEntries, name: "max_entries", upperBound: 10_000)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(
      maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)
    if let predicate {
      guard !predicate.isEmpty else {
        throw GatewayToolError.invalidArguments("predicate must not be empty when provided.")
      }
      try validateUTF8ByteLimit(predicate, name: "predicate", maxBytes: 4_096)
    }

    var arguments = [
      "show",
      "--style", "ndjson",
      "--color", "none",
      "--no-pager",
      "--last", "\(lastSeconds)s",
    ]
    if includeInfo {
      arguments.append("--info")
    }
    if includeDebug {
      arguments.append("--debug")
    }
    if let predicate {
      arguments.append(contentsOf: ["--predicate", predicate])
    }

    let result = try commandRunner.run(
      executable: "/usr/bin/log",
      arguments: arguments,
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )

    let decoder = JSONDecoder()
    var events: [JSONValue] = []
    var unparsedLines: [JSONValue] = []
    var observedLineCount = 0
    var returnedLineCount = 0
    for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(rawLine)
      guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
      }
      observedLineCount += 1
      guard returnedLineCount < maxEntries else {
        continue
      }
      returnedLineCount += 1
      do {
        events.append(try decoder.decode(JSONValue.self, from: Data(line.utf8)))
      } catch {
        unparsedLines.append(
          .object([
            "line": .string(line),
            "error": .string(error.localizedDescription),
          ]))
      }
    }

    let omittedLineCount = max(0, observedLineCount - returnedLineCount)
    return .object([
      "operation": .string("logs.query"),
      "source": .string("macos_unified_log"),
      "last_seconds": .integer(Int64(lastSeconds)),
      "max_entries": .integer(Int64(maxEntries)),
      "predicate": predicate.map(JSONValue.string) ?? .null,
      "include_info": .bool(includeInfo),
      "include_debug": .bool(includeDebug),
      "observed_line_count": .integer(Int64(observedLineCount)),
      "returned_line_count": .integer(Int64(returnedLineCount)),
      "event_count": .integer(Int64(events.count)),
      "unparsed_line_count": .integer(Int64(unparsedLines.count)),
      "omitted_line_count": .integer(Int64(omittedLineCount)),
      "truncated": .bool(
        result.stdoutTruncated || observedLineCount > returnedLineCount || result.timedOut),
      "events": .array(events),
      "unparsed_lines": .array(unparsedLines),
      "execution": .object([
        "executable": .string(result.executable),
        "arguments": .array(result.arguments.map(JSONValue.string)),
        "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
        "timed_out": .bool(result.timedOut),
        "stdout_bytes": .integer(Int64(result.stdout.utf8.count)),
        "stdout_truncated": .bool(result.stdoutTruncated),
        "stderr": .string(result.stderr),
        "stderr_truncated": .bool(result.stderrTruncated),
      ]),
    ])
  }

  internal func serviceStatus(arguments object: [String: JSONValue]) throws -> JSONValue {
    let domain = try requiredString("domain", in: object)
    let label = try requiredString("label", in: object)
    let timeout = optionalInt("timeout_ms", in: object) ?? 10_000
    let maxOutputBytes =
      optionalInt("max_output_bytes", in: object)
      ?? configuration.policy.maxOutputBytes

    guard ["system", "user", "gui"].contains(domain) else {
      throw GatewayToolError.invalidArguments(
        "domain must be one of: system, user, gui.")
    }
    try validateLaunchServiceLabel(label)
    try validateBoundedPositive(timeout, name: "timeout_ms", upperBound: 600_000)
    try validateBoundedPositive(
      maxOutputBytes, name: "max_output_bytes", upperBound: 20_971_520)

    let uid = Int(geteuid())
    let target =
      domain == "system"
      ? "system/\(label)"
      : "\(domain)/\(uid)/\(label)"
    let result = try commandRunner.run(
      executable: "/bin/launchctl",
      arguments: ["print", target],
      workingDirectory: configuration.workspaceDirectory,
      environment: [:],
      timeoutMilliseconds: timeout,
      maxOutputBytes: maxOutputBytes
    )
    let found = result.exitCode == 0 && !result.timedOut

    return .object([
      "operation": .string("service.status"),
      "source": .string("launchctl_print"),
      "domain": .string(domain),
      "uid": domain == "system" ? .null : .integer(Int64(uid)),
      "label": .string(label),
      "target": .string(target),
      "found": .bool(found),
      "fields": found ? .object(launchServiceSafeFields(result.stdout)) : .object([:]),
      "raw_output_returned": .bool(false),
      "environment_returned": .bool(false),
      "execution": .object([
        "executable": .string(result.executable),
        "arguments": .array(result.arguments.map(JSONValue.string)),
        "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
        "timed_out": .bool(result.timedOut),
        "stdout_bytes": .integer(Int64(result.stdout.utf8.count)),
        "stdout_truncated": .bool(result.stdoutTruncated),
        "stderr": .string(result.stderr),
        "stderr_truncated": .bool(result.stderrTruncated),
      ]),
    ])
  }

  private func validateLaunchServiceLabel(_ label: String) throws {
    try validateUTF8ByteLimit(label, name: "label", maxBytes: 512)
    guard !label.isEmpty, !label.hasPrefix("-") else {
      throw GatewayToolError.invalidArguments(
        "label must be a non-empty launch service label, not an option.")
    }
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    guard label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      throw GatewayToolError.invalidArguments(
        "label may contain only letters, digits, dot, underscore, or hyphen.")
    }
  }

  private func launchServiceSafeFields(_ stdout: String) -> [String: JSONValue] {
    let allowed: [String: String] = [
      "active count": "active_count",
      "path": "path",
      "type": "type",
      "state": "state",
      "bundle id": "bundle_id",
      "program": "program",
      "domain": "domain",
      "asid": "audit_session_id",
      "minimum runtime": "minimum_runtime_seconds",
      "base minimum runtime": "base_minimum_runtime_seconds",
      "exit timeout": "exit_timeout_seconds",
      "runs": "runs",
      "pid": "pid",
      "immediate reason": "immediate_reason",
      "forks": "forks",
      "execs": "execs",
      "initialized": "initialized",
      "trampolined": "trampolined",
      "started suspended": "started_suspended",
      "last exit code": "last_exit_code",
    ]
    var fields: [String: JSONValue] = [:]
    for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(rawLine)
      guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else {
        continue
      }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let parts = trimmed.components(separatedBy: " = ")
      guard parts.count == 2, let outputKey = allowed[parts[0]] else {
        continue
      }
      let value = parts[1]
      if let integer = Int(value) {
        fields[outputKey] = .integer(Int64(integer))
      } else {
        fields[outputKey] = .string(value)
      }
    }
    return fields
  }

  internal func describeEnvironment() -> JSONValue {
    let processEnvironment = ProcessInfo.processInfo.environment
    var declaredKeys = Set<String>()

    var serverEntries: [JSONValue] = []
    if let accessTokenEnv = configuration.server.http.accessTokenEnv {
      serverEntries.append(
        environmentEntry(
          key: accessTokenEnv,
          owner: "server.http",
          purpose: "access_token_env",
          valueOrigin: "process_environment",
          processEnvironment: processEnvironment,
          declaredKeys: &declaredKeys
        ))
    }
    let cliEntries: [JSONValue] = configuration.cli.commands.map { command in
      JSONValue.object([
        "id": .string(command.id),
        "env": .array(
          command.env.keys.sorted().map { key in
            environmentEntry(
              key: key,
              owner: "cli.\(command.id)",
              purpose: "env",
              valueOrigin: "configured_provider_env",
              processEnvironment: processEnvironment,
              declaredKeys: &declaredKeys
            )
          }),
      ])
    }

    let mcpEntries: [JSONValue] = configuration.mcp.servers.map { server in
      JSONValue.object([
        "id": .string(server.id),
        "env": .array(
          server.env.keys.sorted().map { key in
            environmentEntry(
              key: key,
              owner: "mcp.\(server.id)",
              purpose: "env",
              valueOrigin: "configured_provider_env",
              processEnvironment: processEnvironment,
              declaredKeys: &declaredKeys
            )
          }),
      ])
    }

    let presentCount = declaredKeys.filter { processEnvironment[$0] != nil }.count
    return .object([
      "summary": .object([
        "declared_key_count": .integer(Int64(declaredKeys.count)),
        "process_environment_present_count": .integer(Int64(presentCount)),
        "values_redacted": .bool(true),
      ]),
      "server": .array(serverEntries),
      "cli": .array(cliEntries),
      "mcp": .array(mcpEntries),
    ])
  }

  private func passwdJSON(for uid: uid_t) -> JSONValue {
    guard let pointer = getpwuid(uid) else {
      return .null
    }
    let value = pointer.pointee
    return .object([
      "uid": .integer(Int64(value.pw_uid)),
      "gid": .integer(Int64(value.pw_gid)),
      "name": cStringJSON(value.pw_name),
      "home_directory": cStringJSON(value.pw_dir),
      "shell": cStringJSON(value.pw_shell),
    ])
  }

  private func groupJSON(for gid: gid_t) -> JSONValue {
    guard let pointer = getgrgid(gid) else {
      return .null
    }
    let value = pointer.pointee
    return .object([
      "gid": .integer(Int64(value.gr_gid)),
      "name": cStringJSON(value.gr_name),
    ])
  }

  private func cStringJSON(_ pointer: UnsafePointer<CChar>?) -> JSONValue {
    guard let pointer else {
      return .null
    }
    return .string(String(cString: pointer))
  }

  private func fixedCString<T>(_ value: T) -> String {
    withUnsafePointer(to: value) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { buffer in
        String(cString: buffer)
      }
    }
  }

  private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
      return nil
    }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
      return nil
    }
    return stringFromNullTerminatedCString(buffer)
  }

  private func sysctlInteger(_ name: String) -> Int64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
      return nil
    }

    switch size {
    case MemoryLayout<Int32>.size:
      var value: Int32 = 0
      var valueSize = size
      guard sysctlbyname(name, &value, &valueSize, nil, 0) == 0 else {
        return nil
      }
      return Int64(value)

    case MemoryLayout<Int64>.size:
      var value: Int64 = 0
      var valueSize = size
      guard sysctlbyname(name, &value, &valueSize, nil, 0) == 0 else {
        return nil
      }
      return value

    default:
      return nil
    }
  }

  internal func stringFromNullTerminatedCString(_ buffer: [CChar]) -> String {
    let endIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
    let bytes = buffer[..<endIndex].map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "unknown"
    }
  }

  private func thermalStateRank(_ state: ProcessInfo.ThermalState) -> Int {
    switch state {
    case .nominal:
      return 0
    case .fair:
      return 1
    case .serious:
      return 2
    case .critical:
      return 3
    @unknown default:
      return -1
    }
  }

  private func systemProcess(line: String) -> JSONValue {
    let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
      .map(String.init)
    guard parts.count == 8,
      let pid = Int(parts[0]),
      let parentPID = Int(parts[1]),
      let cpuPercent = Double(parts[4]),
      let memoryPercent = Double(parts[5])
    else {
      return .object([
        "parsed": .bool(false),
        "raw_line": .string(line),
      ])
    }

    return .object([
      "parsed": .bool(true),
      "pid": .integer(Int64(pid)),
      "parent_pid": .integer(Int64(parentPID)),
      "user": .string(parts[2]),
      "state": .string(parts[3]),
      "cpu_percent": .number(cpuPercent),
      "memory_percent": .number(memoryPercent),
      "elapsed": .string(parts[6]),
      "command": .string(parts[7]),
    ])
  }

  private func systemProcess(_ process: JSONValue, matches query: String?) -> Bool {
    guard let query, !query.isEmpty else {
      return true
    }
    guard let object = process.objectValue else {
      return false
    }
    let fields = [
      object["user"]?.stringValue,
      object["state"]?.stringValue,
      object["command"]?.stringValue,
      object["raw_line"]?.stringValue,
    ].compactMap { $0?.lowercased() }
    return fields.contains { $0.contains(query) }
  }

  internal func volumeResourceKeys() -> [URLResourceKey] {
    [
      .nameKey,
      .volumeURLKey,
      .volumeNameKey,
      .volumeLocalizedNameKey,
      .volumeUUIDStringKey,
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityForOpportunisticUsageKey,
      .volumeIsLocalKey,
      .volumeIsInternalKey,
      .volumeIsEjectableKey,
      .volumeIsRemovableKey,
      .volumeIsReadOnlyKey,
      .volumeSupportsCasePreservedNamesKey,
      .volumeSupportsCaseSensitiveNamesKey,
      .volumeSupportsCompressionKey,
      .volumeSupportsFileCloningKey,
      .volumeSupportsHardLinksKey,
      .volumeSupportsJournalingKey,
      .volumeSupportsPersistentIDsKey,
      .volumeSupportsSparseFilesKey,
      .volumeSupportsSymbolicLinksKey,
      .volumeSupportsVolumeSizesKey,
    ]
  }

  internal func volumeInfo(url: URL, keys: Set<URLResourceKey>) -> JSONValue {
    let values = try? url.resourceValues(forKeys: keys)
    let name =
      values?.volumeLocalizedName ?? values?.volumeName ?? values?.name ?? url.lastPathComponent
    return .object([
      "path": .string(url.path),
      "name": .string(name),
      "localized_name": values?.volumeLocalizedName.map(JSONValue.string) ?? .null,
      "volume_name": values?.volumeName.map(JSONValue.string) ?? .null,
      "uuid": values?.volumeUUIDString.map(JSONValue.string) ?? .null,
      "total_capacity_bytes": values?.volumeTotalCapacity.map { .integer(Int64($0)) } ?? .null,
      "available_capacity_bytes": values?.volumeAvailableCapacity.map { .integer(Int64($0)) }
        ?? .null,
      "available_capacity_for_important_usage_bytes": values?
        .volumeAvailableCapacityForImportantUsage.map { .integer(Int64($0)) } ?? .null,
      "available_capacity_for_opportunistic_usage_bytes": values?
        .volumeAvailableCapacityForOpportunisticUsage.map { .integer(Int64($0)) } ?? .null,
      "is_local": values?.volumeIsLocal.map(JSONValue.bool) ?? .null,
      "is_internal": values?.volumeIsInternal.map(JSONValue.bool) ?? .null,
      "is_ejectable": values?.volumeIsEjectable.map(JSONValue.bool) ?? .null,
      "is_removable": values?.volumeIsRemovable.map(JSONValue.bool) ?? .null,
      "is_read_only": values?.volumeIsReadOnly.map(JSONValue.bool) ?? .null,
      "supports_case_preserved_names": values?.volumeSupportsCasePreservedNames
        .map(JSONValue.bool) ?? .null,
      "supports_case_sensitive_names": values?.volumeSupportsCaseSensitiveNames
        .map(JSONValue.bool) ?? .null,
      "supports_compression": values?.volumeSupportsCompression.map(JSONValue.bool) ?? .null,
      "supports_file_cloning": values?.volumeSupportsFileCloning.map(JSONValue.bool) ?? .null,
      "supports_hard_links": values?.volumeSupportsHardLinks.map(JSONValue.bool) ?? .null,
      "supports_journaling": values?.volumeSupportsJournaling.map(JSONValue.bool) ?? .null,
      "supports_persistent_ids": values?.volumeSupportsPersistentIDs.map(JSONValue.bool) ?? .null,
      "supports_sparse_files": values?.volumeSupportsSparseFiles.map(JSONValue.bool) ?? .null,
      "supports_symbolic_links": values?.volumeSupportsSymbolicLinks.map(JSONValue.bool) ?? .null,
      "supports_volume_sizes": values?.volumeSupportsVolumeSizes.map(JSONValue.bool) ?? .null,
    ])
  }

  internal func environmentEntry(
    key: String,
    owner: String,
    purpose: String,
    valueOrigin: String,
    processEnvironment: [String: String],
    declaredKeys: inout Set<String>
  ) -> JSONValue {
    declaredKeys.insert(key)
    return .object([
      "key": .string(key),
      "owner": .string(owner),
      "purpose": .string(purpose),
      "value_origin": .string(valueOrigin),
      "process_environment_present": .bool(processEnvironment[key] != nil),
      "value_redacted": .bool(true),
    ])
  }

  internal func httpAuthMode() -> String {
    if configuration.server.http.accessTokenEnv != nil {
      return "bearer"
    }
    return "none"
  }
}
