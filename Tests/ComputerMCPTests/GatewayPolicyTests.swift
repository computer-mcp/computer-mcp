import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class GatewayPolicyTests {
  private let evaluator = GatewayPolicyEvaluator()

  @Test
  func testObserveCannotEnableFullShell() {
    let grant = ProfileGrant(
      id: .chatGPTObserve,
      capabilityIDs: ["shell.run"],
      allowedCallers: [.secureTunnel],
      fullShellEnabled: true
    )

    expectThrows(try grant.validate()) { error in
      #expect((error as? GatewayPolicyConfigurationError) == (.observeCannotEnableFullShell))
    }
  }

  @Test
  func testOperateCanEnableFullShell() throws {
    let grant = ProfileGrant(
      id: .chatGPTOperate,
      capabilityIDs: ["shell.run"],
      allowedCallers: [.secureTunnel],
      fullShellEnabled: true
    )

    try grant.validate()
  }

  @Test
  func testPersistedOperateFullShellStateSurvivesManifestOverlay() {
    let manifest = ProfileGrant(
      id: .chatGPTOperate,
      capabilityIDs: ["file.write"],
      workspaceIDs: [],
      allowedCallers: [.secureTunnel]
    )
    let persisted = ProfileGrant(
      id: .chatGPTOperate,
      capabilityIDs: ["shell.run"],
      workspaceIDs: ["primary"],
      allowedCallers: [.secureTunnel],
      fullShellEnabled: true
    )

    let effective = manifest.applyingPersistedRuntimeState(persisted)

    #expect(
      effective.capabilityIDs
        == Set(["file.write"]).union(ProfileGrant.fullShellCapabilities)
    )
    #expect((effective.workspaceIDs) == (["primary"]))
    #expect(effective.fullShellEnabled)
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
      allowedCallers: [.secureTunnel]
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
      allowedCallers: [.localMCP]
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
          message: "Full Shell must be enabled for the active profile in Computer MCP."
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
}
