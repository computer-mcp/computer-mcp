import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite
struct MCPProviderContinuationTests {
  @Test
  func operationConditionsDoNotMistakeNewWorkForAContinuation() throws {
    let declaration = try #require(
      try MCPProviderContinuation(
        tool(
          handles: ["native": "/params/handle"],
          condition: .object([
            "pointer": .string("/operation~1name"),
            "values": .array([.string("read"), .string("cancel")]),
          ]))))
    let params = JSONValue.object(["handle": .string("reused")])
    for operation in ["read", "cancel"] {
      #expect(
        try declaration.queries(
          arguments: .object(["operation/name": .string(operation), "params": params]))
          == [.init(kind: "fixture.turn", handles: ["native": .string("reused")])])
    }
    #expect(
      try declaration.queries(
        arguments: .object(["operation/name": .string("start"), "params": params])
      ).isEmpty)
    #expect(try declaration.queries(arguments: .object(["params": params])).isEmpty)
    #expect(throws: GatewayToolError.self) {
      try declaration.queries(
        arguments: .object(["operation/name": .integer(1), "params": params]))
    }
  }

  @Test
  func malformedOperationConditionsFailCatalogAdmission() throws {
    let invalid: [JSONValue] = [
      .null, .object([:]),
      .object(["pointer": .string("operation"), "values": .array([.string("read")])]),
      .object(["pointer": .string("/operation"), "values": .array([])]),
      .object(["pointer": .string("/operation"), "values": .array([.integer(1)])]),
      .object(["pointer": .string("/operation"), "values": .array([.string("bad\nname")])]),
      .object([
        "pointer": .string("/operation"), "values": .array([.string("read"), .string("read")]),
      ]),
      .object([
        "pointer": .string("/operation"),
        "values": .array((0...64).map { .string("operation\($0)") }),
      ]),
      .object([
        "pointer": .string("/operation"), "values": .array([.string("read")]),
        "unknown": .bool(true),
      ]),
    ]
    for condition in invalid {
      #expect(throws: GatewayToolError.self) {
        try MCPProviderWork.advertised(by: [tool(handles: ["id": "/handle"], condition: condition)])
      }
    }
  }

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

  @Test
  func nullableNativeScopesAreExplicitAndDoNotCoerceOtherHandles() throws {
    let declaration = try #require(
      try MCPProviderContinuation(
        tool(handles: ["thread": "/thread", "request": "/request"], nullable: [.string("thread")])
      ))
    #expect(
      try declaration.queries(arguments: .object(["thread": .null, "request": .string("owned")]))
        .isEmpty)
    #expect(throws: GatewayToolError.self) {
      try declaration.queries(arguments: .object(["thread": .null, "request": .bool(true)]))
    }
    #expect(throws: GatewayToolError.self) {
      try declaration.queries(arguments: .object(["thread": .string("owned"), "request": .null]))
    }
    let invalid: [[JSONValue]] = [
      [], [.string("unknown")], [.integer(1)], [.string("id"), .string("id")],
    ]
    for names in invalid {
      #expect(throws: GatewayToolError.self) {
        try MCPProviderContinuation(tool(handles: ["id": "/id"], nullable: names))
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

  @Test
  func directoryDistinguishesPendingObservationFromConfirmedAbsence() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "fixture")
    try work.declareContinuations(from: [tool(handles: ["native": "/handle"])])
    let instance = UUID()
    var result = try lookup(ledger)
    #expect(result.applicable && result.matches.isEmpty)
    #expect(result.pendingConnections == [work.connectionID])
    try work.accept(report(instance, 0, []), covering: [])
    result = try lookup(ledger)
    #expect(result.applicable && result.matches.isEmpty && result.pendingConnections.isEmpty)
    let invocation = try work.beginInvocation(tool: "start")
    work.finishInvocation(invocation, confirmed: true)
    #expect(try lookup(ledger).pendingConnections == [work.connectionID])
    try work.accept(
      report(instance, 1, [row(invocation, "lifetime", handles: ["native": .string("reused")])]),
      covering: work.completedInvocations)
    result = try lookup(ledger)
    #expect(result.pendingConnections.isEmpty)
    #expect(result.matches.count == 1 && result.matches.first?.uncertain == false)
    work.observationLost()
    result = try lookup(ledger)
    #expect(result.matches.count == 1 && result.pendingConnections == [work.connectionID])
    try work.accept(report(instance, 2, []), covering: [])
    work.disconnected()
    #expect(try lookup(ledger) == .init())
    #expect(ledger.snapshot.isEmpty)
  }

  @Test
  func ownerSelectionNeverGuessesAcrossPendingOrDuplicateInstances() throws {
    let connection = UUID()
    let instance = UUID()
    let acquisition = UUID()
    func match(_ id: String, connectionID: UUID? = nil, connected: Bool = true)
      -> MCPContinuationDirectory.Match
    {
      .init(
        connectionID: connectionID ?? connection, instanceID: instance,
        resource: .init(kind: "fixture.turn", id: .string(id)), acquiredBy: acquisition,
        connected: connected, uncertain: !connected)
    }
    let resources: Set<MCPContinuationDirectory.Match> = [match("thread"), match("turn")]
    let owned = MCPContinuationDirectory.Lookup(
      applicable: true, matches: resources, pendingConnections: [connection])
    #expect(try MCPContinuationDirectory.uniqueOwner(in: [owned]) == resources)
    #expect(try MCPContinuationDirectory.uniqueOwner(in: [.init()]) == nil)
    #expect(try MCPContinuationDirectory.uniqueOwner(in: [.init(applicable: true)]) == nil)
    let pending = MCPContinuationDirectory.Lookup(applicable: true, pendingConnections: [UUID()])
    for observations in [[pending], [owned, pending]] {
      #expect(throws: GatewayToolError.self) {
        try MCPContinuationDirectory.uniqueOwner(in: observations)
      }
    }
    let other = MCPContinuationDirectory.Lookup(
      applicable: true, matches: [match("thread", connectionID: UUID())])
    for observations in [[owned, other], [other, owned]] {
      #expect(throws: GatewayToolError.self) {
        try MCPContinuationDirectory.uniqueOwner(in: observations)
      }
    }
    let lost = MCPContinuationDirectory.Lookup(
      applicable: true, matches: [match("thread", connected: false)],
      pendingConnections: [connection])
    #expect(throws: GatewayToolError.self) {
      try MCPContinuationDirectory.uniqueOwner(in: [lost])
    }
  }

  @Test
  func directoryRetainsDisconnectedEvidenceAndEveryDuplicateOwner() throws {
    let ledger = GatewayOwnedWork()
    let connectionIDs = try (0..<2).map { index in
      var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "fixture")
      try work.declareContinuations(from: [tool(handles: ["native": "/handle"])])
      let invocation = try work.beginInvocation(tool: "start")
      work.finishInvocation(invocation, confirmed: true)
      try work.accept(
        report(UUID(), 1, [row(invocation, "lifetime", handles: ["native": .string("reused")])]),
        covering: work.completedInvocations)
      if index == 0 { work.disconnected() }
      return work.connectionID
    }
    let result = try lookup(ledger)
    #expect(Set(result.matches.map(\.connectionID)) == Set(connectionIDs))
    #expect(result.pendingConnections == [connectionIDs[0]])
    let lost = try #require(result.matches.first { $0.connectionID == connectionIDs[0] })
    #expect(!lost.connected && lost.uncertain)
    #expect(try lookup(ledger, workspaceID: "other") == .init())
    #expect(try lookup(ledger, workspaceID: nil) == .init())
    #expect(try lookup(ledger, registrationID: "other") == .init())
    #expect(try lookup(ledger, arguments: .object([:])) == .init())
  }

  @Test
  func directoryPublishesLateHandlesAndRejectsRebindingLiveDeclarations() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "fixture")
    let declared = tool(handles: ["native": "/handle"])
    try work.declareContinuations(from: [declared])
    let instance = UUID()
    let invocation = try work.beginInvocation(tool: "start")
    work.finishInvocation(invocation, confirmed: true)
    try work.accept(
      report(instance, 1, [row(invocation, "lifetime")]), covering: work.completedInvocations)
    #expect(try lookup(ledger).matches.isEmpty)
    try work.accept(
      report(instance, 2, [row(invocation, "lifetime", handles: ["native": .string("reused")])]),
      covering: [])
    #expect(try lookup(ledger).matches.count == 1)
    #expect(throws: GatewayToolError.self) {
      try work.declareContinuations(from: [tool(handles: ["native": "/different"])])
    }
    #expect(try lookup(ledger).matches.count == 1)
    try work.declareContinuations(from: [])
    #expect(try lookup(ledger).matches.count == 1)
    try work.accept(report(instance, 3, []), covering: [])
    try work.declareContinuations(from: [])
    #expect(try lookup(ledger) == .init())
  }

  private func lookup(
    _ work: GatewayOwnedWork, workspaceID: String? = "ws", registrationID: String = "fixture",
    arguments: JSONValue = .object(["handle": .string("reused")])
  ) throws -> MCPContinuationDirectory.Lookup {
    try work.continuations.lookup(
      workspaceID: workspaceID, registrationID: registrationID, tool: "continue",
      arguments: arguments)
  }

  @Test
  func admissionRechecksInstanceScopeHandlesAndAcquisition() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "fixture")
    try work.declareContinuations(from: [tool(handles: ["native": "/handle"])])
    let instance = UUID()
    let invocation = try work.beginInvocation(tool: "start")
    work.finishInvocation(invocation, confirmed: true)
    try work.accept(
      report(instance, 1, [row(invocation, "lifetime", handles: ["native": .integer(42)])]),
      covering: work.completedInvocations)
    let key = MCPProviderWork.Key(kind: "fixture.turn", id: .string("lifetime"))
    let arguments = JSONValue.object(["handle": .integer(42)])
    let valid = MCPContinuationTarget(
      workspaceID: "ws", reference: .init(serverID: "fixture", toolName: "continue"),
      connectionID: work.connectionID, instanceID: instance, resources: [key: invocation])
    try work.validate(valid, tool: "continue", arguments: arguments)
    #expect(throws: GatewayToolError.self) {
      try work.validate(valid, tool: "other", arguments: arguments)
    }
    #expect(throws: GatewayToolError.self) {
      try work.validate(valid, tool: "continue", arguments: .object(["handle": .string("42")]))
    }
    for index in 0..<5 {
      let target = MCPContinuationTarget(
        workspaceID: index == 0 ? "other" : "ws",
        reference: .init(serverID: index == 1 ? "other" : "fixture", toolName: "continue"),
        connectionID: index == 2 ? UUID() : work.connectionID,
        instanceID: index == 3 ? UUID() : instance,
        resources: [key: index == 4 ? UUID() : invocation])
      #expect(throws: GatewayToolError.self) {
        try work.validate(target, tool: "continue", arguments: arguments)
      }
    }
    work.disconnected()
    #expect(throws: GatewayToolError.self) {
      try work.validate(valid, tool: "continue", arguments: arguments)
    }
  }

  private func tool(
    handles: [String: String], condition: JSONValue? = nil, nullable: [JSONValue]? = nil
  ) -> MCPTool {
    var selector: [String: JSONValue] = [
      "kind": .string("fixture.turn"), "handles": .object(handles.mapValues(JSONValue.string)),
    ]
    if let condition { selector["when"] = condition }
    if let nullable { selector["nullable_handles"] = .array(nullable) }
    return MCPTool(
      name: "continue", description: "", inputSchema: .object([:]),
      meta: .object([
        MCPProviderWork.metadataKey: .object([
          "format_version": .integer(1), "uri": .string(MCPProviderWork.resourceURI),
        ]),
        MCPProviderContinuation.metadataKey: .object([
          "format_version": .integer(1),
          "selectors": .array([.object(selector)]),
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
