import ComputerMCPCore
import ComputerMCPTransport
import Foundation

/// Each accepted socket retains the HTTP generation that admitted it.
struct HTTPClientControlRegistry: GatewayToolServing {
  let clientControl: any GatewayClientControlProvider
  let owner: GatewayHTTPApp
  let generation: UUID
  let database: GatewayDatabase
  let identity: GatewaySocketConnectionIdentity

  func listTools(context: InvocationContext) throws -> [MCPTool] {
    try clientControl.listTools()
  }

  func callTool(name: String, arguments: JSONValue?, context: InvocationContext) throws
    -> JSONValue
  {
    throw GatewayToolError.invalidArguments("Control operations require async dispatch.")
  }

  func callToolAsync(name: String, arguments: JSONValue?, context: InvocationContext)
    async throws -> JSONValue
  {
    let requestID = UUID().uuidString
    let started = ContinuousClock.now
    let inputDigest = try ControlToolResponse.digest(
      .object(["tool": .string(name), "arguments": arguments ?? .object([:])]))
    let payload: JSONValue
    let decision: AuditDecision
    let isError: Bool
    do {
      payload = try await clientControl.callTool(
        name: name, arguments: arguments, owner: owner, generation: generation)
      decision = .allowed
      isError = false
    } catch {
      let disposition = ControlToolResponse.auditDisposition(for: error)
      payload = .object([
        "error": .object([
          "code": .string(disposition.code),
          "message": .string(ControlToolResponse.errorMessage(error)),
        ])
      ])
      decision = disposition.decision
      isError = true
    }
    let result = ControlToolResponse.envelope(
      payload, requestID: requestID, capabilityID: name, identity: identity, isError: isError)
    let output = try ControlToolResponse.encodedJSON(result)
    try database.recordAudit(
      AuditEvent(
        requestID: requestID, caller: .localCLI, transport: "control_socket",
        socketConnectionID: identity.connectionID, profileID: .localAdmin,
        capabilityID: name, decision: decision,
        durationMilliseconds: ControlToolResponse.milliseconds(started.duration(to: .now)),
        inputDigest: inputDigest, outputDigest: ControlToolResponse.digest(output),
        outputByteCount: output.count, outputTruncated: false))
    return result
  }
}
