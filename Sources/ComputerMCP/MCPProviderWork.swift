import Foundation
import MCP

extension MCPTool {
  /// A downstream resource URI is meaningful only on that provider's connection.
  var exportedMetadata: JSONValue? {
    guard mcpReference != nil, var fields = meta?.objectValue else { return meta }
    fields.removeValue(forKey: MCPProviderWork.metadataKey)
    fields.removeValue(forKey: MCPProviderContinuation.metadataKey)
    return fields.isEmpty ? nil : .object(fields)
  }
}

/// An ordinary MCP resource reports live ownership; it never supplies host authority.
struct MCPProviderWork {
  static let metadataKey = "io.github.computer-mcp/work"
  static let invocationKey = "io.github.computer-mcp/work-invocation"
  static let resourceURI = "computer-mcp://runtime/work/v1"
  static let maximumResources = 1_024
  static let maximumBytes = 512 * 1_024

  enum Identifier: Hashable, Sendable {
    case string(String)
    case integer(Int64)

    init?(_ value: JSONValue) {
      switch value {
      case .string(let value) where MCPProviderContinuation.validName(value): self = .string(value)
      case .integer(let value): self = .integer(value)
      default: return nil
      }
    }

    var json: JSONValue {
      switch self {
      case .string(let value): .string(value)
      case .integer(let value): .integer(value)
      }
    }
  }

  struct Key: Hashable, Sendable {
    let kind: String
    let id: Identifier
  }

  struct Resource: Equatable, Sendable {
    let key: Key
    let acquiredBy: UUID
    let uncertain: Bool
    var handles: [String: Identifier] = [:]

    func matches(_ query: MCPProviderContinuation.Query) -> Bool {
      key.kind == query.kind && !query.handles.isEmpty
        && query.handles.allSatisfy { name, value in
          (name == "id" ? key.id : handles[name]) == value
        }
    }
  }

  struct Report: Equatable, Sendable {
    let instanceID: UUID
    let revision: Int64
    let resources: [Key: Resource]

    init(contents: [MCP.Resource.Content]) throws {
      guard contents.count == 1, let content = contents.first,
        content.uri == MCPProviderWork.resourceURI,
        content.mimeType == "application/json", content.blob == nil,
        let text = content.text, text.utf8.count <= MCPProviderWork.maximumBytes
      else { throw MCPProviderWork.invalidReport() }
      let value: JSONValue
      do { value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) } catch {
        throw MCPProviderWork.invalidReport()
      }
      guard let object = value.objectValue,
        Set(object.keys) == ["format_version", "instance_id", "revision", "resources"],
        object["format_version"]?.int64Value == 1,
        let instanceID = object["instance_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
        let revision = object["revision"]?.int64Value, revision >= 0,
        let resources = object["resources"]?.arrayValue,
        resources.count <= MCPProviderWork.maximumResources
      else { throw MCPProviderWork.invalidReport() }
      var decoded: [Key: Resource] = [:]
      for value in resources {
        guard let item = value.objectValue,
          Set(item.keys).isSubset(of: ["kind", "id", "acquired_by", "state", "handles"]),
          Set(item.keys).isSuperset(of: ["kind", "id", "acquired_by", "state"]),
          let kind = item["kind"]?.stringValue, Self.validIdentifier(kind),
          let acquiredBy = item["acquired_by"]?.stringValue.flatMap(UUID.init(uuidString:)),
          let state = item["state"]?.stringValue, ["active", "uncertain"].contains(state)
        else { throw MCPProviderWork.invalidReport() }
        let id: Identifier
        switch item["id"] {
        case .string(let value) where Self.validIdentifier(value): id = .string(value)
        case .integer(let value): id = .integer(value)
        default: throw MCPProviderWork.invalidReport()
        }
        let key = Key(kind: kind, id: id)
        guard decoded[key] == nil else { throw MCPProviderWork.invalidReport() }
        var handles: [String: Identifier] = [:]
        if let value = item["handles"] {
          guard let entries = value.objectValue,
            (1...MCPProviderContinuation.maximumHandles).contains(entries.count),
            entries.keys.allSatisfy({ $0 != "id" && Self.validIdentifier($0) })
          else { throw MCPProviderWork.invalidReport() }
          for (name, value) in entries {
            guard let identifier = Identifier(value) else { throw MCPProviderWork.invalidReport() }
            handles[name] = identifier
          }
        }
        decoded[key] = Resource(
          key: key, acquiredBy: acquiredBy, uncertain: state == "uncertain", handles: handles)
      }
      self.instanceID = instanceID
      self.revision = revision
      self.resources = decoded
    }

