import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsSystem

@Suite(.nativeIntegration, .serialized)
final class SystemToolProviderDarwinTests {
  @Test
  func testSystemMemoryReturnsReadOnlyVMStats() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.memory"])
        ),
        systemProbe: DarwinSystemProbe()))

    let result = try provider.callTool(
      .init(
        name: "system.memory", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.memory")))
    #expect((payload.objectValue?["source"]) == (.string("host_statistics64")))
    #expect((try #require(payload.objectValue?["physical_memory_bytes"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["page_size_bytes"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["pages"]?.objectValue?["free"]?.numberValue)) >= (0))
    #expect(
      (try #require(payload.objectValue?["bytes"]?.objectValue?["wired"]?.numberValue)) >= (0))
    #expect(
      (try #require(payload.objectValue?["events"]?.objectValue?["faults"]?.numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemCPUReturnsReadOnlyProcessorSummary() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.cpu"])
        ),
        systemProbe: DarwinSystemProbe()))

    let result = try provider.callTool(
      .init(name: "system.cpu", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)
    let processInfo = try #require(payload.objectValue?["process_info"]?.objectValue)
    let hardware = try #require(payload.objectValue?["hardware"]?.objectValue)
    let machine = try #require(hardware["machine"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.cpu")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([.string("ProcessInfo"), .string("sysctlbyname"), .string("uname")])))
    #expect((try #require(processInfo["processor_count"]?.numberValue)) > (0))
    #expect((try #require(processInfo["active_processor_count"]?.numberValue)) > (0))
    #expect(!(machine.isEmpty))
    #expect((hardware["model_identifier"]) != nil)
    #expect((hardware["brand_string"]) != nil)
    #expect((hardware["physical_cpu_count"]) != nil)
    #expect((hardware["logical_cpu_count"]) != nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemThermalReturnsReadOnlyConditionSummary() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["system.thermal"])
        ),
        systemProbe: DarwinSystemProbe()))

    let result = try provider.callTool(
      .init(
        name: "system.thermal", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)
    let thermalState = try #require(payload.objectValue?["thermal_state"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.thermal")))
    #expect((payload.objectValue?["source"]) == (.string("ProcessInfo")))
    #expect(["nominal", "fair", "serious", "critical", "unknown"].contains(thermalState))
    #expect((payload.objectValue?["thermal_state_rank"]?.numberValue) != nil)
    #expect((payload.objectValue?["low_power_mode_enabled"]?.boolValue) != nil)
    #expect((try #require(payload.objectValue?["processor_count"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["active_processor_count"]?.numberValue)) > (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}
