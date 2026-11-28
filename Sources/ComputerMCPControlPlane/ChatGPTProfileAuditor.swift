import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPTunnels
import Foundation

internal struct ChatGPTProfileAuditor: Sendable {
  internal func audit(registry: any GatewayToolServing) throws -> ChatGPTProfileAudit {
    // Catalog validation inventories metadata outside any caller invocation.
    let tools = try GatewayMCPToolSurface(registry: registry).listTools(context: .empty)
    guard !tools.isEmpty else {
      throw ChatGPTProfileAuditError.noTools
    }

    let missingAnnotations = tools.filter { $0.annotations?.readOnlyHint == nil }.map(\.name)
      .sorted()
    guard missingAnnotations.isEmpty else {
      throw ChatGPTProfileAuditError.missingReadOnlyAnnotations(missingAnnotations)
    }
    let invalidSchemas = tools.filter {
      !Self.validObjectSchema($0.inputSchema)
        || $0.outputSchema.map { !Self.validObjectSchema($0) } == true
    }.map(\.name).sorted()
    guard invalidSchemas.isEmpty else {
      throw ChatGPTProfileAuditError.invalidToolSchemas(invalidSchemas)
    }
    let invalidRequirements = tools.filter { tool in
      guard let declaration = tool.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"],
        let data = try? JSONEncoder().encode(declaration),
        (try? JSONDecoder().decode(ToolRequirement.self, from: data)) != nil
      else { return true }
      return false
    }.map(\.name).sorted()
    guard invalidRequirements.isEmpty else {
      throw ChatGPTProfileAuditError.invalidRequirements(invalidRequirements)
    }

    let writeCapable = tools.filter { $0.annotations?.readOnlyHint != true }.map(\.name).sorted()
    return ChatGPTProfileAudit(
      toolCount: tools.count,
      readOnlyToolCount: tools.count - writeCapable.count,
      writeCapableToolNames: writeCapable)
  }

  private static func validObjectSchema(_ value: JSONValue) -> Bool {
    guard let schema = value.objectValue, schema["type"] == .string("object"),
      schema["properties"] == nil || schema["properties"]?.objectValue != nil
    else { return false }
    if let required = schema["required"] {
      guard let entries = required.arrayValue else { return false }
      let names = entries.compactMap(\.stringValue)
      guard names.count == entries.count, Set(names).count == names.count else { return false }
    }
    return true
  }
}
