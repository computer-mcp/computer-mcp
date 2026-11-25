import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPGateway

struct TraeVendorProtocolTests {
  @Test func nativeCloseUsesNegotiatedCapabilityAndCorrelatedSession() throws {
    var protocolState = try initialized()
    protocolState.observe(Data(#"{"jsonrpc":"2.0","id":9,"result":{"sessionId":"sibling"}}"#.utf8))
    #expect(!protocolState.sessionReady)
    protocolState.observe(Data(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"owned"}}"#.utf8))
    #expect(protocolState.sessionReady)
    let wrong =
      #"{"jsonrpc":"2.0","id":3,"method":"session/close","params":{"sessionId":"sibling"}}"#
    let correct =
      #"{"jsonrpc":"2.0","id":3,"method":"session/close","params":{"sessionId":"owned"}}"#
    #expect(throws: VendorExecutionFailure.denied) {
      try protocolState.commitWrite("close", line: wrong, token: nil, arguments: [:])
    }
    try protocolState.commitWrite("close", line: correct, token: nil, arguments: [:])
    #expect(protocolState.closeDispatched)
    #expect(throws: VendorExecutionFailure.denied) {
      try protocolState.commitWrite("close", line: correct, token: nil, arguments: [:])
    }

    var withoutClose = try initialized(close: false)
    withoutClose.observe(Data(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"owned"}}"#.utf8))
    #expect(throws: VendorExecutionFailure.denied) {
      try withoutClose.commitWrite("close", line: correct, token: nil, arguments: [:])
    }
  }

  @Test func promptAndPermissionAnswerMatchAdmittedOperationAndNativeRequest() throws {
    var protocolState = try initialized()
    protocolState.observe(Data(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"owned"}}"#.utf8))
    let prompt =
      #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"owned","prompt":[{"type":"text","text":"hello"}]}}"#
    #expect(throws: VendorExecutionFailure.denied) {
      try protocolState.commitWrite(
        "prompt", line: prompt, token: nil, arguments: ["prompt": .string("different")])
    }
    try protocolState.commitWrite(
      "prompt", line: prompt, token: nil, arguments: ["prompt": .string("hello")])
    #expect(protocolState.promptInFlight)
    #expect(throws: VendorExecutionFailure.denied) {
      try protocolState.bindPermission("permission")
    }
    protocolState.observe(
      Data(
        #"""
        {"jsonrpc":"2.0","id":"request","method":"session/request_permission","params":{"sessionId":"owned","toolCall":{},
        "options":[{"kind":"allow_once","optionId":"allow"},{"kind":"reject_once","optionId":"reject"}]}}
        """#.utf8))
    try protocolState.bindPermission("permission")
    let answer =
      #"{"jsonrpc":"2.0","id":"request","result":{"outcome":{"outcome":"selected","optionId":"reject"}}}"#
    #expect(throws: VendorExecutionFailure.denied) {
      try protocolState.commitWrite(
        "answer", line: answer, token: "permission", arguments: ["option_id": .string("allow")])
    }
    let wrongID = answer.replacingOccurrences(of: #""request""#, with: #""different""#)
    #expect(throws: VendorExecutionFailure.denied) {
      try protocolState.commitWrite(
        "answer", line: wrongID, token: "permission", arguments: ["option_id": .string("reject")])
    }
    try protocolState.commitWrite(
      "answer", line: answer, token: "permission", arguments: ["option_id": .string("reject")])
    #expect(throws: VendorExecutionFailure.denied) {
      try protocolState.commitWrite(
        "answer", line: answer, token: "permission", arguments: ["option_id": .string("reject")])
    }
    protocolState.observe(
      Data(#"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#.utf8))
    #expect(!protocolState.promptInFlight)
  }

  private func initialized(close: Bool = true) throws -> TraeVendorProtocol {
    var protocolState = try TraeVendorProtocol(open: [:], directory: "/fixture")
    try protocolState.commitWrite(
      "setup",
      line:
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"computer-mcp-plugin-trae","version":"1"}}}"#,
      token: nil, arguments: [:])
    protocolState.observe(
      Data(
        #"""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"traecli-acp",
        "version":"0.207.1-tob"},"agentCapabilities":{"sessionCapabilities":\#(close ? #"{"close":{}}"# : "{}")}}}
        """#.utf8))
    try protocolState.commitWrite(
      "setup",
      line:
        #"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/fixture","mcpServers":[]}}"#,
      token: nil, arguments: [:])
    return protocolState
  }
}
