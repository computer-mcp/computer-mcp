import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite
struct MCPProviderWorkTests {
  @Test
  func gatewayExportsDoNotAdvertiseADownstreamConnectionResource() throws {
    let tool = MCPTool(
      name: "native", description: "", inputSchema: .object([:]),
      meta: .object([
        MCPProviderWork.metadataKey: .object([
          "format_version": .integer(1), "uri": .string(MCPProviderWork.resourceURI),
        ]),
        "io.github.computer-mcp/risk": .string("full-shell"), "publisher": .string("fixture"),
      ]))
    #expect(tool.sdkTool._meta?.fields[MCPProviderWork.metadataKey] != nil)
    for prefix in ["", "registered"] {
      let exposed = tool.prefixed(prefix, serverID: "provider")
      #expect(exposed.meta == tool.meta)
      #expect(exposed.sdkTool._meta?.fields[MCPProviderWork.metadataKey] == nil)
      #expect(exposed.json.objectValue?["_meta"]?.objectValue?[MCPProviderWork.metadataKey] == nil)
      #expect(exposed.sdkTool._meta?.fields["publisher"] == .string("fixture"))
      #expect(exposed.json.objectValue?["_meta"]?.objectValue?["publisher"] == .string("fixture"))
      #expect(try exposed.declaredRiskFloor == .fullShell)
      #expect(exposed.sdkTool._meta?.fields["io.github.computer-mcp/risk"] == .string("full-shell"))
    }
  }

