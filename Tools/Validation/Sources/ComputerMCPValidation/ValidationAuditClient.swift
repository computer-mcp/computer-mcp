import Foundation

private final class ValidationAuditMemoryStore: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [AuditEvent] = []
  private var registeredWorkspaces: [RegisteredWorkspace] = []

  func append(_ event: AuditEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  func matching(requestID: String) -> [AuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events.filter { $0.requestID == requestID }
  }

  func recent(limit: Int) -> [AuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return Array(events.suffix(max(0, limit)).reversed())
  }

  func workspaces() -> [RegisteredWorkspace] {
    lock.lock()
    defer { lock.unlock() }
    return registeredWorkspaces
  }
}

/// Validation audit reader backed by the shipped `audit export` CLI contract.
public struct GatewayDatabase: Sendable {
  private enum Storage: Sendable {
    case product(path: String)
    case memory(ValidationAuditMemoryStore)
  }

  private struct AuditExport: Decodable {
    let schemaVersion: Int
    let events: [AuditEvent]
  }

  private let storage: Storage

  public init(path: String) throws {
    storage = .product(path: URL(fileURLWithPath: path).standardizedFileURL.path)
  }

  public init(inMemory: Void) throws {
    storage = .memory(ValidationAuditMemoryStore())
  }

  public func recordAudit(_ event: AuditEvent) throws {
    guard case .memory(let store) = storage else {
      throw ValidationProcessError.launchFailed(
        "Validation cannot write a production audit database."
      )
    }
    store.append(event)
  }

  public func auditEvents(requestID: String) throws -> [AuditEvent] {
    switch storage {
    case .memory(let store):
      return store.matching(requestID: requestID)
    case .product(let path):
      return try exportedEvents(arguments: ["--request-id", requestID], databasePath: path)
    }
  }

  public func auditEvents(limit: Int) throws -> [AuditEvent] {
    switch storage {
    case .memory(let store):
      return store.recent(limit: limit)
    case .product(let path):
      return try exportedEvents(arguments: ["--limit", String(limit)], databasePath: path)
    }
  }

  public func auditEvent(requestID: String) throws -> AuditEvent? {
    try auditEvents(requestID: requestID).first
  }

  public func workspaces() throws -> [RegisteredWorkspace] {
    switch storage {
    case .memory(let store):
      return store.workspaces()
    case .product:
      let data = try ValidationProductCommand().run(["workspace", "list"])
      let value = try ValidationCanonicalJSONCoding.decoder().decode(JSONValue.self, from: data)
      guard let rows = value.objectValue?["workspaces"]?.arrayValue else { return [] }
      return try rows.map { row in
        let data = try ValidationCanonicalJSONCoding.encoder().encode(row)
        return try ValidationCanonicalJSONCoding.decoder().decode(
          RegisteredWorkspace.self,
          from: data
        )
      }
    }
  }

  private func exportedEvents(arguments: [String], databasePath: String) throws -> [AuditEvent] {
    let data = try ValidationProductCommand().run(
      ["audit", "export", "--database", databasePath] + arguments
    )
    let decoder = ValidationCanonicalJSONCoding.decoder()
    decoder.dateDecodingStrategy = .iso8601
    let export = try decoder.decode(AuditExport.self, from: data)
    guard export.schemaVersion == 1 else {
      throw ValidationArtifactError.unsupportedSchema(
        artifact: "Audit Export",
        expected: 1,
        actual: export.schemaVersion
      )
    }
    return export.events
  }
}
