import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite
struct MCPProviderContinuationTests {
  @Test
  func nativeHandleQueriesPreserveTypesAndDecodePointers() throws {
    let declaration = try #require(
      try MCPProviderContinuation(
        tool(handles: [
          "thread": "/thread/id", "turn": "/items/0/a~1b~0c",
        ])))
    let queries = try declaration.queries(
      arguments: .object([
        "thread": .object(["id": .string("native")]),
        "items": .array([.object(["a/b~c": .integer(9_007_199_254_740_993)])]),
      ]))
    #expect(
      queries == [
        .init(
          kind: "fixture.turn",
          handles: [
            "thread": .string("native"), "turn": .integer(9_007_199_254_740_993),
          ])
      ])
    let optional = try #require(try MCPProviderContinuation(tool(handles: ["id": "/session"])))
    #expect(try optional.queries(arguments: .object([:])).isEmpty)
    for value in [JSONValue.null, .bool(true), .number(1.5), .string(""), .string("bad\0id")] {
      #expect(throws: GatewayToolError.self) {
        try optional.queries(arguments: .object(["session": value]))
      }
    }
  }

  @Test(arguments: ["", "not/a/pointer", "/bad~2escape", "/unfinished~", "/bad\nfield"])
  func malformedPointersFailAtCatalogValidation(_ pointer: String) throws {
    #expect(throws: GatewayToolError.self) {
      try MCPProviderWork.advertised(by: [tool(handles: ["id": pointer])])
    }
  }

  @Test
  func metadataIsBoundedAndRequiresTheWorkResource() throws {
    let declared = tool(handles: ["id": "/session"])
    var fields = try #require(declared.meta?.objectValue)
    fields.removeValue(forKey: MCPProviderWork.metadataKey)
    let unbound = MCPTool(
      name: declared.name, description: declared.description, inputSchema: declared.inputSchema,
      meta: .object(fields))
    #expect(throws: GatewayToolError.self) { try MCPProviderWork.advertised(by: [unbound]) }
    let oversized = Dictionary(uniqueKeysWithValues: (0...16).map { ("field\($0)", "/id") })
    #expect(throws: GatewayToolError.self) { try MCPProviderContinuation(tool(handles: oversized)) }
  }

  @Test
  func exportedToolsDoNotLeakConnectionLocalSelectors() throws {
    let declared = tool(handles: ["id": "/session"])
    #expect(declared.sdkTool._meta?.fields[MCPProviderContinuation.metadataKey] != nil)
    let exposed = declared.prefixed("fixture", serverID: "provider")
    #expect(exposed.sdkTool._meta?.fields[MCPProviderContinuation.metadataKey] == nil)
    #expect(
      exposed.json.objectValue?["_meta"]?.objectValue?[MCPProviderContinuation.metadataKey] == nil)
    #expect(exposed.meta?.objectValue?[MCPProviderContinuation.metadataKey] != nil)
  }

  @Test
  func aliasesAreOnceBoundToAnActualOwnedLifetime() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "fixture")
    let instance = UUID()
    let acquisition = try work.beginInvocation(tool: "start")
    work.finishInvocation(acquisition, confirmed: true)
    let query = MCPProviderContinuation.Query(
      kind: "fixture.turn", handles: ["native": .string("reusable")])
    let initial = row(acquisition, "reservation-1", handles: ["native": .string("reusable")])
    try work.accept(report(instance, 1, [initial]), covering: work.completedInvocations)
    #expect(
      work.resources(matching: query) == [.init(kind: "fixture.turn", id: .string("reservation-1"))]
    )
    #expect(work.resources(matching: .init(kind: "other", handles: query.handles)).isEmpty)
    #expect(
      work.resources(
        matching: .init(kind: "fixture.turn", handles: ["id": .string("reservation-1")])
      ).count == 1)
    for changed in [
      row(acquisition, "reservation-1"),
      row(acquisition, "reservation-1", handles: ["native": .string("different")]),
    ] {
      #expect(throws: GatewayToolError.self) {
        try work.accept(report(instance, 2, [changed]), covering: [])
      }
      #expect(work.resources(matching: query).count == 1)
    }
    work.observationLost()
    #expect(work.resources(matching: query).count == 1)
    let next = try work.beginInvocation(tool: "start")
    work.finishInvocation(next, confirmed: true)
    try work.accept(
      report(instance, 3, [row(next, "reservation-2", handles: ["native": .string("reusable")])]),
      covering: work.completedInvocations)
    #expect(
      work.resources(matching: query) == [.init(kind: "fixture.turn", id: .string("reservation-2"))]
    )
    try work.accept(report(instance, 4, []), covering: [])
    #expect(work.resources(matching: query).isEmpty && ledger.snapshot.isEmpty)
  }

  @Test
  func malformedOrReservedAliasesCannotFormAReport() throws {
    let acquisition = UUID()
    for handles in [
      JSONValue.null, .object([:]), .object(["id": .string("shadow")]),
      .object(["native": .bool(true)]), .object(["native": .string("bad\0id")]),
    ] {
      var value = try #require(row(acquisition, "lifetime").objectValue)
      value["handles"] = handles
      #expect(throws: GatewayToolError.self) { try report(UUID(), 1, [.object(value)]) }
    }
  }

  private func tool(handles: [String: String]) -> MCPTool {
    MCPTool(
      name: "continue", description: "", inputSchema: .object([:]),
      meta: .object([
        MCPProviderWork.metadataKey: .object([
          "format_version": .integer(1), "uri": .string(MCPProviderWork.resourceURI),
        ]),
        MCPProviderContinuation.metadataKey: .object([
          "format_version": .integer(1),
          "selectors": .array([
            .object([
              "kind": .string("fixture.turn"),
              "handles": .object(handles.mapValues(JSONValue.string)),
            ])
          ]),
        ]),
      ]))
  }

  private func row(_ acquisition: UUID, _ id: String, handles: [String: JSONValue]? = nil)
    -> JSONValue
  {
    var object: [String: JSONValue] = [
      "kind": .string("fixture.turn"), "id": .string(id), "state": .string("active"),
      "acquired_by": .string(acquisition.uuidString),
    ]
    if let handles { object["handles"] = .object(handles) }
    return .object(object)
  }

  private func report(_ instance: UUID, _ revision: Int64, _ rows: [JSONValue]) throws
    -> MCPProviderWork.Report
  {
    let value = JSONValue.object([
      "format_version": .integer(1), "instance_id": .string(instance.uuidString),
      "revision": .integer(revision), "resources": .array(rows),
    ])
    return try MCPProviderWork.Report(contents: [
      .text(
        String(decoding: JSONEncoder().encode(value), as: UTF8.self),
        uri: MCPProviderWork.resourceURI, mimeType: "application/json")
    ])
  }
}
