import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPApp

struct MCPRegistrationDraftTests {
  @Test
  func authenticationBindingSurvivesBothEditors() throws {
    let binding = MCPHTTPAuthentication(
      endpoint: "https://example.test/mcp", keychainAccount: "mcp.test")
    let server = MCPServerConfig(
      id: "remote", transport: .streamableHTTP, url: binding.endpoint, authentication: binding)
    #expect(try MCPRegistrationDraft(server: server).value().authentication == binding)
    #expect(
      PluginMCPDraft(id: "remote", settings: .init(authentication: binding)).value.authentication
        == binding)
  }
  @Test
  func draftRetainsExactLaunchAndPolicySettings() throws {
    let server = MCPServerConfig(
      id: "manual", transport: .stdio, command: "/tmp/My MCP/执行",
      args: ["", "含 空格", "a\nb", "--", "-1"], env: ["FIXTURE": "a\nb"], cwd: "workspace",
      exposure: .reexport, prefix: "", capabilities: ["tools", "resources"],
      allowedTools: ["inspect", "工具"], startupTimeoutMs: 987, requestTimeoutMs: 456,
      toolRisks: ["inspect": .readOnly], hostServices: true, enabled: false)
    var draft = MCPRegistrationDraft(server: server)
    #expect(try draft.value() == server)
    draft.server.allowAnyTool = true
    #expect(try draft.value().allowedTools.isEmpty)
    #expect(try draft.value().toolRisks == server.toolRisks)
    draft.argumentsJSON = #"["good", 3]"#
    #expect(throws: DecodingError.self) { try draft.value() }
  }
}

@MainActor
struct MCPRegistrationModelTests {
  @Test(arguments: [false, true])
  func processRecoveryUsesReviewedScopeAndNeverProbesOrRetries(fails: Bool) async throws {
    let host = MCPRegistrationControlFake()
    host.failRecovery = fails
    let model = MCPRegistrationModel(controlPlane: host)
    await model.checkConnection(id: "manual", workspaceID: "fixture")
    let receipt = try #require(model.doctorReport?.processReceipts?.first)
    await model.recoverProcess(id: "other", workspaceID: "fixture", receipt: receipt)
    await model.recoverProcess(id: "manual", workspaceID: "other", receipt: receipt)
    #expect(host.recoveryRequests.isEmpty)
    await model.recoverProcess(id: "manual", workspaceID: "fixture", receipt: receipt)
    await model.recoverProcess(id: "manual", workspaceID: "fixture", receipt: receipt)
    #expect(
      host.recoveryRequests == [["manual", "fixture", "receipt", "receipt-digest", "digest"]])
    #expect(host.doctorRequests == ["manual:fixture"])
    #expect(model.doctorReport == nil && !model.isBusy)
    #expect(model.processRecovered == !fails)
    #expect((model.errorMessage != nil) == fails)
  }

  @Test
  func connectionFailureClearsOldSuccessAndDoesNotApplyChanges() async {
    let host = MCPRegistrationControlFake()
    let model = MCPRegistrationModel(controlPlane: host)
    await model.checkConnection(id: "manual", workspaceID: "first")
    #expect(model.doctorReport?.workspaceID == "first")
    host.failDoctor = true
    await model.checkConnection(id: "manual", workspaceID: "second")
    #expect(model.doctorReport == nil && model.errorMessage != nil && !model.isBusy)
    #expect(host.doctorRequests == ["manual:first", "manual:second"])
    #expect(host.appliedDigests.isEmpty)
  }

  @Test
  func credentialChangesUseReviewedBindingAndClearFailures() async {
    let host = MCPRegistrationControlFake()
    let model = MCPRegistrationModel(controlPlane: host)
    await model.loadCredential(id: "remote")
    #expect(model.credentialStatus?.present == false)
    #expect(await model.saveCredential(id: "other", token: "fixture") == false)
    #expect(await model.saveCredential(id: "remote", token: "fixture"))
    #expect(model.credentialStatus?.present == true)
    host.failCredential = true
    #expect(await model.saveCredential(id: "remote", token: nil) == false)
    #expect(await model.saveCredential(id: "remote", token: nil) == false)
    #expect(host.credentialRequests == ["binding", "binding"])
    #expect(model.credentialStatus == nil && model.errorMessage != nil && !model.isBusy)
  }

  @Test
  func pendingReviewPreventsConnectionProbe() async {
    let host = MCPRegistrationControlFake()
    let model = MCPRegistrationModel(controlPlane: host)
    #expect(await model.review(.add(host.server)))
    await model.checkConnection(id: "manual", workspaceID: "fixture")
    #expect(host.doctorRequests.isEmpty && model.preview != nil)
  }

  @Test
  func reviewDoesNotApplyAndApplyUsesTheReviewedDigest() async throws {
    let host = MCPRegistrationControlFake()
    let model = MCPRegistrationModel(controlPlane: host)
    #expect(await model.review(.add(host.server)))
    #expect(host.appliedDigests.isEmpty && model.preview != nil)
    await model.apply()
    #expect(host.appliedDigests == ["reviewed-digest"])
    #expect(model.preview == nil && model.errorMessage == nil && !model.isBusy)
    #expect(model.snapshot?.registrations.first?.server == host.server)
  }

  @Test
  func failedReplacementPreviewCannotApplyThePreviousChange() async {
    let host = MCPRegistrationControlFake()
    let model = MCPRegistrationModel(controlPlane: host)
    #expect(await model.review(.add(host.server)))
    host.failReview = true
    #expect(await model.review(.remove(id: host.server.id)) == false)
    #expect(model.preview == nil && model.errorMessage != nil)
    await model.apply()
    #expect(host.appliedDigests.isEmpty)
  }

  @Test
  func staleApplyClearsReviewAndDoesNotRetry() async {
    let host = MCPRegistrationControlFake()
    let model = MCPRegistrationModel(controlPlane: host)
    #expect(await model.review(.add(host.server)))
    host.failApply = true
    await model.apply()
    await model.apply()
    #expect(host.appliedDigests == ["reviewed-digest"])
    #expect(model.preview == nil && model.errorMessage != nil && !model.isBusy)
    #expect(model.snapshot == nil)
  }
}

