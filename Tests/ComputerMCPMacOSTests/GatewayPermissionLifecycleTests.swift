import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.serialized)
struct GatewayPermissionLifecycleTests {
  @Test
  func localOneTimeAnswerRunsOnlyTheExactHTTPRetryOnce() async throws {
    let fixture = try PermissionFixture()
    defer { fixture.removeFiles() }
    try await fixture.http.startListening()
    do {
      let client = try await fixture.connect()
      let tool = try #require(try await client.listTools().first { $0.name == "file.remove_xattr" })
      #expect(
        tool.inputSchema.objectValue?["properties"]?.objectValue?["_permission_request_ids"] != nil)
      #expect(tool.destructiveHint == true)
      #expect(tool.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
      let pending = try await client.call(toolName: tool.name, arguments: .object(fixture.target))
      let ids = try requestIDs(pending)
      let metadata = try permissionError(pending)
      #expect(metadata["request_group_id"]?.stringValue?.isEmpty == false)
      #expect(metadata["retry"]?.objectValue?["field"] == .string("_permission_request_ids"))
      let requests = try #require(metadata["requests"]?.arrayValue)
      #expect(requests.count == ids.count)
      #expect(
        requests.allSatisfy {
          $0.objectValue?["permission"] == .string("project")
            && $0.objectValue?["object"] == .string("fixture")
            && $0.objectValue?["value"] == .string("write")
            && $0.objectValue?["owner"] == .string("local-owner")
            && $0.objectValue?["expires_at"]?.stringValue != nil
        })
      let view = try fixture.control.view()
      #expect(Set(view.requests.map { $0.request.id }) == Set(ids))
      #expect(
        view.requests.allSatisfy {
          $0.profileID == .chatGPTOperate && $0.alwaysIsShared
            && $0.request.status == .pending
            && $0.request.invocation.tool == "file.remove_xattr"
        })
      #expect(fixture.hasAttribute())
      let unanswered = try await fixture.retry(client, ids: ids)
      #expect(unanswered.result.objectValue?["isError"] == .bool(true))
      #expect(fixture.hasAttribute())

      try fixture.answer(ids, .onlyThisTime)
      var changed = fixture.target
      changed["dry_run"] = .bool(true)
      let mismatched = try await fixture.retry(client, arguments: changed, ids: ids)
      #expect(try permissionError(mismatched)["code"] == .string("permission.retry_mismatch"))
      #expect(fixture.hasAttribute())
      let differentTool = try await fixture.retry(
        client, tool: "file.write",
        arguments: [
          "project_id": .string("fixture"), "path": .string("value.txt"),
          "content": .string("unreviewed overwrite"),
        ], ids: ids)
      #expect(try permissionError(differentTool)["code"] == .string("permission.retry_mismatch"))
      #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "original")

      let allowed = try await fixture.retry(client, ids: ids)
      #expect(allowed.result.objectValue?["isError"] != .bool(true))
      #expect(!fixture.hasAttribute())
      let consumed = try fixture.control.view().requests.filter { ids.contains($0.request.id) }
      #expect(
        consumed.allSatisfy {
          if case .consumed = $0.request.status { return true }
          return false
        })
      let profile = try #require(
        try fixture.control.view().profiles.first { $0.id == .chatGPTOperate })
      #expect(profile.permissions.state(for: .project("fixture")) == .granted(.read))
      try fixture.replaceAttribute(with: "new attribute")
      let replayed = try await fixture.retry(client, ids: ids)
      #expect(try permissionError(replayed)["code"] == .string("permission.retry_consumed"))
      #expect(fixture.hasAttribute())
      #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "original")
      await client.disconnect()
      await fixture.http.stop()
    } catch {
      await fixture.http.stop()
      throw error
    }
  }

  @Test
  func alwaysAnswerPersistsAcrossReconnectAndRevocationStopsExistingClients() async throws {
    let fixture = try PermissionFixture()
    defer { fixture.removeFiles() }
    try await fixture.http.startListening()
    do {
      let first = try await fixture.connect()
      let pending = try await first.call(
        toolName: "file.remove_xattr", arguments: .object(fixture.target))
      try fixture.answer(requestIDs(pending), .always)
      let profile = try #require(
        try fixture.control.view().profiles.first { $0.id == .chatGPTOperate })
      #expect(profile.permissions.state(for: .project("fixture")) == .granted(.write))
      await first.disconnect()

      let reconnected = try await fixture.connect()
      let allowed = try await reconnected.call(
        toolName: "file.remove_xattr", arguments: .object(fixture.target))
      #expect(allowed.result.objectValue?["isError"] != .bool(true))
      #expect(!fixture.hasAttribute())
      try fixture.replaceAttribute(with: "revoked target")
      let beforeRevocation = try fixture.control.view()
      _ = try fixture.control.revokePermission(
        .project("fixture"), profileID: .chatGPTOperate,
        expectedRevision: beforeRevocation.revision)
      let denied = try await reconnected.call(
        toolName: "file.remove_xattr", arguments: .object(fixture.target))
      #expect(try permissionError(denied)["code"] == .string("permission.denied"))
      #expect(try fixture.control.view().requests.count == beforeRevocation.requests.count)
      #expect(fixture.hasAttribute())
      #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "original")
      await reconnected.disconnect()
      await fixture.http.stop()
    } catch {
      await fixture.http.stop()
      throw error
    }
  }

  @Test
  func explicitDenyDoesNotCreateARequest() async throws {
    let fixture = try PermissionFixture(projectState: .denied)
    defer { fixture.removeFiles() }
    try await fixture.http.startListening()
    do {
      let client = try await fixture.connect()
      let denied = try await client.call(
        toolName: "file.remove_xattr", arguments: .object(fixture.target))
      let metadata = try permissionError(denied)
      #expect(metadata["code"] == .string("permission.denied"))
      #expect(metadata["request_ids"] == nil)
      #expect(try fixture.control.view().requests.isEmpty)
      #expect(fixture.hasAttribute())
      await client.disconnect()
      await fixture.http.stop()
    } catch {
      await fixture.http.stop()
      throw error
    }
  }

  @Test(arguments: ["ceiling", "unreadable", "invalid"])
  func managedSourcesRefuseCallsWithoutPromptingAndRetainLocalDiagnostics(source: String)
    async throws
  {
    let fixture = try PermissionFixture()
    defer { fixture.removeFiles() }
    try await fixture.http.startListening()
    do {
      let client = try await fixture.connect()
      switch source {
      case "ceiling":
        fixture.reader.set(.machineFile, .available(Data("[projects]\nfixture = 'read'\n".utf8)))
      case "unreadable": fixture.reader.set(.machineFile, .unreadable("Fixture source unavailable"))
      default: fixture.reader.set(.machineFile, .available(Data("invalid = [".utf8)))
      }
      let denied = try await client.call(
        toolName: "file.remove_xattr", arguments: .object(fixture.target))
      let metadata = try permissionError(denied)
      #expect(metadata["code"] == .string("permission.managed_limit"))
      #expect(metadata["sources"] == .array([.string("machine")]))
      #expect(metadata["request_ids"] == nil)
      let view = try fixture.control.view()
      #expect(view.requests.isEmpty)
      let diagnostic = try #require(view.sources.first { $0.source == .machine })
      #expect(diagnostic.location == "fixture/machineFile")
      #expect((diagnostic.failure != nil) == (source != "ceiling"))
      #expect(fixture.hasAttribute())
      #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "original")
      await client.disconnect()
      await fixture.http.stop()
    } catch {
      await fixture.http.stop()
      throw error
    }
  }

  @Test
  func revocationRetiresPendingRequestAndRejectsStaleOwnerAnswers() async throws {
    let fixture = try PermissionFixture()
    defer { fixture.removeFiles() }
    try await fixture.http.startListening()
    do {
      let client = try await fixture.connect()
      let ids = try requestIDs(
        await client.call(toolName: "file.remove_xattr", arguments: .object(fixture.target)))
      let beforeRevocation = try fixture.control.view()
      _ = try fixture.control.revokePermission(
        .project("fixture"), profileID: .chatGPTOperate,
        expectedRevision: beforeRevocation.revision)
      let current = try fixture.control.view()
      #expect(
        current.requests.filter { ids.contains($0.request.id) }.allSatisfy {
          $0.request.status == .revoked
        })
      for id in ids {
        #expect(throws: GatewayPermissionError.revisionConflict) {
          try fixture.control.answerRequest(
            id, answer: .onlyThisTime, expectedRevision: beforeRevocation.revision)
        }
        #expect(throws: (any Error).self) {
          try fixture.control.answerRequest(
            id, answer: .onlyThisTime, expectedRevision: current.revision)
        }
      }
      let denied = try await fixture.retry(client, ids: ids)
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(fixture.hasAttribute())
      await client.disconnect()
      await fixture.http.stop()
    } catch {
      await fixture.http.stop()
      throw error
    }
  }

  @Test(arguments: [GatewayCallerKind.secureTunnel, .cloudflareTunnel, .localMCP])
  func remoteAndMCPCallersCannotConstructLocalOwnerAuthority(caller: GatewayCallerKind) {
    #expect(throws: GatewayPermissionError.localOwnerRequired) {
      try GatewayPermissionOwner(
        context: .init(
          caller: caller, profileID: .localAdmin, trustedPrincipalID: "verified-client"),
        validate: {})
    }
  }

  private func permissionError(_ report: GatewayCallReport) throws -> [String: JSONValue] {
    try #require(report.result.objectValue?["isError"] == .bool(true), "\(report.result)")
    return try #require(
      report.result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
  }

  private func requestIDs(_ report: GatewayCallReport) throws -> [UUID] {
    let metadata = try permissionError(report)
    try #require(metadata["code"] == .string("permission.required"), "\(report.result)")
    let values = try #require(metadata["request_ids"]?.arrayValue)
    let ids = try values.map { try #require($0.stringValue.flatMap(UUID.init(uuidString:))) }
    try #require(!ids.isEmpty)
    return ids
  }

  @Test
  func oneTimeResultReadRequiresItsOriginalExecutionAndVerifiedPrincipal() async throws {
    let database = try GatewayDatabase(inMemory: ())
    let platform = fixtureHostedPlatform()
    let profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try database.saveProfile(profile)
    let runtime = try database.permissionRuntime(platform: platform)
    try await runtime.ready()
    let control = try fixturePermissionControl(database: database, platform: platform)
    let server = MCPServerConfig(id: "fixture", transport: .stdio, command: "/usr/bin/false")
    let configuration = GatewayConfiguration(mcp: .init(servers: [server]))
    func executionContext(principal: String) -> ExecutionContext {
      .init(caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: principal)
    }
    func host(principal: String) -> MCPHostContext {
      MCPHostContext(
        runtimeID: UUID(), context: executionContext(principal: principal),
        projectID: "fixture", rootURL: URL(fileURLWithPath: "/private/tmp"), readOnly: true,
        executionDatabase: database)
    }
    let owner = host(principal: "verified-first")
    let subject = try GatewayPermissionSubject(
      context: executionContext(principal: "verified-first"))
    let requirements = try InvocationRequirements(actions: [
      .init(requirement: .init(.mcpServer("fixture"), .read))
    ])
    let decision = try runtime.service.admit(
      subject: subject, tool: "fixture.metadata", projectID: "fixture",
      argumentsDigest: "original-input", requirements: requirements)
    guard case .requests(let pending) = decision else {
      Issue.record("Expected the original invocation to need object permission")
      return
    }
    for request in pending {
      _ = try control.answerRequest(
        request.id, answer: .onlyThisTime, expectedRevision: control.view().revision)
    }
    let retry = try runtime.service.admit(
      subject: subject, tool: "fixture.metadata", projectID: "fixture",
      argumentsDigest: "original-input", requirements: requirements,
      retryIDs: Set(pending.map(\.id)))
    guard case .allowed(let authorization) = retry else {
      Issue.record("Expected the exact one-time retry to be admitted")
      return
    }
    let execution = try runtime.store.transactionWithDatabase { _, ledger in
      let execution = try ledger.startExecution(
        owner: subject.principal, authorizationIDs: [authorization.id])
      try ledger.finishInvocation(authorization.id)
      try ledger.finishExecution(execution.id, retainUntil: Date().addingTimeInterval(3600))
      return execution
    }
    let scope = MCPExecutionRecord.digest(
      .array([
        .string(owner.launchMetadata.principalID), .string(owner.launchMetadata.profileID.rawValue),
        .string(owner.launchMetadata.project.id),
      ]))
    let journal = MCPExecutionJournal(database: database, scope: scope)
    _ = try journal.reserve(
      server: server, tool: "metadata", arguments: .object([:]), requestID: "owned",
      executionID: execution.id)
    _ = try journal.reserve(
      server: server, tool: "metadata", arguments: .object([:]), requestID: "unbound",
      executionID: nil)
    for id in ["owned", "unbound"] {
      try journal.update(serverID: server.id, requestID: id) {
        try $0.finish(result: .object(["content": .array([])]), failed: false)
      }
    }
    func receiptContext(principal: String, list: Bool = false) throws -> InvocationContext {
      let tool = list ? "mcp.requests.list" : "mcp.requests.read"
      let requirements = InvocationRequirements(mode: .sandbox)
      let decision = try runtime.service.admit(
        subject: GatewayPermissionSubject(context: executionContext(principal: principal)),
        tool: tool, projectID: "fixture", argumentsDigest: "receipt-selector",
        requirements: requirements)
      guard case .allowed(let receipt) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      let descriptor = CapabilityDescriptor(
        id: tool, risk: .readOnly,
        requirement: .init(access: .none, execution: list ? .list : .read(argument: "request_id")),
        projectRequirement: .none, localOnly: false, usesNetwork: false)
      return InvocationContext(
        resolvedInvocation: .init(
          descriptor: descriptor, identity: receipt.invocation, requirements: requirements,
          pluginOrigins: []),
        admission: .init(descriptor: descriptor),
        executionAuthority: try runtime.coordinator.continuation(authorizationID: receipt.id))
    }
    func client(principal: String) -> AuthorizedMCPClient {
      AuthorizedMCPClient(
        base: MCPProxyClient(launcher: platform.launcher, hostContext: host(principal: principal)),
        policy: .init(configuration: configuration, grant: profile))
    }
    let first = client(principal: "verified-first")
    let second = client(principal: "verified-second")
    let reconnected = client(principal: "verified-first")
    let firstProof = try receiptContext(principal: "verified-first")
    let secondProof = try receiptContext(principal: "verified-second")
    do {
      #expect(throws: (any Error).self) {
        try first.readRequest(
          server: server, requestID: "owned", offset: 0, maxBytes: 4096, context: .empty)
      }
      let result = try first.readRequest(
        server: server, requestID: "owned", offset: 0, maxBytes: 4096, context: firstProof)
      #expect(result.objectValue?["state"] == .string("succeeded"))
      #expect(
        try reconnected.readRequest(
          server: server, requestID: "owned", offset: 0, maxBytes: 4096,
          context: receiptContext(principal: "verified-first")) == result)
      #expect(throws: (any Error).self) {
        try second.readRequest(
          server: server, requestID: "owned", offset: 0, maxBytes: 4096, context: secondProof)
      }
      #expect(throws: (any Error).self) {
        try first.readRequest(
          server: server, requestID: "owned", offset: 0, maxBytes: 4096, context: secondProof)
      }
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try first.readRequest(
          server: server, requestID: "unbound", offset: 0, maxBytes: 4096, context: firstProof)
      }
      #expect(
        try first.activeRequests(
          server: server, context: receiptContext(principal: "verified-first", list: true)
        ).objectValue?["requests"] == .array([]))
      #expect(throws: (any Error).self) {
        try first.callTool(
          server: server, name: "metadata", arguments: .object([:]), context: firstProof)
      }
      #expect(
        try control.view().profiles.first { $0.id == .chatGPTOperate }?.permissions.state(
          for: .mcpServer("fixture")) == .notGranted)
      _ = try control.revokePermission(
        .mcpServer("fixture"), profileID: .chatGPTOperate, expectedRevision: control.view().revision
      )
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try reconnected.readRequest(
          server: server, requestID: "owned", offset: 0, maxBytes: 4096, context: firstProof)
      }
      await first.shutdown()
      await second.shutdown()
      await reconnected.shutdown()
    } catch {
      await first.shutdown()
      await second.shutdown()
      await reconnected.shutdown()
      throw error
    }
  }

}

