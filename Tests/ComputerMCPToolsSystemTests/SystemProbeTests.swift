import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsSystem

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct SystemProbeTests {
  @Test
  func nativeReadingsUseTheInjectedProbe() throws {
    let provider = SystemToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: .init(enabled: ["system.memory", "system.cpu", "system.thermal"])),
        systemProbe: Probe()))
    func payload(_ name: String) throws -> [String: JSONValue] {
      let result = try provider.callTool(.init(name: name, arguments: nil, context: .empty))
      return try #require(
        result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
    }
    let memory = try payload("system.memory")
    #expect(memory["physical_memory_bytes"] == .integer(9_007_199_254_740_993))
    #expect(memory["pages"]?.objectValue?["free"] == .integer(2))
    #expect(memory["bytes"]?.objectValue?["free"] == .integer(8192))
    #expect(memory["events"]?.objectValue?["faults"] == .integer(7))
    let hardware = try #require(payload("system.cpu")["hardware"]?.objectValue)
    #expect(hardware["model_identifier"] == .string("fixture"))
    #expect(hardware["physical_cpu_count"] == .integer(4))
    #expect(hardware["brand_string"] == .null)
    #expect(hardware["arm64_supported"] == .bool(true))
    let thermal = try payload("system.thermal")
    #expect(thermal["thermal_state"] == .string("serious"))
    #expect(thermal["thermal_state_rank"] == .integer(2))
    #expect(thermal["low_power_mode_enabled"] == .bool(true))
  }

  @Test
  func providersKeepTheirOwnDefinitionsAndDispatch() throws {
    let environment = ToolEnvironment(
      launcher: testExecutionLauncher(),
      configuration: GatewayConfiguration(builtin: .init(enabled: ["system.time", "network.dns"])))
    let system = SystemToolProvider(environment: environment)
    let network = NetworkToolProvider(environment: environment)
    #expect(try system.definitions().map(\.tool.name) == ["system.time"])
    #expect(try network.definitions().map(\.tool.name) == ["network.dns"])
    #expect(try system.definitions().first?.tool.annotations?.openWorldHint == false)
    #expect(try network.definitions().first?.tool.annotations?.openWorldHint == true)
    #expect(throws: GatewayToolError.unknownTool("network.dns")) {
      try system.callTool(.init(name: "network.dns", arguments: nil, context: .empty))
    }
    #expect(throws: GatewayToolError.unknownTool("system.time")) {
      try network.callTool(.init(name: "system.time", arguments: nil, context: .empty))
    }
    #expect(throws: GatewayToolError.disabled("system.memory is disabled by configuration.")) {
      try system.callTool(.init(name: "system.memory", arguments: nil, context: .empty))
    }
  }
}

private struct Probe: SystemProbe {
  func processes(
    deadline: ContinuousClock.Instant, visit: (SystemProcess) throws -> Bool
  ) throws -> Bool {
    Issue.record("Unexpected process query")
    return false
  }

  func memoryStatistics() throws -> SystemMemoryStatistics {
    .init(
      physicalMemoryBytes: 9_007_199_254_740_993, pageSizeBytes: 4096,
      pageCounts: ["free": 2], eventCounts: ["faults": 7])
  }

  func cpuHardware() -> SystemCPUHardware {
    .init(
      modelIdentifier: "fixture", brandString: nil, physicalCPUCount: 4, logicalCPUCount: 8,
      physicalCPUMax: nil, logicalCPUMax: nil, frequencyHz: nil, minimumFrequencyHz: nil,
      maximumFrequencyHz: nil, arm64Supported: true)
  }

  func thermalCondition() -> SystemThermalCondition {
    .init(state: .serious, lowPowerModeEnabled: true)
  }
}