@MainActor
private final class MCPRegistrationControlFake: MCPRegistrationManaging {
  let server = MCPServerConfig(id: "manual", transport: .stdio, command: "/bin/cat", enabled: false)
  var appliedDigests: [String?] = []
  var failReview = false
  var failApply = false
  var failDoctor = false
  var doctorRequests: [String] = []
  var credentialRequests: [String] = []
  var credentialPresent = false
  var failCredential = false
  var failRecovery = false
  var recoveryRequests: [[String]] = []

  func recoverMCPProcessReceipt(
    id: String, workspaceID: String, receiptID: String, expectedReceiptDigest: String,
    expectedCurrentDigest: String
  ) async throws {
    recoveryRequests.append([
      id, workspaceID, receiptID, expectedReceiptDigest, expectedCurrentDigest,
    ])
    if failRecovery { throw AtomicManifestStoreError.staleDigest }
  }

  func mcpCredentialStatus(id: String) async throws -> MCPRegistrationCredentialStatus {
    if failCredential { throw AtomicManifestStoreError.staleDigest }
    return .init(
      registrationID: id,
      authentication: .init(endpoint: "https://example.test/mcp", keychainAccount: "mcp.test"),
      bindingDigest: "binding", present: credentialPresent)
  }
  func changeMCPCredential(id: String, expectedBindingDigest: String, token: String?) async throws {
    credentialRequests.append(expectedBindingDigest)
    if failCredential { throw AtomicManifestStoreError.staleDigest }
    credentialPresent = token != nil
  }

  func doctorMCPRegistration(id: String, workspaceID: String) async throws
    -> MCPRegistrationDoctorReport
  {
    doctorRequests.append("\(id):\(workspaceID)")
    if failDoctor { throw GatewayToolError.unknownMCPServer(id) }
    return .init(
      registrationID: id, workspaceID: workspaceID, currentDigest: "digest",
      checkedAt: Date(), status: .passed, stage: "connection_and_catalog",
      processReceipts: [
        .init(
          id: "receipt", digest: "receipt-digest", ownerPID: nil,
          state: "cleanup_failed", recoverable: true, blocksLaunch: true)
      ], message: "Fixture result"
    )
  }

  func fetchMCPRegistrations() async throws -> MCPRegistrationSnapshot {
    .init(currentDigest: "applied-digest", registrations: [.init(server: server, origin: nil)])
  }

  func changeMCPRegistration(
    _ change: MCPRegistrationChange, apply: Bool, expectedCurrentDigest: String?
  ) async throws -> MCPRegistrationChangePreview {
    if apply {
      appliedDigests.append(expectedCurrentDigest)
      if failApply { throw AtomicManifestStoreError.staleDigest }
    } else if failReview {
      throw GatewayToolError.unknownMCPServer(change.id)
    }
    return .init(
      id: change.id, currentDigest: "reviewed-digest", proposedDigest: "next-digest", before: nil,
      after: server)
  }
}
