import Foundation

/// Positive ceilings supplied by managed policy. Nil leaves that dimension at
/// the host default (or unbounded for memory and background duration).
package struct ExecutionLimitCeilings: Equatable, Sendable, Codable {
  package let timeMilliseconds: Int64?
  package let outputBytes: Int64?
  package let memoryBytes: Int64?
  package let retentionSeconds: Int64?
  package let retainedOutputBytes: Int64?

  package init(
    timeMilliseconds: Int64? = nil, outputBytes: Int64? = nil, memoryBytes: Int64? = nil,
    retentionSeconds: Int64? = nil, retainedOutputBytes: Int64? = nil
  ) throws {
    guard
      [timeMilliseconds, outputBytes, memoryBytes, retentionSeconds, retainedOutputBytes]
        .compactMap({ $0 }).allSatisfy({ $0 > 0 })
    else { throw PermissionModelError.invalidExecutionLimits }
    self.timeMilliseconds = timeMilliseconds
    self.outputBytes = outputBytes
    self.memoryBytes = memoryBytes
    self.retentionSeconds = retentionSeconds
    self.retainedOutputBytes = retainedOutputBytes
  }

  package static let none = try! Self()

  private enum CodingKeys: String, CodingKey {
    case timeMilliseconds, outputBytes, memoryBytes, retentionSeconds, retainedOutputBytes
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      timeMilliseconds: values.decodeIfPresent(Int64.self, forKey: .timeMilliseconds),
      outputBytes: values.decodeIfPresent(Int64.self, forKey: .outputBytes),
      memoryBytes: values.decodeIfPresent(Int64.self, forKey: .memoryBytes),
      retentionSeconds: values.decodeIfPresent(Int64.self, forKey: .retentionSeconds),
      retainedOutputBytes: values.decodeIfPresent(Int64.self, forKey: .retainedOutputBytes))
  }
}

package struct ExecutionLimitRequest: Hashable, Sendable, Codable {
  package let background: Bool
  package let timeMilliseconds: Int64?

  package init(background: Bool = false, timeMilliseconds: Int64? = nil) throws {
    guard timeMilliseconds.map({ $0 > 0 && (background || $0 <= 600_000) }) ?? true else {
      throw PermissionModelError.invalidExecutionLimits
    }
    self.background = background
    self.timeMilliseconds = timeMilliseconds
  }

  private enum CodingKeys: String, CodingKey { case background, timeMilliseconds }
  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      background: values.decode(Bool.self, forKey: .background),
      timeMilliseconds: values.decodeIfPresent(Int64.self, forKey: .timeMilliseconds))
  }

  package static let foreground = try! Self()
  package static let background = try! Self(background: true)
}

/// Backend guarantees are reported by the host launcher, never by a tool argument.
package struct ExecutionLimitCapabilities: Equatable, Sendable, Codable {
  package let memory: Bool
  package let liveMemory: Bool

  package init(memory: Bool = false, liveMemory: Bool = false) {
    self.memory = memory
    self.liveMemory = memory && liveMemory
  }
}

package struct EffectiveExecutionLimits: Equatable, Sendable, Codable {
  package let timeMilliseconds: Int64?
  package let outputBytes: Int64
  package let memoryBytes: Int64?
  package let retentionSeconds: Int64
  package let retainedOutputBytes: Int64
  /// Every present policy's ceilings remain available for owner diagnostics.
  package let sources: [PolicySource: ExecutionLimitCeilings]

  package func requireEnforceable(by capabilities: ExecutionLimitCapabilities) throws {
    if memoryBytes != nil && !capabilities.memory {
      throw PermissionModelError.unenforceableMemoryLimit
    }
  }

  package static func resolve(_ request: ExecutionLimitRequest, limits: [ManagedLimits]) throws
    -> Self
  {
    if !limits.allSatisfy({ $0.unreadableSources.isEmpty }) {
      throw PermissionModelError.invalidExecutionLimits
    }
    var sources: [PolicySource: ExecutionLimitCeilings] = [:]
    let policies = limits.flatMap {
      $0.sources.compactMap { source, availability -> ExecutionLimitCeilings? in
        guard case .available(let policy) = availability else { return nil }
        if let existing = sources[source] {
          sources[source] = try! ExecutionLimitCeilings(
            timeMilliseconds: minimum(
              existing.timeMilliseconds, policy.executionLimits.timeMilliseconds),
            outputBytes: minimum(existing.outputBytes, policy.executionLimits.outputBytes),
            memoryBytes: minimum(existing.memoryBytes, policy.executionLimits.memoryBytes),
            retentionSeconds: minimum(
              existing.retentionSeconds, policy.executionLimits.retentionSeconds),
            retainedOutputBytes: minimum(
              existing.retainedOutputBytes, policy.executionLimits.retainedOutputBytes))
        } else {
          sources[source] = policy.executionLimits
        }
        return policy.executionLimits
      }
    }
    let time = request.timeMilliseconds ?? (request.background ? nil : 120_000)
    return Self(
      timeMilliseconds: policies.reduce(time) { minimum($0, $1.timeMilliseconds) },
      outputBytes: policies.compactMap(\.outputBytes).reduce(8 * 1024 * 1024, min),
      memoryBytes: policies.compactMap(\.memoryBytes).min(),
      retentionSeconds: policies.compactMap(\.retentionSeconds).reduce(86_400, min),
      retainedOutputBytes: policies.compactMap(\.retainedOutputBytes).reduce(
        1024 * 1024 * 1024, min),
      sources: sources)
  }

  /// An existing execution keeps the ceilings already applied by its backend.
  /// Reconciliation can tighten them; relaxing policy applies to later executions.
  package func tightening(_ previous: Self) -> Self {
    var sources = previous.sources
    for (source, current) in self.sources {
      let old = sources[source] ?? .none
      sources[source] = try! ExecutionLimitCeilings(
        timeMilliseconds: Self.minimum(old.timeMilliseconds, current.timeMilliseconds),
        outputBytes: Self.minimum(old.outputBytes, current.outputBytes),
        memoryBytes: Self.minimum(old.memoryBytes, current.memoryBytes),
        retentionSeconds: Self.minimum(old.retentionSeconds, current.retentionSeconds),
        retainedOutputBytes: Self.minimum(old.retainedOutputBytes, current.retainedOutputBytes))
    }
    return Self(
      timeMilliseconds: Self.minimum(timeMilliseconds, previous.timeMilliseconds),
      outputBytes: min(outputBytes, previous.outputBytes),
      memoryBytes: Self.minimum(memoryBytes, previous.memoryBytes),
      retentionSeconds: min(retentionSeconds, previous.retentionSeconds),
      retainedOutputBytes: min(retainedOutputBytes, previous.retainedOutputBytes), sources: sources)
  }

  private static func minimum(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): min(lhs, rhs)
    case (.some(let value), nil), (nil, .some(let value)): value
    case (nil, nil): nil
    }
  }
}

package enum ExecutionLimitEndReason: String, Codable, Sendable {
  case timeLimit, memoryLimitUnavailable
}
