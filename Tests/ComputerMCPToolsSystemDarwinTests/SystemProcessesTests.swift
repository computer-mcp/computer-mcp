import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatformDarwin
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Darwin
import Foundation
import Testing

@testable import ComputerMCPToolsSystem

struct SystemProcessesTests {
  @Test
  func snapshotIncludesOwnArgumentsAndOtherUserExecutable() async throws {
    let snapshot = try await snapshot()
    let processes = try #require(snapshot["processes"]?.arrayValue)
    let own = try #require(
      processes.first { $0.objectValue?["pid"] == .integer(Int64(getpid())) }?.objectValue)
    #expect(own["parsed"] == .bool(true))
    #expect(own["parent_pid"] == .integer(Int64(getppid())))
    #expect(own["user"] == .string(NSUserName()))
    #expect(own["command"] == .string(ProcessInfo.processInfo.arguments.joined(separator: " ")))
    #expect(try #require(own["cpu_percent"]?.numberValue) >= 0)
    #expect(try #require(own["memory_percent"]?.numberValue) > 0)
    #expect(own["elapsed"]?.stringValue != nil)
    #expect(own["state"]?.stringValue?.isEmpty == false)

    let launchd = try #require(
      processes.first { $0.objectValue?["pid"] == .integer(1) }?.objectValue)
    #expect(geteuid() != 0)
    #expect(launchd["user"] == .string("root"))
    let command = try #require(launchd["command"]?.stringValue)
    #expect(command.contains("launchd"))
    #expect(command.hasSuffix(" [arguments unavailable]"))
    #expect(launchd["cpu_percent"] == .null)
    #expect(launchd["memory_percent"] == .null)
    #expect(snapshot["argv"] == .array([]))
    let result = try #require(snapshot["result"]?.objectValue)
    #expect(result["executable"] == .null)
    #expect(result["exit_code"] == .null)
    #expect(result["arguments"] == .array([]))
    #expect(result["timed_out"] == .bool(false))
    #expect(snapshot["truncated"] == .bool(false))
  }

  @Test
  func filteringMatchesCommandsArgumentsUsersAndState() async throws {
    let ownPID = JSONValue.integer(Int64(getpid()))
    let query = try #require(ProcessInfo.processInfo.arguments.last).uppercased()
    let filtered = try await snapshot(["query": .string(query)])
    #expect(filtered["query"] == .string(query))
    let processes = try #require(filtered["processes"]?.arrayValue)
    #expect(processes.contains { $0.objectValue?["pid"] == ownPID })
    #expect(
      processes.allSatisfy {
        $0.objectValue?["command"]?.stringValue?.uppercased().contains(query) == true
      })
    let user = try await snapshot(["query": .string(NSUserName().uppercased())])
    #expect(user["processes"]?.arrayValue?.contains { $0.objectValue?["pid"] == ownPID } == true)
    let state = try await snapshot(["query": .string("s")])
    #expect(
      state["processes"]?.arrayValue?.contains { $0.objectValue?["pid"] == .integer(1) } == true)
    let missing = try await snapshot(["query": .string(UUID().uuidString)])
    #expect(missing["process_count"] == .integer(0))
    #expect(missing["processes"] == .array([]))
    #expect(missing["truncated"] == .bool(false))
  }

  @Test
  func resultAndByteLimitsReturnBoundedSnapshots() async throws {
    let limited = try await snapshot(["max_results": .integer(1)])
    #expect(limited["process_count"] == .integer(1))
    #expect(limited["processes"]?.arrayValue?.count == 1)
    #expect(limited["processes"]?.arrayValue?.first?.objectValue?["pid"] == .integer(1))
    #expect(limited["truncated"] == .bool(true))
    #expect(limited["result"]?.objectValue?["stdout_truncated"] == .bool(false))
    let bytes = try await snapshot(["max_output_bytes": .integer(1)])
    #expect(bytes["process_count"] == .integer(0))
    #expect(bytes["processes"] == .array([]))
    #expect(bytes["truncated"] == .bool(true))
    #expect(bytes["result"]?.objectValue?["stdout_truncated"] == .bool(true))
  }

  @Test(arguments: 0..<8)
  func emptyArgumentDoesNotExposeEnvironment(pathPadding: Int) async throws {
    let directory = try ScopedTemporaryDirectory()
    let executable = directory.url.appendingPathComponent(
      "sleep" + String(repeating: "x", count: pathPadding))
    try FileManager.default.createSymbolicLink(
      atPath: executable.path, withDestinationPath: "/bin/sleep")
    let argv = ["", "60"].map { $0.withCString { strdup($0) } } + [nil]
    let env =
      ["COMPUTER_MCP_ARGUMENTS_SENTINEL=not-an-argument"].map {
        $0.withCString { strdup($0) }
      } + [nil]
    defer { for pointer in argv + env { free(pointer) } }
    var pid: pid_t = 0
    let status = argv.withUnsafeBufferPointer { arguments in
      env.withUnsafeBufferPointer { environment in
        posix_spawn(
          &pid, executable.path, nil, nil, arguments.baseAddress!, environment.baseAddress!)
      }
    }
    try #require(status == 0)
    defer {
      kill(pid, SIGKILL)
      while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
    }
    let result = try await snapshot()
    let child = try #require(
      result["processes"]?.arrayValue?.first {
        $0.objectValue?["pid"] == .integer(Int64(pid))
      }?.objectValue)
    #expect(child["command"] == .string(" 60"))
  }

  private func snapshot(_ arguments: [String: JSONValue] = [:]) async throws -> [String: JSONValue]
  {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: .init(enabled: ["system.processes"])),
        systemProbe: DarwinSystemProbe()))
    var bounded: [String: JSONValue] = [
      "max_results": .integer(10_000), "max_output_bytes": .integer(20_971_520),
    ]
    bounded.merge(arguments) { _, new in new }
    let response = try await provider.callToolAsync(
      .init(name: "system.processes", arguments: .object(bounded), context: .empty))
    let result = try #require(
      response.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
    #expect(result["operation"] == .string("system.processes"))
    #expect(
      result["process_count"]?.int64Value == Int64(result["processes"]?.arrayValue?.count ?? -1))
    return result
  }
}