private struct PermissionFixture {
  static let attribute = "com.computer-mcp.permission-fixture"
  let root: URL
  let file: URL
  let database: GatewayDatabase
  let gateway: GatewayRuntime
  let http: GatewayHTTPRuntime
  let control: PermissionControlService
  let reader = TestManagedPolicyReader()

  var target: [String: JSONValue] {
    [
      "project_id": .string("fixture"), "path": .string("value.txt"),
      "name": .string(Self.attribute), "dry_run": .bool(false),
    ]
  }

  init(projectState: PermissionState = .granted(.read)) throws {
    root = URL(fileURLWithPath: "/private/tmp/cm-permission-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    file = root.appendingPathComponent("value.txt")
    try Data("original".utf8).write(to: file)
    let data = Data("reviewed attribute".utf8)
    let attributePath = file.path
    let result = data.withUnsafeBytes {
      setxattr(attributePath, Self.attribute, $0.baseAddress, $0.count, 0, 0)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    database = try fixturePermissionDatabase(path: root.appendingPathComponent("state.sqlite").path)
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate,
      permissions: fixturePermissions([.project("fixture"): projectState]),
      fullAccess: true, allowedCallers: [.secureTunnel])
    try database.saveProfile(profile.grant)
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    let nonGit = try fixtureNonGitProject(root: root)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate), profiles: [profile],
      cli: .init(commands: [nonGit.git]),
      builtin: .init(enabled: ["file.remove_xattr", "file.write"]), projectDirectory: root)
    var platform = nonGit.platform
    platform.permissionPolicyReader = reader
    let permissionService = try database.permissionRuntime(platform: platform).service
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "fixture-owner"),
      validate: {})
    control = PermissionControlService(service: permissionService, owner: { owner })
    gateway = try GatewayRuntime(
      configuration: configuration, database: database,
      registeredProjects: [project], platform: platform)
    http = GatewayHTTPRuntime(
      configuration: configuration, registry: gateway, host: "127.0.0.1", port: 0,
      publicBaseURL: nil, accessToken: "permission-lifecycle-fixture")
  }

  func connect() async throws -> GatewayClientSession {
    let port = try #require(await http.boundPort())
    let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
    let previous = Set(await http.controlSessions().map(\.id))
    let client = try await GatewayClientSession.connectHTTP(
      endpoint: endpoint, accessToken: "permission-lifecycle-fixture")
    let session = try #require(await http.controlSessions().first { !previous.contains($0.id) })
    _ = try await http.approveControlSession(
      id: session.id, lifetime: .thisSession, expectedRevision: session.revision,
      expectedTrustRevision: 0)
    return client
  }

  func answer(_ ids: [UUID], _ answer: PermissionAnswer) throws {
    for id in ids {
      _ = try control.answerRequest(id, answer: answer, expectedRevision: control.view().revision)
    }
  }

  func retry(
    _ client: GatewayClientSession, tool: String = "file.remove_xattr",
    arguments: [String: JSONValue]? = nil, ids: [UUID]
  ) async throws -> GatewayCallReport {
    var arguments = arguments ?? target
    arguments["_permission_request_ids"] = .array(ids.map { .string($0.uuidString) })
    return try await client.call(toolName: tool, arguments: .object(arguments))
  }

  func hasAttribute() -> Bool { getxattr(file.path, Self.attribute, nil, 0, 0, 0) >= 0 }
  func replaceAttribute(with value: String) throws {
    let data = Data(value.utf8)
    let result = data.withUnsafeBytes {
      setxattr(file.path, Self.attribute, $0.baseAddress, $0.count, 0, 0)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
  func removeFiles() { try? FileManager.default.removeItem(at: root) }
}
