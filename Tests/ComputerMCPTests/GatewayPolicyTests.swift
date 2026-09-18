import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class GatewayPolicyTests {
  private let evaluator = GatewayPolicyEvaluator()

  @Test
  func testReadOnlyModeCannotEnableFullShell() {
    let grant = ProfileGrant(
      id: .chatGPTObserve,
      capabilityIDs: ["shell.run"],
      allowedCallers: [.secureTunnel],
      fullShellEnabled: true
    )

    expectThrows(try grant.validate()) { error in
      #expect((error as? GatewayPolicyConfigurationError) == (.fullShellRequiresFullAccess))
    }
  }

  @Test
  func testFullAccessModeCanEnableFullShell() throws {
    let grant = ProfileGrant(
      id: .chatGPTOperate,
      capabilityIDs: ["shell.run"],
      allowedCallers: [.secureTunnel],
      fullShellEnabled: true,
      mode: .localFullAccess
    )

    try grant.validate()
  }

  @Test
  func testPersistedOperateFullShellStateSurvivesManifestOverlay() {
    let manifest = ProfileGrant(
      id: .chatGPTOperate,
      capabilityIDs: ["file.write"],
      workspaceIDs: [],
      allowedCallers: [.secureTunnel],
      mode: .workspaceOperations
    )
    let persisted = ProfileGrant(
      id: .chatGPTOperate,
      capabilityIDs: ["shell.run"],
      workspaceIDs: ["primary"],
      allowedCallers: [.secureTunnel],
      fullShellEnabled: true,
      mode: .localFullAccess,
      confirmationPolicy: .allWrites,
      authorizationRevision: 0
    )

    let effective = manifest.applyingPersistedRuntimeState(persisted)

    #expect(
      effective.capabilityIDs
        == Set(["file.write"]).union(ProfileGrant.fullShellCapabilities)
    )
    #expect((effective.workspaceIDs) == (["primary"]))
    #expect(effective.fullShellEnabled)
    #expect(effective.mode == .localFullAccess)
    #expect(effective.confirmationPolicy == .allWrites)
    #expect(effective.authorizationRevision == 0)
  }

  @Test
  func testSavedAuthorizationReplacesAllPermissionFields() {
    let id = GatewayProfileID(rawValue: "custom-client")!
    let manifest = ProfileGrant(
      id: id, capabilityIDs: ["file.write"], workspaceIDs: ["one"],
      allowedCallers: [.secureTunnel], mcpServerIDs: ["first"], mode: .workspaceOperations)
    let saved = ProfileGrant(
      id: id, capabilityIDs: ["file.read"], workspaceIDs: ["two"],
      allowedCallers: [.cloudflareTunnel], mcpServerIDs: ["second"],
      mode: .readOnly, confirmationPolicy: .allWrites, authorizationRevision: 3)
    #expect(manifest.applyingPersistedRuntimeState(saved) == saved)
  }

  @Test
  func testLocalAdminCannotBeUsedByTunnelCaller() {
    let capability = CapabilityDescriptor(id: "file.read", risk: .readOnly)
    let context = ExecutionContext(caller: .secureTunnel, profileID: .localAdmin)

    #expect(
      (evaluator.evaluate(
        capability: capability,
        context: context,
        grant: .localAdmin,
        registeredWorkspaceIDs: []
      ))
        == (.deny(
          code: .localAdminRemote,
          message: "local-admin is available only to local callers."
        )))
  }

  @Test
  func testRequiredWorkspaceMustBeExplicitAndGranted() {
    let capability = CapabilityDescriptor(
      id: "file.write",
      risk: .workspaceWrite,
      workspaceRequirement: .required
    )
    let grant = ProfileGrant(
      id: .chatGPTOperate,
      capabilityIDs: ["file.write"],
      workspaceIDs: ["alpha"],
      allowedCallers: [.secureTunnel],
      mode: .workspaceOperations
    )

    let missing = evaluator.evaluate(
      capability: capability,
      context: ExecutionContext(caller: .secureTunnel, profileID: .chatGPTOperate),
      grant: grant,
      registeredWorkspaceIDs: ["alpha", "beta"]
    )
    #expect(
      (missing)
        == (.deny(code: .workspaceRequired, message: "An explicit workspace_id is required.")))

    let allowed = evaluator.evaluate(
      capability: capability,
      context: ExecutionContext(
        caller: .secureTunnel,
        profileID: .chatGPTOperate,
        workspaceID: "alpha"
      ),
      grant: grant,
      registeredWorkspaceIDs: ["alpha", "beta"]
    )
    #expect((allowed) == (.allow))
  }

  @Test
  func testFullShellRequiresProfileEnablement() {
    let capability = CapabilityDescriptor(id: "shell.run", risk: .fullShell)
    let context = ExecutionContext(caller: .localMCP, profileID: .localAdmin)
    let disabled = ProfileGrant(
      id: .localAdmin,
      capabilityIDs: ["shell.run"],
      allowedCallers: [.localMCP],
      mode: .localFullAccess
    )

    #expect(
      (evaluator.evaluate(
        capability: capability,
        context: context,
        grant: disabled,
        registeredWorkspaceIDs: []
      ))
        == (.deny(
          code: .fullShellDisabled,
          message:
            "Arbitrary execution requires local-full-access mode and separate Full Shell permission."
        )))

    var enabled = disabled
    enabled.fullShellEnabled = true
    #expect(
      (evaluator.evaluate(
        capability: capability,
        context: context,
        grant: enabled,
        registeredWorkspaceIDs: []
      )) == (.allow))
  }

  @Test
  func testNewGrantDoesNotAuthorizeWritesOrExecution() {
    let profileID = GatewayProfileID(rawValue: "new-client")!
    let grant = ProfileGrant(id: profileID, capabilityIDs: ["*"], allowedCallers: [.localMCP])
    #expect(grant.mode == .readOnly)
    #expect(grant.confirmationPolicy == .riskBased)
    #expect(!grant.fullShellEnabled)
    #expect(!grant.permitsRisk(.workspaceWrite))
    #expect(!grant.permitsRisk(.externalWrite))
    #expect(!grant.permitsRisk(.destructive))
    #expect(!grant.permitsRisk(.fullShell))
  }

  @Test(arguments: [GatewayCallerKind.secureTunnel, .cloudflareTunnel, .localMCP])
  func testModeIsIndependentOfProfileNameAndChannel(caller: GatewayCallerKind) throws {
    for profileID in [
      GatewayProfileID.chatGPTObserve, .cloudflareObserve,
      GatewayProfileID(rawValue: "custom-client")!,
    ] {
      let grant = ProfileGrant(
        id: profileID, capabilityIDs: ["file.write", "shell.run"],
        allowedCallers: [caller], fullShellEnabled: true, mode: .localFullAccess)
      try grant.validate()
      let context = ExecutionContext(caller: caller, profileID: profileID)
      for capability in [
        CapabilityDescriptor(id: "file.write", risk: .workspaceWrite),
        CapabilityDescriptor(id: "shell.run", risk: .fullShell),
      ] {
        #expect(
          evaluator.evaluate(
            capability: capability, context: context, grant: grant, registeredWorkspaceIDs: [])
            == .allow)
      }
    }
  }

  @Test
  func testWorkspaceModeDoesNotAuthorizeArbitraryExecution() {
    let profileID = GatewayProfileID(rawValue: "workspace-client")!
    let grant = ProfileGrant(
      id: profileID, capabilityIDs: ["shell.run"], allowedCallers: [.localMCP],
      fullShellEnabled: true, mode: .workspaceOperations)
    #expect(throws: GatewayPolicyConfigurationError.fullShellRequiresFullAccess) {
      try grant.validate()
    }
    #expect(
      !evaluator.evaluate(
        capability: .init(id: "shell.run", risk: .fullShell),
        context: .init(caller: .localMCP, profileID: profileID), grant: grant,
        registeredWorkspaceIDs: []
      ).isAllowed)
  }

  @Test
  func testExplicitReadOnlyModeAppliesToOperateNames() {
    let grant = ProfileGrant(
      id: .chatGPTOperate, capabilityIDs: ["file.write"], allowedCallers: [.secureTunnel],
      mode: .readOnly)
    #expect(
      !evaluator.evaluate(
        capability: .init(id: "file.write", risk: .workspaceWrite),
        context: .init(caller: .secureTunnel, profileID: .chatGPTOperate), grant: grant,
        registeredWorkspaceIDs: []
      ).isAllowed)
  }

  @Test
  func testConfirmationPoliciesDoNotGrantCapabilities() {
    let risks: [CapabilityRisk] = [
      .readOnly, .workspaceWrite, .externalWrite, .destructive, .fullShell,
    ]
    #expect(
      risks.map(GatewayConfirmationPolicy.riskBased.requiresConfirmation) == [
        false, false, true, true, true,
      ])
    #expect(
      risks.map(GatewayConfirmationPolicy.allWrites.requiresConfirmation) == [
        false, true, true, true, true,
      ])
    #expect(risks.allSatisfy { !GatewayConfirmationPolicy.never.requiresConfirmation(for: $0) })
    let profileID = GatewayProfileID(rawValue: "client")!
    let grant = ProfileGrant(
      id: profileID, capabilityIDs: [], allowedCallers: [.localMCP],
      mode: .localFullAccess, confirmationPolicy: .never)
    #expect(
      !evaluator.evaluate(
        capability: .init(id: "file.write", risk: .workspaceWrite),
        context: .init(caller: .localMCP, profileID: profileID), grant: grant,
        registeredWorkspaceIDs: []
      ).isAllowed)
  }

  @Test
  func testToolWildcardDoesNotGrantWorkspaces() {
    let id = GatewayProfileID(rawValue: "client")!
    var grant = ProfileGrant(
      id: id, capabilityIDs: ["*"], allowedCallers: [.localMCP], mode: .workspaceOperations)
    let capability = CapabilityDescriptor(
      id: "file.write", risk: .workspaceWrite, workspaceRequirement: .required)
    let context = ExecutionContext(caller: .localMCP, profileID: id, workspaceID: "one")
    #expect(
      !evaluator.evaluate(
        capability: capability, context: context, grant: grant, registeredWorkspaceIDs: ["one"]
      ).isAllowed)
    grant.workspaceIDs = ["*"]
    #expect(
      evaluator.evaluate(
        capability: capability, context: context, grant: grant, registeredWorkspaceIDs: ["one"]
      ).isAllowed)
    #expect(
      !evaluator.evaluate(
        capability: capability, context: context, grant: grant, registeredWorkspaceIDs: []
      ).isAllowed)
  }

  @Test
  func testTrustedPrincipalSurvivesReconnectAndOldContextDecodes() throws {
    let first = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate,
      transportTrace: .init(transport: "gateway_socket", socketConnectionID: "first"),
      trustedPrincipalID: "registered-client")
    var reconnected = first
    reconnected.transportTrace?.socketConnectionID = "second"
    #expect(first.principalID == reconnected.principalID)
    #expect(first.principalID == "registered-client")
    let oldJSON = #"{"requestID":"r","caller":"local-mcp","profileID":"client"}"#
    let decoded = try JSONDecoder().decode(ExecutionContext.self, from: Data(oldJSON.utf8))
    #expect(decoded.trustedPrincipalID == nil)
    #expect(decoded.principalID == "local-mcp:client")
  }
}