    private static func validIdentifier(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.count <= 1_024
        && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
  }

  private struct Invocation {
    let tool: String
    let hostContext: MCPHostToolDirectory.InvocationLease?
    var confirmed = false
    var uncertain = false
  }

  private struct Ownership {
    let resource: Resource
    let tool: String
    let lease: GatewayOwnedWork.Lease
    let hostContext: MCPHostToolDirectory.InvocationLease?
  }

  private let work: GatewayOwnedWork
  private let workspaceID: String?
  private let registrationID: String
  let connectionID: UUID
  private var invocations: [UUID: Invocation] = [:]
  private var ownership: [Key: Ownership] = [:]
  private var observation: GatewayOwnedWork.Lease?
  private var report: Report?
  private var continuations: [String: MCPProviderContinuation] = [:]
  private var connected = true

  init(
    work: GatewayOwnedWork, workspaceID: String?, registrationID: String,
    connectionID: UUID = UUID()
  ) {
    self.work = work
    self.workspaceID = workspaceID
    self.registrationID = registrationID
    self.connectionID = connectionID
    requireObservation()
  }

  static func advertised(by tools: [MCPTool]) throws -> Bool {
    var advertised = false
    for tool in tools {
      _ = try MCPProviderContinuation(tool)
      guard let value = tool.meta?.objectValue?[metadataKey] else { continue }
      guard let fields = value.objectValue, Set(fields.keys) == ["format_version", "uri"],
        fields["format_version"]?.int64Value == 1, fields["uri"] == .string(resourceURI)
      else {
        throw GatewayToolError.executionFailed(
          "[mcp.invalid_work_metadata] Unsupported provider work resource declaration.")
      }
      advertised = true
    }
    return advertised
  }

  var needsObservation: Bool {
    observation != nil || !ownership.isEmpty || !invocations.isEmpty
  }

  /// Only invocations completed before the read began may be discharged by that read.
  var completedInvocations: Set<UUID> {
    Set(invocations.compactMap { $0.value.confirmed ? $0.key : nil })
  }

  var status: JSONValue {
    .object([
      "format_version": .integer(1),
      "instance_id": report.map { .string($0.instanceID.uuidString) } ?? .null,
      "revision": report.map { .integer($0.revision) } ?? .null,
      "resource_count": .integer(Int64(ownership.count)),
      "unsettled_invocation_count": .integer(Int64(invocations.count)),
      "observation_pending": .bool(observation != nil),
    ])
  }

  mutating func beginInvocation(
    tool: String, hostContext: MCPHostToolDirectory.InvocationLease? = nil
  ) throws -> UUID {
    guard invocations.count < Self.maximumResources else {
      throw GatewayToolError.executionFailed(
        "[mcp.work_capacity] Provider work observation must settle before admitting more calls.")
    }
    let id = UUID()
    invocations[id] = Invocation(tool: tool, hostContext: hostContext)
    requireObservation()
    return id
  }

  mutating func finishInvocation(_ id: UUID, confirmed: Bool) {
    guard invocations[id] != nil else { return }
    requireObservation()
    if confirmed {
      invocations[id]?.confirmed = true
      invocations[id]?.uncertain = false
    } else {
      invocations[id]?.uncertain = true
      observationLost()
    }
  }

  mutating func observationLost() {
    requireObservation()
    observation?.markUncertain()
    for item in ownership.values { item.lease.markUncertain() }
  }

  mutating func disconnected() {
    connected = false
    if needsObservation { observationLost() }
    publishContinuations()
  }

