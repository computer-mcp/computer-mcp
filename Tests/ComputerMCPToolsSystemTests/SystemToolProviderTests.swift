import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsSystem

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite(.nativeIntegration, .serialized)
final class SystemToolProviderTests {
  @Test
  func testSystemInfoReturnsReadOnlyMacOSSummary() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.info"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.info", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operating_system"]?.objectValue?["name"]) == (.string("macOS")))
    #expect((payload.objectValue?["hardware"]?.objectValue?["processor_count"]) != nil)
    #expect((payload.objectValue?["process"]?.objectValue?["id"]) != nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemKernelReturnsReadOnlyUnameSummary() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.kernel"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.kernel", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.kernel")))
    #expect((payload.objectValue?["source"]) == (.string("uname")))
    #expect((payload.objectValue?["operating_system"]?.objectValue?["name"]) == (.string("macOS")))
    #expect(
      !(try #require(payload.objectValue?["kernel"]?.objectValue?["name"]?.stringValue).isEmpty))
    #expect(
      !(try #require(payload.objectValue?["kernel"]?.objectValue?["release"]?.stringValue).isEmpty))
    #expect(
      !(try #require(payload.objectValue?["hardware"]?.objectValue?["machine"]?.stringValue)
        .isEmpty))
    #expect(
      (try #require(payload.objectValue?["hardware"]?.objectValue?["processor_count"]?.numberValue))
        > (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemSoftwareUsesSWVersFixedArgvAndParsesVersion() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      ProductName:\t\tmacOS
      ProductVersion:\t\t15.6
      BuildVersion:\t\t24G84
      """
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.software"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.software",
        arguments: .object(["timeout_ms": .number(1234)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["sw_vers"]!))
    #expect((runner.calls.first?.arguments) == ([]))
    #expect((payload.objectValue?["operation"]) == (.string("system.software")))
    #expect((payload.objectValue?["source"]) == (.string(systemExecutables["sw_vers"]!)))
    #expect((payload.objectValue?["product"]?.objectValue?["name"]) == (.string("macOS")))
    #expect((payload.objectValue?["product"]?.objectValue?["version"]) == (.string("15.6")))
    #expect((payload.objectValue?["product"]?.objectValue?["build_version"]) == (.string("24G84")))
    #expect(
      (try #require(
        payload.objectValue?["process_info"]?.objectValue?["major_version"]?.numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemLocaleReturnsReadOnlyLocaleSummary() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.locale"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.locale", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.locale")))
    #expect((payload.objectValue?["source"]) == (.string("Foundation.Locale")))
    #expect(
      !(try #require(payload.objectValue?["locale"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["preferred_languages"]?.arrayValue) != nil)
    #expect(
      !(try #require(payload.objectValue?["calendar"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect(
      !(try #require(payload.objectValue?["time_zone"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["time_zone"]?.objectValue?["seconds_from_gmt"]) != nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemLoadReturnsReadOnlyLoadAverage() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.load"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.load", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.load")))
    #expect((payload.objectValue?["source"]) == (.string("getloadavg")))
    #expect((try #require(payload.objectValue?["sample_count"]?.numberValue)) >= (1))
    #expect((try #require(payload.objectValue?["active_processor_count"]?.numberValue)) > (0))
    #expect(
      (try #require(payload.objectValue?["load_average"]?.objectValue?["one_minute"]?.numberValue))
        >= (0))
    #expect(
      (try #require(
        payload.objectValue?["load_per_active_processor"]?.objectValue?["one_minute"]?
          .numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemTimeReturnsLocalTimeSnapshot() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.time"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.time", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["now"]?.objectValue?["iso8601"]?.stringValue) != nil)
    #expect((payload.objectValue?["now"]?.objectValue?["unix_time"]?.numberValue) != nil)
    #expect(
      !(try #require(payload.objectValue?["time_zone"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["time_zone"]?.objectValue?["seconds_from_gmt"]) != nil)
    #expect(
      (try #require(payload.objectValue?["system"]?.objectValue?["uptime_seconds"]?.numberValue))
        > (0))
  }

  @Test
  func testSystemUptimeReturnsReadOnlyBootTimeSummary() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.uptime"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.uptime", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)
    let uptime = try #require(payload.objectValue?["uptime_seconds"]?.numberValue)
    let bootTime = try #require(payload.objectValue?["boot_time"]?.objectValue)
    let now = try #require(payload.objectValue?["now"]?.objectValue)
    let bootUnixTime = try #require(bootTime["unix_time"]?.numberValue)
    let nowUnixTime = try #require(now["unix_time"]?.numberValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.uptime")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([.string("ProcessInfo.systemUptime"), .string("Date")])))
    #expect((uptime) > (0))
    #expect((bootTime["iso8601"]?.stringValue) != nil)
    #expect((now["iso8601"]?.stringValue) != nil)
    #expect((bootUnixTime) < (nowUnixTime))
    #expect((abs((nowUnixTime - bootUnixTime) - uptime)) < (1))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemUserReturnsCurrentPOSIXIdentity() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.user"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.user", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)
    let ids = try #require(payload.objectValue?["ids"]?.objectValue)
    let user = try #require(payload.objectValue?["user"]?.objectValue)
    let effectiveUser = try #require(payload.objectValue?["effective_user"]?.objectValue)
    let group = try #require(payload.objectValue?["group"]?.objectValue)
    let effectiveGroup = try #require(payload.objectValue?["effective_group"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.user")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([
          .string("getuid"),
          .string("geteuid"),
          .string("getgid"),
          .string("getegid"),
          .string("getpwuid"),
          .string("getgrgid"),
        ])))
    #expect((ids["uid"]) == (.number(Double(getuid()))))
    #expect((ids["effective_uid"]) == (.number(Double(geteuid()))))
    #expect((ids["gid"]) == (.number(Double(getgid()))))
    #expect((ids["effective_gid"]) == (.number(Double(getegid()))))
    #expect(!(try #require(user["name"]?.stringValue).isEmpty))
    #expect(!(try #require(effectiveUser["name"]?.stringValue).isEmpty))
    #expect(!(try #require(group["name"]?.stringValue).isEmpty))
    #expect(!(try #require(effectiveGroup["name"]?.stringValue).isEmpty))
    #expect((user["home_directory"]) != nil)
    #expect((user["shell"]) != nil)
    #expect((payload.objectValue?["users"]) == nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemGroupsReturnsCurrentSupplementaryGroups() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.groups"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.groups", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)
    let groupCount = getgroups(0, nil)
    let groups = try #require(payload.objectValue?["supplementary_groups"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.groups")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([
          .string("getgroups"),
          .string("getgid"),
          .string("getegid"),
          .string("getgrgid"),
        ])))
    #expect((payload.objectValue?["primary_gid"]) == (.number(Double(getgid()))))
    #expect((payload.objectValue?["effective_gid"]) == (.number(Double(getegid()))))
    #expect(
      (payload.objectValue?["supplementary_group_count"]) == (.number(Double(max(groupCount, 0)))))
    #expect((groups.count) == (max(Int(groupCount), 0)))
    if let first = groups.first?.objectValue {
      #expect((first["gid"]?.numberValue) != nil)
      #expect((first["group"]) != nil)
    }
    #expect((payload.objectValue?["users"]) == nil)
    #expect((payload.objectValue?["groups"]) == nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemPowerUsesPMSetWithoutShellInterpolation() throws {
    let runner = RecordingCommandRunner()
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.power"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.power",
        arguments: .object(["timeout_ms": .number(1234)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["pmset"]!))
    #expect((runner.calls.first?.arguments) == (["-g", "batt"]))
    #expect((payload.objectValue?["operation"]) == (.string("system.power")))
  }

  @Test
  func testSystemVolumesReturnsMountedVolumeSummary() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.volumes"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.volumes",
        arguments: .object(["include_hidden": .bool(false)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["volume_count"]) != nil)
    #expect((payload.objectValue?["volumes"]?.arrayValue) != nil)
  }

  @Test
  func testSystemProcessesUsesPSFixedArgvAndParsesSnapshot() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
        123     1 root     Ss     0.0  0.1 01:02:03 /sbin/launchd
        456   123 exampleuser S      12.5 1.2 00:00:05 /fixture/apps/Terminal
      broken line
      """
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.processes"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.processes",
        arguments: .object([
          "query": .string("terminal"),
          "max_results": .number(5),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let processes = try #require(payload.objectValue?["processes"]?.arrayValue)
    let first = try #require(processes.first?.objectValue)

    #expect((runner.calls.first?.executable) == (systemExecutables["ps"]!))
    #expect(
      (runner.calls.first?.arguments)
        == (["-axo", "pid=,ppid=,user=,stat=,pcpu=,pmem=,etime=,comm="]))
    #expect((payload.objectValue?["operation"]) == (.string("system.processes")))
    #expect((payload.objectValue?["query"]) == (.string("terminal")))
    #expect((payload.objectValue?["process_count"]) == (.number(1)))
    #expect((first["parsed"]) == (.bool(true)))
    #expect((first["pid"]) == (.number(456)))
    #expect((first["parent_pid"]) == (.number(123)))
    #expect((first["user"]) == (.string("exampleuser")))
    #expect((first["state"]) == (.string("S")))
    #expect((first["cpu_percent"]) == (.number(12.5)))
    #expect((first["memory_percent"]) == (.number(1.2)))
    #expect((first["elapsed"]) == (.string("00:00:05")))
    #expect((first["command"]) == (.string("/fixture/apps/Terminal")))
  }

  @Test
  func testSystemProcessesReportsTruncationAndRejectsBadBounds() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
        123     1 root     Ss     0.0  0.1 01:02:03 /sbin/launchd
        456   123 exampleuser S      12.5 1.2 00:00:05 /fixture/apps/Terminal
      """
    runner.stdoutTruncated = true
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.processes"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.processes",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let processes = try #require(payload.objectValue?["processes"]?.arrayValue)

    #expect((processes.count) == (1))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout_truncated"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "system.processes",
          arguments: .object(["max_results": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testSystemWhichResolvesExecutableFromPathWithoutRunningIt() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("sample-tool")
    try "#!/bin/sh\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.which"])
        ),
        environment: ["PATH": directory.path],
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.which",
        arguments: .object([
          "name": .string("sample-tool"),
          "all_matches": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.which")))
    #expect((payload.objectValue?["name"]) == (.string("sample-tool")))
    #expect((payload.objectValue?["found"]) == (.bool(true)))
    #expect((payload.objectValue?["resolved_path"]) == (.string(executable.path)))
    #expect((payload.objectValue?["paths"]) == (.array([.string(executable.path)])))
    #expect((payload.objectValue?["match_count"]) == (.number(1)))
    #expect((payload.objectValue?["all_matches"]) == (.bool(true)))
    #expect((payload.objectValue?["path_entry_count"]) == (.number(1)))
    #expect((payload.objectValue?["environment"]) == nil)

    let missing = try provider.callTool(
      .init(
        name: "system.which",
        arguments: .object(["name": .string("missing-tool")]), context: .empty
      ))
    let missingPayload = try decodeTextPayload(missing)
    #expect((missingPayload.objectValue?["found"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["paths"]) == (.array([])))
  }

  @Test
  func testSystemWhichRejectsBadExecutableNames() {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.which"])
        ),
        builtinExecutables: systemExecutables))

    for name in ["", "-tool", "../tool", "bad tool", "."] {
      expectThrows(
        try provider.callTool(
          .init(
            name: "system.which",
            arguments: .object(["name": .string(name)]), context: .empty
          ))
      ) { error in
        #expect(error.localizedDescription.contains("name"))
      }
    }
  }

  @Test
  func testSystemPathReturnsStructuredEntriesWithoutEnvironmentDump() throws {
    let directory = try temporaryDirectory()
    let missing = directory.appendingPathComponent("missing")
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.path"])
        ),
        environment: ["PATH": "\(directory.path):\(missing.path):\(directory.path)"],
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "system.path",
        arguments: .object([
          "include_missing": .bool(true),
          "max_entries": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.path")))
    #expect((payload.objectValue?["source"]) == (.string("process_environment")))
    #expect((payload.objectValue?["path_entry_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["environment"]) == nil)
    #expect((entries[0].objectValue?["path"]) == (.string(directory.path)))
    #expect((entries[0].objectValue?["exists"]) == (.bool(true)))
    #expect((entries[0].objectValue?["is_directory"]) == (.bool(true)))
    #expect((entries[0].objectValue?["is_absolute"]) == (.bool(true)))
    #expect((entries[0].objectValue?["duplicate_of_index"]) == (.null))
    #expect((entries[1].objectValue?["path"]) == (.string(missing.path)))
    #expect((entries[1].objectValue?["exists"]) == (.bool(false)))
    #expect((entries[1].objectValue?["is_directory"]) == (.bool(false)))
    #expect((entries[2].objectValue?["duplicate_of_index"]) == (.number(0)))

    let existingOnly = try provider.callTool(
      .init(
        name: "system.path",
        arguments: .object([
          "include_missing": .bool(false),
          "max_entries": .number(1),
        ]), context: .empty
      ))
    let existingPayload = try decodeTextPayload(existingOnly)
    let existingEntries = try #require(existingPayload.objectValue?["entries"]?.arrayValue)
    #expect((existingPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((existingPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((existingEntries.map { $0.objectValue?["path"] }) == ([.string(directory.path)]))
  }

  @Test
  func testSystemPathRejectsBadBounds() {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.path"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "system.path",
          arguments: .object(["max_entries": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }
  }

  @Test
  func testLogsQueryUsesBoundedNDJSONArgvAndParsesEvents() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      """
      {"eventMessage":"first","processImagePath":"/fixture/bin/example"}
      not-json
      {"eventMessage":"third"}
      """
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["logs.query"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "logs.query",
        arguments: .object([
          "last_seconds": .number(300),
          "max_entries": .number(2),
          "predicate": .string("process == \"example\""),
          "include_info": .bool(true),
          "include_debug": .bool(true),
          "timeout_ms": .number(12_345),
          "max_output_bytes": .number(65_536),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let events = try #require(payload.objectValue?["events"]?.arrayValue)
    let unparsed = try #require(payload.objectValue?["unparsed_lines"]?.arrayValue)

    #expect((runner.calls.first?.executable) == (systemExecutables["log"]!))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "show", "--style", "ndjson", "--color", "none", "--no-pager", "--last", "300s",
          "--info", "--debug", "--predicate", "process == \"example\"",
        ]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (12_345))
    #expect((runner.calls.first?.maxOutputBytes) == (65_536))
    #expect((payload.objectValue?["operation"]) == (.string("logs.query")))
    #expect((payload.objectValue?["source"]) == (.string("macos_unified_log")))
    #expect((payload.objectValue?["observed_line_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_line_count"]) == (.number(2)))
    #expect((payload.objectValue?["event_count"]) == (.number(1)))
    #expect((payload.objectValue?["unparsed_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["omitted_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((events.first?.objectValue?["eventMessage"]) == (.string("first")))
    #expect((unparsed.first?.objectValue?["line"]) == (.string("not-json")))
    #expect((payload.objectValue?["execution"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testLogsQueryRequiresExplicitBoundsAndRejectsBadPredicate() {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["logs.query"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(.init(name: "logs.query", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("last_seconds"))
    }
    expectThrows(
      try provider.callTool(
        .init(
          name: "logs.query",
          arguments: .object([
            "last_seconds": .number(1),
            "max_entries": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }
    expectThrows(
      try provider.callTool(
        .init(
          name: "logs.query",
          arguments: .object([
            "last_seconds": .number(1),
            "max_entries": .number(1),
            "predicate": .string(""),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("predicate"))
    }
  }

  @Test
  func testServiceStatusUsesCurrentUIDAndRedactsUnsafeLaunchctlSections() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      """
      gui/501/com.example.worker = {
      \tactive count = 1
      \tpath = /Library/LaunchAgents/com.example.worker.plist
      \ttype = LaunchAgent
      \tstate = running
      \tenvironment = {
      \t\tSECRET_TOKEN => do-not-return
      \t}
      \tpid = 123
      \truns = 4
      }
      """
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["service.status"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "service.status",
        arguments: .object([
          "domain": .string("gui"),
          "label": .string("com.example.worker"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let fields = try #require(payload.objectValue?["fields"]?.objectValue)
    let encoded = try JSONEncoder().encode(payload)
    let text = String(decoding: encoded, as: UTF8.self)

    #expect((runner.calls.first?.executable) == (systemExecutables["launchctl"]!))
    #expect((runner.calls.first?.arguments) == (["print", "gui/\(geteuid())/com.example.worker"]))
    #expect((payload.objectValue?["operation"]) == (.string("service.status")))
    #expect((payload.objectValue?["found"]) == (.bool(true)))
    #expect((payload.objectValue?["environment_returned"]) == (.bool(false)))
    #expect((payload.objectValue?["raw_output_returned"]) == (.bool(false)))
    #expect((fields["state"]) == (.string("running")))
    #expect((fields["pid"]) == (.number(123)))
    #expect((fields["runs"]) == (.number(4)))
    #expect((fields["environment"]) == nil)
    #expect(!(text.contains("SECRET_TOKEN")))
    #expect(!(text.contains("do-not-return")))
  }

  @Test
  func testServiceStatusReportsMissingAndRejectsUnsafeTargets() throws {
    let runner = RecordingCommandRunner()
    runner.exitCode = 113
    runner.stdout = "environment = { SECRET_TOKEN => do-not-return }"
    runner.stderr = "Could not find service"
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["service.status"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "service.status",
        arguments: .object([
          "domain": .string("system"),
          "label": .string("com.example.missing"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    #expect((runner.calls.first?.arguments) == (["print", "system/com.example.missing"]))
    #expect((payload.objectValue?["found"]) == (.bool(false)))
    #expect((payload.objectValue?["fields"]) == (.object([:])))
    #expect((payload.objectValue?["execution"]?.objectValue?["stdout"]) == nil)

    expectThrows(
      try provider.callTool(
        .init(
          name: "service.status",
          arguments: .object([
            "domain": .string("login"),
            "label": .string("com.example.worker"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("domain"))
    }
    expectThrows(
      try provider.callTool(
        .init(
          name: "service.status",
          arguments: .object([
            "domain": .string("gui"),
            "label": .string("../com.example.worker"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("label"))
    }
  }

  @Test
  func testNetworkInterfacesUsesIfconfigWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.interfaces"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.interfaces",
        arguments: .object(["interface": .string("lo0")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["ifconfig"]!))
    #expect((runner.calls.first?.arguments) == (["lo0"]))
    #expect((payload.objectValue?["operation"]) == (.string("network.interfaces")))
    #expect((payload.objectValue?["interface"]) == (.string("lo0")))

    _ = try provider.callTool(
      .init(name: "network.interfaces", arguments: .object([:]), context: .empty))
    #expect((runner.calls.last?.arguments) == (["-a"]))
  }

  @Test
  func testNetworkInterfacesRejectsOptionLikeInterfaceName() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.interfaces"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.interfaces",
          arguments: .object(["interface": .string("-a")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }
  }

  @Test
  func testNetworkDNSUsesSCUtilWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.dns"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.dns", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["scutil"]!))
    #expect((runner.calls.first?.arguments) == (["--dns"]))
    #expect((payload.objectValue?["operation"]) == (.string("network.dns")))
  }

  @Test
  func testNetworkResolveUsesSystemResolverWithoutShell() throws {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.resolve"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.resolve",
        arguments: .object([
          "host": .string("localhost"),
          "family": .string("ipv4"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let addresses = try #require(payload.objectValue?["addresses"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("network.resolve")))
    #expect((payload.objectValue?["source"]) == (.string("getaddrinfo")))
    #expect((payload.objectValue?["host"]) == (.string("localhost")))
    #expect((payload.objectValue?["family"]) == (.string("ipv4")))
    #expect((payload.objectValue?["resolved"]) == (.bool(true)))
    #expect((addresses.count) >= (1))
    #expect(
      addresses.contains { address in
        address.objectValue?["family"] == .string("ipv4")
          && address.objectValue?["address"] == .string("127.0.0.1")
      })
    #expect((payload.objectValue?["result"]) == nil)
  }

  @Test
  func testNetworkResolveReportsUnresolvedHostAsResult() throws {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.resolve"])
        ),
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.resolve",
        arguments: .object([
          "host": .string("::1"),
          "family": .string("ipv4"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("network.resolve")))
    #expect((payload.objectValue?["resolved"]) == (.bool(false)))
    #expect((payload.objectValue?["error_code"]?.numberValue) != nil)
    #expect(!(try #require(payload.objectValue?["error"]?.stringValue).isEmpty))
    #expect((payload.objectValue?["addresses"]) == (.array([])))
  }

  @Test
  func testNetworkResolveRejectsBadInputs() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.resolve"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.resolve",
          arguments: .object(["host": .string("https://example.com")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.resolve",
          arguments: .object([
            "host": .string("localhost"),
            "family": .string("link"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.resolve",
          arguments: .object([
            "host": .string("localhost"),
            "max_results": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testNetworkProxyUsesSCUtilWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      <dictionary> {
        HTTPEnable : 0
        HTTPSEnable : 0
      }
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.proxy"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.proxy",
        arguments: .object(["timeout_ms": .number(1234)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["scutil"]!))
    #expect((runner.calls.first?.arguments) == (["--proxy"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((payload.objectValue?["operation"]) == (.string("network.proxy")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkProxyRejectsBadTimeout() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.proxy"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.proxy",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }
  }

  @Test
  func testNetworkServicesUsesNetworkSetupWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      An asterisk (*) denotes that a network service is disabled.
      Wi-Fi
      Thunderbolt Bridge
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.services"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.services",
        arguments: .object([
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["networksetup"]!))
    #expect((runner.calls.first?.arguments) == (["-listallnetworkservices"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.services")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-listallnetworkservices")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkServicesRejectsBadBounds() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.services"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.services",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.services",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkHardwarePortsUsesNetworkSetupWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Hardware Port: Wi-Fi
      Device: en0
      Ethernet Address: aa:bb:cc:dd:ee:ff
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.hardware_ports"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.hardware_ports",
        arguments: .object([
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["networksetup"]!))
    #expect((runner.calls.first?.arguments) == (["-listallhardwareports"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.hardware_ports")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-listallhardwareports")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkHardwarePortsRejectsBadBounds() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.hardware_ports"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.hardware_ports",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.hardware_ports",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkWiFiDiscoversDeviceAndUsesFixedNetworkSetupArgv() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(
        stdout: """
          Hardware Port: Thunderbolt Bridge
          Device: bridge0
          Ethernet Address: aa:bb:cc:dd:ee:00

          Hardware Port: Wi-Fi
          Device: en0
          Ethernet Address: aa:bb:cc:dd:ee:ff
          """),
      RecordingCommandRunner.Output(stdout: "Wi-Fi Power (en0): On\n"),
      RecordingCommandRunner.Output(stdout: "Current Wi-Fi Network: StudioNet\n"),
    ]
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.wifi"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.wifi",
        arguments: .object([
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (3))
    #expect((runner.calls[0].executable) == (systemExecutables["networksetup"]!))
    #expect((runner.calls[0].arguments) == (["-listallhardwareports"]))
    #expect((runner.calls[1].arguments) == (["-getairportpower", "en0"]))
    #expect((runner.calls[2].arguments) == (["-getairportnetwork", "en0"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[1].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.wifi")))
    #expect((payload.objectValue?["available"]) == (.bool(true)))
    #expect((payload.objectValue?["device"]) == (.string("en0")))
    #expect((payload.objectValue?["hardware_port"]) == (.string("Wi-Fi")))
    #expect((payload.objectValue?["power"]) == (.string("on")))
    #expect((payload.objectValue?["associated"]) == (.bool(true)))
    #expect((payload.objectValue?["ssid"]) == (.string("StudioNet")))
    #expect(
      (payload.objectValue?["discovery_argv"]) == (.array([.string("-listallhardwareports")])))
    #expect((payload.objectValue?["discovery"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testNetworkWiFiReportsUnavailableWithoutRunningPowerQueries() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Hardware Port: Thunderbolt Bridge
      Device: bridge0
      Ethernet Address: aa:bb:cc:dd:ee:00
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.wifi"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.wifi", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (1))
    #expect((payload.objectValue?["operation"]) == (.string("network.wifi")))
    #expect((payload.objectValue?["available"]) == (.bool(false)))
    #expect((payload.objectValue?["device"]) == (.null))
    #expect((payload.objectValue?["associated"]) == (.bool(false)))
    #expect((payload.objectValue?["ssid"]) == (.null))
    #expect((payload.objectValue?["power_argv"]) == (.null))
    #expect((payload.objectValue?["network_argv"]) == (.null))
  }

  @Test
  func testNetworkWiFiRejectsBadInputs() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.wifi"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.wifi",
          arguments: .object(["device": .string("-bad")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("interface"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.wifi",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.wifi",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkVPNUsesScutilNCListAndParsesServices() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Available network connection services in the current set (*=enabled):
      * (Disconnected)   53F34FF6-F7ED-4085-8674-4EACFD48520A PPP --> LG Monitor Controls "LG Monitor Controls"            [PPP:Modem]
        (Connected)      11111111-2222-3333-4444-555555555555 IKEv2 --> Work VPN "Work VPN"            [VPN:IKEv2]
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.vpn"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.vpn",
        arguments: .object([
          "max_results": .number(1),
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let services = try #require(payload.objectValue?["services"]?.arrayValue)
    let first = try #require(services.first?.objectValue)

    #expect((runner.calls.count) == (1))
    #expect((runner.calls[0].executable) == (systemExecutables["scutil"]!))
    #expect((runner.calls[0].arguments) == (["--nc", "list"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[0].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.vpn")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("--nc"), .string("list")])))
    #expect((payload.objectValue?["service_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((first["enabled"]) == (.bool(true)))
    #expect((first["status"]) == (.string("Disconnected")))
    #expect((first["connected"]) == (.bool(false)))
    #expect((first["id"]) == (.string("53F34FF6-F7ED-4085-8674-4EACFD48520A")))
    #expect((first["name"]) == (.string("LG Monitor Controls")))
    #expect((first["protocol"]) == (.string("PPP")))
    #expect((first["type"]) == (.string("PPP:Modem")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testNetworkVPNRejectsBadBounds() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.vpn"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.vpn",
          arguments: .object(["max_results": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.vpn",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.vpn",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkLocationsUsesNetworkSetupWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = "Automatic\n"
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.locations"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.locations",
        arguments: .object([
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (2))
    #expect((runner.calls[0].executable) == (systemExecutables["networksetup"]!))
    #expect((runner.calls[0].arguments) == (["-getcurrentlocation"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[0].maxOutputBytes) == (4096))
    #expect((runner.calls[1].executable) == (systemExecutables["networksetup"]!))
    #expect((runner.calls[1].arguments) == (["-listlocations"]))
    #expect((runner.calls[1].timeoutMilliseconds) == (1234))
    #expect((runner.calls[1].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.locations")))
    #expect((payload.objectValue?["current_argv"]) == (.array([.string("-getcurrentlocation")])))
    #expect((payload.objectValue?["list_argv"]) == (.array([.string("-listlocations")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["current"]?.objectValue?["stdout"]) == (.string("Automatic\n")))
    #expect((payload.objectValue?["locations"]?.objectValue?["stdout"]) == (.string("Automatic\n")))
  }

  @Test
  func testNetworkLocationsRejectsBadBounds() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.locations"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.locations",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.locations",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkRoutesUsesNetstatWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Routing tables

      Internet:
      Destination        Gateway            Flags        Netif Expire
      default            192.168.1.1        UGSc           en0
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.routes"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.routes",
        arguments: .object([
          "family": .string("inet"),
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["netstat"]!))
    #expect((runner.calls.first?.arguments) == (["-rn", "-f", "inet"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.routes")))
    #expect((payload.objectValue?["family"]) == (.string("inet")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))

    _ = try provider.callTool(
      .init(name: "network.routes", arguments: .object([:]), context: .empty))
    #expect((runner.calls.last?.arguments) == (["-rn"]))
  }

  @Test
  func testNetworkRoutesRejectsBadInputs() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.routes"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.routes",
          arguments: .object(["family": .string("link")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.routes",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.routes",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkConnectionsUsesNetstatWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Active Internet connections (including servers)
      Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
      tcp4       0      0  127.0.0.1.51712       127.0.0.1.3000         ESTABLISHED
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.connections"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.connections",
        arguments: .object([
          "family": .string("inet"),
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["netstat"]!))
    #expect((runner.calls.first?.arguments) == (["-an", "-f", "inet"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.connections")))
    #expect((payload.objectValue?["family"]) == (.string("inet")))
    #expect(
      (payload.objectValue?["argv"]) == (.array([.string("-an"), .string("-f"), .string("inet")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))

    _ = try provider.callTool(
      .init(name: "network.connections", arguments: .object([:]), context: .empty))
    #expect((runner.calls.last?.arguments) == (["-an"]))
  }

  @Test
  func testNetworkConnectionsRejectsBadInputs() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.connections"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.connections",
          arguments: .object(["family": .string("link")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.connections",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.connections",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkARPUsesARPWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      ? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.arp"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.arp",
        arguments: .object([
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["arp"]!))
    #expect((runner.calls.first?.arguments) == (["-an"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.arp")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-an")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkARPRejectsBadBounds() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.arp"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.arp",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.arp",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkPingUsesPingWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      PING 127.0.0.1 (127.0.0.1): 56 data bytes
      64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.044 ms
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.ping"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.ping",
        arguments: .object([
          "host": .string("127.0.0.1"),
          "count": .number(2),
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["ping"]!))
    #expect((runner.calls.first?.arguments) == (["-c", "2", "127.0.0.1"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.ping")))
    #expect((payload.objectValue?["host"]) == (.string("127.0.0.1")))
    #expect((payload.objectValue?["count"]) == (.number(2)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("-c"), .string("2"), .string("127.0.0.1")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkPingRejectsBadInputs() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.ping"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.ping",
          arguments: .object(["host": .string("-c")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.ping",
          arguments: .object(["host": .string("https://example.com")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.ping",
          arguments: .object([
            "host": .string("localhost"),
            "count": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("count"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.ping",
          arguments: .object([
            "host": .string("localhost"),
            "max_output_bytes": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkTCPCheckUsesNCWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stderr = "Connection to 127.0.0.1 port 443 [tcp/https] succeeded!\n"
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.tcp_check"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("127.0.0.1"),
          "port": .number(443),
          "connect_timeout_seconds": .number(2),
          "timeout_ms": .number(3456),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["nc"]!))
    #expect((runner.calls.first?.arguments) == (["-G", "2", "-zv", "127.0.0.1", "443"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (3456))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.tcp_check")))
    #expect((payload.objectValue?["host"]) == (.string("127.0.0.1")))
    #expect((payload.objectValue?["port"]) == (.number(443)))
    #expect((payload.objectValue?["connect_timeout_seconds"]) == (.number(2)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("-G"), .string("2"), .string("-zv"), .string("127.0.0.1"), .string("443"),
        ])))
    #expect((payload.objectValue?["result"]?.objectValue?["stderr"]) == (.string(runner.stderr)))
  }

  @Test
  func testNetworkTCPCheckRejectsBadInputs() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.tcp_check"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.tcp_check",
          arguments: .object(["host": .string("localhost")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("port"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.tcp_check",
          arguments: .object([
            "host": .string("-example.com"),
            "port": .number(443),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.tcp_check",
          arguments: .object([
            "host": .string("https://example.com"),
            "port": .number(443),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.tcp_check",
          arguments: .object([
            "host": .string("localhost"),
            "port": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("port"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.tcp_check",
          arguments: .object([
            "host": .string("localhost"),
            "port": .number(443),
            "connect_timeout_seconds": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("connect_timeout_seconds"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.tcp_check",
          arguments: .object([
            "host": .string("localhost"),
            "port": .number(443),
            "max_output_bytes": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkHTTPCheckUsesCurlWithFixedArgvAndParsesMetadata() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      hello
      __COMPUTER_MCP_HTTP_CHECK_META__
      http_code=200
      url_effective=https://example.com/health
      content_type=text/plain
      redirect_url=
      time_total=0.125000
      size_download=5
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.http_check"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.http_check",
        arguments: .object([
          "url": .string("https://example.com/health"),
          "method": .string("GET"),
          "include_body": .bool(true),
          "follow_redirects": .bool(true),
          "max_redirects": .number(3),
          "connect_timeout_seconds": .number(2),
          "timeout_ms": .number(3456),
          "max_body_bytes": .number(128),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["curl"]!))
    #expect((runner.calls.first?.timeoutMilliseconds) == (3456))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "--disable", "--silent", "--show-error", "--max-time", "3", "--connect-timeout", "2",
          "--location", "--max-redirs", "3", "--request", "GET", "--range", "0-127",
          "--output", "-", "--write-out",
          "\n__COMPUTER_MCP_HTTP_CHECK_META__\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nredirect_url=%{redirect_url}\ntime_total=%{time_total}\nsize_download=%{size_download}\n",
          "--", "https://example.com/health",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("network.http_check")))
    #expect((payload.objectValue?["method"]) == (.string("GET")))
    #expect((payload.objectValue?["include_body"]) == (.bool(true)))
    #expect((payload.objectValue?["follow_redirects"]) == (.bool(true)))
    #expect((payload.objectValue?["http_code"]) == (.number(200)))
    #expect((payload.objectValue?["url_effective"]) == (.string("https://example.com/health")))
    #expect((payload.objectValue?["content_type"]) == (.string("text/plain")))
    #expect((payload.objectValue?["redirect_url"]) == (.null))
    #expect((payload.objectValue?["time_total_seconds"]) == (.number(0.125)))
    #expect((payload.objectValue?["size_download_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["body"]) == (.string("hello")))
    #expect((payload.objectValue?["body_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["meta_found"]) == (.bool(true)))
  }

  @Test
  func testNetworkHTTPCheckDefaultsToHeadAndRejectsBadInputs() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """

      __COMPUTER_MCP_HTTP_CHECK_META__
      http_code=404
      url_effective=http://127.0.0.1:8080/mcp
      content_type=
      redirect_url=
      time_total=0.010000
      size_download=0
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.http_check"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.http_check",
        arguments: .object(["url": .string("http://127.0.0.1:8080/mcp")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(runner.calls.first?.arguments.contains("--head") == true)
    #expect(runner.calls.first?.arguments.contains("/dev/null") == true)
    #expect((payload.objectValue?["method"]) == (.string("HEAD")))
    #expect((payload.objectValue?["include_body"]) == (.bool(false)))
    #expect((payload.objectValue?["http_code"]) == (.number(404)))
    #expect((payload.objectValue?["body"]) == (.null))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.http_check",
          arguments: .object(["url": .string("ftp://example.com")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("http or https"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.http_check",
          arguments: .object(["url": .string("https://user:pass@example.com")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("userinfo"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.http_check",
          arguments: .object([
            "url": .string("https://example.com"),
            "method": .string("POST"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("HEAD or GET"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.http_check",
          arguments: .object([
            "url": .string("https://example.com"),
            "max_body_bytes": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_body_bytes"))
    }
  }

  @Test
  func testNetworkListenersUsesLSOFWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
      node    12345 test   12u  IPv4 0x0000      0t0  TCP 127.0.0.1:3000 (LISTEN)
      """
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.listeners"])
        ),
        commandRunner: runner,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "network.listeners",
        arguments: .object([
          "timeout_ms": .number(1234),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == (systemExecutables["lsof"]!))
    #expect((runner.calls.first?.arguments) == (["-nP", "-iTCP", "-sTCP:LISTEN"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.listeners")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("-nP"), .string("-iTCP"), .string("-sTCP:LISTEN")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkListenersRejectsBadBounds() {
    let provider = NetworkToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["network.listeners"])
        ),
        builtinExecutables: systemExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.listeners",
          arguments: .object(["timeout_ms": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "network.listeners",
          arguments: .object(["max_output_bytes": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testEnvironmentDescribeReportsOnlyConfiguredEnvNamesAndRedactsValues() throws {
    let config = GatewayConfiguration.fixture(
      server: ServerConfig(
        http: HTTPServerConfig(
          publicBaseURL: "https://gateway.example.com",
          accessTokenEnv: "COMPUTER_MCP_TOKEN"
        )
      ),
      cli: CLISectionConfig(commands: [
        CLICommandConfig(
          id: "secret-cli",
          executable: "/bin/echo",
          env: ["SECRET_CLI_TOKEN": "super-secret-cli-value"]
        )
      ]),
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "secret-mcp",
          transport: .stdio,
          command: "/bin/cat",
          env: ["SECRET_MCP_TOKEN": "super-secret-mcp-value"]
        )
      ]),
      builtin: BuiltinConfig(enabled: ["env.describe"])
    )
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: config,
        builtinExecutables: systemExecutables))

    let result = try provider.callTool(
      .init(
        name: "env.describe", arguments: .object([:]), context: .empty))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))

    #expect(!(text.contains("super-secret-cli-value")))
    #expect(!(text.contains("super-secret-mcp-value")))
    #expect((payload.objectValue?["summary"]?.objectValue?["values_redacted"]) == (.bool(true)))
    #expect((payload.objectValue?["summary"]?.objectValue?["declared_key_count"]) == (.number(3)))
    let serverKeys = payload.objectValue?["server"]?.arrayValue?
      .compactMap { $0.objectValue?["key"] }
    #expect((serverKeys) == ([.string("COMPUTER_MCP_TOKEN")]))
    #expect(
      (payload.objectValue?["cli"]?.arrayValue?.first?.objectValue?["env"]?.arrayValue?.first?
        .objectValue?["key"]) == (.string("SECRET_CLI_TOKEN")))
    #expect(
      (payload.objectValue?["mcp"]?.arrayValue?.first?.objectValue?["env"]?.arrayValue?.first?
        .objectValue?["value_origin"]) == (.string("configured_provider_env")))
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
  private var directories: [ScopedTemporaryDirectory] = []

  private func temporaryDirectory() throws -> URL {
    let directory = try ScopedTemporaryDirectory()
    directories.append(directory)
    return directory.url
  }
}

private let systemExecutables = Dictionary(
  uniqueKeysWithValues: [
    "sw_vers",
    "pmset",
    "ps",
    "log",
    "launchctl",
    "ifconfig",
    "scutil",
    "networksetup",
    "netstat",
    "arp",
    "ping",
    "nc",
    "curl",
    "lsof",
  ].map { ($0, "/fixture/bin/\($0)") })
