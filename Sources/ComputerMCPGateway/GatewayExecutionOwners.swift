import ComputerMCPCore
import Foundation

/// A locator for one host-owned lifetime; possession confers no authorization.
package struct GatewayOwnerSelection: Sendable, Equatable {
  package let runtimeID: UUID
  package let projectID: String
  let ownershipID: UUID

  package init(runtimeID: UUID, projectID: String, ownershipID: UUID) {
    self.runtimeID = runtimeID
    self.projectID = projectID
    self.ownershipID = ownershipID
  }

  package init(_ value: JSONValue?) throws {
    guard let object = value?.objectValue,
      Set(object.keys) == ["runtime_id", "project_id", "ownership_id"],
      let runtimeID = object["runtime_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
      let projectID = object["project_id"]?.stringValue,
      MCPProviderContinuation.validName(projectID),
      let ownershipID = object["ownership_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    else {
      throw GatewayToolError.invalidArguments(
        "[runtime.invalid_owner] Supply an owner returned by runtime.owners.list.")
    }
    self.init(runtimeID: runtimeID, projectID: projectID, ownershipID: ownershipID)
  }

  package var json: JSONValue {
    .object([
      "runtime_id": .string(runtimeID.uuidString), "project_id": .string(projectID),
      "ownership_id": .string(ownershipID.uuidString),
    ])
  }

  var cursor: String { runtimeID.uuidString + ":" + ownershipID.uuidString }

  package static func unavailable() -> GatewayToolError {
    .invalidArguments(
      "[runtime.owner_unavailable] The selected execution owner is unavailable. Query current owners; no replacement was started."
    )
  }
}

package enum GatewayOwnerRouting {
  package typealias Call =
    @Sendable (GatewayOwnerSelection, String, JSONValue) async throws -> JSONValue
  @TaskLocal package static var runtimes: [GatewayRuntime] = []
  @TaskLocal package static var call: Call?
  @TaskLocal package static var selection: GatewayOwnerSelection?

  package static let definitions = [
    ToolDefinition(
      tool: MCPTool(
        name: "runtime.owners.list",
        description:
          "List retained execution owners in one authorized project, without starting providers. Use the returned owner with runtime.owners.call to address a previous execution instance. Ownership is a locator, not permission.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "project_id": .object(["type": .string("string")]),
            "server": .object(["type": .string("string")]),
            "after": .object([
              "type": .string("string"),
              "description": .string(
                "Cursor returned by the previous page. The live directory may change between pages."
              ),
            ]),
            "limit": .object([
              "type": .string("integer"), "minimum": .integer(1), "maximum": .integer(100),
              "default": .integer(50),
            ]),
          ]),
          "required": .array([.string("project_id")]), "additionalProperties": .bool(false),
        ]),
        annotations: .init(
          readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
      capability: CapabilityDescriptor(
        id: "runtime.owners.list", risk: .readOnly,
        projectRequirement: .required,
        localOnly: false, usesNetwork: false
      )
    ),
    ToolDefinition(
      tool: MCPTool(
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
                  uniqueKeysWithValues: ["runtime_id", "project_id", "ownership_id"].map {
                    ($0, .object(["type": .string("string")]))
                  })),
              "required": .array(
                ["runtime_id", "project_id", "ownership_id"].map(JSONValue.string)),
              "additionalProperties": .bool(false),
            ]),
            "tool": .object(["type": .string("string")]),
            "arguments": .object(["type": .string("object"), "additionalProperties": .bool(true)]),
            "project_id": .object([
              "type": .string("string"),
              "description": .string("Must equal the selected owner's project."),
            ]),
          ]),
          "required": .array([.string("owner"), .string("tool"), .string("project_id")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: .init(
          readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)),
      capability: CapabilityDescriptor(
        id: "runtime.owners.call", risk: .readOnly,
        projectRequirement: .required,
        localOnly: false, usesNetwork: false
      )
    ),
  ]
}
