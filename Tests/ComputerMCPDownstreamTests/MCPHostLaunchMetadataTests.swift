import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPDownstream

struct MCPHostLaunchMetadataTests {
  @Test(arguments: [false, true], [false, true])
  func encodingPreservesHostLaunchJSONSemantics(traced: Bool, managed: Bool) throws {
    let runtimeID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let context = ExecutionContext(
      caller: .localMCP, profileID: .chatGPTOperate,
      transportTrace: traced
        ? .init(
          transport: "gateway_socket", socketConnectionID: "connection",
          tunnelInstanceID: "tunnel-instance", tunnelProfileID: "tunnel-profile") : nil,
      trustedPrincipalID: "host-principal")
    let root = URL(fileURLWithPath: "/tmp/项目 / project")
    let managedRoot = managed ? URL(fileURLWithPath: "/tmp/managed/../projects") : nil
    let metadata = MCPHostLaunchMetadata(
      runtimeID: runtimeID, context: context, projectID: "project", rootURL: root,
      readOnly: !managed, managedProjectRoot: managedRoot)
    let legacy = LegacyHostLaunchContext(
      runtimeID: runtimeID, caller: context.caller, profileID: context.profileID,
      project: .init(id: "project", rootPath: root.path), readOnly: !managed,
      transportTrace: context.transportTrace,
      managedProjectRoot: managedRoot?.standardizedFileURL.path,
      principalID: context.principalID)
    let expected = try JSONDecoder().decode(
      [String: JSONValue].self, from: JSONEncoder().encode(legacy))
    let actual = try JSONDecoder().decode(
      [String: JSONValue].self, from: JSONEncoder().encode(metadata))
    #expect(actual == expected)
    let environment = try MCPHostLaunchMetadata.launchEnvironment(
      inherited: [:], overrides: [:], context: metadata)
    let wire = try #require(environment[MCPHostLaunchMetadata.environmentKey])
    let environmentValue = try JSONDecoder().decode(
      [String: JSONValue].self, from: Data(wire.utf8))
    #expect(environmentValue == expected)
  }

  @Test(arguments: [false, true])
  func hostKeysAreStrippedBeforeTrustedMetadataIsApplied(scoped: Bool) throws {
    let keys = [
      MCPHostLaunchMetadata.environmentKey, MCPHostLaunchMetadata.descriptorEnvironmentKey,
      MCPHostLaunchMetadata.readHandleEnvironmentKey,
      MCPHostLaunchMetadata.writeHandleEnvironmentKey,
    ]
    let inherited = Dictionary(uniqueKeysWithValues: keys.map { ($0, "ancestor") })
      .merging(["KEEP": "inherited", "REPLACE": "inherited"]) { _, value in value }
    let overrides = Dictionary(uniqueKeysWithValues: keys.map { ($0, "registration") })
      .merging(["EMPTY": "", "REPLACE": "registration"]) { _, value in value }
    let metadata = makeMetadata()
    let environment = try MCPHostLaunchMetadata.launchEnvironment(
      inherited: inherited, overrides: overrides, context: scoped ? metadata : nil)
    #expect(environment["KEEP"] == "inherited")
    #expect(environment["EMPTY"] == "")
    #expect(environment["REPLACE"] == "registration")
    for key in keys.dropFirst() { #expect(environment[key] == nil) }
    if scoped {
      let wire = try #require(environment[MCPHostLaunchMetadata.environmentKey])
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8))
      #expect(value.objectValue?["caller"] == .string("local-cli"))
      #expect(value.objectValue?["runtimeID"] == .string(metadata.runtimeID.uuidString))
      #expect(value.objectValue?["principalID"] == .string("local-cli:local-admin"))
      #expect(
        Set(try #require(value.objectValue).keys) == [
          "formatVersion", "runtimeID", "caller", "profileID", "workspace", "readOnly",
          "principalID",
        ])
    } else {
      #expect(environment[MCPHostLaunchMetadata.environmentKey] == nil)
    }
  }

  @Test
  func metadataLimitCountsEncodedUTF8BytesAndAllowsExactly16KiB() throws {
    let overhead = try JSONEncoder().encode(makeMetadata(projectID: "")).count
    let limit = 16_384 - overhead
    let metadata = makeMetadata(projectID: String(repeating: "x", count: limit))
    let environment = try MCPHostLaunchMetadata.launchEnvironment(
      inherited: [:], overrides: [:], context: metadata)
    #expect(environment[MCPHostLaunchMetadata.environmentKey]?.utf8.count == 16_384)
    for projectID in [
      String(repeating: "x", count: limit + 1), String(repeating: "界", count: limit),
    ] {
      #expect(
        throws: GatewayToolError.executionFailed("Downstream MCP host context exceeds 16 KiB.")
      ) {
        try MCPHostLaunchMetadata.launchEnvironment(
          inherited: [:], overrides: [:], context: makeMetadata(projectID: projectID))
      }
    }
  }

  private func makeMetadata(projectID: String = "project") -> MCPHostLaunchMetadata {
    .init(
      runtimeID: UUID(), context: .init(caller: .localCLI, profileID: .localAdmin),
      projectID: projectID, rootURL: URL(fileURLWithPath: "/tmp"), readOnly: false)
  }
}

/// The host launch wire contract, including its original optional-field encoding.
private struct LegacyHostLaunchContext: Encodable {
  struct Project: Encodable {
    let id: String
    let rootPath: String
  }
  let formatVersion = 1
  let runtimeID: UUID
  let caller: GatewayCallerKind
  let profileID: GatewayProfileID
  let project: Project
  let readOnly: Bool
  let transportTrace: GatewayTransportTrace?
  let managedProjectRoot: String?
  let principalID: String

  private enum CodingKeys: String, CodingKey {
    case formatVersion, runtimeID, caller, profileID, readOnly, transportTrace, principalID
    case project = "workspace"
    case managedProjectRoot = "managedWorkspaceRoot"
  }
}
