import ComputerMCPCore
import ComputerMCPPlatform
import Darwin
import Foundation

package struct DarwinSystemProbe: SystemProbe {
  package init() {}

  package func memoryStatistics() throws -> SystemMemoryStatistics {
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

    return SystemMemoryStatistics(
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, pageSizeBytes: pageSize,
      pageCounts: [
        "free": freePages,
        "active": activePages,
        "inactive": inactivePages,
        "wired": wiredPages,
        "speculative": speculativePages,
        "compressed": compressedPages,
        "purgeable": purgeablePages,
        "internal": internalPages,
        "external": externalPages,
      ],
      eventCounts: [
        "pageins": stats.pageins,
        "pageouts": stats.pageouts,
        "faults": stats.faults,
        "copy_on_write_faults": stats.cow_faults,
        "compressions": stats.compressions,
        "decompressions": stats.decompressions,
        "swapins": stats.swapins,
        "swapouts": stats.swapouts,
      ])
  }

  package func cpuHardware() -> SystemCPUHardware {
    SystemCPUHardware(
      modelIdentifier: sysctlString("hw.model"),
      brandString: sysctlString("machdep.cpu.brand_string"),
      physicalCPUCount: sysctlInteger("hw.physicalcpu"),
      logicalCPUCount: sysctlInteger("hw.logicalcpu"),
      physicalCPUMax: sysctlInteger("hw.physicalcpu_max"),
      logicalCPUMax: sysctlInteger("hw.logicalcpu_max"),
      frequencyHz: sysctlInteger("hw.cpufrequency"),
      minimumFrequencyHz: sysctlInteger("hw.cpufrequency_min"),
      maximumFrequencyHz: sysctlInteger("hw.cpufrequency_max"),
      arm64Supported: sysctlInteger("hw.optional.arm64").map { $0 != 0 })
  }

  package func thermalCondition() -> SystemThermalCondition {
    let state: SystemThermalCondition.State
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: state = .nominal
    case .fair: state = .fair
    case .serious: state = .serious
    case .critical: state = .critical
    @unknown default: state = .unknown
    }
    return SystemThermalCondition(
      state: state, lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
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

  private func stringFromNullTerminatedCString(_ buffer: [CChar]) -> String {
    let endIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
    let bytes = buffer[..<endIndex].map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

}
