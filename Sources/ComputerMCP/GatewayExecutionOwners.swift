import Foundation

/// A locator for one host-owned lifetime; possession confers no authorization.
struct GatewayOwnerSelection: Sendable, Equatable {
  let runtimeID: UUID
  let workspaceID: String
  let ownershipID: UUID

  init(runtimeID: UUID, workspaceID: String, ownershipID: UUID) {
    self.runtimeID = runtimeID
    self.workspaceID = workspaceID
    self.ownershipID = ownershipID
  }

  init(_ value: JSONValue?) throws {
    guard let object = value?.objectValue,
      Set(object.keys) == ["runtime_id", "workspace_id", "ownership_id"],
      let runtimeID = object["runtime_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
      let workspaceID = object["workspace_id"]?.stringValue,
      MCPProviderContinuation.validName(workspaceID),
      let ownershipID = object["ownership_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    else {
      throw GatewayToolError.invalidArguments(
        "[runtime.invalid_owner] Supply an owner returned by runtime.owners.list.")
    }
    self.init(runtimeID: runtimeID, workspaceID: workspaceID, ownershipID: ownershipID)
  }

  var json: JSONValue {
    .object([
      "runtime_id": .string(runtimeID.uuidString), "workspace_id": .string(workspaceID),
      "ownership_id": .string(ownershipID.uuidString),
    ])
  }

  var cursor: String { runtimeID.uuidString + ":" + ownershipID.uuidString }

  static func unavailable() -> GatewayToolError {
    .invalidArguments(
      "[runtime.owner_unavailable] The selected execution owner is unavailable. Query current owners; no replacement was started."
    )
  }
}

enum GatewayOwnerRouting {
  typealias Call = @Sendable (GatewayOwnerSelection, String, JSONValue) async throws -> JSONValue
  @TaskLocal static var runtimes: [GatewayRuntime] = []
  @TaskLocal static var call: Call?
  @TaskLocal static var selection: GatewayOwnerSelection?

  static let tools = [
    MCPTool(
      name: "runtime.owners.list",
      description:
        "List retained execution owners in one authorized workspace, without starting providers. Use the returned owner with runtime.owners.call to address a previous execution instance. Ownership is a locator, not permission.",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "workspace_id": .object(["type": .string("string")]),
          "server": .object(["type": .string("string")]),
          "after": .object([
            "type": .string("string"),
            "description": .string(
              "Cursor returned by the previous page. The live directory may change between pages."),
          ]),
          "limit": .object([
            "type": .string("integer"), "minimum": .integer(1), "maximum": .integer(100),
            "default": .integer(50),
          ]),
        ]),
        "required": .array([.string("workspace_id")]), "additionalProperties": .bool(false),
      ]),
      annotations: .init(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
    MCPTool(
      name: "runtime.owners.call",
      description:
        "Call a gateway tool on one retained execution owner. Supply its exact owner, target tool and unchanged target arguments. Current target permissions and approvals still apply; stale owners fail without launching replacements. For operations.prepare or operations.commit, use the same owner for both calls.",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "owner": .object([
            "type": .string("object"),
            "properties": .object(
              Dictionary(
                uniqueKeysWithValues: ["runtime_id", "workspace_id", "ownership_id"].map {
                  ($0, .object(["type": .string("string")]))
                })),
            "required": .array(
              ["runtime_id", "workspace_id", "ownership_id"].map(JSONValue.string)),
            "additionalProperties": .bool(false),
          ]),
          "tool": .object(["type": .string("string")]),
          "arguments": .object(["type": .string("object"), "additionalProperties": .bool(true)]),
          "workspace_id": .object([
            "type": .string("string"),
            "description": .string("Must equal the selected owner's workspace."),
          ]),
        ]),
        "required": .array([.string("owner"), .string("tool"), .string("workspace_id")]),
        "additionalProperties": .bool(false),
      ]),
      annotations: .init(
        readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)),
  ]
}