  mutating func accept(_ next: Report, covering completed: Set<UUID>) throws {
    if let report {
      guard next.instanceID == report.instanceID, next.revision >= report.revision,
        next.revision != report.revision || next == report
      else { throw Self.invalidReport() }
    }
    var bindings = invocations.mapValues(\.tool)
    var contexts = invocations.compactMapValues(\.hostContext)
    for item in ownership.values {
      bindings[item.resource.acquiredBy] = item.tool
      if let context = item.hostContext { contexts[item.resource.acquiredBy] = context }
    }
    // Validate the entire snapshot before releasing any owner or creating partial state.
    for resource in next.resources.values {
      if let existing = ownership[resource.key] {
        guard existing.resource.acquiredBy == resource.acquiredBy,
          existing.resource.handles.allSatisfy({ resource.handles[$0.key] == $0.value })
        else {
          throw Self.invalidReport()
        }
      }
      guard bindings[resource.acquiredBy] != nil else { throw Self.invalidReport() }
    }
    var replacement: [Key: Ownership] = [:]
    for resource in next.resources.values {
      if let existing = ownership[resource.key] {
        replacement[resource.key] = Ownership(
          resource: resource, tool: existing.tool, lease: existing.lease,
          hostContext: existing.hostContext)
      } else if let tool = bindings[resource.acquiredBy] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity = JSONValue.object([
          "connection_id": .string(connectionID.uuidString),
          "instance_id": .string(next.instanceID.uuidString),
          "kind": .string(resource.key.kind), "id": resource.key.id.json,
        ])
        let lease = work.retain(
          .mcpResource, workspaceID: workspaceID, registrationID: registrationID,
          resourceID: String(decoding: try encoder.encode(identity), as: UTF8.self))
        replacement[resource.key] = Ownership(
          resource: resource, tool: tool, lease: lease, hostContext: contexts[resource.acquiredBy])
      }
    }
    // Acquire every new owner before releasing old owners or the observation barrier.
    for (key, item) in ownership where replacement[key] == nil { item.lease.finish() }
    ownership = replacement
    for item in ownership.values {
      if item.resource.uncertain {
        item.lease.markUncertain()
      } else {
        item.lease.confirmObservation()
      }
    }
    for id in completed where invocations[id]?.confirmed == true {
      invocations.removeValue(forKey: id)
    }
    report = next
    if invocations.isEmpty {
      observation?.finish()
      observation = nil
    } else if invocations.values.contains(where: \.uncertain) {
      observation?.markUncertain()
    } else {
      observation?.confirmObservation()
    }
    publishContinuations()
  }

  func resources(matching query: MCPProviderContinuation.Query) -> Set<Key> {
    Set(ownership.values.compactMap { $0.resource.matches(query) ? $0.resource.key : nil })
  }

  func validate(_ target: MCPContinuationTarget, tool: String, arguments: JSONValue) throws {
    guard connected, target.connectionID == connectionID,
      target.workspaceID == workspaceID,
      target.reference == MCPToolReference(serverID: registrationID, toolName: tool),
      target.instanceID == report?.instanceID,
      let declaration = continuations[tool]
    else { throw MCPContinuationTarget.unavailable() }
    let queries = try declaration.queries(arguments: arguments)
    guard
      ownership.values.contains(where: { item in
        target.resources[item.resource.key] == item.resource.acquiredBy
          && queries.contains(where: item.resource.matches)
      })
    else { throw MCPContinuationTarget.unavailable() }
  }

  mutating func declareContinuations(from tools: [MCPTool]) throws {
    var declarations: [String: MCPProviderContinuation] = [:]
    for tool in tools {
      let declaration = try MCPProviderContinuation(tool)
      if needsObservation, let existing = continuations[tool.name], existing != declaration {
        throw GatewayToolError.invalidArguments(
          "[mcp.continuation_changed] Continuation bindings cannot change while the connection owns work."
        )
      }
      if let declaration {
        declarations[tool.name] = declaration
      }
    }
    // Removed tools still locate their retained owners; discovery independently
    // decides whether that connection can currently execute the operation.
    continuations =
      needsObservation ? continuations.merging(declarations) { _, new in new } : declarations
    publishContinuations()
  }

  private func publishContinuations() {
    work.continuations.update(
      connectionID: connectionID,
      entry: .init(
        workspaceID: workspaceID, registrationID: registrationID,
        instanceID: report?.instanceID, declarations: continuations,
        resources: ownership.values.map(\.resource), observationPending: observation != nil,
        connected: connected))
  }

  private mutating func requireObservation() {
    guard observation == nil else { return }
    observation = work.retain(
      .mcpObservation, workspaceID: workspaceID, registrationID: registrationID,
      resourceID: connectionID.uuidString)
    publishContinuations()
  }

  private static func invalidReport() -> GatewayToolError {
    .executionFailed("[mcp.invalid_work_report] Provider work observation is invalid or stale.")
  }
}