  @Test
  func declarationsUseOnlyTheVersionedResourceOnTheOwningConnection() throws {
    func tool(_ value: JSONValue?) -> MCPTool {
      MCPTool(
        name: "run", description: "", inputSchema: .object([:]),
        meta: value.map { .object([MCPProviderWork.metadataKey: $0]) })
    }
    let declaration = JSONValue.object([
      "format_version": .integer(1), "uri": .string(MCPProviderWork.resourceURI),
    ])
    #expect(try MCPProviderWork.advertised(by: [tool(nil)]) == false)
    #expect(try MCPProviderWork.advertised(by: [tool(nil), tool(declaration)]))
    for declaration in [
      JSONValue.null,
      .object(["format_version": .integer(2), "uri": .string(MCPProviderWork.resourceURI)]),
      .object(["format_version": .integer(1), "uri": .string("https://unrelated.invalid")]),
    ] {
      #expect(throws: GatewayToolError.self) {
        try MCPProviderWork.advertised(by: [tool(declaration)])
      }
    }
  }

  @Test
  func completeReportsTransferOwnershipAndKeepExactResourceIdentities() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "provider")
    let invocation = try work.beginInvocation(tool: "start")
    work.finishInvocation(invocation, confirmed: true)
    let instance = UUID()
    let integer: Int64 = 9_007_199_254_740_993
    try work.accept(
      report(
        instance, 1,
        [
          resource(invocation, id: .integer(integer)),
          resource(invocation, id: .string(String(integer))),
        ]), covering: work.completedInvocations)
    #expect(ledger.snapshot.count == 2)
    #expect(
      ledger.snapshot.allSatisfy {
        $0.kind == .mcpResource && $0.workspaceID == "ws" && $0.registrationID == "provider"
          && !$0.uncertain
      })
    let identities = try ledger.snapshot.map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.resourceID.utf8)).objectValue?["id"]
    }
    #expect(identities.contains(.integer(integer)))
    #expect(identities.contains(.string(String(integer))))
    try work.accept(report(instance, 2, []), covering: [])
    #expect(ledger.snapshot.isEmpty)
    #expect(!work.needsObservation)
  }

  @Test
  func liveResourcesRetainAcquisitionForDerivedWorkUntilFinalRelease() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "provider")
    let invocation = try work.beginInvocation(tool: "start")
    work.finishInvocation(invocation, confirmed: true)
    let instance = UUID()
    try work.accept(
      report(instance, 1, [resource(invocation)]), covering: work.completedInvocations)
    #expect(work.completedInvocations.isEmpty)
    let child = resource(invocation, id: .string("child"))
    try work.accept(report(instance, 2, [child]), covering: [])
    #expect(ledger.snapshot.count == 1)
    #expect(ledger.snapshot.first?.kind == .mcpResource)
    try work.accept(report(instance, 3, []), covering: [])
    #expect(ledger.snapshot.isEmpty)
    let replay = try report(instance, 4, [child])
    #expect(throws: GatewayToolError.self) { try work.accept(replay, covering: []) }
  }

  @Test
  func aReadStartedBeforeCompletionCannotDischargeThatInvocation() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "provider")
    let invocation = try work.beginInvocation(tool: "start")
    let covered = work.completedInvocations
    work.finishInvocation(invocation, confirmed: true)
    let instance = UUID()
    try work.accept(report(instance, 1, []), covering: covered)
    #expect(!ledger.snapshot.isEmpty)
    #expect(work.completedInvocations == [invocation])
    try work.accept(
      report(instance, 2, [resource(invocation)]), covering: work.completedInvocations)
    #expect(ledger.snapshot.count == 1)
    #expect(ledger.snapshot.first?.kind == .mcpResource)
  }

  @Test
  func observationLossRequiresValidSameInstanceEvidenceToReleaseOwners() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "provider")
    let invocation = try work.beginInvocation(tool: "start")
    work.finishInvocation(invocation, confirmed: true)
    let instance = UUID()
    let first = try report(instance, 5, [resource(invocation)])
    try work.accept(first, covering: work.completedInvocations)
    work.observationLost()
    #expect(ledger.snapshot.allSatisfy { $0.uncertain })
    for invalid in [
      try report(UUID(), 6, []), try report(instance, 4, []), try report(instance, 5, []),
    ] {
      #expect(throws: GatewayToolError.self) { try work.accept(invalid, covering: []) }
      #expect(ledger.snapshot.contains { $0.kind == .mcpResource && $0.uncertain })
    }
    try work.accept(first, covering: [])
    #expect(ledger.snapshot.count == 1)
    #expect(ledger.snapshot.first?.uncertain == false)
    work.disconnected()
    #expect(ledger.snapshot.allSatisfy { $0.uncertain })
  }

  @Test
  func foreignAcquisitionsAndChangedCreatorsCannotReleaseKnownWork() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "provider")
    let invocation = try work.beginInvocation(tool: "start")
    work.finishInvocation(invocation, confirmed: true)
    let instance = UUID()
    try work.accept(
      report(instance, 1, [resource(invocation)]), covering: work.completedInvocations)
    let owner = ledger.snapshot.first?.id
    let other = try work.beginInvocation(tool: "other")
    for resources in [[resource(UUID(), id: .string("foreign"))], [resource(other)]] {
      let invalid = try report(instance, 2, resources)
      #expect(throws: GatewayToolError.self) { try work.accept(invalid, covering: []) }
      #expect(ledger.snapshot.contains { $0.id == owner })
    }
    // A disappeared resource cannot reuse an expired acquisition reference.
    try work.accept(report(instance, 2, []), covering: [])
    let replay = try report(instance, 3, [resource(invocation)])
    #expect(throws: GatewayToolError.self) { try work.accept(replay, covering: []) }
  }

  @Test
  func cancelledRequestWithoutResponseStaysUncertainDespiteEmptyReports() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "provider")
    let invocation = try work.beginInvocation(tool: "start")
    work.finishInvocation(invocation, confirmed: false)
    let instance = UUID()
    try work.accept(report(instance, 1, []), covering: work.completedInvocations)
    #expect(ledger.snapshot.count == 1)
    #expect(ledger.snapshot.first?.uncertain == true)
    work.finishInvocation(invocation, confirmed: true)
    try work.accept(report(instance, 1, []), covering: work.completedInvocations)
    #expect(ledger.snapshot.isEmpty)
    work.disconnected()
    #expect(ledger.snapshot.isEmpty)
  }

  @Test
  func rejectedWholeReportCannotPartiallyCreateOrReleaseWork() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "provider")
    let invocation = try work.beginInvocation(tool: "start")
    let before = ledger.snapshot
    let invalid = try report(
      UUID(), 1, [resource(invocation), resource(UUID(), id: .string("bad"))])
    #expect(throws: GatewayToolError.self) { try work.accept(invalid, covering: []) }
    #expect(ledger.snapshot == before)
  }

  @Test
  func capacityRejectsBeforeNewAdmissionAndRecoversAfterObservation() throws {
    let ledger = GatewayOwnedWork()
    var work = MCPProviderWork(work: ledger, workspaceID: "ws", registrationID: "provider")
    var ids: [UUID] = []
    for _ in 0..<MCPProviderWork.maximumResources {
      ids.append(try work.beginInvocation(tool: "run"))
    }
    #expect(throws: GatewayToolError.self) { try work.beginInvocation(tool: "overflow") }
    for id in ids { work.finishInvocation(id, confirmed: true) }
    try work.accept(report(UUID(), 1, []), covering: work.completedInvocations)
    #expect(ledger.snapshot.isEmpty)
    _ = try work.beginInvocation(tool: "next")
  }

  @Test
  func parserRejectsAmbiguousUnboundedAndUnsupportedReports() throws {
    let invocation = UUID()
    #expect(
      try report(
        UUID(), 0, [resource(invocation, id: .string(String(repeating: "x", count: 1_024)))]
      )
      .resources.count == 1)
    let base: [String: JSONValue] = [
      "format_version": .integer(1), "instance_id": .string(UUID().uuidString),
      "revision": .integer(0), "resources": .array([]),
    ]
    let mutations: [[String: JSONValue]] = [
      ["format_version": .integer(2)], ["revision": .integer(-1)], ["revision": .number(0.5)],
      ["principal_id": .string("forged")], ["instance_id": .string("invalid")],
      ["resources": .array([resource(invocation), resource(invocation)])],
      ["resources": .array([resource(invocation, id: .bool(true))])],
      ["resources": .array([resource(invocation, id: .number(1.5))])],
      [
        "resources": .array([
          resource(invocation, id: .string(String(repeating: "x", count: 1_025)))
        ])
      ],
      ["resources": .array(Array(repeating: resource(invocation), count: 1_025))],
    ]
    for change in mutations {
      let value = JSONValue.object(base.merging(change) { _, new in new })
      #expect(throws: GatewayToolError.self) { try decode(value) }
    }
    #expect(throws: GatewayToolError.self) {
      try MCPProviderWork.Report(contents: [
        .text(
          String(repeating: " ", count: MCPProviderWork.maximumBytes + 1),
          uri: MCPProviderWork.resourceURI, mimeType: "application/json")
      ])
    }
    #expect(throws: GatewayToolError.self) { try MCPProviderWork.Report(contents: []) }
    #expect(throws: GatewayToolError.self) {
      try MCPProviderWork.Report(contents: [.text("{}", uri: "https://unrelated.invalid")])
    }
  }

  private func resource(_ invocation: UUID, id: JSONValue = .string("job")) -> JSONValue {
    .object([
      "kind": .string("session"), "id": id,
      "acquired_by": .string(invocation.uuidString), "state": .string("active"),
    ])
  }

  private func report(_ instance: UUID, _ revision: Int64, _ resources: [JSONValue]) throws
    -> MCPProviderWork.Report
  {
    try decode(
      .object([
        "format_version": .integer(1), "instance_id": .string(instance.uuidString),
        "revision": .integer(revision), "resources": .array(resources),
      ]))
  }

  private func decode(_ value: JSONValue) throws -> MCPProviderWork.Report {
    try MCPProviderWork.Report(contents: [
      .text(
        String(decoding: JSONEncoder().encode(value), as: UTF8.self),
        uri: MCPProviderWork.resourceURI, mimeType: "application/json")
    ])
  }
}
