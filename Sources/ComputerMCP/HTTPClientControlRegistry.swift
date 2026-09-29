import Foundation

/// Each accepted socket retains the HTTP generation that admitted it.
struct HTTPClientControlRegistry: GatewayToolServing {
  let owner: GatewayHTTPApp
  let generation: UUID
  let database: GatewayDatabase
  let identity: GatewaySocketConnectionIdentity

  func listTools() throws -> [MCPTool] {
    try GatewayClientControl.contracts.map { try $0.tool() }
  }

  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    throw GatewayToolError.invalidArguments("Control operations require async dispatch.")
  }

  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    let requestID = UUID().uuidString
    let started = ContinuousClock.now
    let inputDigest = try ControlToolResponse.digest(
      .object(["tool": .string(name), "arguments": arguments ?? .object([:])]))
    let payload: JSONValue
    let decision: AuditDecision
    let isError: Bool
    do {
      guard let contract = GatewayClientControl.contracts.first(where: { $0.name == name }) else {
        throw GatewayToolError.unknownTool(name)
      }
      let object = try contract.validate(arguments)
      payload = try await GatewayClientControl.http(owner, generation: generation)
        .call(name: name, arguments: object)
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
