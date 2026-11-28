import ComputerMCPCore
import ComputerMCPPermissions
import Foundation
import Testing

struct GatewayPolicyTests {
  private let profileID = GatewayProfileID(rawValue: "client")!
  private var tool: CapabilityDescriptor {
    CapabilityDescriptor(
      id: "file.read", risk: .readOnly, requirement: .none,
      projectRequirement: .required)
  }

  @Test
  func authenticatedBoundaryLeavesPermissionAdmissionToTheLedger() {
    let grant = ProfileGrant(id: profileID, allowedCallers: [.localMCP])
    let context = ExecutionContext(caller: .localMCP, profileID: profileID, projectID: "project")
    #expect(
      GatewayPolicyEvaluator().evaluate(
        capability: tool, context: context,
        grant: grant, registeredProjectIDs: ["project"]) == .allow)
    #expect(grant.permissions.entries.isEmpty)
    #expect(!grant.fullAccess)
  }

  @Test
  func callerAndProfileIdentityMustMatch() {
    let grant = ProfileGrant(id: profileID, allowedCallers: [.localMCP])
    let wrongCaller = ExecutionContext(
      caller: .secureTunnel, profileID: profileID, projectID: "project")
    let wrongProfile = ExecutionContext(
      caller: .localMCP, profileID: .chatGPTOperate, projectID: "project")
    let evaluator = GatewayPolicyEvaluator()
    guard
      case .deny(let callerCode, _) = evaluator.evaluate(
        capability: tool, context: wrongCaller,
        grant: grant, registeredProjectIDs: ["project"]),
      case .deny(let profileCode, _) = evaluator.evaluate(
        capability: tool, context: wrongProfile,
        grant: grant, registeredProjectIDs: ["project"])
    else {
      Issue.record("Identity mismatch was admitted")
      return
    }
    #expect(callerCode == .callerDenied)
    #expect(profileCode == .profileMismatch)
  }

  @Test
  func requiredProjectsMustBeExplicitAndRegistered() {
    let grant = ProfileGrant(id: profileID, allowedCallers: [.localMCP])
    let missing = ExecutionContext(caller: .localMCP, profileID: profileID)
    let unknown = ExecutionContext(caller: .localMCP, profileID: profileID, projectID: "unknown")
    let evaluator = GatewayPolicyEvaluator()
    guard
      case .deny(let missingCode, _) = evaluator.evaluate(
        capability: tool, context: missing,
        grant: grant, registeredProjectIDs: ["project"]),
      case .deny(let unknownCode, _) = evaluator.evaluate(
        capability: tool, context: unknown,
        grant: grant, registeredProjectIDs: ["project"])
    else {
      Issue.record("Invalid project routing was admitted")
      return
    }
    #expect(missingCode == .projectRequired)
    #expect(unknownCode == .projectDenied)
  }

  @Test
  func localAdministrationAndLocalToolsRemainLocal() {
    let evaluator = GatewayPolicyEvaluator()
    let admin = ProfileGrant(id: .localAdmin, allowedCallers: [.secureTunnel])
    let remote = ExecutionContext(
      caller: .secureTunnel, profileID: .localAdmin, projectID: "project")
    guard
      case .deny(let adminCode, _) = evaluator.evaluate(
        capability: tool, context: remote,
        grant: admin, registeredProjectIDs: ["project"])
    else {
      Issue.record("Remote administration was admitted")
      return
    }
    #expect(adminCode == .localAdminRemote)
    var local = tool
    local.localOnly = true
    let client = ProfileGrant(id: profileID, allowedCallers: [.secureTunnel])
    let clientContext = ExecutionContext(
      caller: .secureTunnel, profileID: profileID, projectID: "project")
    guard
      case .deny(let localCode, _) = evaluator.evaluate(
        capability: local, context: clientContext,
        grant: client, registeredProjectIDs: ["project"])
    else {
      Issue.record("Local-only tool was admitted")
      return
    }
    #expect(localCode == .localOnly)
  }

  @Test
  func newPrincipalDefaultsRemainDistinctFromExplicitStoredProfiles() {
    let fresh = ProfileGrant.newPrincipal(id: profileID, allowedCallers: [.localMCP])
    let stored = ProfileGrant(id: profileID, allowedCallers: [.localMCP])
    #expect(fresh.permissions.state(for: .machineInformation) == .granted(.access))
    #expect(fresh.permissions.state(for: .skills) == .granted(.access))
    #expect(fresh.permissions.state(for: .screen) == .notGranted)
    #expect(stored.permissions.entries.isEmpty)
  }

  @Test
  func trustedPrincipalSurvivesReconnectAndOldContextDecodes() throws {
    let first = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate,
      transportTrace: .init(transport: "gateway_socket", socketConnectionID: "first"),
      trustedPrincipalID: "registered-client")
    var reconnected = first
    reconnected.transportTrace?.socketConnectionID = "second"
    #expect(first.principalID == reconnected.principalID)
    let oldJSON = #"{"requestID":"r","caller":"local-mcp","profileID":"client"}"#
    let decoded = try JSONDecoder().decode(ExecutionContext.self, from: Data(oldJSON.utf8))
    #expect(decoded.trustedPrincipalID == nil)
    #expect(decoded.principalID == "local-mcp:client")
  }
}
