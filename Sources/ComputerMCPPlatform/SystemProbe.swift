/// Native system readings unavailable through the portable Foundation and POSIX APIs.
package protocol SystemProbe: Sendable {
  func memoryStatistics() throws -> SystemMemoryStatistics
  func cpuHardware() -> SystemCPUHardware
  func thermalCondition() -> SystemThermalCondition
  /// Visits a PID-ordered snapshot until `visit` returns false. Returns true on timeout.
  /// Processes that exit during inspection may be omitted; unreadable fields are nil.
  func processes(
    deadline: ContinuousClock.Instant, visit: (SystemProcess) throws -> Bool
  ) throws -> Bool
}

package struct SystemProcess: Sendable {
  package let pid: Int32
  package let parentPID: Int32
  package let user: String
  package let state: String
  /// Lifetime CPU time divided by elapsed wall time, as a percentage of one CPU.
  package let cpuPercent: Double?
  /// Resident bytes as a percentage of physical memory.
  package let memoryPercent: Double?
  package let elapsedSeconds: Double?
  package let executable: String
  /// Nil when the kernel does not permit reading argv. Never includes environment entries.
  package let arguments: [String]?

  package init(
    pid: Int32, parentPID: Int32, user: String, state: String, cpuPercent: Double?,
    memoryPercent: Double?, elapsedSeconds: Double?, executable: String, arguments: [String]?
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.user = user
    self.state = state
    self.cpuPercent = cpuPercent
    self.memoryPercent = memoryPercent
    self.elapsedSeconds = elapsedSeconds
    self.executable = executable
    self.arguments = arguments
  }
}

package struct SystemMemoryStatistics: Sendable {
  package let physicalMemoryBytes: UInt64
  package let pageSizeBytes: UInt64
  package let pageCounts: [String: UInt64]
  package let eventCounts: [String: UInt64]

  package init(
    physicalMemoryBytes: UInt64, pageSizeBytes: UInt64,
    pageCounts: [String: UInt64], eventCounts: [String: UInt64]
  ) {
    self.physicalMemoryBytes = physicalMemoryBytes
    self.pageSizeBytes = pageSizeBytes
    self.pageCounts = pageCounts
    self.eventCounts = eventCounts
  }
}

package struct SystemCPUHardware: Sendable {
  package let modelIdentifier: String?
  package let brandString: String?
  package let physicalCPUCount: Int64?
  package let logicalCPUCount: Int64?
  package let physicalCPUMax: Int64?
  package let logicalCPUMax: Int64?
  package let frequencyHz: Int64?
  package let minimumFrequencyHz: Int64?
  package let maximumFrequencyHz: Int64?
  package let arm64Supported: Bool?

  package init(
    modelIdentifier: String?, brandString: String?, physicalCPUCount: Int64?,
    logicalCPUCount: Int64?, physicalCPUMax: Int64?, logicalCPUMax: Int64?,
    frequencyHz: Int64?, minimumFrequencyHz: Int64?, maximumFrequencyHz: Int64?,
    arm64Supported: Bool?
  ) {
    self.modelIdentifier = modelIdentifier
    self.brandString = brandString
    self.physicalCPUCount = physicalCPUCount
    self.logicalCPUCount = logicalCPUCount
    self.physicalCPUMax = physicalCPUMax
    self.logicalCPUMax = logicalCPUMax
    self.frequencyHz = frequencyHz
    self.minimumFrequencyHz = minimumFrequencyHz
    self.maximumFrequencyHz = maximumFrequencyHz
    self.arm64Supported = arm64Supported
  }
}

package struct SystemThermalCondition: Sendable {
  package enum State: String, Sendable {
    case nominal, fair, serious, critical, unknown

    package var rank: Int {
      switch self {
      case .nominal: 0
      case .fair: 1
      case .serious: 2
      case .critical: 3
      case .unknown: -1
      }
    }
  }

  package let state: State
  package let lowPowerModeEnabled: Bool

  package init(state: State, lowPowerModeEnabled: Bool) {
    self.state = state
    self.lowPowerModeEnabled = lowPowerModeEnabled
  }
}
